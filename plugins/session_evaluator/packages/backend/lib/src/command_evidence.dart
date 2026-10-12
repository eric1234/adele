part of 'session_evidence_collector.dart';

extension on _Collection {
  // Even maximally JSON-escaped 4096-unit text fits comfortably under the host's
  // 1 MiB/1000-row response limits. Do not repeat arbitrarily sized IDs per chunk.
  static const _pageChunks = 32;

  String get _captureProjection =>
      '''
${commandCaptures.columns.map((column) => 'h.$column').join(', ')},
(SELECT COUNT(*) FROM adele_command_chunks c
 WHERE c.run_id = h.run_id AND c.invocation_id = h.invocation_id) AS chunk_count,
(SELECT MIN(position) FROM adele_command_chunks c
 WHERE c.run_id = h.run_id AND c.invocation_id = h.invocation_id) AS first_position,
(SELECT MAX(position) FROM adele_command_chunks c
 WHERE c.run_id = h.run_id AND c.invocation_id = h.invocation_id) AS last_position
''';

  Map<String, Object?> _header(Map<String, Object?> row) {
    final header = Map<String, Object?>.of(row);
    final count = header.remove('chunk_count');
    final first = header.remove('first_position');
    final last = header.remove('last_position');
    validateCommandHeader(header);
    final highWater = header['high_water'] as int;
    evidenceRequire(
      count is int &&
          count == highWater &&
          (highWater == 0
              ? first == null && last == null
              : first is int && last is int && first == 1 && last == highWater),
      'Command chunks disagree with their atomically observed header extent.',
    );
    evidenceRequire(
      header['session_id'] == sessionId,
      'Foreign command Session.',
    );
    return header;
  }

