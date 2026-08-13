import 'dart:async';
import 'dart:io';

import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:scripted_model_contract/scripted_model_contract.dart';
import 'package:test/test.dart';

void main() {
  test(
    'streams typed model items with bounded cancellation through AOT',
    () async {
      final String repository =
          Directory.current.parent.parent.parent.parent.path;
      final Directory artifacts = Directory(
        '$repository/.dart_tool/adele/integration/scripted-stream',
      )..createSync(recursive: true);
      final String dart = Platform.resolvedExecutable;
      final String runtime = '${File(dart).parent.path}/dartaotruntime';
      final File hostArtifact = File('${artifacts.path}/host.aot');
      final File pluginArtifact = File('${artifacts.path}/scripted.aot');
      await _compile(
        dart,
        '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact.path,
        repository,
      );
      await _compile(
        dart,
        '$repository/plugins/scripted_model/packages/backend/bin/scripted_model_backend.dart',
        pluginArtifact.path,
        repository,
      );
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: runtime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection generationA = await host.startPlugin(
        pluginId: 'dev.adele.fixture.scripted-model',
        artifactUri: pluginArtifact.uri,
      );
      final ScriptedModelFixtureServiceClient clientA =
          ScriptedModelFixtureServiceClient(generationA);
      final List<ScriptedModelStreamItem> ordinary = await clientA
          .invokeStream(_ordinaryRequest())
          .toList();
      expect(
        ordinary.map((ScriptedModelStreamItem item) => item.kind),
        <ScriptedModelStreamItemKind>[
          ScriptedModelStreamItemKind.text,
          ScriptedModelStreamItemKind.toolCall,
        ],
      );
      expect(ordinary.last.toolCall?.name, ScriptedModelProviderNames.toolName);

      await expectLater(
        clientA.invokeStream(
          const ScriptedModelRequest(messages: [], tools: []),
        ),
        emitsError(isA<ScriptedModelFailure>()),
      );
      await clientA.resetStreamProbe();

      final List<int> sequences = <int>[];
      late final StreamSubscription<ScriptedModelStreamItem> subscription;
      final Completer<void> first = Completer<void>();
      subscription = clientA.invokeStream(_longRequest()).listen((item) {
        sequences.add(item.sequence!);
        if (sequences.length == 1) {
          subscription.pause();
          first.complete();
        }
      });
      await first.future;
      final ScriptedModelStreamProbe paused = await clientA.streamProbe();
      expect(paused.advanced, 1);
      expect(paused.active, 1);
      subscription.resume();
      while (sequences.length < 3) {
        await Future<void>.delayed(Duration.zero);
      }
      await subscription.cancel().timeout(const Duration(seconds: 2));
      final ScriptedModelStreamProbe cancelled = await clientA.streamProbe();
      expect(sequences, <int>[0, 1, 2]);
      expect(cancelled.advanced, lessThanOrEqualTo(4));
      expect(cancelled.cancellations, 1);
      expect(cancelled.active, 0);

      final Completer<Object> disappeared = Completer<Object>();
      late final StreamSubscription<ScriptedModelStreamItem>
      disappearingSubscription;
      bool disappearancePaused = false;
      disappearingSubscription = clientA.invokeStream(_longRequest()).listen((
        _,
      ) {
        if (!disappearancePaused) {
          disappearancePaused = true;
          disappearingSubscription.pause();
        }
      }, onError: disappeared.complete);
      while ((await clientA.streamProbe()).active == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final Future<void> oldStreamTerminal = disappeared.future.then((_) {});
      await generationA.close();
      disappearingSubscription.resume();
      expect(await disappeared.future, isA<PluginConnectionClosed>());
      await oldStreamTerminal;
      final PluginBackendConnection generationB = await host.startPlugin(
        pluginId: 'dev.adele.fixture.scripted-model',
        artifactUri: pluginArtifact.uri,
      );
      final List<ScriptedModelStreamItem> fresh =
          await ScriptedModelFixtureServiceClient(
            generationB,
          ).invokeStream(_ordinaryRequest()).toList();
      expect(fresh, hasLength(2));
      await generationA.close();
      expect(generationB.isClosed, isFalse);
      await generationB.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

abstract final class ScriptedModelProviderNames {
  static const String toolName = 'inspect_resource';
}

ScriptedModelRequest _ordinaryRequest() => const ScriptedModelRequest(
  messages: <ScriptedModelMessage>[
    ScriptedModelMessage(
      role: ScriptedModelMessageRole.user,
      content: 'inspect',
      toolCallId: null,
      toolOutcome: null,
      toolProposal: null,
    ),
  ],
  tools: <ScriptedToolDefinition>[
    ScriptedToolDefinition(
      name: ScriptedModelProviderNames.toolName,
      description: 'fixture',
      argumentsSchema: <String, Object?>{},
    ),
  ],
);

ScriptedModelRequest _longRequest() => const ScriptedModelRequest(
  messages: <ScriptedModelMessage>[
    ScriptedModelMessage(
      role: ScriptedModelMessageRole.user,
      content: 'fixture:long-stream',
      toolCallId: null,
      toolOutcome: null,
      toolProposal: null,
    ),
  ],
  tools: <ScriptedToolDefinition>[],
);

Future<void> _compile(
  String dart,
  String entrypoint,
  String output,
  String workingDirectory,
) async {
  final ProcessResult result = await Process.run(dart, <String>[
    'compile',
    'aot-snapshot',
    entrypoint,
    '-o',
    output,
  ], workingDirectory: workingDirectory);
  if (result.exitCode != 0) throw StateError(result.stderr.toString());
}
