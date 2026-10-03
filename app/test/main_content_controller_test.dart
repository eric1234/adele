import 'dart:async';

import 'package:adele_desktop/ui/main_content/main_content_controller.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ExtensionRegistry extensions;
  late Session session;
  late MainContentController controller;

  setUp(() {
    extensions = ExtensionRegistry();
    session = Session(
      id: SessionId('session'),
      taskId: TaskId('task'),
      strategyId: OrchestrationStrategyId('test.strategy'),
    );
    controller = MainContentController(
      session: session,
      extensions: extensions,
    );
  });
  tearDown(() => controller.dispose());

  ExtensionRegistration register(
    String id,
    FutureOr<void> Function(MainContentAccess) attach, {
    int order = 0,
    List<MainContentAction> actions = const [],
    void Function(MainContentAccess)? detach,
  }) => extensions.register(
    point: mainContentContributions,
    id: ExtensionId(id),
    value: MainContentContribution(
      order: order,
      attach: attach,
      actions: actions,
      detach: detach,
    ),
  );

  MainContentPane pane(String id, {VoidCallback? release}) => MainContentPane(
    id: id,
    title: id,
    createPresentation: () => const SizedBox.shrink(),
    release: release,
  );

  ExtensionRegistration registerChat({int order = 100}) => register(
    'test.chat',
    (access) => access.open(pane('chat')),
    order: order,
  );

  test('no contributions or empty groups produce no entries', () {
    expect(controller.entries, isEmpty);
    controller.reconcile();
    expect(controller.entries, isEmpty);
    late MainContentAccess access;
    register('test.empty', (value) => access = value);
    controller.reconcile();
    expect(controller.entries, isEmpty);
    access.open(pane('only'));
    expect(controller.entries.single.info.id, 'only');
    access.remove('only');
    expect(controller.entries, isEmpty);
  });

  test(
    'ordered live actions exist independently of panes and create fresh input',
    () {
      final attached = <String, MainContentAccess>{};
      final received = <MainContentAccess>[];
      for (final (id, order, labels) in [
        ('test.z', 0, ['z']),
        ('test.a', 0, ['a2', 'a1']),
        ('test.first', -1, ['first']),
      ]) {
        register(
          id,
          (access) => attached[id] = access,
          order: order,
          actions: [
            for (final label in labels)
              MainContentAction(
                id: label,
                label: label,
                createPresentation: (access) {
                  received.add(access);
                  return SizedBox(key: UniqueKey());
                },
              ),
          ],
        );
      }
      controller.reconcile();
      expect(controller.entries, isEmpty);
      expect(received, isEmpty);
      final actions = controller.actions;
      expect(actions.map((action) => action.label), ['first', 'a2', 'a1', 'z']);
      expect(() => actions.clear(), throwsUnsupportedError);
      final action = actions.first;
      expect(action.id, 'first');
      final firstInput = action.createPresentation();
      expect(action.createPresentation(), isNot(same(firstInput)));
      expect(received, [
        same(attached['test.first']),
        same(attached['test.first']),
      ]);
      attached['test.first']!.open(pane('pane'));
      attached['test.first']!.remove('pane');
      expect(controller.entries, isEmpty);
      expect(controller.actions.first, same(action));
      controller.dispose();
      expect(action.isActive, isFalse);
      expect(action.createPresentation, throwsStateError);
      expect(controller.actions, isEmpty);
    },
  );

  test(
    'action retirement is immediate and same-ID replacement cannot revive it',
    () async {
      final accesses = <MainContentAccess>[];
      final action = MainContentAction(
        id: 'input',
        label: 'Choose resource',
        createPresentation: (access) {
          accesses.add(access);
          return const SizedBox.shrink();
        },
      );
      final registration = register('test.actions', (_) {}, actions: [action]);
      controller.reconcile();
      final old = controller.actions.single;
      old.createPresentation();
      final retirement = registration.close();
      expect(old.isActive, isFalse);
      expect(controller.actions, isEmpty);
      expect(old.createPresentation, throwsStateError);
      register('test.actions', (_) {}, actions: [action]);
      controller.reconcile();
      final replacement = controller.actions.single;
      expect(replacement, isNot(same(old)));
      replacement.createPresentation();
      expect(accesses.first.isActive, isFalse);
      expect(accesses.last.isActive, isTrue);
      expect(accesses.first, isNot(same(accesses.last)));
      await retirement;
    },
  );

  test(
    'detach runs once for empty and failed groups without blocking cleanup',
    () async {
      final detached = <MainContentAccess>[];
      final attached = <MainContentAccess>[];
      var releases = 0;
      final empty = register(
        'test.empty',
        attached.add,
        detach: (access) {
          expect(access.isActive, isFalse);
          detached.add(access);
          throw StateError('fixture detach failure');
        },
      );
      register('test.failed', (access) {
        attached.add(access);
        access.open(pane('pane', release: () => releases++));
        throw StateError('fixture attachment failure');
      }, detach: detached.add);
      controller.reconcile();
      await Future<void>.delayed(Duration.zero);
      expect(detached, [same(attached.last)]);
      expect(releases, 1);
      await empty.close();
      controller.reconcile();
      expect(detached, [same(attached.last), same(attached.first)]);
      controller.dispose();
      expect(detached, hasLength(2));
      expect(releases, 1);
    },
  );

  test(
    'independent groups sort by order then exact ExtensionId, not plugin',
    () {
      registerChat();
      register('test.plugin.z', (access) => access.open(pane('z')));
      register('test.plugin.a', (access) {
        access.open(pane('a2'));
        access.open(pane('a1'));
      });
      register('test.empty', (_) {}, order: -100);
      register('test.last', (access) => access.open(pane('last')), order: 101);
      register('test.first', (access) => access.open(pane('first')), order: -1);
      controller.reconcile();
      expect(controller.entries.map((entry) => entry.info.id), [
        'first',
        'a2',
        'a1',
        'z',
        'chat',
        'last',
      ]);
    },
  );

  for (final chatOrder in [100, 400]) {
    test('Chat order $chatOrder follows the ordinary group policy', () {
      registerChat(order: chatOrder);
      register('test.source', (access) {
        access.open(pane('a'));
        access.open(pane('b'));
      }, order: 300);
      controller.reconcile();
      expect(
        controller.entries.map((entry) => entry.info.id),
        chatOrder == 100 ? ['chat', 'a', 'b'] : ['a', 'b', 'chat'],
      );
    });
  }

  test('snapshots, duplicate open, title and complete local permutations', () {
    registerChat();
    late MainContentAccess access;
    var attachments = 0;
    var releases = 0;
    final original = pane('a', release: () => releases++);
    register('test.group', (value) {
      attachments++;
      access = value;
      access.open(original);
      access.open(pane('b'));
    });
    controller.reconcile();
    final originalEntry = controller.entries.first;
    final snapshot = access.panes;
    expect(access.session, same(session));
    expect(() => snapshot.clear(), throwsUnsupportedError);
    final duplicate = pane('a', release: () => releases += 100);
    expect(() => access.open(duplicate), throwsArgumentError);
    expect(() => access.open(original), throwsArgumentError);
    expect(access.panes, hasLength(2));
    expect(controller.entries.first, same(originalEntry));
    access.setTitle('a', 'Renamed');
    expect(snapshot.first.title, 'a');
    expect(access.panes.first.title, 'Renamed');
    for (final order in <List<String>>[
      ['a'],
      ['a', 'a'],
      ['a', 'other'],
      ['a', 'b', 'b'],
    ]) {
      expect(() => access.setOrder(order), throwsArgumentError);
    }
    expect(() => access.setTitle('a', ' '), throwsArgumentError);
    expect(() => access.focus('other'), throwsArgumentError);
    access.setOrder(['b', 'a']);
    expect(access.panes.map((pane) => pane.id), ['b', 'a']);
    expect(controller.entries[1], same(originalEntry));
    controller.reconcile();
    register('test.unrelated-empty', (_) {});
    controller.reconcile();
    expect(attachments, 1);
    access.remove('a');
    access.remove('a');
    access.open(duplicate);
    expect(originalEntry.isActive, isFalse);
    expect(releases, 1);
    expect(access.panes.map((pane) => pane.id), ['b', 'a']);
    controller.dispose();
    expect(releases, 101);
  });

  test(
    'retirement fences synchronously and same-ID replacement is fresh',
    () async {
      registerChat();
      final accesses = <MainContentAccess>[];
      var releases = 0;
      final contribution = MainContentContribution(
        order: 0,
        attach: (access) {
          accesses.add(access);
          access.open(pane('a', release: () => releases++));
        },
      );
      final registration = extensions.register(
        point: mainContentContributions,
        id: ExtensionId('test.group'),
        value: contribution,
      );
      register('test.sibling', (access) => access.open(pane('sibling')));
      controller.reconcile();
      final sibling = controller.entries[1];
      final old = accesses.single;
      final retirement = registration.close();
      expect(old.isActive, isFalse);
      expect(() => old.setTitle('a', 'late'), throwsStateError);
      expect(() => old.panes, throwsStateError);
      extensions.register(
        point: mainContentContributions,
        id: ExtensionId('test.group'),
        value: contribution,
      );
      controller.reconcile();
      expect(accesses, hasLength(2));
      expect(accesses.last.isActive, isTrue);
      expect(old.isActive, isFalse);
      expect(releases, 1);
      expect(controller.entries[1], same(sibling));
      await retirement;
    },
  );

  test(
    'failed attachment releases its panes without retrying or losing siblings',
    () async {
      registerChat();
      var attempts = 0;
      var releases = 0;
      late MainContentAccess failed;
      register('test.failed', (access) {
        attempts++;
        failed = access;
        access.open(pane('failed', release: () => releases++));
        throw StateError('fixture failure');
      });
      register('test.healthy', (access) => access.open(pane('healthy')));
      controller.reconcile();
      await Future<void>.delayed(Duration.zero);
      controller.reconcile();
      expect(failed.isActive, isFalse);
      expect(attempts, 1);
      expect(releases, 1);
      expect(controller.entries.map((entry) => entry.info.id), [
        'healthy',
        'chat',
      ]);
    },
  );

  test(
    'current-context loss before a frame permanently fences captured access',
    () {
      controller.dispose();
      var current = true;
      controller = MainContentController(
        session: session,
        extensions: extensions,
        isCurrent: () => current,
      );
      registerChat();
      late MainContentAccess access;
      register('test.group', (value) => access = value);
      controller.reconcile();
      current = false;
      expect(() => access.open(pane('late')), throwsStateError);
      current = true;
      expect(access.isActive, isFalse);
      expect(() => access.session, throwsStateError);
    },
  );

  test(
    'pending attachment cannot write after its controller departs',
    () async {
      registerChat();
      final ready = Completer<void>();
      late MainContentAccess access;
      var rejected = false;
      register('test.pending', (value) async {
        access = value;
        await ready.future;
        try {
          value.open(pane('late'));
        } on StateError {
          rejected = true;
        }
      });
      controller.reconcile();
      expect(access.session, same(session));
      controller.dispose();
      ready.complete();
      await Future<void>.delayed(Duration.zero);
      expect(rejected, isTrue);
      expect(access.isActive, isFalse);
      expect(controller.entries, isEmpty);
    },
  );
}