  Future<Map<String, Object?>> readCommands(
    Map<String, Object?> identity,
    List<Map<String, Object?>> runs,
  ) async {
    final version = await ownerVersion(commandSchemaOwner);
    final hasCaptures = await hasTable(commandCaptures.name);
    final hasChunks = await hasTable(commandChunks.name);
    final captures = <Map<String, Object?>>[];
    if (version == null && !hasCaptures && !hasChunks) {
      return {
        'status': 'unavailable',
        'schema_version': null,
        'captures': captures,
      };
    }
    if (version != 1 || !hasCaptures || !hasChunks) {
      incompatible('Missing or incompatible Command Tools schema/version.');
    }
    await checkTable(commandCaptures);
    await checkTable(commandChunks);
    final count = await query(
      'command capture extent',
      'SELECT COUNT(*) AS row_count FROM adele_command_captures h '
          'WHERE h.session_id = :session LIMIT 1',
    );
    evidenceRequire(
      count.length == 1 &&
          count.single['row_count'] is int &&
          (count.single['row_count'] as int) >= 0,
      'Invalid command capture count.',
    );
    final expected = count.single['row_count'] as int;
    if (expected > sessionEvidenceMaxRows - rowsRead) {
      throw const SessionEvidenceFailure(
        code: 'collection_limit',
        message: 'Command captures exceed the collection row bound.',
      );
    }
    final retained = {for (final run in runs) run['id']: run};
    String? afterInvocation;
    String? afterRun;
    final seen = <(String, String)>{};
    while (true) {
      // Match the producer's primary-key order. Keep the initial query separate:
      // a nullable-cursor OR can prevent SQLite from range-seeking the index.
      final page = await query(
        'command capture headers',
        'SELECT $_captureProjection FROM adele_command_captures h '
            'WHERE h.session_id = :session '
            '${afterInvocation == null ? '' : 'AND (h.invocation_id, h.run_id) > (:after_invocation, :after_run) '}'
            'ORDER BY h.invocation_id, h.run_id LIMIT 1',
        {':after_invocation': ?afterInvocation, ':after_run': ?afterRun},
      );
      evidenceRequire(page.length <= 1, 'Invalid command header page.');
      if (page.isEmpty) break;
      final header = _header(page.single);
      final runId = header['run_id'] as String;
      final invocationId = header['invocation_id'] as String;
      evidenceRequire(
        seen.add((runId, invocationId)),
        'Duplicate command capture identity.',
      );
      evidenceRequire(
        header['environment_id'] == identity['environment_id'],
        'Command capture disagrees with Session Environment authority.',
      );
      final run = retained[runId];
      if (run == null) {
        // Read only an ownership boolean, never another Session's Run or output.
        final foreign = await query(
          'command Run association',
          'SELECT EXISTS (SELECT 1 FROM adele_product_runs '
              'WHERE id = :run AND session_id <> :session) AS foreign_run '
              'WHERE $sessionExists LIMIT 1',
          {':run': runId},
        );
        evidenceRequire(
          foreign.length == 1 && foreign.single['foreign_run'] == 0,
          'Command Run belongs to another Session.',
        );
      } else {
        final evidence = run['evidence'] as Map<String, Object?>;
        final tools =
            (evidence['tool_invocations'] as List<Map<String, Object?>>)
                .where((tool) => tool['invocation_id'] == invocationId)
                .toList();
        final changes = evidence['tool_changes'] as List<Map<String, Object?>>;
        evidenceRequire(
          tools.length == 1 &&
              tools.single['tool_id'] == commandToolId &&
              changes.any(
                (change) =>
                    change['tool_invocation_id'] == invocationId &&
                    change['kind'] == 'executionStarted',
              ),
          'Command capture has inconsistent terminal tool provenance.',
        );
        final arguments =
            jsonDecode(tools.single['canonical_arguments_json'] as String)
                as Map<String, dynamic>;
        final argv = jsonDecode(header['arguments_json'] as String) as List;
        final toolArgv = arguments['arguments'];
        evidenceRequire(
          arguments['program'] == header['program'] &&
              arguments['workingDirectory'] == header['working_directory'] &&
              arguments['timeoutSeconds'] == header['timeout_seconds'] &&
              toolArgv is List &&
              toolArgv.length == argv.length &&
              List.generate(
                argv.length,
                (i) => i,
              ).every((i) => argv[i] == toolArgv[i]),
          'Command metadata disagrees with its exact terminal invocation.',
        );
      }

      final highWater = header['high_water'] as int;
      if (highWater > sessionEvidenceMaxRows - rowsRead ||
          (header['total_code_units'] as int) >
              sessionEvidenceMaxBytes - bytesRead) {
        throw const SessionEvidenceFailure(
          code: 'collection_limit',
          message:
              'Command transcript exceeds the remaining collection budget.',
        );
      }
      final chunks = <Map<String, Object?>>[];
      var units = 0;
      while (chunks.length < highWater) {
        final rows = await query(
          'command output chunks',
          'SELECT c.position, c.stream, c.text FROM adele_command_chunks c '
              'JOIN adele_command_captures h '
              'ON h.run_id = c.run_id AND h.invocation_id = c.invocation_id '
              'WHERE h.session_id = :session AND h.run_id = :run '
              'AND h.invocation_id = :invocation AND c.position > :after '
              'AND c.position <= :high_water ORDER BY c.position LIMIT $_pageChunks',
          {
            ':run': runId,
            ':invocation': invocationId,
            ':after': chunks.length,
            ':high_water': highWater,
          },
        );
        final remaining = highWater - chunks.length;
        evidenceRequire(
          rows.length == (remaining < _pageChunks ? remaining : _pageChunks),
          'Missing committed command chunks.',
        );
        for (final chunk in rows) {
          validateCommandChunk(chunk, chunks.length + 1);
          units += (chunk['text'] as String).length;
          chunks.add(chunk);
        }
      }
      evidenceRequire(
        units == header['total_code_units'],
        'Command decoded-text extent mismatch.',
      );

      // A writer only appends and then seals. Export the earlier committed
      // header/prefix, allowing validated growth but never upgrading its state.
      final finalRows = await query(
        'command capture snapshot validation',
        'SELECT $_captureProjection FROM adele_command_captures h '
            'WHERE h.session_id = :session AND h.run_id = :run '
            'AND h.invocation_id = :invocation LIMIT 2',
        {':run': runId, ':invocation': invocationId},
      );
      evidenceRequire(
        finalRows.length == 1,
        'Command capture disappeared or duplicated during collection.',
      );
      final current = _header(finalRows.single);
      const mutable = [
        'state',
        'version',
        'high_water',
        'total_code_units',
        'termination',
        'exit_code',
        'failure',
      ];
      evidenceRequire(
        header.keys
            .where((key) => !mutable.contains(key))
            .every((key) => header[key] == current[key]),
        'Command metadata changed during collection.',
      );
      final unchanged = header.keys.every((key) => header[key] == current[key]);
      final addedChunks = (current['high_water'] as int) - highWater;
      final addedUnits = (current['total_code_units'] as int) - units;
      evidenceRequire(
        unchanged ||
            (header['state'] == 'capturing' &&
                (current['version'] as int) > (header['version'] as int) &&
                addedChunks >= 0 &&
                addedUnits >= addedChunks &&
                addedUnits <= addedChunks * commandChunkCodeUnits &&
                (addedChunks > 0 || current['state'] != 'capturing')),
        'Command snapshot regressed or changed without an append/seal.',
      );
      captures.add({
        'header': header,
        'chunks': chunks,
        'completeness': switch (header['state']) {
          'complete' => 'complete',
          'failed' => 'incomplete',
          _ => 'unsealed_liveness_unknown',
        },
        'terminal_provenance': run == null
            ? 'terminal_evidence_unavailable'
            : 'matched',
        'consistency': 'committed_high_water_snapshot',
      });
      afterInvocation = invocationId;
      afterRun = runId;
    }
    evidenceRequire(
      captures.length == expected,
      'Command capture discovery extent changed or has duplicate identities.',
    );
    return {
      'status': 'available',
      'schema_version': version,
      'captures': captures,
    };
  }

