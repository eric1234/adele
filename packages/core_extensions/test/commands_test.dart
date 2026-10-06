import 'dart:async';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';

void main() {
  group('CommandId', () {
    test('has stable value equality, hashing, and string representation', () {
      final id = CommandId('dev.adele.test.command-2');
      final sameId = CommandId(id.value);
      expect(id.value, 'dev.adele.test.command-2');
      expect(id, sameId);
      expect(id.hashCode, sameId.hashCode);
      expect(id.toString(), id.value);
      expect(id, isNot(CommandId('dev.adele.test.other')));
      expect(id, isNot(ExtensionId(id.value)));
      expect(<CommandId>{id, sameId}, hasLength(1));
    });

    test('uses the shared public identity grammar', () {
      for (final value in <String>[
        '',
        'single',
        'dev..adele',
        'dev.adele_bad',
        'dev.adele.-bad',
        'dev.adele.bad-',
        'Dev.adele.bad',
        'dev.ad\u00e8le.bad',
        'dev.adele.bad\n',
      ]) {
        expect(() => CommandId(value), throwsFormatException, reason: value);
      }
    });
  });

  group('CommandContribution', () {
    test('uses the stable typed extension point', () {
      expect(
        commandContributions,
        ExtensionPoint<CommandContribution>('dev.adele.extension.commands'),
      );
      expect(ExtensionRegistry().discover(commandContributions), isEmpty);
    });

    test('preserves valid labels and bounds UTF-16 code units', () {
      for (final label in <String>[
        'Open Project...',
        '  Command with spaces  ',
        'Ouvrir le projet \u00e9tendu',
        'x' * 160,
        '\u{1f680}' * 80,
      ]) {
        expect(_command(label: label).label, label);
      }
      expect(() => _command(label: 'x' * 161), throwsArgumentError);
      expect(() => _command(label: '\u{1f680}' * 81), throwsArgumentError);
    });

    test('rejects blank labels, controls, and Unicode line breaks', () {
      for (final label in <String>[
        '',
        '   ',
        '\u00a0',
        'before\u2028after',
        'before\u2029after',
        for (var unit = 0; unit <= 0x9f; unit++)
          if (unit < 0x20 || unit >= 0x7f)
            'before${String.fromCharCode(unit)}after',
      ]) {
        expect(
          () => _command(label: label),
          throwsArgumentError,
          reason: label.codeUnits.toString(),
        );
      }
    });
  });

  group('CommandResolver', () {
    late ExtensionRegistry registry;
    late CommandResolver resolver;

    setUp(() {
      registry = ExtensionRegistry();
      resolver = CommandResolver(registry);
    });

    test(
      'zero commands are valid and explicit resolution is typed missing',
      () {
        final id = CommandId('dev.adele.test.missing');
        expect(resolver.discover(), isEmpty);
        expect(
          () => resolver.resolve(id),
          throwsA(isA<CommandNotFound>().having((e) => e.id, 'id', id)),
        );
      },
    );

    test('captures contribution metadata and exact registration identity', () {
      final contribution = _command();
      final registration = _register(registry, contribution);
      final resolved = resolver.resolve(contribution.id);
      expect(resolved.id, contribution.id);
      expect(resolved.label, contribution.label);
      expect(resolved.binding.value, same(contribution));
      expect(registration.owns(resolved.binding), isTrue);
      expect(
        resolved.binding.isSameRegistration(resolver.discover().single.binding),
        isTrue,
      );
    });

    test('discovery is deterministic by folded label then command ID', () {
      for (final (id, label) in <(String, String)>[
        ('a', 'Zulu'),
        ('d', 'alpha'),
        ('c', 'ALPHA'),
        ('b', 'Beta'),
      ]) {
        _register(registry, _command(id: 'dev.adele.test.$id', label: label));
      }
      final commands = resolver.discover();
      expect(commands.map((command) => command.id.value), <String>[
        'dev.adele.test.c',
        'dev.adele.test.d',
        'dev.adele.test.b',
        'dev.adele.test.a',
      ]);
      expect(() => commands.clear(), throwsUnsupportedError);
    });

    test('discovery and resolution do not evaluate availability', () {
      var evaluations = 0;
      final contribution = _command(
        availability: () {
          evaluations++;
          throw StateError('not needed for discovery');
        },
      );
      _register(registry, contribution);
      expect(resolver.discover(), hasLength(1));
      expect(resolver.resolve(contribution.id).id, contribution.id);
      expect(evaluations, 0);
    });

    test('hidden, disabled, and enabled identities remain discoverable', () {
      for (final state in CommandAvailability.values) {
        _register(
          registry,
          _command(
            id: 'dev.adele.test.${state.name}',
            availability: () => state,
          ),
        );
      }
      expect(
        resolver.discover().map((command) => command.availability),
        unorderedEquals(CommandAvailability.values),
      );
    });

    test('all duplicate identities are omitted regardless of availability', () {
      final id = CommandId('dev.adele.test.duplicate');
      final extensions = <ExtensionId>[];
      for (final state in CommandAvailability.values.reversed) {
        final extensionId = 'dev.adele.test.${state.name}';
        extensions.add(ExtensionId(extensionId));
        _register(
          registry,
          _command(id: id.value, availability: () => state),
          extensionId: extensionId,
        );
      }
      final independent = _command(id: 'dev.adele.test.independent');
      _register(registry, independent);
      expect(resolver.discover().single.id, independent.id);
      extensions.sort((a, b) => a.value.compareTo(b.value));
      expect(
        () => resolver.resolve(id),
        throwsA(
          isA<AmbiguousCommand>()
              .having((e) => e.id, 'id', id)
              .having((e) => e.extensionIds, 'extensionIds', extensions),
        ),
      );
      final error = AmbiguousCommand(id, extensions);
      extensions.clear();
      expect(error.extensionIds, hasLength(3));
      expect(() => error.extensionIds.clear(), throwsUnsupportedError);
    });

    test(
      'discovery is fresh and commands use registration not command IDs',
      () async {
        final contribution = _command();
        final snapshot = resolver.discover();
        final registration = _register(
          registry,
          contribution,
          extensionId: 'dev.adele.test.registration',
        );
        expect(snapshot, isEmpty);
        expect(resolver.discover().single.id, contribution.id);
        expect(
          resolver.discover().single.binding.id,
          ExtensionId('dev.adele.test.registration'),
        );
        await registration.close();
        expect(resolver.discover(), isEmpty);
        expect(
          () => resolver.resolve(contribution.id),
          throwsA(isA<CommandNotFound>()),
        );
      },
    );
  });

  group('ResolvedCommand', () {
    late ExtensionRegistry registry;
    late CommandResolver resolver;

    setUp(() {
      registry = ExtensionRegistry();
      resolver = CommandResolver(registry);
    });

    for (final state in CommandAvailability.values) {
      test('$state is evaluated on every read and invocation', () async {
        var evaluations = 0;
        var calls = 0;
        final contribution = _command(
          availability: () {
            evaluations++;
            return state;
          },
          invoke: () => calls++,
        );
        _register(registry, contribution);
        final command = resolver.resolve(contribution.id);
        expect(evaluations, 0);
        expect(command.availability, state);
        expect(command.availability, state);
        expect(evaluations, 2);
        final pending = command.invoke();
        expect(evaluations, 3);
        expect(calls, state == CommandAvailability.enabled ? 1 : 0);
        if (state == CommandAvailability.enabled) {
          await pending;
        } else {
          await expectLater(
            pending,
            throwsA(
              isA<CommandUnavailable>().having(
                (e) => e.id,
                'id',
                contribution.id,
              ),
            ),
          );
        }
      });
    }

    test(
      'invocation rechecks state instead of using displayed availability',
      () async {
        var state = CommandAvailability.enabled;
        var calls = 0;
        final contribution = _command(
          availability: () => state,
          invoke: () => calls++,
        );
        _register(registry, contribution);
        final command = resolver.resolve(contribution.id);
        expect(command.availability, CommandAvailability.enabled);
        for (final unavailable in <CommandAvailability>[
          CommandAvailability.disabled,
          CommandAvailability.hidden,
        ]) {
          state = unavailable;
          await expectLater(
            command.invoke(),
            throwsA(isA<CommandUnavailable>()),
          );
        }
        expect(calls, 0);
        state = CommandAvailability.enabled;
        await command.invoke();
        expect(calls, 1);
      },
    );

    test(
      'availability errors fail closed without invoking or becoming sticky',
      () async {
        Object? failure = StateError('private owner state');
        var calls = 0;
        final contribution = _command(
          availability: () {
            if (failure case final error?) throw error;
            return CommandAvailability.enabled;
          },
          invoke: () => calls++,
        );
        _register(registry, contribution);
        final command = resolver.resolve(contribution.id);
        for (final error in <Object>[
          StateError('broken'),
          Exception('broken'),
          'non-Exception failure',
        ]) {
          failure = error;
          expect(command.availability, CommandAvailability.disabled);
          await expectLater(
            command.invoke(),
            throwsA(isA<CommandUnavailable>()),
          );
        }
        expect(calls, 0);
        failure = null;
        expect(command.availability, CommandAvailability.enabled);
        await command.invoke();
        expect(calls, 1);
      },
    );

    test(
      'retirement wins over missing identity and skips owner callbacks',
      () async {
        var evaluations = 0;
        var calls = 0;
        final contribution = _command(
          availability: () {
            evaluations++;
            return CommandAvailability.enabled;
          },
          invoke: () => calls++,
        );
        final registration = _register(registry, contribution);
        final command = resolver.resolve(contribution.id);
        final closing = registration.close();
        expect(command.availability, CommandAvailability.disabled);
        await expectLater(
          command.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(evaluations, 0);
        expect(calls, 0);
        expect(command.id, contribution.id);
        expect(command.label, contribution.label);
        await closing;
      },
    );

    test(
      'reusing registration, command IDs, and the object never retargets',
      () async {
        var calls = 0;
        final contribution = _command(invoke: () => calls++);
        final registration = _register(registry, contribution);
        final captured = resolver.resolve(contribution.id);
        await registration.close();
        final replacement = _register(registry, contribution);
        final fresh = resolver.resolve(contribution.id);
        expect(captured.binding.isSameRegistration(fresh.binding), isFalse);
        expect(replacement.owns(captured.binding), isFalse);
        expect(captured.availability, CommandAvailability.disabled);
        await expectLater(
          captured.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(calls, 0);
        await fresh.invoke();
        expect(calls, 1);
      },
    );

    test(
      'new conflicts block a captured command until the conflict retires',
      () async {
        var calls = 0;
        var evaluations = 0;
        final contribution = _command(
          availability: () {
            evaluations++;
            return CommandAvailability.enabled;
          },
          invoke: () => calls++,
        );
        _register(registry, contribution);
        final captured = resolver.resolve(contribution.id);
        final duplicate = _register(
          registry,
          _command(availability: () => CommandAvailability.hidden),
          extensionId: 'dev.adele.test.duplicate',
        );
        expect(captured.availability, CommandAvailability.disabled);
        await expectLater(captured.invoke(), throwsA(isA<AmbiguousCommand>()));
        expect(calls, 0);
        expect(evaluations, 0);
        await duplicate.close();
        expect(captured.availability, CommandAvailability.enabled);
        await captured.invoke();
        expect(calls, 1);
      },
    );

    for (final invoke in <bool>[false, true]) {
      test('rechecks retirement during availability, invoke=$invoke', () async {
        late ExtensionRegistration registration;
        var calls = 0;
        final contribution = _command(
          availability: () {
            unawaited(registration.close());
            _register(registry, _command());
            return CommandAvailability.enabled;
          },
          invoke: () => calls++,
        );
        registration = _register(registry, contribution);
        final captured = resolver.resolve(contribution.id);
        if (invoke) {
          await expectLater(
            captured.invoke(),
            throwsA(isA<StaleExtensionBinding>()),
          );
        } else {
          expect(captured.availability, CommandAvailability.disabled);
        }
        expect(calls, 0);
      });

      test('rechecks conflicts during availability, invoke=$invoke', () async {
        var calls = 0;
        final contribution = _command(
          availability: () {
            _register(
              registry,
              _command(availability: () => CommandAvailability.hidden),
              extensionId: 'dev.adele.test.duplicate',
            );
            return CommandAvailability.enabled;
          },
          invoke: () => calls++,
        );
        _register(registry, contribution);
        final captured = resolver.resolve(contribution.id);
        if (invoke) {
          await expectLater(
            captured.invoke(),
            throwsA(isA<AmbiguousCommand>()),
          );
        } else {
          expect(captured.availability, CommandAvailability.disabled);
        }
        expect(calls, 0);
      });
    }

    test(
      'invocation has no asynchronous gap after availability evaluation',
      () async {
        var state = CommandAvailability.enabled;
        var calls = 0;
        final contribution = _command(
          availability: () {
            scheduleMicrotask(() => state = CommandAvailability.disabled);
            return state;
          },
          invoke: () {
            expect(state, CommandAvailability.enabled);
            calls++;
          },
        );
        _register(registry, contribution);
        final pending = resolver.resolve(contribution.id).invoke();
        expect(calls, 1);
        await pending;
        expect(state, CommandAvailability.disabled);
      },
    );

    for (final fails in <bool>[false, true]) {
      test(
        'admitted async completion survives retirement, fails=$fails',
        () async {
          final completion = Completer<void>();
          final error = StateError('invocation failure');
          var calls = 0;
          var replacements = 0;
          final contribution = _command(
            invoke: () {
              calls++;
              return completion.future;
            },
          );
          final registration = _register(registry, contribution);
          final captured = resolver.resolve(contribution.id);
          final pending = captured.invoke();
          expect(calls, 1);
          await registration.close();
          _register(registry, _command(invoke: () => replacements++));
          final settled = expectLater(
            pending,
            fails ? throwsA(same(error)) : completes,
          );
          if (fails) {
            completion.completeError(error);
          } else {
            completion.complete();
          }
          await settled;
          expect(replacements, 0);
          expect(captured.availability, CommandAvailability.disabled);
          await expectLater(
            captured.invoke(),
            throwsA(isA<StaleExtensionBinding>()),
          );
        },
      );
    }

    test('synchronous implementation errors propagate unchanged', () async {
      final error = StateError('implementation failed');
      final contribution = _command(invoke: () => throw error);
      _register(registry, contribution);
      final captured = resolver.resolve(contribution.id);
      await expectLater(captured.invoke(), throwsA(same(error)));
      expect(captured.availability, CommandAvailability.enabled);
    });

    test('state reads and invocation add no registry notifications', () async {
      var changes = 0;
      final subscription = registry.changes.listen((_) => changes++);
      addTearDown(subscription.cancel);
      var state = CommandAvailability.disabled;
      final contribution = _command(availability: () => state);
      final registration = _register(registry, contribution);
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
      final captured = resolver.resolve(contribution.id);
      expect(captured.availability, CommandAvailability.disabled);
      state = CommandAvailability.enabled;
      resolver.discover();
      expect(captured.availability, CommandAvailability.enabled);
      await captured.invoke();
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
      await registration.close();
      await Future<void>.delayed(Duration.zero);
      expect(changes, 2);
    });
  });
}

CommandContribution _command({
  String id = 'dev.adele.test.command',
  String label = 'Run command',
  CommandAvailability Function()? availability,
  FutureOr<void> Function()? invoke,
}) => CommandContribution(
  id: CommandId(id),
  label: label,
  availability: availability ?? () => CommandAvailability.enabled,
  invoke: invoke ?? () {},
);

ExtensionRegistration _register(
  ExtensionRegistry registry,
  CommandContribution contribution, {
  String? extensionId,
}) => registry.register(
  point: commandContributions,
  id: ExtensionId(extensionId ?? contribution.id.value),
  value: contribution,
);
