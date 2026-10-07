import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_desktop/ui/commands/command_palette.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _library = 'package:command_probe/main.dart';
const _bound = Duration(seconds: 10);

CommandId _id(String name) => CommandId('dev.example.command.$name');

void main() {
  late Uint8List bytes;
  late Directory root;
  late NativeAdeleRuntime runtime;
  late CommandResolver commands;

  setUpAll(() {
    final compiler = Compiler()..entrypoints.add(_library);
    bytes = compiler.compile({
      'command_probe': {
        'main.dart': '''
int calls = 0;
void success() {
  calls++;
  if (calls != 1) throw StateError('operation runtime was reused');
}
Future<void> failure() async {
  throw StateError('private frontend command diagnostic');
}
int malformed() => 42;
''',
      },
    }).write();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('adele-command-palette-');
    final installation = await Directory('${root.path}/frontend-only').create();
    await File('${installation.path}/frontend.evc').writeAsBytes(bytes);
    await File(
      '${installation.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': 'dev.example.frontend-only',
          'version': 'test',
          'displayName': 'Frontend-only Commands',
        },
        'components': {
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations': <Object?>[],
            'extensions': [
              for (final name in ['success', 'failure', 'malformed'])
                PreparedCommandExtension(
                  extensionId: ExtensionId('dev.example.registration.$name'),
                  commandId: _id(name),
                  label: 'Frontend $name',
                  library: _library,
                  entrypoint: name,
                ).toJson(),
            ],
          },
        },
      }),
    );
    runtime = NativeAdeleRuntime();
    commands = CommandResolver(runtime.extensions);
  });

  tearDown(() async {
    await runtime.close();
    await root.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('command-palette-button')));
    await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsOneWidget);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.runAsync(() async {
      try {
        if (find.byType(AdeleApplication).evaluate().isNotEmpty) {
          await tester.binding.handleRequestAppExit();
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime.close();
      }
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'normal frontend-only startup invokes EVC from the pre-Project global palette',
    (tester) async {
      try {
        await tester.runAsync(() async {
          final activated = runtime.extensions.changes.firstWhere(
            (_) => commands.discover().any((c) => c.id == _id('success')),
          );
          late Future<void> starting;
          await tester.pumpWidget(
            AdeleApplication(
              createRuntime: () => runtime,
              readChatGptConfiguration: () => null,
              bootstrapPlugins: (plugins) => starting = plugins.start(
                installationRoot: root.path,
                dartaotruntimeExecutable: '${root.path}/missing-runtime',
                hostArtifactPath: '${root.path}/missing-host.aot',
              ),
            ),
          );
          await activated.timeout(_bound);
          await starting.timeout(_bound);
        });
        await tester.pumpAndSettle();

        expect(runtime.plugins.state, ApplicationPluginState.ready);
        expect(runtime.plugins.failure, isNull);
        expect(runtime.plugins.catalog!.issues, isEmpty);
        final installation = runtime.plugins.catalog!.installations.single;
        expect(installation.backendArtifactUri, isNull);
        expect(installation.frontend!.presentations, isEmpty);
        expect(installation.frontend!.extensions, hasLength(3));
        expect(runtime.plugins.backends, isEmpty);
        expect(runtime.plugins.host, isNull);
        expect(runtime.extensions.discover(mainContentContributions), isEmpty);
        expect(runtime.extensions.discover(consoleContributions), isEmpty);
        expect(runtime.extensions.discover(taskBrowserContributions), isEmpty);
        expect(
          runtime.extensions.discover(projectSelectorContributions),
          isEmpty,
        );
        expect(
          tester.widget<AdeleShell>(find.byType(AdeleShell)).project,
          isNull,
        );
        expect(find.text('No Project is open'), findsOneWidget);
        expect(commands.discover(), hasLength(5));
        final captured = commands.resolve(_id('success'));
        expect(captured.availability, CommandAvailability.enabled);

        for (var attempt = 0; attempt < 2; attempt++) {
          await open(tester);
          for (final name in ['success', 'failure', 'malformed']) {
            expect(
              tester
                  .widget<ListTile>(
                    find.widgetWithText(ListTile, 'Frontend $name'),
                  )
                  .enabled,
              isTrue,
            );
          }
          await tester.tap(find.text('Frontend success'));
          await tester.pumpAndSettle();
          expect(find.byType(CommandPalette), findsNothing);
          expect(find.byType(SnackBar), findsNothing);
        }

        // Different declared entrypoints prove execution, not just registration.
        await open(tester);
        await tester.tap(find.text('Frontend failure'));
        await tester.pumpAndSettle();
        expect(find.byType(CommandPalette), findsNothing);
        expect(
          find.text('The command could not be completed.'),
          findsOneWidget,
        );
        expect(find.textContaining('private frontend'), findsNothing);
        expect(find.textContaining('StateError'), findsNothing);
        await expectLater(
          commands.resolve(_id('malformed')).invoke(),
          throwsFormatException,
        );
        expect(runtime.plugins.host, isNull);
        expect(runtime.plugins.backends, isEmpty);
        expect(tester.takeException(), isNull);

        await unmount(tester);
        expect(captured.availability, CommandAvailability.disabled);
        await expectLater(
          captured.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
      } finally {
        await unmount(tester);
      }
    },
  );

  testWidgets(
    'frontend retirement updates the open palette and fences same-ID replacement',
    (tester) async {
      // Explicit owner access exercises retirement without a production test hook.
      // It uses the same catalog and activation path as application startup.
      final frontend = ApplicationFrontendBootstrap(
        extensions: runtime.extensions,
      );
      final replacement = ApplicationFrontendBootstrap(
        extensions: runtime.extensions,
      );
      try {
        await tester.runAsync(() async {
          await frontend.start(await PreparedPluginCatalog.discover(root.path));
          await tester.pumpWidget(
            AdeleApplication(
              createRuntime: () => runtime,
              readChatGptConfiguration: () => null,
              bootstrapPlugins: (_) async {},
            ),
          );
        });
        await tester.pumpAndSettle();
        final captured = commands.resolve(_id('success'));
        final invoke = captured.binding.value.invoke;
        final availability = captured.binding.value.availability;
        await open(tester);
        final staleTap = tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Frontend success'))
            .onTap!;
        await tester.runAsync(frontend.close);
        await tester.pumpAndSettle();
        expect(find.byType(CommandPalette), findsOneWidget);
        expect(find.text('No commands are available.'), findsOneWidget);
        expect(find.text('Frontend success'), findsNothing);
        expect(availability(), CommandAvailability.disabled);

        await tester.runAsync(() async {
          await replacement.start(
            await PreparedPluginCatalog.discover(root.path),
          );
        });
        await tester.pumpAndSettle();
        expect(find.text('Frontend success'), findsOneWidget);
        expect(captured.availability, CommandAvailability.disabled);
        expect(
          captured.binding.isSameRegistration(
            commands.resolve(captured.id).binding,
          ),
          isFalse,
        );
        await expectLater(
          captured.invoke(),
          throwsA(isA<StaleExtensionBinding>()),
        );
        await expectLater(Future<void>.sync(invoke), throwsStateError);
        staleTap();
        await tester.pumpAndSettle();
        expect(find.byType(CommandPalette), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        await tester.tap(find.text('Frontend success'));
        await tester.pumpAndSettle();
        expect(find.byType(CommandPalette), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(runtime.plugins.host, isNull);
        expect(runtime.plugins.backends, isEmpty);
      } finally {
        await tester.runAsync(() async {
          await frontend.close();
          await replacement.close();
        });
        await unmount(tester);
      }
    },
  );
}
