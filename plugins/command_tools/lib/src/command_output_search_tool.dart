import 'dart:convert';

import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:command_tools_contract/command_tools_contract.dart';

import 'command_output_search.dart';

final ToolId searchCommandOutputToolId = ToolId(
  'dev.adele.plugin.command-tools.search-command-output',
);

final ExtensionId commandOutputSearchExtensionId = ExtensionId(
  'dev.adele.plugin.command-tools.output-search',
);

/// A model-context bound, not the backend transport's whole-frame limit.
const int maximumCommandOutputSearchModelBytes = 256 * 1024;
const int maximumCommandOutputSearchModelCursorCodeUnits = 16 * 1024;

/// Shared read-only semantics. Retain [search] for the contribution generation so
/// authenticated cursors remain usable across distinct tool invocations.
ToolRegistration searchCommandOutputToolRegistration(
  CommandOutputSearch search,
) => _SearchCommandOutputExecutable(search).registration;

final class _SearchCommandOutputExecutable implements ToolExecutable {
  const _SearchCommandOutputExecutable(this.search);

  final CommandOutputSearch search;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: searchCommandOutputToolId,
      description: 'Search retained command output in the current Session.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'search_command_output',
      description:
          'Read-only search of a previous run_command capture in the current '
          'Session, including earlier Runs. Use the exact runId and '
          'toolInvocationId returned by run_command, not this search invocation. '
          'Searches retained decoded stdout then stderr, not files or a terminal '
          'screen; does not launch or rerun commands. Pattern is a case-sensitive '
          'Dart regular expression on individual LF-delimited lines (maximum '
          '256 UTF-16 units); empty patterns and literal line breaks are invalid. '
          'before/after default to 3/5 context lines (0..10); maxMatches defaults '
          'to 10 (1..10). Results distinguish hits from context and escape text '
          'as JSON. Offsets and lengths are UTF-16 units; line numbers are '
          'one-based independently per stream. Complete, failed, and interrupted '
          'captures are searchable; absent/live captures are not empty exhaustive '
          'searches. Inspect captureState, termination, exitCode, stop, '
          'exhaustive, and coverage gaps; exhaustive means retained output only, '
          'not program success or proof of complete capture. For continuation '
          'pass cursor unchanged with the same IDs, pattern, and bounds. Cursors '
          'expire on backend replacement. Model results retain bounded line '
          'excerpts; cursors over 16,384 characters are explicitly unavailable '
          'under the model-output budget, not silently clipped.',
      argumentsSchema: const {
        'type': 'object',
        'required': ['runId', 'toolInvocationId', 'pattern'],
        'properties': {
          'runId': {
            'type': 'string',
            'minLength': 1,
            'maxLength': CommandOutputSearch.maximumIdentityCodeUnits,
          },
          'toolInvocationId': {
            'type': 'string',
            'minLength': 1,
            'maxLength': CommandOutputSearch.maximumIdentityCodeUnits,
          },
          'pattern': {
            'type': 'string',
            'minLength': 1,
            'maxLength': CommandOutputSearch.maximumPatternCodeUnits,
          },
          'before': {
            'type': 'integer',
            'minimum': 0,
            'maximum': CommandOutputSearch.maximumContextLines,
            'default': CommandOutputSearch.defaultBefore,
          },
          'after': {
            'type': 'integer',
            'minimum': 0,
            'maximum': CommandOutputSearch.maximumContextLines,
            'default': CommandOutputSearch.defaultAfter,
          },
          'maxMatches': {
            'type': 'integer',
            'minimum': 1,
            'maximum': CommandOutputSearch.maximumMatches,
            'default': CommandOutputSearch.maximumMatches,
          },
          'cursor': {
            'type': 'string',
            'maxLength': CommandOutputSearch.maximumCursorCodeUnits,
          },
        },
        'additionalProperties': false,
      },
    ),
    executable: this,
  );

  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> proposed) {
    const fields = {
      'runId',
      'toolInvocationId',
      'pattern',
      'before',
      'after',
      'maxMatches',
      'cursor',
    };
    if (proposed.keys.any((key) => !fields.contains(key)) ||
        [
          'runId',
          'toolInvocationId',
          'pattern',
        ].any((key) => proposed[key] is! String) ||
        [
          'before',
          'after',
          'maxMatches',
        ].any((key) => proposed.containsKey(key) && proposed[key] is! int) ||
        (proposed.containsKey('cursor') && proposed['cursor'] is! String)) {
      throw const ToolArgumentValidationException(
        'search_command_output requires string runId, toolInvocationId, and '
        'pattern; only integer before/after/maxMatches and string cursor '
        'are optional.',
      );
    }
    // Validation has no execution context. This placeholder cannot reach reads;
    // execution always supplies the host's authoritative Session identity.
    final request = _request(proposed, 'validation');
    try {
      CommandOutputSearch.validateRequest(request);
      if ((request.cursor?.length ?? 0) >
          CommandOutputSearch.maximumCursorCodeUnits) {
        throw const ToolArgumentValidationException(
          'Search cursor is too large.',
        );
      }
    } on CommandOutputFailure catch (error) {
      throw ToolArgumentValidationException(error.message);
    }
    return CanonicalToolArguments({
      'runId': request.runId,
      'toolInvocationId': request.toolInvocationId,
      'pattern': request.pattern,
      'before': request.before,
      'after': request.after,
      'maxMatches': request.maxMatches,
      if (request.cursor != null) 'cursor': request.cursor,
    });
  }

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    final request = _request(arguments.snapshot, context.sessionId.value);
    return EffectDescription(
      effects: const [ToolEffect.resourceInspection],
      targets: [
        EffectTarget(
          uri: Uri(
            scheme: 'adele-command-output',
            pathSegments: [
              context.sessionId.value,
              request.runId,
              request.toolInvocationId,
            ],
          ),
        ),
      ],
      summary:
          'Read retained command output for Run ${jsonEncode(request.runId)}, '
          'invocation ${jsonEncode(request.toolInvocationId)} in the current '
          'Session. No command execution or output mutation.',
    );
  }

  @override
  void validateBinding() {}

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    try {
      final request = _request(arguments.snapshot, context.sessionId.value);
      final result = await search.search(request);
      yield ToolExecutionTerminal(_outcome(request, result));
    } on Object catch (error) {
      final code = error is CommandOutputFailure
          ? error.code
          : 'search_unavailable';
      final invalidRequest =
          code == 'invalid_search' || code == 'invalid_search_cursor';
      final inspected =
          code == 'association_mismatch' || code == 'stale_search_cursor';
      final cursorFailure =
          code == 'invalid_search_cursor' || code == 'stale_search_cursor';
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: invalidRequest || inspected
              ? ToolFailureKind.domain
              : ToolFailureKind.infrastructure,
          effectCertainty: invalidRequest
              ? EffectCertainty.knownNotOccurred
              : inspected
              ? EffectCertainty.knownOccurred
              : EffectCertainty.uncertain,
          modelContent: _encode({
            'runId': arguments.snapshot['runId'],
            'toolInvocationId': arguments.snapshot['toolInvocationId'],
            'pattern': arguments.snapshot['pattern'],
            'error': code,
            'message':
                'Retained command output search failed. This is not a '
                'no-match result; no command was launched or output modified.',
            if (cursorFailure)
              'recovery':
                  'The cursor is invalid, stale, or from '
                  'another backend generation. Start a fresh search without cursor '
                  'using the exact capture IDs and desired query; do not rerun '
                  'the command.',
          }),
          hostData: {'code': code},
          cause: error,
        ),
      );
    }
  }

  CommandOutputSearchRequest _request(
    Map<String, Object?> args,
    String session,
  ) => CommandOutputSearchRequest(
    sessionId: session,
    runId: args['runId']! as String,
    toolInvocationId: args['toolInvocationId']! as String,
    pattern: args['pattern']! as String,
    before: args['before'] as int? ?? CommandOutputSearch.defaultBefore,
    after: args['after'] as int? ?? CommandOutputSearch.defaultAfter,
    maxMatches:
        args['maxMatches'] as int? ?? CommandOutputSearch.maximumMatches,
    cursor: args['cursor'] as String?,
  );
}

