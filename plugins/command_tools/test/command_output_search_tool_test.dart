import 'dart:convert';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart' show ModelToolComposer;
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:test/test.dart';

import 'support/command_storage.dart';

void main() {
  late CommandTestStorage storage;
  late CommandTranscriptStore store;
  late CommandOutputSearch engine;
  late ToolRegistration registration;

  setUp(() {
    storage = CommandTestStorage();
    store = CommandTranscriptStore(storage);
    engine = CommandOutputSearch(store);
    registration = searchCommandOutputToolRegistration(engine);
  });
  tearDown(() async {
    await store.close();
    storage.close();
  });

  Future<ToolOutcome> execute({
    Map<String, Object?> arguments = const {},
    ToolExecutionContext? context,
    ToolRegistration? tool,
  }) async {
    final executable = (tool ?? registration).executable;
    final observation = await collectToolExecution(
      executable.execute(
        await executable.validateAndNormalize({..._arguments, ...arguments}),
        context ?? _context(),
      ),
    );
    expect(observation.progress, isEmpty);
    return observation.outcome;
  }

  test('exact public identity, narrow schema, and shared defaults', () async {
    expect(registration.definition.id, searchCommandOutputToolId);
    expect(searchCommandOutputToolId, isNot(runCommandToolId));
    expect(commandOutputSearchExtensionId, isNot(commandToolsExtensionId));
    expect(registration.modelDefinition.alias, 'search_command_output');
    final schema = registration.modelDefinition.argumentsSchema;
    expect(schema['required'], ['runId', 'toolInvocationId', 'pattern']);
    expect(schema['additionalProperties'], isFalse);
    expect((schema['properties']! as Map).keys, [
      'runId',
      'toolInvocationId',
      'pattern',
      'before',
      'after',
      'maxMatches',
      'cursor',
    ]);
    final canonical = await registration.executable.validateAndNormalize(
      _arguments,
    );
    expect(canonical.snapshot, {
      ..._arguments,
      'before': 3,
      'after': 5,
      'maxMatches': 10,
    });
    expect(storage.schemaChecks, 0);
    expect(storage.queries, 0);
    expect(storage.transactions, 0);
  });

  test(
    'rejects unknown authority selectors, malformed shapes, and S1 bounds',
    () async {
      for (final proposed in <Map<String, Object?>>[
        {},
        {'runId': 'run', 'toolInvocationId': 'invocation'},
        for (final field in [
          'sessionId',
          'environmentId',
          'path',
          'stream',
          'limit',
        ])
          {..._arguments, field: 'forbidden'},
        for (final field in ['runId', 'toolInvocationId', 'pattern'])
          for (final value in [null, 7, '', 'x' * 1025])
            {..._arguments, field: value},
        for (final pattern in [
          '[',
          '\x00',
          '\n',
          '\r',
          '\u2028',
          '\u2029',
          'x' * 257,
        ])
          {..._arguments, 'pattern': pattern},
        for (final field in ['before', 'after'])
          for (final value in [null, '1', 1.0, -1, 11])
            {..._arguments, field: value},
        for (final value in [null, '1', 1.0, 0, 11])
          {..._arguments, 'maxMatches': value},
        for (final value in [
          null,
          7,
          'x' * (CommandOutputSearch.maximumCursorCodeUnits + 1),
        ])
          {..._arguments, 'cursor': value},
      ]) {
        await expectLater(
          () => registration.executable.validateAndNormalize(proposed),
          throwsA(isA<ToolArgumentValidationException>()),
          reason: proposed.keys.join(','),
        );
      }
      expect(storage.schemaChecks, 0);
      expect(storage.queries, 0);
      expect(storage.transactions, 0);
    },
  );

  test(
    'description is certain resource inspection without storage access',
    () async {
      final effects = await registration.executable.describe(
        await registration.executable.validateAndNormalize(_arguments),
        _context(),
      );
      registration.executable.validateBinding();
      expect(effects.effects, {ToolEffect.resourceInspection});
      expect(effects.uncertainty, EffectUncertainty.none);
      expect(effects.targets.single.uri.scheme, 'adele-command-output');
      expect(effects.targets.single.uri.pathSegments, [
        'session',
        'run',
        'invocation',
      ]);
      expect(
        effects.summary,
        contains('No command execution or output mutation'),
      );
      expect(storage.schemaChecks, 0);
      expect(storage.queries, 0);
      expect(storage.transactions, 0);
    },
  );

  test(
    'native search registration is independent and retires exactly',
    () async {
      final extensions = ExtensionRegistry();
      final plugin = CommandToolsPlugin(transcripts: store);
      final activation = plugin.activateSearch(extensions);
      final context = _NoServices();
      final tools = (await ModelToolComposer(
        extensions,
      ).materialize(context)).materialize();
      final tool = tools.tools.single;
      expect(tool.modelDefinition.alias, 'search_command_output');
      expect(context.requests, 0);
      expect(storage.schemaChecks, 0);
      expect(
        extensions.discover(modelToolContributions).single.id,
        commandOutputSearchExtensionId,
      );
      expect(
        () => plugin.activateSearch(extensions),
        throwsA(isA<ExtensionRegistrationException>()),
      );
      final deferred = tool.executable.execute(
        await tool.executable.validateAndNormalize(_arguments),
        _context(),
      );
      await activation.close();
      expect(
        tool.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      await expectLater(deferred, emitsError(isA<StaleToolBindingException>()));
      expect(extensions.discover(modelToolContributions), isEmpty);
      expect(storage.queries, 0);
      final replacement = plugin.activateSearch(extensions);
      await replacement.close();
    },
  );

  test('missing native storage fails explicit search registration', () {
    final extensions = ExtensionRegistry();
    expect(
      () => const CommandToolsPlugin().activateSearch(extensions),
      throwsStateError,
    );
    expect(extensions.discover(modelToolContributions), isEmpty);
  });

  test(
    'default context, independent pipes, exact S1 locators and escaped text',
    () async {
      final writer = await _begin(store);
      await _append(
        writer,
        'zero\none\ntwo\nhit\r\x1b[31m\x00\x85\u2028\u2029\u{1f600}\nfour\nfive\nsix\nseven\neight\nnine\n',
      );
      await _append(writer, 'error hit\ntail', stderr: true);
      await writer.seal(_completed(exitCode: 17));
      final outcome = await execute();
      final body = _body(outcome);
      final lines = _lines(body);
      expect(outcome.disposition, ToolOutcomeDisposition.success);
      expect(outcome.effectCertainty, EffectCertainty.knownOccurred);
      expect(body['pattern'], 'hit');
      expect(body['before'], 3);
      expect(body['after'], 5);
      expect(body['maxMatches'], 10);
      expect(body['captureState'], 'complete');
      expect(body['termination'], 'exited');
      expect(body['exitCode'], 17);
      expect(body['matchCount'], 2);
      expect(body['exhaustive'], isTrue);
      expect(body['committedOutputOnly'], isFalse);
      expect(body['stop'], 'end');
      expect(body['cursor'], isNull);
      expect(body['continuation'], 'none');
      expect(
        lines
            .where((line) => line['stream'] == 'stdout')
            .map((line) => line['lineNumber']),
        [1, 2, 3, 4, 5, 6, 7, 8, 9],
      );
      final hit = lines.singleWhere(
        (line) => line['stream'] == 'stdout' && line['isMatch'] == true,
      );
      expect(hit, {
        'stream': 'stdout',
        'lineNumber': 4,
        'chunk': 1,
        'offset': 13,
        'text': 'hit\r\x1b[31m\x00\x85\u2028\u2029\u{1f600}',
        'excerptOffset': 0,
        'length': 15,
        'terminated': true,
        'isMatch': true,
        'matchStart': 0,
        'matchEnd': 3,
        'truncatedBefore': false,
        'truncatedAfter': false,
      });
      for (final control in [
        '\x00',
        '\r',
        '\x1b',
        '\x85',
        '\u2028',
        '\u2029',
      ]) {
        expect(outcome.modelContent, isNot(contains(control)));
      }
      expect(outcome.modelContent, contains(r'\u001b'));
      expect(outcome.hostData, isNot(contains('lines')));
      expect(outcome.hostData, isNot(contains('cursor')));
      expect(outcome.hostData, isNot(contains('stdout')));
    },
  );

  test(
    'matches omitted preview middle with unchanged bounded excerpts',
    () async {
      final text = '${'x' * 9000}hit${'y' * 5000}';
      await _capture(store, text);
      final body = _body(await execute());
      final line = _lines(body).single;
      expect(line['text'], contains('hit'));
      expect(
        (line['text']! as String).length,
        CommandOutputSearch.maximumExcerptCodeUnits,
      );
      expect(line['matchStart'], 9000);
      expect(line['matchEnd'], 9003);
      expect(line['length'], text.length);
      expect(line['truncatedBefore'], isTrue);
      expect(line['truncatedAfter'], isTrue);
      expect(line['terminated'], isFalse);
      expect(body['exhaustive'], isTrue);
    },
  );

  test(
    'case sensitive and zero-width patterns use the engine semantics',
    () async {
      await _capture(store, 'HIT\nhit\n');
      expect(_body(await execute())['matchCount'], 1);
      final body = _body(
        await execute(arguments: {'pattern': '^', 'before': 0, 'after': 0}),
      );
      expect(body['matchCount'], 2);
      expect(
        _lines(body).map((line) => [line['matchStart'], line['matchEnd']]),
        [
          [0, 0],
          [0, 0],
        ],
      );
    },
  );

  test(
    'absent, capturing, complete empty, and exhaustive no-match differ',
    () async {
      final absent = await execute();
      expect(absent.disposition, ToolOutcomeDisposition.failure);
      expect(absent.failureKind, ToolFailureKind.domain);
      expect(absent.effectCertainty, EffectCertainty.knownOccurred);
      expect(absent.hostData['code'], 'capture_absent');
      var body = _body(absent);
      expect(body['captureState'], 'absent');
      expect(body['stop'], 'absent');
      expect(body['exhaustive'], isFalse);
      expect(body['reachedEnd'], isFalse);
      expect(body['matchCount'], 0);
      expect(storage.transactions, 0);
      final writer = await _begin(store);
      final capturing = await execute();
      expect(capturing.disposition, ToolOutcomeDisposition.failure);
      expect(capturing.failureKind, ToolFailureKind.domain);
      expect(capturing.hostData['code'], 'capture_live');
      body = _body(capturing);
      expect(body['captureState'], 'capturing');
      expect(body['stop'], 'capturing');
      expect(body['exhaustive'], isFalse);
      expect(body['cursor'], isNull);
      await writer.seal(_completed());
      body = _body(await execute());
      expect(body['captureState'], 'complete');
      expect(body['stop'], 'end');
      expect(body['exhaustive'], isTrue);
      expect(body['lines'], isEmpty);
      await _capture(store, 'not matching\n', run: 'other-run');
      body = _body(await execute(arguments: {'runId': 'other-run'}));
      expect(body['stop'], 'end');
      expect(body['exhaustive'], isTrue);
      expect(body['matchCount'], 0);
    },
  );

  for (final state in ['complete', 'failed', 'interrupted']) {
    test(
      'fresh reader searches $state historical Run without mutations',
      () async {
        final writer = await _begin(store);
        await _append(writer, 'hit retained\n');
        if (state == 'complete') await writer.seal(_completed(exitCode: 23));
        if (state == 'failed') {
          await writer.fail('secret failure detail', termination: 'timedOut');
        }
        await store.close();
        final fresh = CommandTranscriptStore(storage);
        addTearDown(fresh.close);
        final before = _storedRows(storage);
        final transactions = storage.transactions;
        storage.beforeTransaction = (_) => fail('Search may not write.');
        final body = _body(
          await execute(
            tool: searchCommandOutputToolRegistration(
              CommandOutputSearch(fresh),
            ),
            context: _context(
              run: 'later-run',
              invocation: 'search-invocation',
            ),
          ),
        );
        expect(body['runId'], 'run');
        expect(body['toolInvocationId'], 'invocation');
        expect(body['captureState'], state);
        expect(body['committedOutputOnly'], state != 'complete');
        expect(body['exhaustive'], isTrue);
        expect(_lines(body).single['text'], 'hit retained');
        expect(
          body['termination'],
          state == 'complete'
              ? 'exited'
              : state == 'failed'
              ? 'timedOut'
              : null,
        );
        expect(body['exitCode'], state == 'complete' ? 23 : null);
        expect(jsonEncode(body), isNot(contains('secret failure detail')));
        expect(_storedRows(storage), before);
        expect(storage.transactions, transactions);
        expect(fresh.activeCaptureCount, 0);
        expect(fresh.observerCount, 0);
      },
    );
  }

  test(
    'host Session is authoritative and exact Run/invocation pairs isolate output',
    () async {
      await _capture(store, 'hit original\n');
      await _capture(store, 'hit reused invocation\n', run: 'second-run');
      await _capture(store, 'hit sibling\n', invocation: 'sibling');
      final wrongSession = await execute(context: _context(session: 'other'));
      expect(wrongSession.disposition, ToolOutcomeDisposition.failure);
      expect(wrongSession.failureKind, ToolFailureKind.domain);
      expect(wrongSession.effectCertainty, EffectCertainty.knownOccurred);
      expect(wrongSession.hostData['code'], 'association_mismatch');
      expect(wrongSession.modelContent, isNot(contains('hit original')));
      for (final args in [
        {'runId': 'missing'},
        {'toolInvocationId': 'missing'},
      ]) {
        expect(_body(await execute(arguments: args))['captureState'], 'absent');
      }
      expect(
        _lines(
          _body(await execute(arguments: {'runId': 'second-run'})),
        ).single['text'],
        'hit reused invocation',
      );
      expect(
        _lines(
          _body(await execute(arguments: {'toolInvocationId': 'sibling'})),
        ).single['text'],
        'hit sibling',
      );
      expect(_lines(_body(await execute())).single['text'], 'hit original');
    },
  );

  test(
    'cursor continues across invocations and materializations without rereading old hits',
    () async {
      await _capture(store, 'before\nhit one\nbetween\nhit two\nafter\n');
      final before = _storedRows(storage);
      var body = _body(await execute(arguments: {'maxMatches': 1}));
      final hits = <Object?>[];
      while (true) {
        hits.addAll(
          _lines(body)
              .where((line) => line['isMatch'] == true)
              .map((line) => line['text']),
        );
        if (body['cursor'] == null) break;
        expect(body['continuation'], 'available');
        body = _body(
          await execute(
            arguments: {'maxMatches': 1, 'cursor': body['cursor']},
            context: _context(
              run: 'later-run',
              invocation: 'search-${hits.length}',
            ),
            tool: searchCommandOutputToolRegistration(engine),
          ),
        );
      }
      expect(hits, ['hit one', 'hit two']);
      expect(body['reachedEnd'], isTrue);
      expect(body['exhaustive'], isTrue);
      expect(_storedRows(storage), before);
      expect(store.observerCount, 0);
    },
  );

  test(
    'foreign, malformed, changed-query and stale cursors fail, never empty success',
    () async {
      await _capture(store, 'hit one\nhit two\n');
      final first = _body(await execute(arguments: {'maxMatches': 1}));
      final cursor = first['cursor'];
      expect(cursor, isA<String>());
      for (final args in [
        {'cursor': 'broken'},
        {'cursor': '${cursor}x'},
        {'cursor': cursor, 'pattern': 'other'},
        {'cursor': cursor, 'runId': 'other-run'},
        {'cursor': cursor, 'toolInvocationId': 'sibling'},
        {'cursor': cursor, 'before': 0},
        {'cursor': cursor, 'after': 0},
        {'cursor': cursor, 'maxMatches': 2},
      ]) {
        final queries = storage.queries;
        final outcome = await execute(arguments: {'maxMatches': 1, ...args});
        expect(outcome.disposition, ToolOutcomeDisposition.failure);
        expect(outcome.failureKind, ToolFailureKind.domain);
        expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
        expect(
          _body(outcome)['recovery'],
          contains('fresh search without cursor'),
        );
        expect(outcome.hostData['code'], 'invalid_search_cursor');
        expect(_body(outcome), isNot(contains('lines')));
        expect(storage.queries, queries);
      }
      final foreign = await execute(
        arguments: {'maxMatches': 1, 'cursor': cursor},
        tool: searchCommandOutputToolRegistration(CommandOutputSearch(store)),
      );
      expect(foreign.hostData['code'], 'invalid_search_cursor');
      final wrongSession = await execute(
        arguments: {'maxMatches': 1, 'cursor': cursor},
        context: _context(session: 'other'),
      );
      expect(wrongSession.hostData['code'], 'invalid_search_cursor');
      storage.database.execute(
        'UPDATE adele_command_captures SET version=version+1',
      );
      final stale = await execute(
        arguments: {'maxMatches': 1, 'cursor': cursor},
      );
      expect(stale.disposition, ToolOutcomeDisposition.failure);
      expect(stale.failureKind, ToolFailureKind.domain);
      expect(stale.effectCertainty, EffectCertainty.knownOccurred);
      expect(stale.hostData['code'], 'stale_search_cursor');
    },
  );

  test('unsearched long lines are not exhaustive no-match results', () async {
    await _capture(
      store,
      'hit${'x' * CommandOutputSearch.maximumLineCodeUnits}\n',
    );
    final body = _body(await execute());
    expect(body['stop'], 'end');
    expect(body['matchCount'], 0);
    expect(body['reachedEnd'], isTrue);
    expect(body['exhaustive'], isFalse);
    expect(body['unsearchedLongLines'], 1);
    expect(body['regexTimeouts'], 0);
  });

  test(
    'regex timeout reports the coverage gap and usable continuation',
    () async {
      await _capture(store, '${'a' * 10000}!\na\n');
      final body = _body(
        await execute(
          arguments: {'pattern': r'^(a+)+$', 'before': 0, 'after': 0},
        ),
      );
      expect(body['stop'], 'regexLimit');
      expect(body['regexTimeouts'], 1);
      expect(body['exhaustive'], isFalse);
      expect(body['cursor'], isNotNull);
      final resumed = _body(
        await execute(
          arguments: {
            'pattern': r'^(a+)+$',
            'before': 0,
            'after': 0,
            'cursor': body['cursor'],
          },
        ),
      );
      expect(resumed['matchCount'], 1);
      expect(resumed['regexTimeouts'], 1);
      expect(resumed['reachedEnd'], isTrue);
      expect(resumed['exhaustive'], isFalse);
    },
  );

  for (final failure in ['backing', 'read', 'corruption', 'closed']) {
    test(
      '$failure is infrastructure failure, not an absent or no-match result',
      () async {
        if (failure == 'backing') {
          storage.beforeSchema = () =>
              throw StateError('private backing detail');
        } else {
          await _capture(store, 'hit\n');
          if (failure == 'read') {
            storage.afterQuery = (_, _) =>
                throw StateError('private read detail');
          }
          if (failure == 'corruption') {
            storage.database.execute('DELETE FROM adele_command_chunks');
          }
          if (failure == 'closed') await store.close();
        }
        final outcome = await execute();
        expect(outcome.disposition, ToolOutcomeDisposition.failure);
        expect(outcome.failureKind, ToolFailureKind.infrastructure);
        expect(outcome.effectCertainty, EffectCertainty.uncertain);
        expect(outcome.modelContent, contains('not a no-match result'));
        expect(outcome.modelContent, isNot(contains('private')));
        expect(_body(outcome)['runId'], _arguments['runId']);
        expect(
          _body(outcome)['toolInvocationId'],
          _arguments['toolInvocationId'],
        );
        expect(_body(outcome)['pattern'], _arguments['pattern']);
        expect(_body(outcome), isNot(contains('lines')));
        expect(outcome.hostData, isNot(contains('captureState')));
      },
    );
  }

  test(
    'oversized authenticated cursor is omitted honestly, never clipped or duplicated',
    () async {
      await _capture(
        store,
        '${List.filled(10, '${'\x00' * 512}\n').join()}hit one\nhit two\n',
      );
      const request = CommandOutputSearchRequest(
        sessionId: 'session',
        runId: 'run',
        toolInvocationId: 'invocation',
        pattern: 'hit',
        before: 10,
        after: 0,
        maxMatches: 1,
      );
      final raw = await engine.search(request);
      expect(
        raw.cursor!.length,
        greaterThan(maximumCommandOutputSearchModelCursorCodeUnits),
      );
      final outcome = await execute(
        arguments: {'before': 10, 'after': 0, 'maxMatches': 1},
      );
      final body = _body(outcome);
      expect(body['cursor'], isNull);
      expect(body['cursorTooLarge'], isTrue);
      expect(body['continuation'], 'unavailableModelResultLimit');
      expect(body['stop'], raw.stop.name);
      expect(body['matchCount'], 1);
      expect(body['reachedEnd'], isFalse);
      expect(body['exhaustive'], isFalse);
      expect(
        _lines(body).map((line) => line['text']),
        raw.lines.map((line) => line.text),
      );
      expect(body['notice'], contains('fresh search'));
      expect(body['notice'], contains('not a command rerun'));
      expect(outcome.hostData, isNot(contains('cursor')));
      expect(outcome.modelContent, isNot(contains(raw.cursor!)));
      expect(
        utf8.encode(outcome.modelContent).length,
        lessThanOrEqualTo(maximumCommandOutputSearchModelBytes),
      );
    },
  );

  test(
    'worst-case escaped text and full context fit model and wire budgets intact',
    () async {
      final text = List.generate(
        10,
        (_) => List.generate(
          21,
          (i) => i == 10 ? 'hit\n' : '${'\x00' * 78}\n',
        ).join(),
      ).join();
      await _capture(store, text);
      final outcome = await execute(arguments: {'before': 10, 'after': 10});
      final body = _body(outcome);
      expect(outcome.disposition, ToolOutcomeDisposition.success);
      expect(body['matchCount'], 10);
      expect(_lines(body), hasLength(210));
      expect(
        _lines(body)
            .where((line) => line['isMatch'] == false)
            .every((line) => line['text'] == '\x00' * 78),
        isTrue,
      );
      expect(utf8.encode(outcome.modelContent).length, greaterThan(64 * 1024));
      expect(
        utf8.encode(outcome.modelContent).length,
        lessThanOrEqualTo(maximumCommandOutputSearchModelBytes),
      );
      // Include the second JSON escaping layer and all terminal outcome fields.
      final frame = jsonEncode({
        'type': 'streamData',
        'id': 'search',
        'value': {
          'kind': 'terminal',
          'progress': null,
          'outcome': {
            'disposition': outcome.disposition.name,
            'failureKind': null,
            'effectCertainty': outcome.effectCertainty.name,
            'modelContent': outcome.modelContent,
            'hostData': outcome.hostData,
            'hostDiagnostic': outcome.hostDiagnostic,
          },
        },
      });
      expect(utf8.encode(frame).length, lessThan(8 * 1024 * 1024));
      expect(outcome.hostData, isNot(contains('lines')));
      expect(outcome.hostData, isNot(contains('cursor')));
    },
  );
}

const _arguments = <String, Object?>{
  'runId': 'run',
  'toolInvocationId': 'invocation',
  'pattern': 'hit',
};

ToolExecutionContext _context({
  String session = 'session',
  String run = 'current-run',
  String invocation = 'search-invocation',
}) => ToolExecutionContext(
  sessionId: SessionId(session),
  runId: RunId(run),
  toolInvocationId: invocation,
);

Map<String, Object?> _body(ToolOutcome outcome) =>
    jsonDecode(outcome.modelContent) as Map<String, Object?>;
List<Map<String, Object?>> _lines(Map<String, Object?> body) =>
    (body['lines']! as List).cast<Map<String, Object?>>();

List<Object?> _storedRows(CommandTestStorage storage) => [
  for (final table in ['adele_command_captures', 'adele_command_chunks'])
    storage.database
        .select('SELECT * FROM $table ORDER BY rowid')
        .map((row) => Map<String, Object?>.from(row))
        .toList(),
];

Future<CommandCaptureWriter> _begin(
  CommandTranscriptStore store, {
  String run = 'run',
  String invocation = 'invocation',
}) => store.begin(
  context: _context(run: run, invocation: invocation),
  environmentId: 'environment',
  request: EnvironmentForegroundProcessRequest(
    program: 'fixture',
    arguments: [],
    relativeWorkingDirectory: '',
    timeoutSeconds: 30,
  ),
);

Future<void> _capture(
  CommandTranscriptStore store,
  String text, {
  String run = 'run',
  String invocation = 'invocation',
}) async {
  final writer = await _begin(store, run: run, invocation: invocation);
  await _append(writer, text);
  await writer.seal(_completed());
}

Future<void> _append(
  CommandCaptureWriter writer,
  String text, {
  bool stderr = false,
}) async {
  for (var offset = 0; offset < text.length;) {
    var end = offset + 16384;
    if (end > text.length) end = text.length;
    if (end < text.length &&
        text.codeUnitAt(end - 1) >= 0xd800 &&
        text.codeUnitAt(end - 1) <= 0xdbff) {
      end--;
    }
    await writer.append(
      EnvironmentProcessOutput(
        stream: stderr
            ? EnvironmentProcessOutputStream.stderr
            : EnvironmentProcessOutputStream.stdout,
        text: text.substring(offset, end),
      ),
    );
    offset = end;
  }
}

EnvironmentProcessCompleted _completed({int exitCode = 0}) =>
    EnvironmentProcessCompleted(
      termination: EnvironmentProcessTermination.exited,
      exitCode: exitCode,
      stdoutTruncated: false,
      stderrTruncated: false,
    );

final class _NoServices implements ModelToolHostContext {
  int requests = 0;
  @override
  SessionId get sessionId => SessionId('session');
  @override
  Future<T> requireHostService<T extends Object>() async {
    requests++;
    throw StateError('Search may not request host services.');
  }
}
