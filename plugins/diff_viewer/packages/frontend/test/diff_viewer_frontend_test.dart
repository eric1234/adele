import 'dart:async';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/backend_invocation_bridge.dart';
import 'package:adele_desktop/frontend/environment_capability_access_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/session_presentation_lifecycle_bridge.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../../app/tool/diff_viewer_frontend_compiler.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late PreparedFrontend frontend;
  late _Port port;
  late SessionPresentationLifecycleBridge lifecycle;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('diff-viewer-eval-');
    artifact = File('${temporary.path}/frontend.evc');
    await compileDiffViewerFrontend(
      repositoryRoot: Directory.current.parent.parent.parent.parent,
      sdkPath: diffViewerDartSdk(),
      artifact: artifact,
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async {
    frontend = await PreparedFrontend.load(artifact);
    port = _Port();
    lifecycle = SessionPresentationLifecycleBridge(isActive: () => true);
  });
  tearDown(() async {
    frontend.invalidate();
    await port.dispatcher.close();
  });

  Future<void> mount(WidgetTester tester, {Key? key}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: frontend.createPresentation(
            key: key,
            library: diffViewerFrontendLibrary,
            entrypoint: 'buildDiffPane',
            createBridge: () => PreparedFrontendBridges([
              MainContentBridge(
                context: const {'sessionId': 'canonical'},
                isActive: () => true,
              ),
              lifecycle,
              port,
            ]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'actual generated eval snapshot renders unified lines and releases access',
    (tester) async {
      port.service.value = _snapshot();
      await mount(tester);
      expect(find.text('notes.txt  [modified]'), findsOneWidget);
      expect(find.text('@@ -3,2 +3,2 @@'), findsOneWidget);
      expect(find.text('   3    3  shared'), findsOneWidget);
      expect(find.text('   4      -before'), findsOneWidget);
      expect(find.text('        4 +after'), findsOneWidget);
      expect(find.text(r'\ No newline at end of file'), findsOneWidget);
      expect(port.resolutions, 1);
      expect(port.service.calls, 1);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1']);
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets(
    'loading, clean, unavailable, error and manual retry are truthful',
    (tester) async {
      final held = Completer<ChangeSetSnapshot>();
      port.service.pending = held.future;
      await mount(tester);
      expect(port.service.calls, 1);
      expect(find.text('Loading unstaged changes...'), findsOneWidget);
      expect(port.handles, hasLength(1));
      held.complete(ChangeSetSnapshot(files: []));
      await tester.pumpAndSettle();
      expect(find.text('No unstaged changes.'), findsOneWidget);
      expect(port.handles, isEmpty);
      port.available = false;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(
        find.text('Diff unavailable for this Environment.'),
        findsOneWidget,
      );
      expect(port.service.calls, 1);
      port.available = true;
      port.service.failure = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Unable to load unstaged changes.'), findsOneWidget);
      expect(find.textContaining('private failure'), findsNothing);
      expect(port.handles, isEmpty);
      port.service.failure = false;
      port.service.value = _snapshot();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('notes.txt  [modified]'), findsOneWidget);
      expect(port.resolutions, 4);
      expect(port.service.calls, 3);
      expect(port.handles, isEmpty);
    },
  );

  testWidgets(
    'generated eval decoder rejects malformed nested DTOs and retry resolves anew',
    (tester) async {
      port.wireResponse = {
        'files': [
          {
            'relativePath': 'invalid.txt',
            'changeKind': 'modified',
            'contentStatus': 'text',
            'detail': null,
            'hunks': [
              {
                'oldStart': 1,
                'oldCount': 1,
                'newStart': 1,
                'newCount': 1,
                'lines': [
                  {'kind': 'addition', 'text': 'invalid', 'noNewline': 'false'},
                ],
              },
            ],
          },
        ],
      };
      await mount(tester);
      expect(find.text('Unable to load unstaged changes.'), findsOneWidget);
      expect(port.handles, isEmpty);
      port.wireResponse = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('No unstaged changes.'), findsOneWidget);
      expect(port.resolutions, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new refresh releases old access and ignores a late older snapshot',
    (tester) async {
      final old = Completer<ChangeSetSnapshot>();
      port.service.pending = old.future;
      await mount(tester);
      expect(port.service.calls, 1);
      port.service.value = _snapshot(path: 'new.txt');
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('new.txt  [modified]'), findsOneWidget);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1', 'handle-2']);
      old.complete(_snapshot(path: 'obsolete.txt'));
      await tester.pumpAndSettle();
      expect(find.text('new.txt  [modified]'), findsOneWidget);
      expect(find.textContaining('obsolete.txt'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'departure releases pending access without waiting and remains retryable',
    (tester) async {
      final old = Completer<ChangeSetSnapshot>();
      port.service.pending = old.future;
      await mount(tester);
      expect(port.service.calls, 1);
      await lifecycle.prepareToDeactivate();
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1']);
      old.complete(_snapshot(path: 'departed.txt'));
      await tester.pumpAndSettle();
      expect(find.textContaining('departed.txt'), findsNothing);
      // A sibling can refuse navigation after this pane's accepted hook.
      port.service.value = _snapshot(path: 'retry.txt');
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('retry.txt  [modified]'), findsOneWidget);
    },
  );

  testWidgets(
    'dispose releases held snapshot and old completion never enters a new view',
    (tester) async {
      final old = Completer<ChangeSetSnapshot>();
      port.service.pending = old.future;
      await mount(tester);
      final previous = port;
      await tester.pumpWidget(const SizedBox());
      expect(previous.handles, isEmpty);
      expect(previous.releases, ['handle-1']);
      port = _Port()..service.value = _snapshot(path: 'current.txt');
      lifecycle = SessionPresentationLifecycleBridge(isActive: () => true);
      await mount(tester, key: const ValueKey('new-presentation'));
      old.complete(_snapshot(path: 'obsolete.txt'));
      await tester.pumpAndSettle();
      await previous.dispatcher.close();
      expect(find.text('current.txt  [modified]'), findsOneWidget);
      expect(find.textContaining('obsolete.txt'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'superseded pending resolution releases its late handle without reading',
    (tester) async {
      final resolution = Completer<void>();
      port.resolving = resolution.future;
      await mount(tester);
      expect(port.resolutions, 1);
      expect(port.service.calls, 0);
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(port.service.calls, 1);
      expect(find.text('No unstaged changes.'), findsOneWidget);
      resolution.complete();
      await tester.pumpAndSettle();
      expect(port.service.calls, 1);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-2', 'handle-1']);
    },
  );

  testWidgets(
    'non-text statuses are explicit and large text builds rows lazily',
    (tester) async {
      port.service.value = ChangeSetSnapshot(
        files: [
          for (final status in [
            'binary',
            'unsupported',
            'oversized',
            'conflicted',
          ])
            ChangedFile(
              relativePath: '$status.dat',
              changeKind: 'unsupported',
              contentStatus: status,
              detail: 'Not displayed: $status',
              hunks: [],
            ),
        ],
      );
      await mount(tester);
      for (final status in [
        'binary',
        'unsupported',
        'oversized',
        'conflicted',
      ]) {
        expect(find.text(status), findsOneWidget);
        expect(find.text('Not displayed: $status'), findsOneWidget);
      }
      port.service.value = ChangeSetSnapshot(
        files: [
          ChangedFile(
            relativePath: 'large.txt',
            changeKind: 'added',
            contentStatus: 'text',
            detail: null,
            hunks: [
              DiffHunk(
                oldStart: 0,
                oldCount: 0,
                newStart: 1,
                newCount: 2000,
                lines: List.generate(
                  2000,
                  (index) => DiffLine(
                    kind: 'addition',
                    text: 'line-$index',
                    noNewline: false,
                  ),
                ),
              ),
            ],
          ),
        ],
      );
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.textContaining('+line-0'), findsOneWidget);
      expect(find.textContaining('+line-1999'), findsNothing);
      expect(tester.widgetList(find.byType(Text)).length, lessThan(100));
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

ChangeSetSnapshot _snapshot({String path = 'notes.txt'}) => ChangeSetSnapshot(
  files: [
    ChangedFile(
      relativePath: path,
      changeKind: 'modified',
      contentStatus: 'text',
      detail: null,
      hunks: [
        DiffHunk(
          oldStart: 3,
          oldCount: 2,
          newStart: 3,
          newCount: 2,
          lines: const [
            DiffLine(kind: 'context', text: 'shared', noNewline: false),
            DiffLine(kind: 'deletion', text: 'before', noNewline: false),
            DiffLine(kind: 'addition', text: 'after', noNewline: true),
          ],
        ),
      ],
    ),
  ],
);

class _Service implements ChangeSetSourceService {
  ChangeSetSnapshot value = ChangeSetSnapshot(files: []);
  Future<ChangeSetSnapshot>? pending;
  bool failure = false;
  int calls = 0;
  @override
  Future<ChangeSetSnapshot> snapshotUnstaged() async {
    calls++;
    final held = pending;
    pending = null;
    if (held != null) return held;
    if (failure) {
      throw const ChangeSetFailure(code: 'failed', message: 'private failure');
    }
    return value;
  }
}

// Test-only request port: real generated native/eval codecs and production
// settlement, but deliberately no host revocation so the pane's epoch is tested.
// Canonical contextual authority and AOT are covered by the app integration.
class _Port extends EnvironmentCapabilityAccessDeclarations
    implements PreparedFrontendBridge, AdeleRequestChannel {
  final _Service service = _Service();
  late final dispatcher = ChangeSetSourceServiceDispatcher(
    service,
    concurrent: true,
  );
  final Set<String> handles = {};
  final List<String> releases = [];
  final Zone zone = Zone.current;
  int resolutions = 0;
  bool available = true;
  bool active = true;
  Map<String, Object?>? wireResponse;
  Future<void>? resolving;
  late final transport = BackendInvocationBridge(
    channelFor: (handle) => handles.contains(handle) ? this : null,
    validateAdmission: () {},
    validateSettlement: () {},
    isPresentationActive: () => active,
  );

  @override
  void configureForRuntime(Runtime runtime) {
    const library = 'package:adele_ui/environment_capability_bridge.dart';
    runtime
      ..registerBridgeFunc(library, 'resolveEnvironmentCapabilityProvider', (
        _,
        _,
        args,
      ) {
        expect(args[0]!.$value, changeSetSourceCapability.id.value);
        expect(args[1]!.$value, 1);
        expect(args[2]!.$value, changeSetSourceServiceId);
        expect(args[3]!.$value, isNull);
        final handle = 'handle-${++resolutions}';
        final wait = resolving;
        resolving = null;
        final completion = Completer<$Value>();
        zone.run(() async {
          if (wait != null) await wait;
          if (available) handles.add(handle);
          completion.complete(
            wrapStructuredBridgeData(available ? handle : null),
          );
        });
        return $Future<$Value>.wrap(completion.future);
      })
      ..registerBridgeFunc(library, 'releaseEnvironmentCapabilityProvider', (
        _,
        _,
        args,
      ) {
        final handle = args[0]!.$value as String;
        final removed = handles.remove(handle);
        if (removed) releases.add(handle);
        return $bool(removed);
      })
      ..registerBridgeFunc(
        library,
        'requestEnvironmentCapability',
        (_, _, args) => transport.evalRequest(runtime, args),
      )
      ..registerBridgeFunc(
        library,
        'settleEnvironmentCapabilityOperation',
        (_, _, args) => BackendInvocationBridge.settleOperation(runtime, args),
      );
  }

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(method, changeSetSourceServiceSnapshotUnstagedId);
    expect(payload, isEmpty);
    if (wireResponse != null) return wireResponse;
    final result = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': resolutions,
      'method': method,
      'payload': payload,
    });
    if (result['ok'] != true) throw StateError('private failure');
    return result['payload'];
  }

  @override
  void invalidate() {
    active = false;
    transport.invalidate();
  }
}