ToolOutcome _outcome(
  CommandOutputSearchRequest request,
  CommandOutputSearchResult result,
) {
  final unavailable = switch (result.stop) {
    CommandOutputSearchStop.absent => 'capture_absent',
    CommandOutputSearchStop.capturing => 'capture_live',
    _ => null,
  };
  final summary = <String, Object?>{
    'runId': request.runId,
    'toolInvocationId': request.toolInvocationId,
    'pattern': request.pattern,
    'before': request.before,
    'after': request.after,
    'maxMatches': request.maxMatches,
    'code': ?unavailable,
    'captureState': result.captureState,
    'termination': result.termination,
    'exitCode': result.exitCode,
    'committedOutputOnly': result.committedOutputOnly,
    'matchCount': result.matchCount,
    'stop': result.stop.name,
    'reachedEnd': result.reachedEnd,
    'exhaustive': result.exhaustive,
    'contextIncomplete': result.contextIncomplete,
    'unsearchedLongLines': result.unsearchedLongLines,
    'regexTimeouts': result.regexTimeouts,
    'scannedCodeUnits': result.scannedCodeUnits,
    'storagePages': result.storagePages,
  };
  // Keep every S1 line/excerpt intact. A cursor is atomic: exceeding the smaller
  // model-context budget cannot turn it into a clipped token or fabricated end.
  final cursorTooLarge =
      (result.cursor?.length ?? 0) >
      maximumCommandOutputSearchModelCursorCodeUnits;
  final metadata = <String, Object?>{
    ...summary,
    'continuation': cursorTooLarge
        ? 'unavailableModelResultLimit'
        : result.cursor == null
        ? 'none'
        : 'available',
    'cursorTooLarge': cursorTooLarge,
  };
  final content = _encode({
    ...metadata,
    'notice': unavailable != null
        ? 'No search was performed: the capture is '
              '${result.captureState}. This is not an exhaustive no-match result. '
              'Check the exact capture IDs or wait for capture completion; '
              'do not rerun the command merely to search output.'
        : cursorTooLarge
        ? 'Cursor omitted because it exceeds the model-output cursor budget. '
              'Continuation is unavailable; this is not an exhaustive result. '
              'Start a fresh search with narrower context or a more selective '
              'pattern, not a command rerun.'
        : 'Only retained captured output was searched, not uncaptured output '
              'or files. Exhaustiveness does not establish program success. '
              'Text is escaped JSON; excerpts may be truncated independently '
              'of search coverage. Context may repeat across continuations.',
    'lines': [for (final line in result.lines) _line(line)],
    'cursor': cursorTooLarge ? null : result.cursor,
  });
  if (utf8.encode(content).length > maximumCommandOutputSearchModelBytes) {
    throw StateError('Search metadata exceeds the model-result size budget.');
  }
  return ToolOutcome(
    disposition: unavailable == null
        ? ToolOutcomeDisposition.success
        : ToolOutcomeDisposition.failure,
    failureKind: unavailable == null ? null : ToolFailureKind.domain,
    effectCertainty: EffectCertainty.knownOccurred,
    modelContent: content,
    hostData: metadata,
  );
}

Map<String, Object?> _line(CommandOutputSearchLine line) => {
  'stream': line.stream,
  'lineNumber': line.lineNumber,
  'chunk': line.chunk,
  'offset': line.offset,
  'text': line.text,
  'excerptOffset': line.excerptOffset,
  'length': line.length,
  'terminated': line.terminated,
  'isMatch': line.isMatch,
  'matchStart': line.matchStart,
  'matchEnd': line.matchEnd,
  'truncatedBefore': line.truncatedBefore,
  'truncatedAfter': line.truncatedAfter,
};

String _encode(Map<String, Object?> value) =>
    jsonEncode(value).replaceAllMapped(
      RegExp('[\x7f-\x9f\u2028\u2029]'),
      (match) =>
          '\\u${match[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
    );
