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

  ConsoleContentDescriptor descriptor(String key, {String title = 'Output'}) =>
      ConsoleContentDescriptor(
        key: key,
        metadata: ConsoleMetadata(title: title),
        data: {'key': key},
      );

  ExtensionBinding<ConsoleContribution> prepared(
    Future<void> Function(ConsoleCreationAccess, ConsoleContentDescriptor)
    create, {
    String id = 'test.prepared',
  }) {
    registry.register(
      point: consoleContributions,
      id: ExtensionId(id),
      value: ConsoleContribution(actions: [], openPrepared: create),
    );
    return registry
        .discover(consoleContributions)
        .singleWhere((entry) => entry.id.value == id);
  }

  test(
    'prepared double open joins, reveals and focuses without replacing content',
    () async {
      final gate = Completer<void>();
      final contents = <_Content>[];
      final owner = prepared((access, data) async {
        final content = _Content(data.metadata.title);
        contents.add(content);
        content.open(access);
        await gate.future;
      });
      controller.setVisible(false);
      final opening = controller.openOrFocus(
        owner: owner,
        session: first,
        descriptor: descriptor('one'),
      );
      expect(controller.visible, isTrue);
      final tab = controller.selectedTab;
      expect(
        controller.openOrFocus(
          owner: owner,
          session: first,
          descriptor: descriptor('one', title: 'Replacement'),
        ),
        same(opening),
      );
      gate.complete();
      await opening;
      expect(contents, hasLength(1));
      expect(tab!.metadata.title, 'Output');
      await controller.openOrFocus(
        owner: owner,
        session: first,
        descriptor: descriptor('two'),
      );
      expect(controller.eligibleTabs, hasLength(2));
      controller.setVisible(false);
      await controller.openOrFocus(
        owner: owner,
        session: first,
        descriptor: descriptor('one'),
      );
      expect(controller.selectedTab, same(tab));
      expect(controller.visible, isTrue);
      expect(contents, hasLength(2));
      expect(contents.every((content) => content.releases == 0), isTrue);
    },
  );

  test(
    'prepared navigation while opening keeps exact Session and does not steal focus',
    () async {
      final gate = Completer<void>();
      final content = _Content('Retained');
      final owner = prepared((access, _) async {
        await gate.future;
        content.open(access);
      });
      final opening = controller.openOrFocus(
        owner: owner,
        session: first,
        descriptor: descriptor('one'),
      );
      controller.setSession(second);
      gate.complete();
      await opening;
      expect(content.registration.isActive, isTrue);
      expect(controller.eligibleTabs, isEmpty);
      expect(controller.selectedTab, isNull);
      controller.setSession(_session('first'));
      expect(controller.eligibleTabs, isEmpty);
      controller.setSession(first);
      expect(controller.selectedTab!.metadata.title, 'Retained');
      controller.selectedPresentation;
      final view = content.mounts.single;
      controller.setSession(null);
      expect(view.isActive, isFalse);
      expect(controller.eligibleTabs, isEmpty);
      await expectLater(
        controller.openOrFocus(
          owner: owner,
          session: first,
          descriptor: descriptor('one'),
        ),
        throwsStateError,
      );
      expect(content.releases, 0);
    },
  );

  for (final departure in ['close', 'retire', 'replace']) {
    test('prepared reveal admits before a listener can $departure', () async {
      final gate = Completer<void>();
      final events = <String>[];
      final content = _Content('Late');
      late ConsoleCreationAccess captured;
      var replacements = 0;
      final registration = registry.register(
        point: consoleContributions,
        id: ExtensionId('test.reentrant'),
        value: ConsoleContribution(
          actions: [],
          openPrepared: (access, _) async {
            events.add('admitted');
            captured = access;
            expect(access.isActive, isTrue);
            expect(access.session, same(first));
            await gate.future;
            content.open(access);
          },
        ),
      );
      final owner = registry.discover(consoleContributions).single;
      controller.setVisible(false);
      Future<void>? retirement;
      var revealed = false;
      controller.addListener(() {
        if (revealed || !controller.visible) return;
        revealed = true;
        events.add('revealed');
        if (departure == 'close') {
          retirement = controller.close();
        } else {
          retirement = registration.close();
          if (departure == 'replace') {
            registry.register(
              point: consoleContributions,
              id: owner.id,
              value: ConsoleContribution(
                actions: [],
                openPrepared: (_, _) async {
                  replacements++;
                },
              ),
            );
          }
        }
      });
      final opening = controller.openOrFocus(
        owner: owner,
        session: first,
        descriptor: descriptor('same'),
      );
      expect(events, ['admitted', 'revealed']);
      expect(captured.isActive, isFalse);
      await retirement;
      gate.complete();
      await opening;
      await content.registration.requestRemoval();
      expect(content.registration.isActive, isFalse);
      expect(content.releases, 1);
      expect(controller.eligibleTabs, isEmpty);
      expect(replacements, 0);
    });
  }

  for (final alreadyPending in [false, true]) {
    test(
      'prepared reveal preserves original intent across listener navigation (pending: $alreadyPending)',
      () async {
        await open(title: 'Keep selected');
        final selected = controller.selectedTab;
        final gate = Completer<void>();
        final content = _Content('Late');
        var calls = 0;
        late ConsoleCreationAccess captured;
        final owner = prepared((access, _) async {
          calls++;
          captured = access;
          await gate.future;
          content.open(access);
        });
        final pending = alreadyPending
            ? controller.openOrFocus(
                owner: owner,
                session: first,
                descriptor: descriptor('late'),
              )
            : null;
        controller.setVisible(false);
        var revealed = false;
        controller.addListener(() {
          if (revealed || !controller.visible) return;
          revealed = true;
          expect(calls, 1);
          controller.setSession(second);
          controller.setSession(first);
        });
        final opening = controller.openOrFocus(
          owner: owner,
          session: first,
          descriptor: descriptor('late'),
        );
        if (pending != null) expect(opening, same(pending));
        expect(revealed, isTrue);
        expect(calls, 1);
        expect(captured.session, same(first));
        expect(captured.isActive, isTrue);
        gate.complete();
        await opening;
        expect(content.registration.isActive, isTrue);
        expect(controller.eligibleTabs, hasLength(2));
        expect(controller.selectedTab, same(selected));
        expect(content.releases, 0);
        await controller.openOrFocus(
          owner: owner,
          session: first,
          descriptor: descriptor('late'),
        );
        expect(controller.selectedTab!.metadata.title, 'Late');
        expect(calls, 1);
      },
    );
  }

  test(
    'prepared keys are separate across Sessions and registrations',
    () async {
      final contents = <_Content>[];
      Future<void> create(
        ConsoleCreationAccess access,
        ConsoleContentDescriptor _,
      ) async {
        final content = _Content('Independent');
        contents.add(content);
        content.open(access);
      }

      final one = prepared(create);
      final two = prepared(create, id: 'test.second');
      await controller.openOrFocus(
        owner: one,
        session: first,
        descriptor: descriptor('same'),
      );
      await controller.openOrFocus(
        owner: two,
        session: first,
        descriptor: descriptor('same'),
      );
      expect(controller.eligibleTabs, hasLength(2));
      controller.setSession(second);
      await controller.openOrFocus(
        owner: one,
        session: second,
        descriptor: descriptor('same'),
      );
      expect(controller.eligibleTabs, hasLength(1));
      expect(contents, hasLength(3));
      controller.setSession(first);
      expect(controller.eligibleTabs, hasLength(2));
    },
  );

  test('pending prepared content cannot steal a newer tab selection', () async {
    final gate = Completer<void>();
    final owner = prepared((access, descriptor) async {
      if (descriptor.key == 'late') await gate.future;
      _Content(descriptor.key).open(access);
    });
    await controller.openOrFocus(
      owner: owner,
      session: first,
      descriptor: descriptor('one'),
    );
    final firstTab = controller.selectedTab;
    await controller.openOrFocus(
      owner: owner,
      session: first,
      descriptor: descriptor('two'),
    );
    final pending = controller.openOrFocus(
      owner: owner,
      session: first,
      descriptor: descriptor('late'),
    );
    controller.select(firstTab!);
    gate.complete();
    await pending;
    expect(controller.eligibleTabs, hasLength(3));
    expect(controller.selectedTab, same(firstTab));
    await controller.openOrFocus(
      owner: owner,
      session: first,
      descriptor: descriptor('late'),
    );
    expect(controller.selectedTab!.metadata.title, 'late');
  });

  test('prepared closed tab is not resurrected by late settlement', () async {
    final gate = Completer<void>();
    final contents = <_Content>[];
    late ConsoleCreationAccess oldAccess;
    final owner = prepared((access, _) async {
      final content = _Content(
        'Output',
        advice: () => const ConsoleCloseAdvice.noConfirmation(),
      );
      contents.add(content);
      content.open(access);
      if (contents.length == 1) {
        oldAccess = access;
        await gate.future;
      }
    });
    final opening = controller.openOrFocus(
      owner: owner,
      session: first,
      descriptor: descriptor('same'),
    );
    await controller.closeTab(
      controller.selectedTab!,
      (_) async => fail('No confirmation'),
    );
    expect(oldAccess.isActive, isFalse);
    final lateTransfer = _Content('Late duplicate');
    lateTransfer.open(oldAccess);
    await lateTransfer.registration.requestRemoval();
    expect(lateTransfer.registration.isActive, isFalse);
    expect(lateTransfer.releases, 1);
    await controller.openOrFocus(
      owner: owner,
      session: first,
      descriptor: descriptor('same'),
    );
    final replacement = controller.selectedTab;
    gate.complete();
    await opening;
    expect(controller.eligibleTabs, [replacement]);
    expect(contents.first.releases, 1);
    expect(contents.last.releases, 0);
  });

  for (final closeHost in [false, true]) {
    test(
      'prepared late admission fenced by ${closeHost ? 'host close' : 'owner replacement'}',
      () async {
        final gate = Completer<void>();
        final content = _Content('Late');
        final value = ConsoleContribution(
          actions: [],
          openPrepared: (access, _) async {
            await gate.future;
            content.open(access);
          },
        );
        final registration = registry.register(
          point: consoleContributions,
          id: ExtensionId('test.owner'),
          value: value,
        );
        final owner = registry.discover(consoleContributions).single;
        final opening = controller.openOrFocus(
          owner: owner,
          session: first,
          descriptor: descriptor('same'),
        );
        if (closeHost) {
          await controller.close();
        } else {
          await registration.close();
          registry.register(
            point: consoleContributions,
            id: owner.id,
            value: value,
          );
        }
        gate.complete();
        await opening;
        await content.registration.requestRemoval();
        expect(content.registration.isActive, isFalse);
        expect(content.releases, 1);
        expect(controller.eligibleTabs, isEmpty);
        await expectLater(
          controller.openOrFocus(
            owner: owner,
            session: first,
            descriptor: descriptor('same'),
          ),
          throwsStateError,
        );
      },
    );
  }

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
    'resident budget is lazy LRU, including selected-only content',
    () async {
      await controller.close();
      controller.dispose();
      controller = ConsoleController(registry, presentationLimit: 2)
        ..setSession(first);
      final contents = [
        _Content('A', keepAlive: true),
        _Content('B', keepAlive: true),
        _Content('C', keepAlive: true),
        _Content('Selected only'),
      ];
      var next = 0;
      await register((access) async => contents[next++].open(access));
      for (final _ in contents) {
        await controller.invoke(controller.actions.single);
      }
      final tabs = controller.eligibleTabs;
      expect(contents.every((content) => content.mounts.isEmpty), isTrue);
      controller.select(tabs[0]);
      final a = controller.selectedPresentation;
      final accessA = contents[0].mounts.single;
      final firstInteraction = accessA.interaction!;
      var changes = 0;
      accessA.changes.addListener(() => changes++);
      controller.select(tabs[1]);
      expect(firstInteraction.isActive, isFalse);
      expect(accessA.isActive, isTrue);
      expect(accessA.interaction, isNull);
      final b = controller.selectedPresentation;
      controller.select(tabs[0]);
      expect(controller.selectedPresentation, same(a));
      expect(accessA.interaction!.isActive, isTrue);
      expect(firstInteraction.isActive, isFalse);
      expect(changes, 2);
      // Hidden output and metadata are not selection recency.
      contents[1].complete('new output');
      controller.select(tabs[2]);
      controller.selectedPresentation;
      expect(controller.residentPresentations.map((entry) => entry.tab), [
        tabs[0],
        tabs[2],
      ]);
      expect(contents[1].mounts.single.isActive, isFalse);
      expect(contents[2].mounts.single.interaction!.isActive, isTrue);
      expect(controller.eligibleTabs, tabs);
      expect(contents.every((content) => content.releases == 0), isTrue);
      controller.select(tabs[3]);
      controller.selectedPresentation;
      expect(accessA.isActive, isFalse);
      expect(controller.residentPresentations, hasLength(2));
      final transient = contents[3].mounts.single;
      controller.select(tabs[2]);
      expect(transient.isActive, isFalse);
      expect(controller.residentPresentations, hasLength(1));
      controller.select(tabs[1]);
      expect(controller.selectedPresentation, isNot(same(b)));
      expect(contents[1].mounts, hasLength(2));
      expect(contents[1].mounts.first.isActive, isFalse);
      expect(contents.every((content) => content.releases == 0), isTrue);
    },
  );

  for (final keepAlive in [false, true]) {
    for (final throws in [false, true]) {
      test(
        'selected eligibility loss is permanent (resident: $keepAlive, throws: $throws)',
        () async {
          var eligible = true;
          final content = _Content(
            'Mutable',
            keepAlive: keepAlive,
            eligible: (_) {
              if (!eligible && throws) throw StateError('private predicate');
              return eligible;
            },
          );
          await register((access) async => content.open(access));
          await controller.invoke(controller.actions.single);
          final tab = controller.selectedTab!;
          final resident = controller.residentPresentations.single;
          final access = resident.access;
          final interaction = access.interaction!;
          var revocations = 0;
          access.changes.addListener(() {
            if (!access.isActive) revocations++;
          });
          eligible = false;
          // Neither a frame nor a controller notification is needed to fence use.
          expect(interaction.isActive, isFalse);
          expect(access.isActive, isFalse);
          expect(access.interaction, isNull);
          expect(revocations, 1);
          expect(controller.residentPresentations, isEmpty);
          expect(controller.selectedTab, isNull);
          expect(controller.selectedPresentation, isNull);
          expect(controller.residentPresentations, isEmpty);
          expect(revocations, 1);
          expect(content.releases, 0);
          expect(content.registration.isActive, isTrue);
          eligible = true;
          expect(access.isActive, isFalse);
          expect(interaction.isActive, isFalse);
          controller.select(tab);
          final fresh = controller.residentPresentations.single;
          expect(fresh, isNot(same(resident)));
          expect(fresh.access, isNot(same(access)));
          expect(fresh.access.isActive, isTrue);
          expect(fresh.access.interaction!.isActive, isTrue);
          expect(content.mounts, hasLength(2));
          expect(content.releases, 0);
        },
      );
    }
  }

  for (final throws in [false, true]) {
    test(
      'hidden eligibility loss preserves warm sibling (throws: $throws)',
      () async {
        var eligible = true;
        final a = _Content(
          'A',
          keepAlive: true,
          eligible: (_) {
            if (!eligible && throws) throw StateError('private predicate');
            return eligible;
          },
        );
        final b = _Content('B', keepAlive: true);
        var next = 0;
        await register((access) async => (next++ == 0 ? a : b).open(access));
        await controller.invoke(controller.actions.single);
        final residentA = controller.residentPresentations.single;
        await controller.invoke(controller.actions.single);
        final widgetB = controller.selectedPresentation;
        final residentB = controller.residentPresentations.last;
        final interactionB = residentB.access.interaction!;
        eligible = false;
        // Collection reconciliation must inspect hidden members, not only selection.
        expect(controller.residentPresentations, [same(residentB)]);
        expect(residentA.access.isActive, isFalse);
        expect(controller.selectedTab, same(residentB.tab));
        expect(controller.selectedPresentation, same(widgetB));
        expect(residentB.access.interaction, same(interactionB));
        expect(interactionB.isActive, isTrue);
        expect(b.mounts, hasLength(1));
        expect(a.releases, 0);
        expect(b.releases, 0);
        eligible = true;
        expect(controller.residentPresentations, [same(residentB)]);
        expect(residentA.access.isActive, isFalse);
        expect(a.mounts, hasLength(1));
        controller.select(residentA.tab);
        expect(controller.residentPresentations, hasLength(2));
        expect(a.mounts, hasLength(2));
        expect(a.mounts.last.isActive, isTrue);
        expect(b.mounts, hasLength(1));
      },
    );
  }

  test(
    'eligibility reconciliation isolates failing and reentrant listeners',
    () async {
      var valid = true;
      var inspecting = false;
      ConsolePresentationAccess? accessA;
      final a = _Content(
        'A',
        keepAlive: true,
        eligible: (_) {
          if (inspecting) {
            // Contributed eligibility cannot recursively evaluate another predicate
            // or construct the currently selected presentation through these getters.
            expect(accessA!.isActive, isFalse);
            expect(controller.selectedPresentation, isNull);
            controller.eligibleTabs;
          }
          return valid;
        },
      );
      final b = _Content(
        'B',
        keepAlive: true,
        eligible: (_) {
          if (!valid) throw StateError('predicate failure');
          return true;
        },
      );
      final c = _Content('C', keepAlive: true);
      final contents = [a, b, c];
      var next = 0;
      await register((access) async => contents[next++].open(access));
      for (final _ in contents) {
        await controller.invoke(controller.actions.single);
        controller.selectedPresentation;
      }
      accessA = a.mounts.single;
      final survivor = controller.residentPresentations.last;
      final interaction = survivor.access.interaction;
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);
      var notifications = 0;
      accessA.changes.addListener(() => throw StateError('listener failure'));
      accessA.changes.addListener(() {
        notifications++;
        expect(accessA!.isActive, isFalse);
        controller.residentPresentations;
        expect(b.mounts.single.isActive, isFalse);
      });
      valid = false;
      inspecting = true;
      expect(controller.residentPresentations, [same(survivor)]);
      inspecting = false;
      expect(controller.residentPresentations, [same(survivor)]);
      expect(survivor.access.interaction, same(interaction));
      expect(errors, hasLength(1));
      expect(errors.single.exception, isA<StateError>());
      expect(notifications, 1);
      expect(contents.every((content) => content.releases == 0), isTrue);
      expect(c.mounts, hasLength(1));
    },
  );

  test(
    'eligibility revocation cannot remove a listener-created replacement',
    () async {
      var valid = true;
      final content = _Content('A', keepAlive: true, eligible: (_) => valid);
      await register((access) async => content.open(access));
      await controller.invoke(controller.actions.single);
      final old = controller.residentPresentations.single;
      var notifications = 0;
      old.access.changes.addListener(() {
        notifications++;
        expect(old.access.isActive, isFalse);
        valid = true;
        controller.select(old.tab);
        controller.selectedPresentation;
      });
      valid = false;
      expect(old.access.isActive, isFalse);
      final replacement = controller.residentPresentations.single;
      expect(replacement, isNot(same(old)));
      expect(replacement.access.isActive, isTrue);
      expect(old.access.isActive, isFalse);
      expect(notifications, 1);
      expect(content.mounts, hasLength(2));
      expect(content.releases, 0);
    },
  );

  test(
    'eligibility checking does not expose a half-constructed resident',
    () async {
      var valid = true;
      var revokeInFactory = true;
      final content = _Content(
        'A',
        keepAlive: true,
        eligible: (_) => valid,
        onCreate: (access) {
          expect(access.isActive, isTrue);
          expect(controller.selectedPresentation, isNull);
          expect(controller.residentPresentations, isEmpty);
          if (revokeInFactory) valid = false;
          return const Text('Prepared');
        },
      );
      await register((access) async => content.open(access));
      await controller.invoke(controller.actions.single);
      final tab = controller.selectedTab!;
      expect(controller.selectedPresentation, isNull);
      expect(controller.residentPresentations, isEmpty);
      expect(content.mounts.single.isActive, isFalse);
      valid = true;
      revokeInFactory = false;
      controller.select(tab);
      expect(controller.residentPresentations, hasLength(1));
      expect(content.mounts, hasLength(2));
      expect(content.mounts.first.isActive, isFalse);
      expect(content.mounts.last.isActive, isTrue);
      expect(content.releases, 0);
    },
  );

  test('eligibility pruning does not change healthy LRU recency', () async {
    await controller.close();
    controller.dispose();
    controller = ConsoleController(registry, presentationLimit: 3)
      ..setSession(first);
    var valid = true;
    final contents = [
      _Content('A', keepAlive: true, eligible: (_) => valid),
      for (final label in ['B', 'C', 'D', 'E'])
        _Content(label, keepAlive: true),
    ];
    var next = 0;
    await register((access) async => contents[next++].open(access));
    for (final _ in contents) {
      await controller.invoke(controller.actions.single);
    }
    final tabs = controller.eligibleTabs;
    for (final tab in tabs.take(3)) {
      controller.select(tab);
      controller.selectedPresentation;
    }
    final c = controller.residentPresentations.last;
    final interaction = c.access.interaction;
    valid = false;
    contents[1].complete('notification, not selection');
    expect(contents.first.mounts.single.isActive, isFalse);
    expect(controller.residentPresentations, hasLength(2));
    expect(c.access.interaction, same(interaction));
    valid = true;
    expect(controller.residentPresentations, hasLength(2));
    for (final tab in tabs.skip(3)) {
      controller.select(tab);
      controller.selectedPresentation;
    }
    expect(contents[1].mounts.single.isActive, isFalse);
    expect(c.access.isActive, isTrue);
    expect(controller.residentPresentations.first, same(c));
    expect(contents.first.mounts, hasLength(1));
    expect(contents.every((content) => content.releases == 0), isTrue);
  });

  test(
    'eligibility loss withdraws a hidden unvisited close question',
    () async {
      var valid = true;
      final a = _Content('A', eligible: (_) => valid);
      final b = _Content('B', keepAlive: true);
      var next = 0;
      await register((access) async => (next++ == 0 ? a : b).open(access));
      await controller.invoke(controller.actions.single);
      final tab = controller.selectedTab!;
      await controller.invoke(controller.actions.single);
      final survivor = controller.residentPresentations.single;
      final answer = Completer<bool>();
      late ConsoleCloseRequest request;
      final closing = controller.closeTab(tab, (value) {
        request = value;
        return answer.future;
      });
      valid = false;
      b.complete('notification');
      expect(request.isPending, isFalse);
      await closing;
      valid = true;
      controller.select(tab);
      controller.selectedPresentation;
      answer.complete(true);
      await Future<void>.value();
      expect(a.releases, 0);
      expect(a.mounts, hasLength(1));
      expect(survivor.access.isActive, isTrue);
    },
  );

  test(
    'eligibility callback cannot carry selection into a different context',
    () async {
      var navigate = false;
      final content = _Content(
        'A',
        keepAlive: true,
        eligible: (_) {
          if (navigate) {
            navigate = false;
            controller.setSession(null);
          }
          return true;
        },
      );
      await register((access) async => content.open(access));
      await controller.invoke(controller.actions.single);
      final resident = controller.residentPresentations.single;
      navigate = true;
      controller.select(resident.tab);
      expect(controller.session, isNull);
      expect(controller.selectedTab, isNull);
      expect(controller.residentPresentations, isEmpty);
      expect(resident.access.isActive, isFalse);
      expect(content.releases, 0);
    },
  );

  test('eviction listener cannot construct in a departed context', () async {
    await controller.close();
    controller.dispose();
    controller = ConsoleController(registry, presentationLimit: 1)
      ..setSession(first);
    final a = _Content('A', keepAlive: true);
    final b = _Content('B', keepAlive: true);
    var next = 0;
    await register((access) async => (next++ == 0 ? a : b).open(access));
    await controller.invoke(controller.actions.single);
    final resident = controller.residentPresentations.single;
    resident.access.changes.addListener(() {
      if (!resident.access.isActive) controller.setSession(null);
    });
    await controller.invoke(controller.actions.single);
    expect(controller.selectedPresentation, isNull);
    expect(controller.session, isNull);
    expect(controller.residentPresentations, isEmpty);
    expect(resident.access.isActive, isFalse);
    expect(b.mounts, isEmpty);
    expect(a.releases, 0);
    expect(b.releases, 0);
  });

  test('reentrant eviction constructs requested resident only once', () async {
    await controller.close();
    controller.dispose();
    controller = ConsoleController(registry, presentationLimit: 1)
      ..setSession(first);
    final a = _Content('A', keepAlive: true);
    final b = _Content('B', keepAlive: true);
    var next = 0;
    await register((access) async => (next++ == 0 ? a : b).open(access));
    await controller.invoke(controller.actions.single);
    final resident = controller.residentPresentations.single;
    resident.access.changes.addListener(() {
      if (!resident.access.isActive) controller.selectedPresentation;
    });
    await controller.invoke(controller.actions.single);
    final selected = controller.selectedPresentation;
    expect(selected, isNotNull);
    expect(controller.residentPresentations.single.widget, same(selected));
    expect(b.mounts, hasLength(1));
    expect(b.mounts.single.isActive, isTrue);
    expect(a.mounts.single.isActive, isFalse);
    expect(a.releases, 0);
    expect(b.releases, 0);
  });

  for (final departure in ['collapse', 'session', 'null', 'unmount', 'close']) {
    test('working-set $departure retires every exact resident', () async {
      final a = _Content('A', keepAlive: true);
      final b = _Content('B', keepAlive: true);
      var next = 0;
      await register((access) async => (next++ == 0 ? a : b).open(access));
      await controller.invoke(controller.actions.single);
      controller.selectedPresentation;
      await controller.invoke(controller.actions.single);
      controller.selectedPresentation;
      final selected = controller.selectedTab;
      final accesses = [a.mounts.single, b.mounts.single];
      switch (departure) {
        case 'collapse':
          controller.setVisible(false);
        case 'session':
          // Eligibility shared across Sessions does not share presentation life.
          controller.setSession(second);
        case 'null':
          controller.setSession(null);
        case 'unmount':
          controller.unmountPresentation();
        case 'close':
          await controller.close();
      }
      expect(accesses.every((access) => !access.isActive), isTrue);
      expect(a.releases, departure == 'close' ? 1 : 0);
      expect(b.releases, departure == 'close' ? 1 : 0);
      if (departure != 'close') {
        controller.setSession(first);
        controller.setVisible(true);
        expect(controller.selectedTab, same(selected));
        controller.selectedPresentation;
        expect(b.mounts, hasLength(2));
        expect(a.mounts, hasLength(1));
        expect(accesses.every((access) => !access.isActive), isTrue);
      }
    });
  }

  test('hidden resident close retires it without affecting siblings', () async {
    final a = _Content('A', keepAlive: true);
    final b = _Content('B', keepAlive: true);
    var next = 0;
    await register((access) async => (next++ == 0 ? a : b).open(access));
    await controller.invoke(controller.actions.single);
    controller.selectedPresentation;
    await controller.invoke(controller.actions.single);
    final selected = controller.selectedPresentation;
    await a.registration.requestRemoval();
    expect(a.mounts.single.isActive, isFalse);
    expect(a.releases, 1);
    expect(b.mounts.single.isActive, isTrue);
    expect(controller.selectedPresentation, same(selected));
    expect(controller.residentPresentations, hasLength(1));
    expect(b.releases, 0);
  });

  test('resident selection still withdraws pending confirmation', () async {
    final a = _Content('A', keepAlive: true);
    final b = _Content('B', keepAlive: true);
    var next = 0;
    await register((access) async => (next++ == 0 ? a : b).open(access));
    await controller.invoke(controller.actions.single);
    final aWidget = controller.selectedPresentation;
    await controller.invoke(controller.actions.single);
    controller.selectedPresentation;
    final gate = Completer<bool>();
    late ConsoleCloseRequest request;
    final closing = controller.closeTab(controller.selectedTab!, (value) {
      request = value;
      return gate.future;
    });
    controller.select(controller.eligibleTabs.first);
    expect(request.isPending, isFalse);
    expect(b.mounts.single.isActive, isTrue);
    expect(b.mounts.single.interaction, isNull);
    expect(controller.selectedPresentation, same(aWidget));
    await closing;
    gate.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(b.releases, 0);
  });

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
        message = value.message;
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
        expect(message.message, 'Close this console?');
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

  for (final departure in [
    'session',
    'clear',
    'hide',
    'selection',
    'unmount',
  ]) {
    test(
      'abandoned confirmation settles and can be replaced after $departure',
      () async {
        final one = _Content('One');
        final two = _Content('Two');
        var count = 0;
        await register((a) async => (count++ == 0 ? one : two).open(a));
        await controller.invoke(controller.actions.single);
        await controller.invoke(controller.actions.single);
        controller.selectedPresentation;
        final gate = Completer<bool>();
        late ConsoleCloseRequest oldRequest;
        final tab = controller.selectedTab!;
        final closing = controller.closeTab(tab, (request) {
          oldRequest = request;
          return gate.future;
        });
        switch (departure) {
          case 'session':
            controller.setSession(second);
          case 'clear':
            controller.setSession(null);
          case 'hide':
            controller.setVisible(false);
          case 'selection':
            controller.select(controller.eligibleTabs.first);
          case 'unmount':
            controller.unmountPresentation();
        }
        await closing;
        expect(gate.isCompleted, isFalse);
        expect(oldRequest.isPending, isFalse);
        expect(two.registration.isActive, isTrue);
        expect(two.releases, 0);
        controller.setSession(first);
        controller.setVisible(true);
        controller.select(tab);
        final freshGate = Completer<bool>();
        late ConsoleCloseRequest freshRequest;
        final freshClose = controller.closeTab(tab, (request) {
          freshRequest = request;
          return freshGate.future;
        });
        expect(freshClose, isNot(same(closing)));
        expect(freshRequest, isNot(same(oldRequest)));
        // An old callback can fail or accept, but cannot clear/answer its successor.
        if (departure == 'unmount') {
          gate.completeError(StateError('late confirmation failure'));
        } else {
          gate.complete(true);
        }
        await Future<void>.delayed(Duration.zero);
        expect(freshRequest.isPending, isTrue);
        expect(controller.closeTab(tab, (_) async => false), same(freshClose));
        expect(two.releases, 0);
        freshGate.complete(false);
        await freshClose;
        expect(two.registration.isActive, isTrue);
      },
    );
  }

  for (final cause in ['removal', 'retirement', 'close', 'dispose']) {
    test(
      '$cause withdraws confirmation before pending cleanup settles',
      () async {
        final cleanup = Completer<ConsoleCleanupResult>();
        final content = _Content('One', release: () => cleanup.future);
        final contribution = await register(
          (access) async => content.open(access),
        );
        await controller.invoke(controller.actions.single);
        final answer = Completer<bool>();
        late ConsoleCloseRequest request;
        final closing = controller.closeTab(controller.selectedTab!, (value) {
          request = value;
          return answer.future;
        });
        Future<void>? removal;
        switch (cause) {
          case 'removal':
            removal = content.registration.requestRemoval();
          case 'retirement':
            await contribution.close();
          case 'close':
            removal = controller.close();
          case 'dispose':
            controller.dispose();
        }
        await closing;
        expect(request.isPending, isFalse);
        expect(answer.isCompleted, isFalse);
        expect(cleanup.isCompleted, isFalse);
        expect(content.releases, 1);
        cleanup.complete(ConsoleCleanupResult());
        await removal;
        answer.completeError(StateError('obsolete dialog failure'));
        await Future<void>.delayed(Duration.zero);
        expect(content.releases, 1);
      },
    );
  }

  test(
    'valid acceptance joins exact cleanup despite later navigation/removal',
    () async {
      final cleanup = Completer<ConsoleCleanupResult>();
      final started = Completer<void>();
      final content = await open(
        release: () {
          started.complete();
          return cleanup.future;
        },
      );
      final gate = Completer<bool>();
      var settled = false;
      final closing = controller.closeTab(
        controller.selectedTab!,
        (_) => gate.future,
      );
      unawaited(closing.then((_) => settled = true));
      gate.complete(true);
      await started.future;
      controller.setSession(second);
      final automatic = content.registration.requestRemoval();
      expect(content.releases, 1);
      expect(settled, isFalse);
      cleanup.complete(ConsoleCleanupResult());
      await Future.wait([closing, automatic]);
      expect(settled, isTrue);
      expect(content.releases, 1);
    },
  );

  test('a late answer cannot close a same-title replacement tab', () async {
    final one = _Content('Same title');
    final two = _Content('Same title');
    var next = 0;
    await register((access) async => (next++ == 0 ? one : two).open(access));
    await controller.invoke(controller.actions.single);
    final answer = Completer<bool>();
    final closing = controller.closeTab(
      controller.selectedTab!,
      (_) => answer.future,
    );
    await one.registration.requestRemoval();
    await closing;
    await controller.invoke(controller.actions.single);
    answer.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(controller.eligibleTabs, hasLength(1));
    expect(one.releases, 1);
    expect(two.registration.isActive, isTrue);
    expect(two.releases, 0);
  });

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
  _Content(
    this.title, {
    this.eligible,
    this.advice,
    this.release,
    this.keepAlive = false,
    this.onCreate,
  });

  final String title;
  final bool keepAlive;
  final Widget Function(ConsolePresentationAccess)? onCreate;
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
        keepAlive: keepAlive,
        createPresentation: (access) {
          mounts.add(access);
          return onCreate?.call(access) ?? Text(evidence.join('\n'));
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
