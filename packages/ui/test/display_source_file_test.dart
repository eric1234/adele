import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ExtensionRegistry registry;
  late DisplaySourceFileResolver resolver;

  setUp(() {
    registry = ExtensionRegistry();
    resolver = DisplaySourceFileResolver(registry);
  });

  test(
    'absent display is unavailable through the public consumer API',
    () async {
      expect(resolver.resolve, throwsA(isA<DisplaySourceFileUnavailable>()));
      await expectLater(
        resolver.display('lib/example.dart'),
        throwsA(isA<DisplaySourceFileUnavailable>()),
      );
    },
  );

  test(
    'one display receives only the relative path and returns its result',
    () async {
      final paths = <String>[];
      final result = <String, Object?>{'ok': true, 'id': 'document'};
      registry.register(
        point: displaySourceFileContributions,
        id: ExtensionId('test.display'),
        value: DisplaySourceFileContribution(
          display: (path) async {
            paths.add(path);
            return result;
          },
        ),
      );
      expect(paths, isEmpty);
      expect(await resolver.display('lib/example.dart'), same(result));
      expect(paths, ['lib/example.dart']);
      final bound = resolver.resolve();
      expect(await bound.value.display('lib/another.dart'), same(result));
      expect(paths, ['lib/example.dart', 'lib/another.dart']);
    },
  );

  test(
    'many are ambiguous; explicit selection never substitutes a provider',
    () async {
      final first = ExtensionId('test.first');
      final second = ExtensionId('test.second');
      final missing = ExtensionId('test.missing');
      final called = <ExtensionId>[];
      for (final id in [second, first]) {
        registry.register(
          point: displaySourceFileContributions,
          id: id,
          value: DisplaySourceFileContribution(
            display: (path) async {
              called.add(id);
              return {'path': path, 'provider': id.value};
            },
          ),
        );
      }
      final ambiguous = isA<AmbiguousDisplaySourceFile>().having(
        (error) => error.extensionIds,
        'sorted provider IDs',
        [first, second],
      );
      expect(resolver.resolve, throwsA(ambiguous));
      await expectLater(resolver.display('file.dart'), throwsA(ambiguous));
      expect(called, isEmpty);
      expect(
        () => AmbiguousDisplaySourceFile([first, second]).extensionIds.clear(),
        throwsUnsupportedError,
      );
      for (final id in [first, second]) {
        expect(resolver.resolve(select: id).id, id);
        expect(await resolver.display('file.dart', select: id), {
          'path': 'file.dart',
          'provider': id.value,
        });
      }
      await expectLater(
        resolver.display('file.dart', select: missing),
        throwsA(
          isA<DisplaySourceFileUnavailable>().having(
            (error) => error.select,
            'requested provider',
            missing,
          ),
        ),
      );
      expect(called, [first, second]);
    },
  );

  test(
    'retirement never migrates a captured binding or pending call',
    () async {
      final id = ExtensionId('test.display');
      final pending = Completer<Map<String, Object?>>();
      var originalCalls = 0;
      var replacementCalls = 0;
      final original = registry.register(
        point: displaySourceFileContributions,
        id: id,
        value: DisplaySourceFileContribution(
          display: (_) {
            originalCalls++;
            return pending.future;
          },
        ),
      );
      final captured = resolver.resolve();
      final call = resolver.display('file.dart');
      final rejected = expectLater(call, throwsA(isA<StaleExtensionBinding>()));
      expect(originalCalls, 1);
      await original.close();
      registry.register(
        point: displaySourceFileContributions,
        id: id,
        value: DisplaySourceFileContribution(
          display: (_) async {
            replacementCalls++;
            return {'ok': true};
          },
        ),
      );
      expect(
        () => captured.value.display('late.dart'),
        throwsA(isA<StaleExtensionBinding>()),
      );
      expect(captured.isSameRegistration(resolver.resolve()), isFalse);
      pending.complete({'ok': true});
      await rejected;
      expect(replacementCalls, 0);
      expect(await resolver.display('fresh.dart', select: id), {'ok': true});
      expect(replacementCalls, 1);
    },
  );

  test(
    'a display failure is preserved without retrying another provider',
    () async {
      final failure = StateError('display failed');
      var calls = 0;
      registry.register(
        point: displaySourceFileContributions,
        id: ExtensionId('test.display'),
        value: DisplaySourceFileContribution(
          display: (_) async {
            calls++;
            throw failure;
          },
        ),
      );
      await expectLater(resolver.display('file.dart'), throwsA(same(failure)));
      expect(calls, 1);
    },
  );
}