  Map<String, Object?> commandTranscriptCoverage(
    Map<String, Object?> commands,
    List<Map<String, Object?>> runs,
  ) {
    final captures = commands['captures'] as List<Map<String, Object?>>;
    final captured = {
      for (final capture in captures)
        (
          (capture['header'] as Map)['run_id'],
          (capture['header'] as Map)['invocation_id'],
        ),
    };
    final missing = <Map<String, Object?>>[];
    for (final run in runs) {
      final evidence = run['evidence'] as Map<String, Object?>;
      for (final tool
          in evidence['tool_invocations'] as List<Map<String, Object?>>) {
        if (tool['tool_id'] != commandToolId ||
            captured.contains((run['id'], tool['invocation_id']))) {
          continue;
        }
        final changes = (evidence['tool_changes'] as List<Map<String, Object?>>)
            .where(
              (change) => change['tool_invocation_id'] == tool['invocation_id'],
            );
        final started = changes.any(
          (change) => change['kind'] == 'executionStarted',
        );
        final denied = changes.any(
          (change) =>
              change['policy_decision'] == 'deny' ||
              change['approved'] == 0 ||
              const [
                'policyDenied',
                'userRejected',
              ].contains(change['outcome_disposition']),
        );
        missing.add({
          'run_id': run['id'],
          'invocation_id': tool['invocation_id'],
          'execution': started
              ? 'started'
              : denied
              ? 'not_executed'
              : 'not_observed',
        });
      }
    }
    return {
      'status': commands['status'] == 'unavailable'
          ? 'unavailable'
          : captures.any(
                  (capture) =>
                      capture['completeness'] != 'complete' ||
                      capture['terminal_provenance'] != 'matched',
                ) ||
                missing.any(
                  (invocation) => invocation['execution'] != 'not_executed',
                )
          ? 'partial'
          : 'complete_retained_captures',
      'invocations_without_capture': missing,
    };
  }
}
