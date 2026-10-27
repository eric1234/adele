import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final graceful in [true, false]) {
    testWidgets(
      '${graceful ? 'accepted exit' : 'widget disposal'} fences the mounted credential owner and drains admitted work',
      (tester) => tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'adele-credential-owner-',
        );
        final installations = await Directory('${root.path}/plugins').create();
        final storage = _GatedStorage();
        final credentials = CredentialService(storage);
        final runtime = NativeAdeleRuntime();
        var constructions = 0;
        late Future<void> starting;
        final roots = PlatformStorageRoots(
          operatingSystem: Platform.operatingSystem,
          configurationRoot: '${root.path}/config',
          localStateRoot: '${root.path}/state',
          localDataRoot: '${root.path}/data',
          cacheRoot: '${root.path}/cache',
        );
        try {
          await tester.pumpWidget(
            AdeleApplication(
              createRuntime: () => runtime,
              createCredentials: () {
                constructions++;
                return credentials;
              },
              configurationRoots: roots,
              readChatGptConfiguration: () => null,
              bootstrapPlugins: (plugins) => starting = plugins.start(
                installationRoot: installations.path,
              ),
            ),
          );
          await starting;
          await tester.pumpAndSettle();
          expect(constructions, 1);
          expect(
            storage.calls,
            0,
            reason: 'Startup must not inspect the OS vault.',
          );
          await tester.pumpWidget(
            AdeleApplication(
              createRuntime: () =>
                  throw StateError('Runtime must not be reconstructed.'),
              createCredentials: () =>
                  throw StateError('Credential owner must not be replaced.'),
              configurationRoots: roots,
              readChatGptConfiguration: () => null,
            ),
          );
          expect(constructions, 1);
          expect(storage.calls, 0);

          final reference = CredentialReference.generate();
          final admitted = credentials.contains(reference);
          await storage.entered.future;
          var exited = false;
          Future<AppExitResponse>? exiting;
          if (graceful) {
            exiting = tester.binding.handleRequestAppExit().then((result) {
              exited = true;
              return result;
            });
            await tester.pump();
          } else {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          await expectLater(
            credentials.contains(reference),
            throwsA(
              isA<CredentialFailure>().having(
                (failure) => failure.kind,
                'kind',
                CredentialFailureKind.closed,
              ),
            ),
          );
          var drained = false;
          final closing = credentials.close().then((_) => drained = true);
          await tester.pump();
          expect(drained, isFalse);
          expect(exited, isFalse);
          storage.release.complete();
          expect(await admitted, isFalse);
          await closing;
          if (exiting != null) expect(await exiting, AppExitResponse.exit);
          expect(storage.calls, 1);
          expect(tester.takeException(), isNull);
        } finally {
          if (!storage.release.isCompleted) storage.release.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          await credentials.close();
          await runtime.close();
          await root.delete(recursive: true);
        }
      }),
    );
  }
}

final class _GatedStorage implements CredentialStorageAdapter {
  final entered = Completer<void>();
  final release = Completer<void>();
  var calls = 0;

  @override
  Future<bool> contains(CredentialReference reference) async {
    calls++;
    entered.complete();
    await release.future;
    return false;
  }

  @override
  Future<String?> read(CredentialReference reference) =>
      throw UnimplementedError();
  @override
  Future<void> write(CredentialReference reference, CredentialSecret secret) =>
      throw UnimplementedError();
  @override
  Future<void> delete(CredentialReference reference) =>
      throw UnimplementedError();
}
