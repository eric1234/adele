import 'dart:io';

import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/core/native_credential_storage_adapter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/credential_storage_probe.dart'
    show disposableCredentialValue, isCredentialSmokeFixture;

const _deadline = Duration(seconds: 20);

bool get _hasPrivateDaemon =>
    isCredentialSmokeFixture &&
    int.tryParse(
          Platform.environment['ADELE_CREDENTIAL_STORAGE_DAEMON_PID'] ?? '',
        ) !=
        null;

void main() {
  testWidgets(
    'real blocked native credential call keeps frames live and close draining',
    (tester) async {
      final fixture = Platform.environment['ADELE_CREDENTIAL_STORAGE_FIXTURE']!;
      final daemon = int.parse(
        Platform.environment['ADELE_CREDENTIAL_STORAGE_DAEMON_PID']!,
      );
      // A gate alone must never authorize stopping an arbitrary inherited PID.
      expect(daemon > 1 && daemon != pid, isTrue);
      expect(
        File('$fixture/daemon.pid').readAsStringSync() == '$daemon',
        isTrue,
      );
      final command = File(
        '/proc/$daemon/cmdline',
      ).readAsStringSync().split('\x00');
      final environment = File(
        '/proc/$daemon/environ',
      ).readAsStringSync().split('\x00');
      expect(command.first.split('/').last == 'gnome-keyring-daemon', isTrue);
      expect(command.contains('$fixture/control'), isTrue);
      expect(environment.contains('HOME=$fixture/home'), isTrue);
      expect(
        environment.contains('GNOME_KEYRING_CONTROL=$fixture/control'),
        isTrue,
      );
      expect(
        environment.contains(
          'DBUS_SESSION_BUS_ADDRESS=${Platform.environment['DBUS_SESSION_BUS_ADDRESS']}',
        ),
        isTrue,
      );

      final reference = CredentialReference.generate();
      final value = disposableCredentialValue();
      final service = createNativeCredentialService();
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 1),
      );
      var frames = 0;
      var completed = false;
      var closed = false;
      var failed = false;
      CredentialSecret? result;
      Future<void>? pending;
      Future<void>? closing;
      try {
        await tester.runAsync(
          () => service
              .store(reference, CredentialSecret(value))
              .timeout(_deadline),
        );
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: AnimatedBuilder(
              animation: controller,
              builder: (_, _) {
                frames++;
                return Text('frames: $frames');
              },
            ),
          ),
        );
        controller.repeat();
        await tester.runAsync(() async {
          // Admission precedes the pause. Stop before yielding to the owner's
          // queued operation; it then reaches the real OS call via Isolate.run.
          pending = service
              .read(reference)
              .then<void>(
                (secret) {
                  result = secret;
                  completed = true;
                },
                onError: (Object _) {
                  failed = true;
                  completed = true;
                },
              );
          expect(Process.killPid(daemon, ProcessSignal.sigstop), isTrue);
          closing = service.close().then((_) {
            closed = true;
          });
          await Future<void>.delayed(const Duration(milliseconds: 150));
        });
        expect(completed, isFalse);
        expect(closed, isFalse);
        final before = frames;
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(frames > before, isTrue);
        expect(completed, isFalse);
        expect(closed, isFalse);
        await tester.runAsync(() async {
          expect(Process.killPid(daemon, ProcessSignal.sigcont), isTrue);
          await pending!.timeout(_deadline);
          await closing!.timeout(_deadline);
        });
        expect(failed, isFalse, reason: 'Native operation failed safely.');
        // Never give the matcher a secret, even on assertion failure.
        expect(
          result?.reveal() == value,
          isTrue,
          reason: 'Credential differs.',
        );
        expect(closed, isTrue);
      } finally {
        // Unconditional resume also covers exceptions immediately after SIGSTOP.
        // The runner owns termination and independently resumes before killing.
        Process.killPid(daemon, ProcessSignal.sigcont);
        controller.dispose();
        await tester.runAsync(() async {
          await pending?.timeout(_deadline);
          await service.close().timeout(_deadline);
          final cleanup = createNativeCredentialService();
          try {
            await cleanup.delete(reference).timeout(_deadline);
            expect(
              await cleanup.contains(reference).timeout(_deadline),
              isFalse,
            );
          } finally {
            await cleanup.close().timeout(_deadline);
          }
        });
      }
      File('$fixture/widget.completed').writeAsStringSync('passed');
    },
    skip: !_hasPrivateDaemon,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
