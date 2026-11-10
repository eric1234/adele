import 'dart:async';
import 'dart:io';

import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/backend_local_state_host.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_backend_support/backend_local_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

void main() {
  test(
    'runtime construction and close never resolve the local-state root',
    () async {
      var calls = 0;
      final runtime = AdeleRuntime(
        localStateRoot: () {
          calls++;
          throw StateError('Unused resolver');
        },
      );
      await runtime.close();
      expect(calls, 0);
    },
  );

  test('lookup is lazy and revalidates before each resolution', () async {
    final calls = <String>[];
    var root = '/fixture/first';
    final host = BackendLocalStateHost(
      validateAccess: () => calls.add('validate'),
      localStateRoot: () {
        calls.add('resolve');
        return root;
      },
    );
    expect(calls, isEmpty);
    expect(await host.getLocalStateRoot(), root);
    root = '/fixture/second';
    expect(await host.getLocalStateRoot(), root);
    expect(calls, ['validate', 'resolve', 'validate', 'resolve']);
  });

  test(
    'default delegates exact platform roots policy without filesystem I/O',
    () async {
      final expected = PlatformStorageRoots.resolve(
        operatingSystem: Platform.operatingSystem,
        environment: Platform.environment,
      ).localStateRoot;
      final host = BackendLocalStateHost(validateAccess: () {});
      await IOOverrides.runZoned(
        () async => expect(await host.getLocalStateRoot(), expected),
        createDirectory: (_) => throw StateError('Unexpected directory handle'),
        createFile: (_) => throw StateError('Unexpected file handle'),
        createLink: (_) => throw StateError('Unexpected link handle'),
      );
    },
  );

  test('path lookup creates no directory and emits no diagnostics', () async {
    final fixture = Directory.systemTemp.createTempSync('adele-local-state-');
    addTearDown(() => fixture.deleteSync(recursive: true));
    final root = '${fixture.path}/not-created/state';
    final diagnostics = <String>[];
    final host = BackendLocalStateHost(
      validateAccess: () {},
      localStateRoot: () => root,
    );
    await runZoned(
      () async => expect(await host.getLocalStateRoot(), root),
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => diagnostics.add(line),
      ),
    );
    expect(fixture.listSync(), isEmpty);
    expect(diagnostics, isEmpty);
  });

  test(
    'revocation rejects queued service entry before resolving a path',
    () async {
      var live = true;
      var resolutions = 0;
      final host = BackendLocalStateHost(
        validateAccess: () {
          if (!live) throw const PluginConnectionClosed('Retired generation.');
        },
        localStateRoot: () {
          resolutions++;
          return '/fixture/state';
        },
      );
      final dispatcher = BackendLocalStateServiceDispatcher(host);
      addTearDown(dispatcher.close);
      final pending = dispatcher.dispatch(_request);
      live = false;
      expect((await pending)['ok'], isFalse);
      await expectLater(
        host.getLocalStateRoot(),
        throwsA(isA<PluginConnectionClosed>()),
      );
      expect(resolutions, 0);
    },
  );

  test(
    'resolution errors are redacted locally and through generated dispatch',
    () async {
      final diagnostics = <String>[];
      final host = BackendLocalStateHost(
        validateAccess: () {},
        localStateRoot: () => PlatformStorageRoots.resolve(
          operatingSystem: 'linux',
          environment: {'HOME': 'private-invalid-home'},
        ).localStateRoot,
      );
      final dispatcher = BackendLocalStateServiceDispatcher(host);
      addTearDown(dispatcher.close);
      await runZoned(
        () async {
          await expectLater(
            host.getLocalStateRoot(),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'The backend local-state root is unavailable.',
              ),
            ),
          );
          final response = await dispatcher.dispatch(_request);
          expect(response['ok'], isFalse);
          expect((response['error']! as Map)['code'], 'internal_error');
          expect(response.toString(), isNot(contains('private-invalid-home')));
          expect(response.toString(), isNot(contains('HOME')));
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => diagnostics.add(line),
        ),
      );
      expect(diagnostics, isEmpty);
    },
  );
}

const _request = <String, Object?>{
  'kind': 'request',
  'requestId': 1,
  'method': backendLocalStateServiceGetLocalStateRootId,
  'payload': <String, Object?>{},
};
