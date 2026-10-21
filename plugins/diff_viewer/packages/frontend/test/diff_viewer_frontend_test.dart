import 'dart:async';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/frontend/backend_invocation_bridge.dart';
import 'package:adele_desktop/frontend/environment_capability_access_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/session_presentation_lifecycle_bridge.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
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
  late ExtensionRegistry sourceRegistry;
  late _Source source;

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
    sourceRegistry = ExtensionRegistry();
    source = _Source();
  });
  tearDown(() async {
    frontend.invalidate();
    await port.dispatcher.close();
  });

  ExtensionRegistration registerSource({String id = 'test.source'}) {
    final registration = sourceRegistry.register(
      point: displaySourceFileContributions,
      id: ExtensionId(id),
      value: DisplaySourceFileContribution(display: source.display),
    );
    addTearDown(registration.close);
    return registration;
  }

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
                resolveSourceDisplay: DisplaySourceFileResolver(
                  sourceRegistry,
                ).resolve,
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
    'Open in Source passes raw unusual paths and Refresh never displays source',
    (tester) async {
      registerSource();
      final paths = [
        'dir/file with spaces.txt',
        'dir/name  [deleted] [modified].txt',
        'dir/quote" tab\t unicode-\u03bb\nname.txt',
      ];
      port.service.value = _snapshot(path: paths.first);
      await mount(tester);
      expect(source.paths, isEmpty);
      for (final path in paths) {
        port.service.value = _snapshot(path: path);
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(source.paths.length, paths.indexOf(path));
        expect(find.text('$path  [modified]'), findsOneWidget);
        await tester.tap(find.text('Open in Source'));
        await tester.pumpAndSettle();
        expect(source.paths.last, path);
        expect(find.text('Unable to open file in Source.'), findsNothing);
      }
      expect(source.paths, paths);
      expect(port.service.calls, 4);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('only known existing text file headers offer Open in Source', (
    tester,
  ) async {
    registerSource();
    await mount(tester);
    for (final scope in ['unstaged', 'uncommitted', 'task']) {
      if (scope != 'unstaged') {
        await tester.tap(
          find.widgetWithText(
            TextButton,
            scope == 'task' ? 'Task / Branch' : 'Uncommitted changes',
          ),
        );
        await tester.pumpAndSettle();
      }
      for (final entry in [
        ('modified', 'text', true),
        ('added', 'text', true),
        ('typeChanged', 'text', true),
        ('deleted', 'text', false),
        ('unsupported', 'text', false),
        ('conflicted', 'text', false),
        ('modified', 'binary', false),
        ('modified', 'oversized', false),
        ('modified', 'unsupported', false),
        ('modified', 'conflicted', false),
      ]) {
        port.service.value = ChangeSetSnapshot(
          files: [
            ChangedFile(
              relativePath: 'file.txt',
              changeKind: entry.$1,
              contentStatus: entry.$2,
              detail: null,
              reviewRevision: null,
              hunks: [],
            ),
          ],
        );
        port.service.uncommitted = UncommittedChangeSetSnapshot(
          staged: port.service.value,
          unstaged: port.service.value,
          // Even text-shaped entries in the conflicts section are not current files.
          conflicts: port.service.value.files,
        );
        port.service.task = TaskChangeSetSnapshot(
          committed: port.service.value,
          uncommitted: port.service.uncommitted,
        );
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(
          find.text('file.txt  [${entry.$1}]'),
          findsNWidgets(
            scope == 'task'
                ? 4
                : scope == 'uncommitted'
                ? 3
                : 1,
          ),
        );
        expect(
          find.text('Open in Source'),
          entry.$3 ? findsOneWidget : findsNothing,
          reason: '$scope: ${entry.$1}/${entry.$2}',
        );
      }
    }
    expect(source.paths, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'missing and multiple Source providers stay explicit without choosing one',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      port.service.value = _snapshot();
      await mount(tester);
      expect(find.text('Source is unavailable.'), findsOneWidget);
      expect(find.text('Open in Source'), findsNothing);
      final first = registerSource();
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Open in Source'),
      );
      final second = registerSource(id: 'test.second-source');
      // A previously rendered callback must recheck current availability.
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(
        find.text('Multiple Source providers are available.'),
        findsWidgets,
      );
      expect(find.text('Open in Source'), findsNothing);
      expect(source.paths, isEmpty);
      await first.close();
      await second.close();
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('Source is unavailable.'), findsOneWidget);
      expect(find.text('notes.txt  [modified]'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending source display suppresses duplicates and failure is nonfatal and retryable',
    (tester) async {
      registerSource();
      final held = Completer<Map<String, Object?>>();
      source.pending = held.future;
      port.service.value = _snapshot();
      await mount(tester);
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Open in Source'),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(source.paths, ['notes.txt']);
      expect(find.text('Opening in Source...'), findsOneWidget);
      expect(find.text('Open in Source'), findsNothing);
      held.complete({'ok': false, 'message': 'private source diagnostic'});
      await tester.pumpAndSettle();
      expect(find.text('Unable to open file in Source.'), findsOneWidget);
      expect(find.text('notes.txt  [modified]'), findsOneWidget);
      expect(find.text('   4      -before'), findsOneWidget);
      expect(find.textContaining('private source diagnostic'), findsNothing);
      expect(port.service.calls, 1);
      await tester.tap(find.text('Open in Source'));
      await tester.pumpAndSettle();
      expect(source.paths, ['notes.txt', 'notes.txt']);
      expect(find.text('Unable to open file in Source.'), findsNothing);
      expect(port.service.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('source exceptions become generic errors, not a failed Diff', (
    tester,
  ) async {
    registerSource();
    source.failure = true;
    port.service.value = _snapshot();
    await mount(tester);
    await tester.tap(find.text('Open in Source'));
    await tester.pumpAndSettle();
    expect(find.text('Unable to open file in Source.'), findsOneWidget);
    expect(find.text('notes.txt  [modified]'), findsOneWidget);
    expect(find.text('Unable to load unstaged changes.'), findsNothing);
    expect(find.textContaining('private source diagnostic'), findsNothing);
    expect(port.service.calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'refresh fences old source feedback and callbacks but retains pending suppression',
    (tester) async {
      registerSource();
      final held = Completer<Map<String, Object?>>();
      source.pending = held.future;
      port.service.value = _snapshot();
      await mount(tester);
      final oldButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Open in Source'),
      );
      oldButton.onPressed!();
      await tester.pumpAndSettle();
      port.service.value = _snapshot(path: 'current.txt');
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('current.txt  [modified]'), findsOneWidget);
      expect(find.text('Opening in Source...'), findsOneWidget);
      expect(source.paths, ['notes.txt']);
      held.complete({'ok': false});
      await tester.pumpAndSettle();
      expect(find.text('Unable to open file in Source.'), findsNothing);
      oldButton.onPressed!();
      await tester.pumpAndSettle();
      expect(source.paths, ['notes.txt']);
      await tester.tap(find.text('Open in Source'));
      await tester.pumpAndSettle();
      expect(source.paths, ['notes.txt', 'current.txt']);
      expect(port.service.calls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  for (final departing in [true, false]) {
    testWidgets('late source completion cannot update departed=$departing UI', (
      tester,
    ) async {
      registerSource();
      final held = Completer<Map<String, Object?>>();
      source.pending = held.future;
      port.service.value = _snapshot();
      await mount(tester);
      await tester.tap(find.text('Open in Source'));
      await tester.pumpAndSettle();
      if (departing) {
        await lifecycle.prepareToDeactivate();
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      held.complete({'ok': false});
      await tester.pumpAndSettle();
      expect(find.text('Unable to open file in Source.'), findsNothing);
      expect(find.text('notes.txt  [modified]'), findsNothing);
      expect(source.paths, ['notes.txt']);
      expect(tester.takeException(), isNull);
    });
  }

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
            'reviewRevision': null,
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
              reviewRevision: null,
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
            reviewRevision: null,
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
      port.service.uncommitted = _uncommitted(
        staged: port.service.value,
        unstaged: _snapshot(path: 'lower-layer.txt'),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Uncommitted changes'));
      await tester.pumpAndSettle();
      expect(find.text('Staged changes'), findsOneWidget);
      expect(find.textContaining('+line-0'), findsOneWidget);
      expect(find.textContaining('+line-1999'), findsNothing);
      expect(find.text('lower-layer.txt  [modified]'), findsNothing);
      expect(find.text('Conflicts'), findsNothing);
      expect(tester.widgetList(find.byType(Text)).length, lessThan(100));
      port.service.task = TaskChangeSetSnapshot(
        committed: port.service.value,
        uncommitted: port.service.uncommitted,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      expect(find.text('Committed changes'), findsOneWidget);
      expect(find.textContaining('+line-0'), findsOneWidget);
      expect(find.textContaining('+line-1999'), findsNothing);
      expect(find.text('Staged changes'), findsNothing);
      expect(find.text('Open in Source'), findsNothing);
      expect(tester.widgetList(find.byType(Text)).length, lessThan(100));
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scope defaults to Unstaged and preserves cancelling same-path layers',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      registerSource();
      const path = 'dir/two words [deleted]\t\u03bb.txt';
      port.service.value = _snapshot(path: 'default.txt');
      port.service.uncommitted = UncommittedChangeSetSnapshot(
        staged: _snapshot(path: path),
        unstaged: _snapshot(path: path, before: 'after', after: 'before'),
        conflicts: [_conflict()],
      );
      await mount(tester);
      expect(port.methods, [changeSetSourceServiceSnapshotUnstagedId]);
      expect(find.text('default.txt  [modified]'), findsOneWidget);
      expect(find.text('Staged changes'), findsNothing);
      expect(find.text('Conflicts'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, 'Uncommitted changes'));
      await tester.pumpAndSettle();
      expect(find.text('default.txt  [modified]'), findsNothing);
      expect(find.text('$path  [modified]'), findsNWidgets(2));
      expect(find.text('   4      -before'), findsOneWidget);
      expect(find.text('        4 +after'), findsOneWidget);
      expect(find.text('   4      -after'), findsOneWidget);
      expect(find.text('        4 +before'), findsOneWidget);
      expect(find.text('conflict.txt  [conflicted]'), findsOneWidget);
      expect(find.text('No uncommitted changes.'), findsNothing);
      final section = find.text('Unstaged changes').last;
      expect(
        tester.getTopLeft(find.text('Staged changes')).dy,
        lessThan(tester.getTopLeft(section).dy),
      );
      expect(
        tester.getTopLeft(section).dy,
        lessThan(tester.getTopLeft(find.text('Conflicts')).dy),
      );
      expect(find.text('Open in Source'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Open in Source')).dy,
        greaterThan(tester.getTopLeft(section).dy),
      );
      await tester.tap(find.text('Open in Source'));
      await tester.pumpAndSettle();
      expect(source.paths, [path]);
      await tester.tap(find.widgetWithText(TextButton, 'Unstaged changes'));
      await tester.pumpAndSettle();
      expect(find.text('default.txt  [modified]'), findsOneWidget);
      expect(find.text('Conflicts'), findsNothing);
      expect(port.methods, [
        changeSetSourceServiceSnapshotUnstagedId,
        changeSetSourceServiceSnapshotUncommittedId,
        changeSetSourceServiceSnapshotUnstagedId,
      ]);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1', 'handle-2', 'handle-3']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Uncommitted loading, clean, unavailable, Retry and Refresh use chosen method',
    (tester) async {
      await mount(tester);
      final held = Completer<UncommittedChangeSetSnapshot>();
      port.service.pendingUncommitted = held.future;
      await tester.tap(find.widgetWithText(TextButton, 'Uncommitted changes'));
      await tester.pumpAndSettle();
      expect(find.text('Loading uncommitted changes...'), findsOneWidget);
      expect(port.handles, hasLength(1));
      held.complete(_uncommitted());
      await tester.pumpAndSettle();
      expect(find.text('No uncommitted changes.'), findsOneWidget);
      expect(find.text('No staged changes.'), findsOneWidget);
      expect(find.text('No unstaged changes.'), findsOneWidget);
      expect(find.text('No conflicts.'), findsOneWidget);
      expect(port.handles, isEmpty);
      port.available = false;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(
        find.text('Diff unavailable for this Environment.'),
        findsOneWidget,
      );
      port.available = true;
      port.service.failure = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Unable to load uncommitted changes.'), findsOneWidget);
      expect(find.textContaining('private failure'), findsNothing);
      expect(port.handles, isEmpty);
      port.service.failure = false;
      port.service.uncommitted = _uncommitted(conflicts: [_conflict()]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('conflict.txt  [conflicted]'), findsOneWidget);
      expect(find.text('No uncommitted changes.'), findsNothing);
      port.service.uncommitted = _uncommitted(
        staged: _snapshot(path: 'staged-only.txt'),
      );
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('staged-only.txt  [modified]'), findsOneWidget);
      expect(find.text('No uncommitted changes.'), findsNothing);
      expect(find.text('Open in Source'), findsNothing);
      expect(port.service.calls, 1);
      expect(port.service.uncommittedCalls, 4);
      expect(
        port.methods.skip(1),
        everyElement(changeSetSourceServiceSnapshotUncommittedId),
      );
      expect(port.resolutions, 6);
      expect(port.handles, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Task renders independent same-path layers from one generated call',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      registerSource();
      const path = 'dir/two words [deleted]\t\u03bb.txt';
      port.service.task = _task(
        committed: _snapshot(
          path: path,
          before: 'baseline',
          after: 'committed',
        ),
        uncommitted: _uncommitted(
          staged: _snapshot(path: path, before: 'committed', after: 'index'),
          unstaged: _snapshot(path: path, before: 'index', after: 'working'),
          conflicts: [_conflict()],
        ),
      );
      await mount(tester);
      expect(find.text('No unstaged changes.'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      expect(port.methods, [
        changeSetSourceServiceSnapshotUnstagedId,
        changeSetSourceServiceSnapshotTaskChangesId,
      ]);
      expect(port.service.calls, 1);
      expect(port.service.uncommittedCalls, 0);
      expect(port.service.taskCalls, 1);
      expect(find.text('$path  [modified]'), findsNWidgets(3));
      expect(find.text('@@ -3,2 +3,2 @@'), findsNWidgets(3));
      expect(find.text('   3    3  shared'), findsNWidgets(3));
      expect(find.text('   4      -baseline'), findsOneWidget);
      expect(find.text('        4 +committed'), findsOneWidget);
      expect(find.text('   4      -committed'), findsOneWidget);
      expect(find.text('        4 +index'), findsOneWidget);
      expect(find.text('   4      -index'), findsOneWidget);
      expect(find.text('        4 +working'), findsOneWidget);
      expect(find.text(r'\ No newline at end of file'), findsNWidgets(3));
      final sections = [
        'Committed changes',
        'Staged changes',
        'Unstaged changes',
        'Conflicts',
      ];
      for (var index = 1; index < sections.length; index++) {
        expect(
          tester.getTopLeft(find.text(sections[index]).last).dy,
          greaterThan(
            tester.getTopLeft(find.text(sections[index - 1]).last).dy,
          ),
        );
      }
      expect(find.text('No task changes.'), findsNothing);
      expect(find.text('Open in Source'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Open in Source')).dy,
        greaterThan(tester.getTopLeft(find.text('Unstaged changes').last).dy),
      );
      await tester.tap(find.text('Open in Source'));
      await tester.pumpAndSettle();
      expect(source.paths, [path]);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1', 'handle-2']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all scope controls and Refresh fit ordinary narrow panes', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    registerSource();
    port.service.value = _snapshot();
    port.service.uncommitted = _uncommitted(unstaged: port.service.value);
    port.service.task = _task(uncommitted: port.service.uncommitted);
    await mount(tester);
    for (final width in [320.0, 480.0, 900.0]) {
      await tester.binding.setSurfaceSize(Size(width, 600));
      await tester.pumpAndSettle();
      for (final label in [
        'Unstaged changes',
        'Uncommitted changes',
        'Task / Branch',
      ]) {
        final button = find.widgetWithText(TextButton, label);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(tester.getRect(button).left, greaterThanOrEqualTo(0));
        expect(tester.getRect(button).right, lessThanOrEqualTo(width));
        expect(
          tester.getTopLeft(find.widgetWithText(TextButton, 'Refresh')).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(button).dy),
        );
        expect(find.text('notes.txt  [modified]'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$width / $label');
      }
    }
  });

  testWidgets(
    'Task clean requires all layers empty and Refresh/Retry retain scope',
    (tester) async {
      await mount(tester);
      final held = Completer<TaskChangeSetSnapshot>();
      port.service.pendingTask = held.future;
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      expect(find.text('Loading task changes...'), findsOneWidget);
      expect(port.handles, hasLength(1));
      held.complete(_task());
      await tester.pumpAndSettle();
      expect(find.text('No task changes.'), findsOneWidget);
      for (final text in [
        'No committed changes.',
        'No staged changes.',
        'No unstaged changes.',
        'No conflicts.',
      ]) {
        expect(find.text(text), findsOneWidget);
      }
      port.available = false;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(
        find.text('Diff unavailable for this Environment.'),
        findsOneWidget,
      );
      port.available = true;
      port.service.failure = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Unable to load task changes.'), findsOneWidget);
      expect(find.textContaining('private failure'), findsNothing);
      expect(port.handles, isEmpty);
      port.service.failure = false;
      port.service.task = _task(
        committed: _snapshot(path: 'committed-only.txt'),
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('committed-only.txt  [modified]'), findsOneWidget);
      expect(find.text('No task changes.'), findsNothing);
      expect(find.text('Open in Source'), findsNothing);
      for (final layer in ['staged', 'unstaged', 'conflicts']) {
        port.service.task = _task(
          uncommitted: _uncommitted(
            staged: layer == 'staged' ? _snapshot() : null,
            unstaged: layer == 'unstaged' ? _snapshot() : null,
            conflicts: layer == 'conflicts' ? [_conflict()] : [],
          ),
        );
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(find.text('No task changes.'), findsNothing);
      }
      expect(port.service.calls, 1);
      expect(port.service.uncommittedCalls, 0);
      expect(port.service.taskCalls, 6);
      expect(port.resolutions, 8);
      expect(
        port.methods.skip(1),
        everyElement(changeSetSourceServiceSnapshotTaskChangesId),
      );
      expect(port.handles, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid three-scope switches and Task Refresh fence every older operation',
    (tester) async {
      final old = Completer<ChangeSetSnapshot>();
      final combined = Completer<UncommittedChangeSetSnapshot>();
      final task = Completer<TaskChangeSetSnapshot>();
      port.service.pending = old.future;
      await mount(tester);
      port.service.pendingUncommitted = combined.future;
      await tester.tap(find.widgetWithText(TextButton, 'Uncommitted changes'));
      await tester.pumpAndSettle();
      port.service.pendingTask = task.future;
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      port.service.task = _task(committed: _snapshot(path: 'current.txt'));
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('current.txt  [modified]'), findsOneWidget);
      expect(port.handles, isEmpty);
      expect(port.releases, ['handle-1', 'handle-2', 'handle-3', 'handle-4']);
      task.complete(_task(committed: _snapshot(path: 'obsolete-task.txt')));
      combined.completeError(StateError('private obsolete failure'));
      old.complete(_snapshot(path: 'obsolete-unstaged.txt'));
      await tester.pumpAndSettle();
      expect(find.text('current.txt  [modified]'), findsOneWidget);
      expect(find.textContaining('obsolete'), findsNothing);
      expect(find.text('Unable to load task changes.'), findsNothing);
      expect(port.methods, [
        changeSetSourceServiceSnapshotUnstagedId,
        changeSetSourceServiceSnapshotUncommittedId,
        changeSetSourceServiceSnapshotTaskChangesId,
        changeSetSourceServiceSnapshotTaskChangesId,
      ]);
      expect(port.releases, hasLength(4));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid pending scope resolutions admit only the latest Task request',
    (tester) async {
      final unstaged = Completer<void>();
      final uncommitted = Completer<void>();
      port.resolving = unstaged.future;
      await mount(tester);
      port.resolving = uncommitted.future;
      await tester.tap(find.widgetWithText(TextButton, 'Uncommitted changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      expect(find.text('No task changes.'), findsOneWidget);
      uncommitted.complete();
      unstaged.complete();
      await tester.pumpAndSettle();
      expect(port.methods, [changeSetSourceServiceSnapshotTaskChangesId]);
      expect(port.releases, ['handle-3', 'handle-2', 'handle-1']);
      expect(port.handles, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final initial in ['unstaged', 'uncommitted', 'task']) {
    final other = initial == 'unstaged' ? 'uncommitted' : 'unstaged';
    final button = initial == 'unstaged'
        ? 'Uncommitted changes'
        : 'Unstaged changes';
    for (final fails in [false, true]) {
      testWidgets(
        'switch from pending $initial snapshot ignores late failure=$fails',
        (tester) async {
          final old = Completer<ChangeSetSnapshot>();
          final combined = Completer<UncommittedChangeSetSnapshot>();
          final task = Completer<TaskChangeSetSnapshot>();
          if (initial == 'unstaged') port.service.pending = old.future;
          await mount(tester);
          if (initial == 'uncommitted') {
            port.service.pendingUncommitted = combined.future;
            await tester.tap(
              find.widgetWithText(TextButton, 'Uncommitted changes'),
            );
            await tester.pumpAndSettle();
          }
          if (initial == 'task') {
            port.service.pendingTask = task.future;
            await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
            await tester.pumpAndSettle();
          }
          expect(find.text('Loading $initial changes...'), findsOneWidget);
          port.service.value = _snapshot(path: 'current.txt');
          port.service.uncommitted = _uncommitted(unstaged: port.service.value);
          await tester.tap(find.widgetWithText(TextButton, button));
          await tester.pumpAndSettle();
          expect(find.text('current.txt  [modified]'), findsOneWidget);
          expect(port.handles, isEmpty);
          final released = List<String>.of(port.releases);
          if (initial == 'unstaged') {
            if (fails) {
              old.completeError(StateError('private obsolete failure'));
            } else {
              old.complete(_snapshot(path: 'obsolete.txt'));
            }
          } else if (initial == 'uncommitted') {
            if (fails) {
              combined.completeError(StateError('private obsolete failure'));
            } else {
              combined.complete(
                _uncommitted(staged: _snapshot(path: 'obsolete.txt')),
              );
            }
          } else {
            if (fails) {
              task.completeError(StateError('private obsolete failure'));
            } else {
              task.complete(_task(committed: _snapshot(path: 'obsolete.txt')));
            }
          }
          await tester.pumpAndSettle();
          expect(find.text('current.txt  [modified]'), findsOneWidget);
          expect(find.textContaining('obsolete.txt'), findsNothing);
          expect(find.text('Unable to load $other changes.'), findsNothing);
          expect(port.releases, released);
          expect(
            port.methods.last,
            other == 'unstaged'
                ? changeSetSourceServiceSnapshotUnstagedId
                : changeSetSourceServiceSnapshotUncommittedId,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'switch from pending $initial resolution releases without invoking',
      (tester) async {
        final held = Completer<void>();
        if (initial == 'unstaged') port.resolving = held.future;
        await mount(tester);
        if (initial != 'unstaged') {
          port.resolving = held.future;
          await tester.tap(
            find.widgetWithText(
              TextButton,
              initial == 'task' ? 'Task / Branch' : 'Uncommitted changes',
            ),
          );
          await tester.pumpAndSettle();
        }
        final before = port.methods.length;
        await tester.tap(find.widgetWithText(TextButton, button));
        await tester.pumpAndSettle();
        expect(find.text('No $other changes.'), findsOneWidget);
        held.complete();
        await tester.pumpAndSettle();
        expect(port.methods, hasLength(before + 1));
        expect(port.handles, isEmpty);
        expect(port.releases, hasLength(port.resolutions));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final resolving in [true, false]) {
    for (final departing in [true, false]) {
      testWidgets(
        'Uncommitted pending resolution=$resolving departure=$departing is fenced',
        (tester) async {
          await mount(tester);
          final resolution = Completer<void>();
          final snapshot = Completer<UncommittedChangeSetSnapshot>();
          if (resolving) {
            port.resolving = resolution.future;
          } else {
            port.service.pendingUncommitted = snapshot.future;
          }
          await tester.tap(
            find.widgetWithText(TextButton, 'Uncommitted changes'),
          );
          await tester.pumpAndSettle();
          if (departing) {
            await lifecycle.prepareToDeactivate();
          } else {
            await tester.pumpWidget(const SizedBox());
          }
          expect(port.handles, isEmpty);
          if (resolving) {
            resolution.complete();
          } else {
            snapshot.complete(
              _uncommitted(staged: _snapshot(path: 'departed.txt')),
            );
          }
          await tester.pumpAndSettle();
          expect(find.textContaining('departed.txt'), findsNothing);
          expect(port.service.uncommittedCalls, resolving ? 0 : 1);
          expect(port.handles, isEmpty);
          expect(port.releases, ['handle-1', 'handle-2']);
          if (departing) {
            port.service.uncommitted = _uncommitted(
              unstaged: _snapshot(path: 'retry.txt'),
            );
            await tester.tap(find.text('Retry'));
            await tester.pumpAndSettle();
            expect(find.text('retry.txt  [modified]'), findsOneWidget);
            expect(
              port.methods.last,
              changeSetSourceServiceSnapshotUncommittedId,
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final resolving in [true, false]) {
    for (final ending in ['departure', 'dispose', 'retirement']) {
      testWidgets('Task pending resolution=$resolving is fenced on $ending', (
        tester,
      ) async {
        await mount(tester);
        final resolution = Completer<void>();
        final snapshot = Completer<TaskChangeSetSnapshot>();
        if (resolving) {
          port.resolving = resolution.future;
        } else {
          port.service.pendingTask = snapshot.future;
        }
        await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
        await tester.pumpAndSettle();
        if (ending == 'departure') {
          await lifecycle.prepareToDeactivate();
        } else if (ending == 'dispose') {
          await tester.pumpWidget(const SizedBox());
        } else {
          frontend.invalidate();
          await tester.pumpAndSettle();
          expect(find.text('Frontend unavailable.'), findsOneWidget);
        }
        expect(port.handles, isEmpty);
        if (resolving) {
          resolution.complete();
        } else {
          snapshot.complete(_task(committed: _snapshot(path: 'departed.txt')));
        }
        await tester.pumpAndSettle();
        expect(find.textContaining('departed.txt'), findsNothing);
        expect(port.service.taskCalls, resolving ? 0 : 1);
        expect(port.handles, isEmpty);
        expect(port.releases, ['handle-1', 'handle-2']);
        if (ending == 'departure') {
          port.service.task = _task(committed: _snapshot(path: 'retry.txt'));
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text('retry.txt  [modified]'), findsOneWidget);
          expect(
            port.methods.last,
            changeSetSourceServiceSnapshotTaskChangesId,
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final target in ['Uncommitted changes', 'Task / Branch']) {
    testWidgets(
      '$target scope switch fences source callbacks and late feedback without duplicate admission',
      (tester) async {
        registerSource();
        final held = Completer<Map<String, Object?>>();
        source.pending = held.future;
        port.service.value = _snapshot();
        port.service.uncommitted = _uncommitted(
          unstaged: _snapshot(path: 'current.txt'),
        );
        port.service.task = _task(uncommitted: port.service.uncommitted);
        await mount(tester);
        final old = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Open in Source'),
        );
        old.onPressed!();
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, target));
        await tester.pumpAndSettle();
        expect(find.text('current.txt  [modified]'), findsOneWidget);
        expect(find.text('Opening in Source...'), findsOneWidget);
        old.onPressed!();
        expect(source.paths, ['notes.txt']);
        held.complete({'ok': false});
        await tester.pumpAndSettle();
        expect(find.text('Unable to open file in Source.'), findsNothing);
        old.onPressed!();
        await tester.pumpAndSettle();
        expect(source.paths, ['notes.txt']);
        await tester.tap(find.text('Open in Source'));
        await tester.pumpAndSettle();
        expect(source.paths, ['notes.txt', 'current.txt']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'generated eval rejects incomplete Uncommitted layers and malformed nested values',
    (tester) async {
      await mount(tester);
      port.service.uncommitted = _uncommitted(
        staged: _snapshot(),
        unstaged: _snapshot(),
        conflicts: [_conflict()],
      );
      await tester.tap(find.widgetWithText(TextButton, 'Uncommitted changes'));
      await tester.pumpAndSettle();
      final wire = port.lastResponse! as Map<String, Object?>;
      for (final invalid in <Map<String, Object?>>[
        {...wire}..remove('staged'),
        {...wire}..remove('unstaged'),
        {...wire}..remove('conflicts'),
        {...wire, 'extra': true},
        {...wire, 'staged': null},
        {
          ...wire,
          'unstaged': {'files': 'invalid'},
        },
        {
          ...wire,
          'conflicts': [null],
        },
        for (final layer in ['staged', 'unstaged'])
          {
            ...wire,
            layer: {
              'files': [
                {...((wire[layer] as Map)['files'] as List).single as Map}
                  ..remove('detail'),
              ],
            },
          },
      ]) {
        port.wireResponse = invalid;
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(
          find.text('Unable to load uncommitted changes.'),
          findsOneWidget,
        );
        expect(find.text('notes.txt  [modified]'), findsNothing);
        expect(find.text('No uncommitted changes.'), findsNothing);
        expect(port.handles, isEmpty);
        port.wireResponse = null;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('notes.txt  [modified]'), findsNWidgets(2));
      }
      expect(
        port.methods.skip(1),
        everyElement(changeSetSourceServiceSnapshotUncommittedId),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'generated eval rejects malformed Task components without partial results',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(tester);
      port.service.task = _task(
        committed: _snapshot(),
        uncommitted: _uncommitted(
          staged: _snapshot(),
          unstaged: _snapshot(),
          conflicts: [_conflict()],
        ),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Task / Branch'));
      await tester.pumpAndSettle();
      final wire = port.lastResponse! as Map<String, Object?>;
      final uncommitted = wire['uncommitted']! as Map<String, Object?>;
      final committed = wire['committed']! as Map<String, Object?>;
      final file = (committed['files']! as List).single as Map<String, Object?>;
      final hunk = (file['hunks']! as List).single as Map<String, Object?>;
      final line = (hunk['lines']! as List).first as Map<String, Object?>;
      for (final invalid in <Map<String, Object?>>[
        {...wire, 'extra': true},
        for (final field in ['committed', 'uncommitted']) ...[
          {...wire}..remove(field),
          {...wire, field: null},
          {...wire, field: 'invalid'},
          {...wire, field: <String, Object?>{}},
        ],
        for (final field in ['staged', 'unstaged', 'conflicts']) ...[
          {
            ...wire,
            'uncommitted': {...uncommitted}..remove(field),
          },
          {
            ...wire,
            'uncommitted': {...uncommitted, field: null},
          },
        ],
        {
          ...wire,
          'uncommitted': {
            ...uncommitted,
            'conflicts': [null],
          },
        },
        for (final layer in ['committed', 'staged', 'unstaged'])
          for (final bad in [
            {
              'files': [
                {...file}..remove('detail'),
              ],
            },
            {
              'files': [
                {
                  ...file,
                  'hunks': [
                    {
                      ...hunk,
                      'lines': [
                        {...line, 'noNewline': 'false'},
                      ],
                    },
                  ],
                },
              ],
            },
          ])
            if (layer == 'committed')
              {...wire, layer: bad}
            else
              {
                ...wire,
                'uncommitted': {...uncommitted, layer: bad},
              },
      ]) {
        port.wireResponse = invalid;
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(find.text('Unable to load task changes.'), findsOneWidget);
        expect(find.text('notes.txt  [modified]'), findsNothing);
        expect(find.text('No task changes.'), findsNothing);
        expect(port.handles, isEmpty);
        port.wireResponse = null;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('notes.txt  [modified]'), findsNWidgets(3));
      }
      expect(
        port.methods.skip(1),
        everyElement(changeSetSourceServiceSnapshotTaskChangesId),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

ChangeSetSnapshot _snapshot({
  String path = 'notes.txt',
  String before = 'before',
  String after = 'after',
}) => ChangeSetSnapshot(
  files: [
    ChangedFile(
      relativePath: path,
      changeKind: 'modified',
      contentStatus: 'text',
      detail: null,
      reviewRevision: null,
      hunks: [
        DiffHunk(
          oldStart: 3,
          oldCount: 2,
          newStart: 3,
          newCount: 2,
          lines: [
            const DiffLine(kind: 'context', text: 'shared', noNewline: false),
            DiffLine(kind: 'deletion', text: before, noNewline: false),
            DiffLine(kind: 'addition', text: after, noNewline: true),
          ],
        ),
      ],
    ),
  ],
);

UncommittedChangeSetSnapshot _uncommitted({
  ChangeSetSnapshot? staged,
  ChangeSetSnapshot? unstaged,
  List<ChangedFile> conflicts = const [],
}) => UncommittedChangeSetSnapshot(
  staged: staged ?? ChangeSetSnapshot(files: []),
  unstaged: unstaged ?? ChangeSetSnapshot(files: []),
  conflicts: conflicts,
);

ChangedFile _conflict() => ChangedFile(
  relativePath: 'conflict.txt',
  changeKind: 'conflicted',
  contentStatus: 'conflicted',
  detail: 'Unmerged index entries.',
  reviewRevision: null,
  hunks: [],
);

TaskChangeSetSnapshot _task({
  ChangeSetSnapshot? committed,
  UncommittedChangeSetSnapshot? uncommitted,
}) => TaskChangeSetSnapshot(
  committed: committed ?? ChangeSetSnapshot(files: []),
  uncommitted: uncommitted ?? _uncommitted(),
);

class _Service implements ChangeSetSourceService {
  ChangeSetSnapshot value = ChangeSetSnapshot(files: []);
  UncommittedChangeSetSnapshot uncommitted = _uncommitted();
  TaskChangeSetSnapshot task = _task();
  Future<ChangeSetSnapshot>? pending;
  Future<UncommittedChangeSetSnapshot>? pendingUncommitted;
  Future<TaskChangeSetSnapshot>? pendingTask;
  bool failure = false;
  int calls = 0;
  int uncommittedCalls = 0;
  int taskCalls = 0;
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

  @override
  Future<UncommittedChangeSetSnapshot> snapshotUncommitted() async {
    uncommittedCalls++;
    final held = pendingUncommitted;
    pendingUncommitted = null;
    if (held != null) return held;
    if (failure) {
      throw const ChangeSetFailure(code: 'failed', message: 'private failure');
    }
    return uncommitted;
  }

  @override
  Future<TaskChangeSetSnapshot> snapshotTaskChanges() async {
    taskCalls++;
    final held = pendingTask;
    pendingTask = null;
    if (held != null) return held;
    if (failure) {
      throw const ChangeSetFailure(code: 'failed', message: 'private failure');
    }
    return task;
  }
}

class _Source {
  final List<String> paths = [];
  Future<Map<String, Object?>>? pending;
  bool failure = false;

  Future<Map<String, Object?>> display(String path) async {
    paths.add(path);
    final held = pending;
    pending = null;
    if (held != null) return held;
    if (failure) throw StateError('private source diagnostic');
    return {'ok': true, 'private': 'private source diagnostic'};
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
  Object? lastResponse;
  final List<String> methods = [];
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
      ..registerBridgeFunc(
        library,
        'resolveEnvironmentBufferedProcessCapabilityProvider',
        (_, _, args) {
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
        },
      )
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
    expect(
      method,
      isIn([
        changeSetSourceServiceSnapshotUnstagedId,
        changeSetSourceServiceSnapshotUncommittedId,
        changeSetSourceServiceSnapshotTaskChangesId,
      ]),
    );
    methods.add(method);
    expect(payload, isEmpty);
    if (wireResponse != null) return wireResponse;
    final result = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': resolutions,
      'method': method,
      'payload': payload,
    });
    if (result['ok'] != true) throw StateError('private failure');
    return lastResponse = result['payload'];
  }

  @override
  void invalidate() {
    active = false;
    transport.invalidate();
  }
}
