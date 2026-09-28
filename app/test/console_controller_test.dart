import 'dart:async';

import 'package:adele_desktop/ui/console/console_controller.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ExtensionRegistry registry;
  late ConsoleController controller;
  late Session first;
  late Session second;

  setUp(() {
    registry = ExtensionRegistry();
    first = _session('first');
    second = _session('second');
    controller = ConsoleController(
      registry,
      cleanupTimeout: const Duration(milliseconds: 10),
    )..setSession(first);
  });

  tearDown(() async {
    await controller.close();
    controller.dispose();
  });

  Future<ExtensionRegistration> register(
    Future<void> Function(ConsoleCreationAccess) create, {
    String id = 'test.console',
    List<ConsoleCreationAction>? actions,
  }) async {
    final registration = registry.register(
      point: consoleContributions,
      id: ExtensionId(id),
      value: ConsoleContribution(
        actions:
            actions ??
            [ConsoleCreationAction(id: 'open', label: 'Open', create: create)],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    return registration;
  }

  Future<_Content> open({
    String title = 'Evidence',
    bool Function(Session)? eligible,
    ConsoleCloseAdvice? Function()? advice,
    Future<ConsoleCleanupResult> Function()? release,
  }) async {
    final content = _Content(
      title,
      eligible: eligible,
      advice: advice,
      release: release,
    );
    await register((access) async => content.open(access));
    await controller.invoke(controller.actions.single);
    return content;
  }

  test('zero contributions do not synthesize a console', () {
    expect(controller.actions, isEmpty);
    expect(controller.eligibleTabs, isEmpty);
    expect(controller.selectedPresentation, isNull);
  });

  test(
    'actions compose in deterministic identity order; getters are immutable',
    () async {
      await register((_) async {}, id: 'test.z');
      await register(
        (_) async {},
        id: 'test.a',
        actions: [
          ConsoleCreationAction(id: 'z', label: 'Z', create: (_) async {}),
          ConsoleCreationAction(id: 'a', label: 'A', create: (_) async {}),
        ],
      );
      expect(controller.actions.map((a) => '${a.contributionId}/${a.id}'), [
        'test.a/a',
        'test.a/z',
        'test.z/open',
      ]);
      expect(() => controller.actions.clear(), throwsUnsupportedError);
      expect(() => controller.eligibleTabs.clear(), throwsUnsupportedError);
    },
  );

  test(
    'completion updates metadata and retains generic read-only evidence',
    () async {
      final content = await open();
      final tab = controller.selectedTab!;
      expect(content.mounts, isEmpty);
      controller.selectedPresentation;
      content.complete('Finished: 42 records');
      expect(tab.metadata.status, ConsoleStatus.completed);
      expect(tab.metadata.description, 'Finished: 42 records');
      expect(content.evidence, ['Finished: 42 records']);
      expect(controller.eligibleTabs, [tab]);
      expect(content.releases, 0);
      expect(content.mounts.single.isActive, isTrue);
    },
  );

  test(
    'creation coalesces per exact action/context and survives navigation',
    () async {
      final gate = Completer<void>();
      final content = _Content('First only', eligible: (s) => s.id == first.id);
      late ConsoleCreationAccess captured;
      var calls = 0;
      await register((access) async {
        calls++;
        captured = access;
        await gate.future;
        content.open(access);
      });
      final choice = controller.actions.single;
      final pending = controller.invoke(choice);
      expect(controller.invoke(choice), same(pending));
      expect(choice.isPending, isTrue);
      controller.setSession(second);
      expect(captured.session, same(first));
      expect(captured.isActive, isTrue);
      expect(choice.isActive, isFalse);
      await controller.invoke(choice);
      gate.complete();
      await pending;
      expect(calls, 1);
      expect(content.registration.isActive, isTrue);
      expect(controller.eligibleTabs, isEmpty);
      expect(controller.selectedTab, isNull);
      controller.setSession(first);
      expect(controller.eligibleTabs.single.metadata.title, 'First only');
      expect(controller.selectedTab, controller.eligibleTabs.single);
    },
  );

  test(
    'late eligible result never selects itself in the new context',
    () async {
      final gate = Completer<void>();
      final late = _Content('Late');
      await register((access) async {
        await gate.future;
        late.open(access);
      });
      final pending = controller.invoke(controller.actions.single);
      controller.setSession(second);
      gate.complete();
      await pending;
      expect(controller.eligibleTabs, hasLength(1));
      expect(controller.selectedTab, isNull);
      expect(controller.selectedPresentation, isNull);
      expect(late.mounts, isEmpty);
      controller.setSession(first);
      expect(controller.selectedTab, isNotNull);
    },
  );

  test('host close fences late open and performs bounded cleanup', () async {
    final gate = Completer<void>();
    final content = _Content('Late');
    late ConsoleCreationAccess access;
    await register((value) async {
      access = value;
      await gate.future;
      content.open(value);
    });
    final pending = controller.invoke(controller.actions.single);
    await controller.close();
    expect(access.isActive, isFalse);
    gate.complete();
    await pending;
    await content.registration.requestRemoval();
    expect(content.registration.isActive, isFalse);
    expect(content.releases, 1);
    expect(content.mounts, isEmpty);
    expect(controller.eligibleTabs, isEmpty);
  });

  for (final fails in [false, true]) {
    test(
      'creation settlement revokes retained access (failure: $fails)',
      () async {
        late ConsoleCreationAccess access;
        await register((value) async {
          access = value;
          expect(access.isActive, isTrue);
          if (fails) throw StateError('private error');
        });
        await controller.invoke(controller.actions.single);
        expect(access.isActive, isFalse);
        final lateContent = _Content('After settlement');
        lateContent.open(access);
        await lateContent.registration.requestRemoval();
        expect(lateContent.registration.isActive, isFalse);
        expect(lateContent.releases, 1);
        expect(controller.eligibleTabs, isEmpty);
      },
    );
  }

  test('selection, order, and evidence survive Session navigation', () async {
    final contents = [_Content('One'), _Content('Two')];
    var index = 0;
    await register((access) async => contents[index++].open(access));
    await controller.invoke(controller.actions.single);
    await controller.invoke(controller.actions.single);
    final tabs = controller.eligibleTabs;
    controller.select(tabs.first);
    controller.setSession(second);
    controller.select(tabs.last);
    controller.setSession(null);
    expect(controller.actions, isEmpty);
    expect(controller.eligibleTabs, isEmpty);
    controller.setSession(first);
    expect(controller.selectedTab, same(tabs.first));
    expect(controller.eligibleTabs, tabs);
    controller.setSession(second);
    expect(controller.selectedTab, same(tabs.last));
    expect(contents.every((content) => content.releases == 0), isTrue);
  });

  test(
    'a new Session keeps the selected tab when its eligibility is shared',
    () async {
      final contents = [_Content('One'), _Content('Two')];
      var index = 0;
      await register((access) async => contents[index++].open(access));
      await controller.invoke(controller.actions.single);
      await controller.invoke(controller.actions.single);
      final selected = controller.selectedTab;
      controller.setSession(second);
      expect(controller.selectedTab, same(selected));
      controller.select(controller.eligibleTabs.first);
      controller.setSession(first);
      expect(controller.selectedTab, same(selected));
    },
  );

  test(
    'selected removal chooses the next eligible neighbor, then the previous',
    () async {
      final contents = [
        _Content('One'),
        _Content('Two'),
        _Content('Hidden', eligible: (session) => session.id == second.id),
        _Content('Three'),
      ];
      var index = 0;
      await register((access) async => contents[index++].open(access));
      await controller.invoke(controller.actions.single);
      await controller.invoke(controller.actions.single);
      controller.setSession(second);
      await controller.invoke(controller.actions.single);
      await controller.invoke(controller.actions.single);
      controller.setSession(first);
      controller.select(controller.eligibleTabs[1]);
      await contents[1].registration.requestRemoval();
      expect(controller.selectedTab!.metadata.title, 'Three');
      await contents[3].registration.requestRemoval();
      expect(controller.selectedTab!.metadata.title, 'One');
      expect(contents.every((content) => content.mounts.isEmpty), isTrue);
    },
  );

  test(
    'presentation access is fresh and permanently revoked on every departure',
    () async {
      final content = await open();
      final firstWidget = controller.selectedPresentation;
      final initial = content.mounts.single;
      expect(controller.selectedPresentation, same(firstWidget));
      controller.setVisible(false);
      expect(initial.isActive, isFalse);
      expect(controller.selectedPresentation, isNull);
      controller.setVisible(true);
      controller.selectedPresentation;
      final afterHide = content.mounts.last;
      expect(afterHide, isNot(same(initial)));
      controller.setSession(second);
      expect(afterHide.isActive, isFalse);
      controller.selectedPresentation;
      final afterContext = content.mounts.last;
      controller.unmountPresentation();
      expect(afterContext.isActive, isFalse);
      controller.selectedPresentation;
      expect(content.mounts.last.isActive, isTrue);
      expect(initial.isActive, isFalse);
      expect(content.releases, 0);
    },
  );

  test(
    'metadata authority stays with exact content, even while unmounted',
    () async {
      final one = _Content('One');
      final two = _Content('Two');
      await register((a) async => one.open(a), id: 'test.one');
      await register((a) async => two.open(a), id: 'test.two');
      await controller.invoke(controller.actions.first);
      await controller.invoke(controller.actions.last);
      controller.setVisible(false);
      one.complete('Retained');
      expect(
        controller.eligibleTabs.first.metadata.status,
        ConsoleStatus.completed,
      );
      expect(
        controller.eligibleTabs.last.metadata.status,
        ConsoleStatus.running,
      );
      await one.registration.requestRemoval();
      one.registration.updateMetadata(ConsoleMetadata(title: 'Stale update'));
      expect(controller.eligibleTabs.single.metadata.title, 'Two');
      expect(two.registration.isActive, isTrue);
      expect(one.mounts, isEmpty);
      expect(two.mounts, isEmpty);
    },
  );

  test('foreign host choices and tabs cannot confer authority', () async {
    final content = await open();
    final other = ConsoleController(registry)..setSession(first);
    addTearDown(other.dispose);
    await other.invoke(controller.actions.single);
    other.select(controller.selectedTab!);
    var confirms = 0;
    await other.closeTab(controller.selectedTab!, (_) async {
      confirms++;
      return true;
    });
    expect(other.eligibleTabs, isEmpty);
    expect(confirms, 0);
    expect(content.registration.isActive, isTrue);
  });

  test(
    'stale action never invokes a replacement with identical identity/value',
    () async {
      var calls = 0;
      final registration = await register((_) async {
        calls++;
      });
      final old = controller.actions.single;
      final value = registry.discover(consoleContributions).single.value;
      await registration.close();
      registry.register(
        point: consoleContributions,
        id: old.contributionId,
        value: value,
      );
      await Future<void>.delayed(Duration.zero);
      await controller.invoke(old);
      expect(calls, 0);
      await controller.invoke(controller.actions.single);
      expect(calls, 1);
    },
  );

  test(
    'cancelling confirmation has no removal, selection, or mount effects',
    () async {
      final content = await open();
      final tab = controller.selectedTab!;
      var message = '';
      await controller.closeTab(tab, (value) async {
        message = value;
        return false;
      });
      expect(message, 'Close this console?');
      expect(controller.selectedTab, same(tab));
      expect(content.registration.isActive, isTrue);
      expect(content.releases, 0);
      expect(content.mounts, isEmpty);
    },
  );

  test(
    'unknown or throwing advice uses generic confirmation, not a veto',
    () async {
      final content = await open(
        advice: () => throw StateError('private detail'),
      );
      await controller.closeTab(controller.selectedTab!, (message) async {
        expect(message, 'Close this console?');
        return true;
      });
      expect(content.releases, 1);
      expect(controller.eligibleTabs, isEmpty);
      expect(controller.warning, isNull);
    },
  );

  test(
    'no-confirmation close revokes immediately, before slow cleanup',
    () async {
      final release = Completer<ConsoleCleanupResult>();
      final content = await open(
        advice: () => const ConsoleCloseAdvice.noConfirmation(),
        release: () => release.future,
      );
      controller.selectedPresentation;
      final access = content.mounts.single;
      final closing = controller.closeTab(controller.selectedTab!, (_) async {
        fail('No confirmation was requested');
      });
      expect(access.isActive, isFalse);
      expect(content.registration.isActive, isFalse);
      expect(controller.eligibleTabs, isEmpty);
      release.complete(ConsoleCleanupResult());
      await closing;
    },
  );

  for (final departure in ['session', 'hide', 'selection', 'unmount']) {
    test('delayed confirmation is inert after $departure', () async {
      final one = _Content('One');
      final two = _Content('Two');
      var count = 0;
      await register((a) async => (count++ == 0 ? one : two).open(a));
      await controller.invoke(controller.actions.single);
      await controller.invoke(controller.actions.single);
      controller.selectedPresentation;
      final gate = Completer<bool>();
      final closing = controller.closeTab(
        controller.selectedTab!,
        (_) => gate.future,
      );
      switch (departure) {
        case 'session':
          controller.setSession(second);
        case 'hide':
          controller.setVisible(false);
        case 'selection':
          controller.select(controller.eligibleTabs.first);
        case 'unmount':
          controller.unmountPresentation();
      }
      gate.complete(true);
      await closing;
      expect(two.registration.isActive, isTrue);
      expect(two.releases, 0);
    });
  }

  test(
    'closing an unselected tab never invokes its presentation factory',
    () async {
      final one = _Content(
        'One',
        advice: () => const ConsoleCloseAdvice.noConfirmation(),
      );
      final two = _Content('Two');
      var count = 0;
      await register((a) async => (count++ == 0 ? one : two).open(a));
      await controller.invoke(controller.actions.single);
      await controller.invoke(controller.actions.single);
      final selected = controller.selectedTab;
      final widget = controller.selectedPresentation;
      await controller.closeTab(
        controller.eligibleTabs.first,
        (_) async => true,
      );
      expect(one.mounts, isEmpty);
      expect(controller.selectedTab, same(selected));
      expect(controller.selectedPresentation, same(widget));
      expect(two.mounts.single.isActive, isTrue);
    },
  );

  test('auto-removal and delayed confirmation coalesce cleanup', () async {
    final content = await open();
    final gate = Completer<bool>();
    final tab = controller.selectedTab!;
    final closing = controller.closeTab(tab, (_) => gate.future);
    expect(controller.closeTab(tab, (_) async => false), same(closing));
    final removal = content.registration.requestRemoval();
    expect(content.registration.requestRemoval(), same(removal));
    await Future.wait([closing, removal]);
    expect(content.releases, 1);
    expect(controller.eligibleTabs, isEmpty);
    gate.complete(true);
    await Future<void>.delayed(Duration.zero);
  });

  for (final failure in ['throw', 'stall', 'warning']) {
    test(
      '$failure cleanup never vetoes removal and leaves a safe external warning',
      () async {
        final stalled = Completer<ConsoleCleanupResult>();
        final content = await open(
          release: () {
            if (failure == 'throw') throw StateError('SECRET-EXCEPTION');
            if (failure == 'stall') return stalled.future;
            return Future.value(
              ConsoleCleanupResult(
                warning: 'Resource may remain.\n${'x' * 300}',
              ),
            );
          },
        );
        await content.registration.requestRemoval();
        expect(controller.eligibleTabs, isEmpty);
        expect(content.registration.isActive, isFalse);
        expect(content.releases, 1);
        expect(controller.warning, isNotNull);
        expect(controller.warning, isNot(contains('SECRET-EXCEPTION')));
        expect(controller.warning!.length, lessThanOrEqualTo(240));
        if (failure == 'stall') {
          stalled.completeError(StateError('late failure'));
        }
        await Future<void>.delayed(Duration.zero);
      },
    );
  }

  test('retirement removes only exact owner and ignores advice', () async {
    final one = _Content('One', advice: () => throw StateError('Do not ask'));
    final two = _Content('Two');
    late ConsoleCreationAccess captured;
    final owner = await register((a) async {
      captured = a;
      one.open(a);
    }, id: 'test.one');
    await register((a) async => two.open(a), id: 'test.two');
    await controller.invoke(controller.actions.first);
    await controller.invoke(controller.actions.last);
    final selected = controller.selectedTab;
    controller.selectedPresentation;
    final presentation = two.mounts.single;
    await owner.close();
    expect(one.registration.isActive, isFalse);
    expect(captured.isActive, isFalse);
    final late = _Content('Late');
    late.open(captured);
    await late.registration.requestRemoval();
    await Future<void>.delayed(Duration.zero);
    expect(one.releases, 1);
    expect(late.releases, 1);
    expect(two.releases, 0);
    expect(controller.selectedTab, same(selected));
    expect(presentation.isActive, isTrue);
  });

  test(
    'retired pending creation cannot transfer its result to a replacement',
    () async {
      final gate = Completer<void>();
      late ConsoleCreationAccess captured;
      final content = _Content('Retired result');
      final owner = await register((access) async {
        captured = access;
        await gate.future;
        content.open(access);
      });
      final pending = controller.invoke(controller.actions.single);
      expect(captured.isActive, isTrue);
      await owner.close();
      await register((_) async {});
      expect(captured.isActive, isFalse);
      gate.complete();
      await pending;
      await content.registration.requestRemoval();
      expect(content.releases, 1);
      expect(content.registration.isActive, isFalse);
      expect(controller.eligibleTabs, isEmpty);
      expect(controller.actions.single.isActive, isTrue);
    },
  );

  test('forced close skips advice and coalesces repeated shutdown', () async {
    final content = await open(advice: () => throw StateError('Do not ask'));
    controller.selectedPresentation;
    final closing = controller.close();
    expect(controller.close(), same(closing));
    expect(content.mounts.single.isActive, isFalse);
    await closing;
    expect(content.releases, 1);
  });

  test('ineligible admission releases content instead of leaking it', () async {
    final content = await open(eligible: (_) => false);
    await content.registration.requestRemoval();
    expect(content.registration.isActive, isFalse);
    expect(content.releases, 1);
    expect(controller.eligibleTabs, isEmpty);
  });

  test(
    'creation/factory failures show generic errors without changing evidence',
    () async {
      await register((access) async {
        access.open(
          ConsoleContent(
            metadata: ConsoleMetadata(title: 'Kept'),
            isEligible: (_) => true,
            createPresentation: (_) => throw StateError('SECRET-FACTORY'),
            release: () async => ConsoleCleanupResult(),
          ),
        );
        throw StateError('SECRET-CREATE');
      });
      await controller.invoke(controller.actions.single);
      final firstWidget = controller.selectedPresentation;
      expect(firstWidget, isNotNull);
      expect(controller.selectedPresentation, same(firstWidget));
      expect(controller.eligibleTabs.single.metadata.title, 'Kept');
      expect(controller.warning, 'The console could not be created.');
    },
  );
}

Session _session(String id) => Session(
  id: SessionId(id),
  taskId: TaskId('task'),
  strategyId: OrchestrationStrategyId('test.strategy'),
);

/// Test-only read-only output, with no terminal/process/Environment dependencies.
class _Content {
  _Content(this.title, {this.eligible, this.advice, this.release});

  final String title;
  final bool Function(Session)? eligible;
  final ConsoleCloseAdvice? Function()? advice;
  final Future<ConsoleCleanupResult> Function()? release;
  final List<String> evidence = [];
  final List<ConsolePresentationAccess> mounts = [];
  late ConsoleTabRegistration registration;
  var releases = 0;

  void open(ConsoleCreationAccess access) {
    registration = access.open(
      ConsoleContent(
        metadata: ConsoleMetadata(title: title, status: ConsoleStatus.running),
        isEligible: eligible ?? (_) => true,
        createPresentation: (access) {
          mounts.add(access);
          return Text(evidence.join('\n'));
        },
        closeAdvice: advice,
        release: () {
          releases++;
          return release?.call() ?? Future.value(ConsoleCleanupResult());
        },
      ),
    );
  }

  void complete(String text) {
    evidence.add(text);
    registration.updateMetadata(
      ConsoleMetadata(
        title: title,
        description: text,
        status: ConsoleStatus.completed,
      ),
    );
  }
}
