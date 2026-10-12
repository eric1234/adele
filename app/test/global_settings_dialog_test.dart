import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/ui/settings/global_settings_dialog.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tools/backend_artifacts.dart';

const _owner = 'dev.example.preferences';
const _enabled = '$_owner.enabled';
const _count = '$_owner.count';
const _message = '$_owner.message';
const _mode = '$_owner.mode';
const _folding = 'dev.adele.source-editor.enable-folding';
const _restart = 'Restart ADELE to apply configuration changes.';

void main() {
  late Directory temporary;
  late PlatformStorageRoots roots;
  late SettingsCatalog catalog;
  final services = <GlobalSettingsService>[];

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('adele-settings-dialog-');
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${temporary.path}/config',
      localStateRoot: '${temporary.path}/state',
      localDataRoot: '${temporary.path}/data',
      cacheRoot: '${temporary.path}/cache',
    );
    catalog = SettingsCatalog([
      _definition(
        _enabled,
        const BooleanSettingType(),
        false,
        label: 'Enable Preview',
        description: 'Show previews alongside documents.',
      ),
      _definition(
        _count,
        IntegerSettingType(minimum: 1, maximum: 5),
        3,
        label: 'Preview Count',
      ),
      _definition(
        _message,
        const StringSettingType(),
        'Initial message',
        label: 'Welcome Message',
        category: 'Workspace',
        section: 'Greeting',
      ),
      _definition(
        _mode,
        EnumSettingType([
          SettingEnumOption('compact', label: 'Compact Display'),
          SettingEnumOption('expanded', label: 'Expanded Display'),
        ]),
        'compact',
        label: 'Preview Mode',
      ),
    ]);
  });

  tearDown(() async {
    for (final service in services) {
      await service.close();
    }
    services.clear();
    await temporary.delete(recursive: true);
  });

  GlobalSettingsService createService() {
    final service = GlobalSettingsService(catalog: catalog, roots: roots);
    services.add(service);
    return service;
  }

  File settingsFile() => File('${roots.configurationRoot}/settings.toml');

  void seed(String contents) {
    final file = settingsFile();
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  Future<void> mount(
    WidgetTester tester, {
    Future<GlobalSettingsService> Function()? service,
    List<String> declarationIssues = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final owner = service == null ? createService() : null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => GlobalSettingsDialog(
                  service: service ?? () async => owner!,
                  declarationIssues: () => declarationIssues,
                ),
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> loaded(WidgetTester tester) => _until(
    tester,
    () => _buttonEnabled(tester, _reload),
    'settings operation did not finish',
  );

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pump();
    await loaded(tester);
  }

  Future<void> expectPersisted(
    String id,
    Object value,
    SettingValueSource source,
  ) async {
    final fresh = await createService().load();
    expect(fresh.failures, isEmpty);
    final resolved = fresh.values[SettingId(id)]!;
    expect(resolved.value, value);
    expect(resolved.source, source);
    expect(resolved.hasGlobalOverride, source == SettingValueSource.global);
  }

  testWidgets('renders declared scalar controls and product metadata', (
    tester,
  ) {
    return tester.runAsync(() async {
      await mount(tester);
      await loaded(tester);
      expect(find.text('Global Settings'), findsOneWidget);
      expect(find.text(_restart), findsOneWidget);
      for (final text in [
        'Editor',
        'Display',
        'Workspace',
        'Greeting',
        'Enable Preview',
        'Preview Count',
        'Welcome Message',
        'Preview Mode',
        'Show previews alongside documents.',
      ]) {
        expect(find.textContaining(text), findsWidgets, reason: text);
      }
      expect(tester.widget<Switch>(_input(_enabled)).value, isFalse);
      expect(tester.widget<TextField>(_input(_count)).controller!.text, '3');
      final message = tester.widget<TextField>(_input(_message));
      expect(message.controller!.text, 'Initial message');
      expect(message.minLines, 2);
      expect(message.maxLines, isNull);
      expect(find.text('Compact Display'), findsOneWidget);
      for (final id in [_enabled, _count, _message, _mode]) {
        expect(_rowText(id, 'Default'), findsOneWidget);
        expect(_buttonEnabled(tester, _save(id)), isTrue);
        expect(_buttonEnabled(tester, _reset(id)), isFalse);
      }
      expect(_rowText(_enabled, 'Effective value: false'), findsOneWidget);
      expect(_rowText(_count, 'Effective value: 3'), findsOneWidget);
      expect(settingsFile().existsSync(), isFalse);
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      expect(Directory(roots.localDataRoot).existsSync(), isFalse);
      expect(Directory(roots.cacheRoot).existsSync(), isFalse);
      await unmount(tester);
    });
  });

  testWidgets(
    'saves explicit default overrides and Reset removes them',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await loaded(tester);
        await tap(tester, _save(_enabled));
        expect(
          settingsFile().readAsStringSync(),
          contains('"$_enabled" = false'),
        );
        expect(_rowText(_enabled, 'Global'), findsOneWidget);
        expect(_rowText(_enabled, 'Effective value: false'), findsOneWidget);
        expect(_buttonEnabled(tester, _save(_enabled)), isFalse);
        expect(_buttonEnabled(tester, _reset(_enabled)), isTrue);
        await expectPersisted(_enabled, false, SettingValueSource.global);

        await tap(tester, _input(_enabled));
        expect(_rowText(_enabled, 'Effective value: false'), findsOneWidget);
        await tap(tester, _save(_enabled));
        expect(_rowText(_enabled, 'Effective value: true'), findsOneWidget);
        await expectPersisted(_enabled, true, SettingValueSource.global);

        await tap(tester, _reset(_enabled));
        expect(settingsFile().readAsStringSync(), isNot(contains(_enabled)));
        expect(_rowText(_enabled, 'Default'), findsOneWidget);
        expect(_rowText(_enabled, 'Effective value: false'), findsOneWidget);
        expect(_buttonEnabled(tester, _save(_enabled)), isTrue);
        await expectPersisted(_enabled, false, SettingValueSource.defaultValue);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets('narrow viewports retain reachable controls without overflow', (
    tester,
  ) {
    return tester.runAsync(() async {
      await mount(tester);
      await loaded(tester);
      await tester.binding.setSurfaceSize(const Size(400, 700));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(Dialog)).width, lessThanOrEqualTo(400));
      await tester.ensureVisible(_input(_message));
      await tester.enterText(_input(_message), 'Narrow-screen draft');
      await tester.pump();
      expect(_buttonEnabled(tester, _save(_message)), isTrue);
      await tap(tester, _reload);
      expect(
        tester.widget<TextField>(_input(_message)).controller!.text,
        'Initial message',
      );
      expect(settingsFile().existsSync(), isFalse);
      await unmount(tester);
    });
  });

  testWidgets('enum displays labels but persists stable values', (tester) {
    return tester.runAsync(() async {
      await mount(tester);
      await loaded(tester);
      await tester.ensureVisible(_input(_mode));
      await tester.tap(_input(_mode));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expanded Display').last);
      await tester.pumpAndSettle();
      await tap(tester, _save(_mode));
      expect(
        settingsFile().readAsStringSync(),
        contains('"$_mode" = "expanded"'),
      );
      expect(
        settingsFile().readAsStringSync(),
        isNot(contains('Expanded Display')),
      );
      expect(_rowText(_mode, 'Global'), findsOneWidget);
      expect(_rowText(_mode, 'Effective value: expanded'), findsOneWidget);
      await expectPersisted(_mode, 'expanded', SettingValueSource.global);
      await tap(tester, _reload);
      expect(find.text('Expanded Display'), findsOneWidget);
      expect(_buttonEnabled(tester, _save(_mode)), isFalse);
      await unmount(tester);
    });
  }, skip: !Platform.isLinux);

  testWidgets(
    'integer validates syntax and inclusive declared bounds',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await loaded(tester);
        for (final invalid in ['', 'not an integer', '1.5', '0', '6']) {
          await tester.enterText(_input(_count), invalid);
          await tester.pump();
          expect(
            _buttonEnabled(tester, _save(_count)),
            isFalse,
            reason: invalid,
          );
          expect(
            tester.widget<TextField>(_input(_count)).decoration!.errorText,
            isNotEmpty,
            reason: invalid,
          );
          expect(_rowText(_count, 'Effective value: 3'), findsOneWidget);
          expect(settingsFile().existsSync(), isFalse);
        }
        for (final valid in [1, 5]) {
          await tester.enterText(_input(_count), '$valid');
          await tester.pump();
          expect(_buttonEnabled(tester, _save(_count)), isTrue);
          await tap(tester, _save(_count));
          expect(_rowText(_count, 'Effective value: $valid'), findsOneWidget);
          await expectPersisted(_count, valid, SettingValueSource.global);
        }
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'multiline and empty strings survive native save and Reload',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await loaded(tester);
        for (final value in ['First line\nSecond line\n', '']) {
          await tester.ensureVisible(_input(_message));
          await tester.enterText(_input(_message), value);
          await tester.pump();
          await tap(tester, _save(_message));
          await expectPersisted(_message, value, SettingValueSource.global);
          await tap(tester, _reload);
          expect(
            tester.widget<TextField>(_input(_message)).controller!.text,
            value,
          );
          expect(_rowText(_message, 'Global'), findsOneWidget);
          expect(_buttonEnabled(tester, _save(_message)), isFalse);
        }
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets('search filters labels, descriptions, IDs and product groups', (
    tester,
  ) {
    return tester.runAsync(() async {
      await mount(tester);
      await loaded(tester);
      await tester.enterText(_input(_message), 'Retained search draft');
      await tester.pump();
      for (final (query, id) in [
        ('WELCOME', _message),
        ('alongside documents', _enabled),
        (_count, _count),
        ('Workspace', _message),
        ('Greeting', _message),
      ]) {
        await tester.enterText(_search, query);
        await tester.pump();
        expect(_row(id), findsOneWidget, reason: query);
        expect(_row(_mode), findsNothing, reason: query);
      }
      await tester.enterText(_search, 'no matching declaration');
      await tester.pump();
      expect(find.textContaining('No settings match'), findsOneWidget);
      await tester.enterText(_search, '');
      await tester.pump();
      for (final id in [_enabled, _count, _message, _mode]) {
        expect(_row(id), findsOneWidget);
      }
      expect(
        tester.widget<TextField>(_input(_message)).controller!.text,
        'Retained search draft',
      );
      expect(settingsFile().existsSync(), isFalse);
      await unmount(tester);
    });
  });

  testWidgets('search excludes hidden editors from keyboard traversal', (
    tester,
  ) {
    return tester.runAsync(() async {
      await mount(tester);
      await loaded(tester);
      await tester.enterText(_search, 'no matching setting');
      await tester.pump();
      for (var index = 0; index < 16; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
          element,
        ) {
          final key = element.widget.key;
          expect(
            key is ValueKey<String> && key.value.startsWith('setting-'),
            isFalse,
            reason: 'A hidden setting received keyboard focus.',
          );
          return true;
        });
      }
      expect(settingsFile().existsSync(), isFalse);
      await unmount(tester);
    });
  });

  testWidgets('empty catalogs and declaration failures have explicit UI', (
    tester,
  ) {
    return tester.runAsync(() async {
      catalog = SettingsCatalog([]);
      await mount(
        tester,
        declarationIssues: const [
          'Rejected settings declaration: invalid type.',
        ],
      );
      await loaded(tester);
      expect(find.text('Global Settings'), findsOneWidget);
      expect(find.textContaining('No settings'), findsOneWidget);
      expect(
        find.textContaining('Rejected settings declaration: invalid type.'),
        findsOneWidget,
      );
      expect(find.text('Default'), findsNothing);
      expect(settingsFile().existsSync(), isFalse);
      await unmount(tester);
    });
  });

  testWidgets(
    'startup failure is visible and Reload retries the service factory',
    (tester) {
      return tester.runAsync(() async {
        var attempts = 0;
        await mount(
          tester,
          service: () async {
            if (++attempts == 1) throw StateError('Settings startup failed.');
            return createService();
          },
        );
        await loaded(tester);
        expect(find.textContaining('Settings startup failed.'), findsOneWidget);
        expect(_row(_enabled), findsNothing);
        await tap(tester, _reload);
        expect(attempts, 2);
        expect(_rowText(_enabled, 'Default'), findsOneWidget);
        expect(find.textContaining('Settings startup failed.'), findsNothing);
        await unmount(tester);
      });
    },
  );

  testWidgets('malformed TOML is not presented as defaults or overwritten', (
    tester,
  ) {
    return tester.runAsync(() async {
      const malformed = 'broken = [\n';
      seed(malformed);
      await mount(tester);
      await loaded(tester);
      expect(find.textContaining('TOML'), findsWidgets);
      expect(_row(_enabled), findsNothing);
      expect(find.text('Default'), findsNothing);
      expect(settingsFile().readAsStringSync(), malformed);
      seed('"$_enabled" = true\n');
      await tap(tester, _reload);
      expect(_rowText(_enabled, 'Global'), findsOneWidget);
      expect(_rowText(_enabled, 'Effective value: true'), findsOneWidget);
      seed(malformed);
      await tap(tester, _reload);
      expect(_row(_enabled), findsNothing);
      expect(find.text('Default'), findsNothing);
      expect(settingsFile().readAsStringSync(), malformed);
      await unmount(tester);
    });
  });

  testWidgets(
    'prepared schema failures remain visible beside healthy settings',
    (tester) {
      return tester.runAsync(() async {
        for (final suffix in ['healthy', 'missing', 'malformed']) {
          final directory = Directory('${temporary.path}/installed/$suffix')
            ..createSync(recursive: true);
          final owner = 'dev.example.$suffix';
          File(
            '${directory.path}/adele_plugin.installation.json',
          ).writeAsStringSync(
            jsonEncode({
              'manifestVersion': 1,
              'metadata': {'id': owner, 'version': '1', 'displayName': suffix},
              'settingsSchema': 'settings.schema.json',
              'components': <String, Object?>{},
            }),
          );
          if (suffix != 'missing') {
            File('${directory.path}/settings.schema.json').writeAsStringSync(
              suffix == 'malformed'
                  ? '{}'
                  : jsonEncode({
                      'schemaVersion': 1,
                      'definitions': [
                        {
                          'id': '$owner.enabled',
                          'type': 'boolean',
                          'default': false,
                          'label': 'Healthy Setting',
                          'category': 'General',
                          'section': 'Display',
                        },
                      ],
                    }),
            );
          }
        }
        final prepared = await PreparedPluginCatalog.discover(
          '${temporary.path}/installed',
        );
        catalog = prepared.settings;
        expect(prepared.issues, hasLength(2));
        expect(
          prepared.issues.every((issue) => issue.isSettingsSchemaIssue),
          isTrue,
        );
        await mount(
          tester,
          declarationIssues: prepared.issues
              .map((issue) => issue.message)
              .toList(),
        );
        await loaded(tester);
        expect(find.text('Healthy Setting'), findsOneWidget);
        expect(
          find.textContaining('Setting declarations unavailable:'),
          findsNWidgets(2),
        );
        expect(
          find.textContaining('Correct the installation and restart ADELE.'),
          findsNWidgets(2),
        );
        expect(settingsFile().existsSync(), isFalse);
        await unmount(tester);
      });
    },
  );

  testWidgets(
    'duplicate prepared declarations reject the whole editing catalog',
    (tester) {
      return tester.runAsync(() async {
        for (final owner in [
          'dev.example.preferences',
          'dev.example.preferences.child',
        ]) {
          final directory = Directory('${temporary.path}/installed/$owner')
            ..createSync(recursive: true);
          File(
            '${directory.path}/adele_plugin.installation.json',
          ).writeAsStringSync(
            jsonEncode({
              'manifestVersion': 1,
              'metadata': {'id': owner, 'version': '1', 'displayName': owner},
              'settingsSchema': 'settings.schema.json',
              'components': <String, Object?>{},
            }),
          );
          File('${directory.path}/settings.schema.json').writeAsStringSync(
            jsonEncode({
              'schemaVersion': 1,
              'definitions': [
                {
                  'id': 'dev.example.preferences.child.enabled',
                  'type': 'boolean',
                  'default': false,
                  'label': 'Conflicting Setting',
                  'category': 'General',
                  'section': 'Display',
                },
              ],
            }),
          );
        }
        final prepared = await PreparedPluginCatalog.discover(
          '${temporary.path}/installed',
        );
        expect(prepared.issues, isEmpty);
        await mount(
          tester,
          service: () async {
            catalog = prepared.settings;
            return createService();
          },
        );
        await loaded(tester);
        expect(find.textContaining('DuplicateSettingId'), findsOneWidget);
        expect(find.text('Conflicting Setting'), findsNothing);
        expect(find.text('Default'), findsNothing);
        expect(settingsFile().existsSync(), isFalse);
        await unmount(tester);
      });
    },
  );

  testWidgets(
    'non-Linux changed saves are errors rather than persisted values',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await loaded(tester);
        await tester.tap(_input(_enabled));
        await tester.pump();
        await tap(tester, _save(_enabled));
        expect(
          find.textContaining('Configuration writes currently require Linux'),
          findsOneWidget,
        );
        expect(_rowText(_enabled, 'Default'), findsOneWidget);
        expect(_rowText(_enabled, 'Effective value: false'), findsOneWidget);
        expect(settingsFile().existsSync(), isFalse);
        await unmount(tester);
      });
    },
    skip: Platform.isLinux,
  );

  for (final invalid in ['"not boolean"', '7']) {
    testWidgets(
      'Reset repairs invalid scalar $invalid without a default fallback',
      (tester) {
        return tester.runAsync(() async {
          const unknown = '"dev.unavailable.setting" = [1, 2] # preserve\n';
          seed('"$_enabled" = $invalid\n$unknown');
          await mount(tester);
          await loaded(tester);
          expect(_rowText(_enabled, 'Default'), findsNothing);
          expect(_rowText(_enabled, 'Effective value: false'), findsNothing);
          expect(_input(_enabled), findsNothing);
          expect(_buttonEnabled(tester, _save(_enabled)), isFalse);
          expect(_buttonEnabled(tester, _reset(_enabled)), isTrue);
          expect(
            find.descendant(
              of: _row(_enabled),
              matching: find.textContaining('boolean'),
            ),
            findsWidgets,
          );
          expect(_rowText(_count, 'Default'), findsOneWidget);
          await tap(tester, _reset(_enabled));
          expect(settingsFile().readAsStringSync(), unknown);
          expect(_rowText(_enabled, 'Default'), findsOneWidget);
          await expectPersisted(
            _enabled,
            false,
            SettingValueSource.defaultValue,
          );
          await unmount(tester);
        });
      },
      skip: !Platform.isLinux,
    );
  }

  for (final unsupported in ['[true]', '{ enabled = true }']) {
    testWidgets(
      'unsupported $unsupported Reset fails with manual repair guidance',
      (tester) {
        return tester.runAsync(() async {
          final original = '"$_enabled" = $unsupported # keep\n';
          seed(original);
          await mount(tester);
          await loaded(tester);
          expect(_rowText(_enabled, 'Default'), findsNothing);
          expect(_input(_enabled), findsNothing);
          expect(_buttonEnabled(tester, _reset(_enabled)), isTrue);
          await tap(tester, _reset(_enabled));
          expect(
            find.textContaining('Could not confirm the save.'),
            findsOneWidget,
          );
          expect(
            find.textContaining(RegExp('manual', caseSensitive: false)),
            findsWidgets,
          );
          expect(_rowText(_enabled, 'Default'), findsNothing);
          expect(_rowText(_enabled, 'Effective value: false'), findsNothing);
          expect(settingsFile().readAsStringSync(), original);
          expect(_rowText(_count, 'Default'), findsOneWidget);
          await unmount(tester);
        });
      },
      skip: !Platform.isLinux,
    );
  }

  testWidgets(
    'conflict preserves external edits and fences writes until Reload',
    (tester) {
      return tester.runAsync(() async {
        seed('"$_enabled" = false\n');
        await mount(tester);
        await loaded(tester);
        await tap(tester, _input(_enabled));
        const external = '"$_enabled" = false\nexternal = 42 # preserve\n';
        seed(external);
        await tap(tester, _save(_enabled));
        expect(
          find.textContaining(RegExp('conflict|changed', caseSensitive: false)),
          findsWidgets,
        );
        expect(settingsFile().readAsStringSync(), external);
        expect(_rowText(_enabled, 'Effective value: false'), findsOneWidget);
        expect(_buttonEnabled(tester, _save(_enabled)), isFalse);
        expect(_buttonEnabled(tester, _reset(_enabled)), isFalse);
        expect(_buttonEnabled(tester, _save(_count)), isFalse);

        await tap(tester, _reload);
        expect(tester.widget<Switch>(_input(_enabled)).value, isFalse);
        expect(_buttonEnabled(tester, _reset(_enabled)), isTrue);
        await tap(tester, _input(_enabled));
        await tap(tester, _save(_enabled));
        expect(
          settingsFile().readAsStringSync(),
          external.replaceFirst('false', 'true'),
        );
        expect(_rowText(_enabled, 'Effective value: true'), findsOneWidget);
        await expectPersisted(_enabled, true, SettingValueSource.global);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'failed native write retains the truthful effective value and draft',
    (tester) {
      return tester.runAsync(() async {
        seed('"$_enabled" = false # original\n');
        await mount(tester);
        await loaded(tester);
        // A file blocking the local-state directory fails real persistence even
        // when tests run with permission to bypass ordinary file mode checks.
        File(roots.localStateRoot).writeAsStringSync('not a directory');
        await tap(tester, _input(_enabled));
        await tap(tester, _save(_enabled));
        expect(
          find.textContaining('Could not confirm the save.'),
          findsOneWidget,
        );
        expect(
          settingsFile().readAsStringSync(),
          '"$_enabled" = false # original\n',
        );
        expect(tester.widget<Switch>(_input(_enabled)).value, isTrue);
        expect(_rowText(_enabled, 'Global'), findsOneWidget);
        expect(_rowText(_enabled, 'Effective value: false'), findsOneWidget);
        expect(_buttonEnabled(tester, _save(_enabled)), isFalse);
        File(roots.localStateRoot).deleteSync();
        await tap(tester, _reload);
        await tap(tester, _input(_enabled));
        await tap(tester, _save(_enabled));
        expect(_rowText(_enabled, 'Effective value: true'), findsOneWidget);
        await expectPersisted(_enabled, true, SettingValueSource.global);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'a lost acknowledgement requires Reload after actual publication',
    (tester) {
      return tester.runAsync(() async {
        final service = _LostAcknowledgementService(
          catalog: catalog,
          roots: roots,
        );
        services.add(service);
        await mount(tester, service: () async => service);
        await loaded(tester);
        await tap(tester, _input(_enabled));
        await tap(tester, _save(_enabled));
        expect(
          find.textContaining('Could not confirm the save.'),
          findsOneWidget,
        );
        expect(find.textContaining('Not saved'), findsNothing);
        expect(
          settingsFile().readAsStringSync(),
          contains('"$_enabled" = true'),
        );
        expect(_rowText(_enabled, 'Default'), findsOneWidget);
        expect(_rowText(_enabled, 'Effective value: false'), findsOneWidget);
        expect(_buttonEnabled(tester, _save(_enabled)), isFalse);
        expect(_buttonEnabled(tester, _reset(_enabled)), isFalse);
        await tap(tester, _reload);
        expect(_rowText(_enabled, 'Global'), findsOneWidget);
        expect(_rowText(_enabled, 'Effective value: true'), findsOneWidget);
        expect(_buttonEnabled(tester, _reset(_enabled)), isTrue);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'rapid repeated Save and Reset callbacks admit only one write',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await loaded(tester);
        for (final action in [_save(_enabled), _reset(_enabled)]) {
          await tester.ensureVisible(action);
          final callback = tester.widget<ButtonStyleButton>(action).onPressed!;
          callback();
          callback();
          await tester.pump();
          await loaded(tester);
          expect(
            find.textContaining(RegExp('conflict', caseSensitive: false)),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        }
        expect(_rowText(_enabled, 'Default'), findsOneWidget);
        expect(settingsFile().readAsStringSync(), isNot(contains(_enabled)));
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'Reload admits one operation and retains a valid editable revision',
    (tester) {
      return tester.runAsync(() async {
        final service = _GatedSettingsService(catalog: catalog, roots: roots);
        services.add(service);
        seed('"$_enabled" = false # original\n');
        await mount(tester, service: () async => service);
        await loaded(tester);
        expect(service.loads, 1);
        await tap(tester, _input(_enabled));
        final save = tester
            .widget<ButtonStyleButton>(_save(_enabled))
            .onPressed!;
        final reset = tester
            .widget<ButtonStyleButton>(_reset(_enabled))
            .onPressed!;
        final reload = tester.widget<ButtonStyleButton>(_reload).onPressed!;
        final pending = Completer<void>();
        service.gate = pending.future;
        try {
          reload();
          reload();
          expect(service.loads, 2);
          // Callbacks captured before rebuilding must obey the same fence.
          save();
          reset();
          expect(service.saves, 0);
          expect(service.resets, 0);
          await tester.pump();
          expect(_buttonEnabled(tester, _reload), isFalse);
          expect(_buttonEnabled(tester, _save(_enabled)), isFalse);
          expect(_buttonEnabled(tester, _reset(_enabled)), isFalse);
          expect(tester.widget<Switch>(_input(_enabled)).onChanged, isNull);
          expect(tester.widget<Switch>(_input(_enabled)).value, isTrue);
          expect(find.byType(LinearProgressIndicator), findsOneWidget);
          expect(
            settingsFile().readAsStringSync(),
            '"$_enabled" = false # original\n',
          );
        } finally {
          service.gate = null;
          pending.complete();
        }
        await loaded(tester);
        expect(service.loads, 2);
        expect(tester.widget<Switch>(_input(_enabled)).value, isFalse);
        await tap(tester, _input(_enabled));
        await tap(tester, _save(_enabled));
        expect(_rowText(_enabled, 'Effective value: true'), findsOneWidget);
        await expectPersisted(_enabled, true, SettingValueSource.global);
        await tap(tester, _reset(_enabled));
        expect(_rowText(_enabled, 'Default'), findsOneWidget);
        await expectPersisted(_enabled, false, SettingValueSource.defaultValue);
        expect(find.textContaining('Not saved'), findsNothing);
        expect(find.textContaining('Could not confirm'), findsNothing);

        // Failure clears admission too, without enabling editing of the old view.
        final failed = Completer<void>();
        service.gate = failed.future;
        final reloadAgain = tester
            .widget<ButtonStyleButton>(_reload)
            .onPressed!;
        reloadAgain();
        reloadAgain();
        expect(service.loads, 3);
        failed.completeError(
          const FileSystemException('Controlled reload failure'),
        );
        service.gate = null;
        await loaded(tester);
        expect(
          find.textContaining('Controlled reload failure'),
          findsOneWidget,
        );
        expect(_input(_enabled), findsNothing);
        seed('"$_enabled" = true\n');
        await tap(tester, _reload);
        expect(service.loads, 4);
        expect(_rowText(_enabled, 'Effective value: true'), findsOneWidget);
        expect(find.textContaining('Controlled reload failure'), findsNothing);
        await tap(tester, _reset(_enabled));
        await expectPersisted(_enabled, false, SettingValueSource.defaultValue);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'captured Reload callbacks cannot overlap Save or Reset',
    (tester) {
      return tester.runAsync(() async {
        final service = _GatedSettingsService(catalog: catalog, roots: roots);
        services.add(service);
        await mount(tester, service: () async => service);
        await loaded(tester);
        for (final action in [_save(_enabled), _reset(_enabled)]) {
          final reload = tester.widget<ButtonStyleButton>(_reload).onPressed!;
          final commit = tester.widget<ButtonStyleButton>(action).onPressed!;
          final pending = Completer<void>();
          service.gate = pending.future;
          try {
            commit();
            reload();
            reload();
            expect(service.loads, 1);
            await tester.pump();
            expect(_buttonEnabled(tester, _reload), isFalse);
            expect(_buttonEnabled(tester, action), isFalse);
            expect(tester.widget<Switch>(_input(_enabled)).onChanged, isNull);
          } finally {
            service.gate = null;
            pending.complete();
          }
          await loaded(tester);
        }
        expect(service.saves, 1);
        expect(service.resets, 1);
        expect(_rowText(_enabled, 'Default'), findsOneWidget);
        await tap(tester, _reload);
        expect(service.loads, 2);
        expect(_rowText(_enabled, 'Default'), findsOneWidget);
        expect(find.textContaining('Not saved'), findsNothing);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets('closing during pending service load ignores late completion', (
    tester,
  ) {
    return tester.runAsync(() async {
      final pending = Completer<GlobalSettingsService>();
      await mount(tester, service: () => pending.future);
      expect(find.byType(GlobalSettingsDialog), findsOneWidget);
      Navigator.of(tester.element(find.byType(GlobalSettingsDialog))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(GlobalSettingsDialog), findsNothing);
      final service = createService();
      pending.complete(service);
      await service.load();
      await tester.pump();
      expect(find.byType(GlobalSettingsDialog), findsNothing);
      expect(tester.takeException(), isNull);
      expect(settingsFile().existsSync(), isFalse);
      await unmount(tester);
    });
  });

  testWidgets(
    'closing during a locked save keeps one admitted native write',
    (tester) {
      return tester.runAsync(() async {
        await mount(tester);
        await loaded(tester);
        await tap(tester, _input(_enabled));
        final lock = File(ConfigurationStore(roots).lockPath);
        lock.parent.createSync(recursive: true);
        // Keep the SDK-only child outside workspace native-asset preparation.
        final helper = File(
          'test/support/settings_lock.dart',
        ).copySync('${temporary.path}/settings_lock.dart');
        final process = await Process.start(
          '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart',
          [helper.path, lock.path],
          workingDirectory: temporary.path,
        );
        final lines = StreamIterator(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );
        final errors = process.stderr.transform(utf8.decoder).join();
        try {
          expect(
            await lines.moveNext().timeout(const Duration(seconds: 15)),
            isTrue,
          );
          expect(lines.current, 'locked');
          final save = tester
              .widget<ButtonStyleButton>(_save(_enabled))
              .onPressed!;
          save();
          save();
          await tester.pump();
          expect(_buttonEnabled(tester, _save(_enabled)), isFalse);
          expect(_buttonEnabled(tester, _reload), isFalse);
          expect(tester.widget<Switch>(_input(_enabled)).onChanged, isNull);
          expect(find.byType(LinearProgressIndicator), findsOneWidget);
          expect(settingsFile().existsSync(), isFalse);
          Navigator.of(tester.element(find.byType(GlobalSettingsDialog))).pop();
          await tester.pumpAndSettle();
          expect(find.byType(GlobalSettingsDialog), findsNothing);
          process.stdin.writeln('release');
          await process.stdin.close();
          expect(
            await process.exitCode.timeout(const Duration(seconds: 10)),
            0,
            reason: await errors,
          );
          await expectPersisted(_enabled, true, SettingValueSource.global);
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byType(GlobalSettingsDialog), findsNothing);
          await unmount(tester);
        } finally {
          process.kill();
          await process.exitCode;
          await lines.cancel();
        }
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'real published Source declaration survives save, reopen and reset',
    (tester) {
      return tester.runAsync(() async {
        final installations = Directory('${temporary.path}/installed');
        await publishStockPluginInstallation(
          repositoryRoot: Directory.current.parent,
          installationDirectory: Directory('${installations.path}/source'),
          pluginId: 'dev.adele.source-editor',
          displayName: 'Source',
        );
        final prepared = await PreparedPluginCatalog.discover(
          installations.path,
        );
        expect(prepared.issues, isEmpty);
        expect(prepared.installations.single.frontend, isNull);
        catalog = prepared.settings;
        expect(catalog.definitions.single.id, SettingId(_folding));
        await mount(tester);
        await loaded(tester);
        expect(find.text('Enable Code Folding'), findsOneWidget);
        expect(_rowText(_folding, 'Default'), findsOneWidget);
        await tap(tester, _input(_folding));
        await tap(tester, _save(_folding));
        await expectPersisted(_folding, true, SettingValueSource.global);
        Navigator.of(tester.element(find.byType(GlobalSettingsDialog))).pop();
        await tester.pumpAndSettle();

        seed('"$_folding" = false # external edit while closed\n');
        await tester.tap(find.text('Open settings'));
        await tester.pump();
        await loaded(tester);
        expect(tester.widget<Switch>(_input(_folding)).value, isFalse);
        expect(_rowText(_folding, 'Global'), findsOneWidget);
        expect(_buttonEnabled(tester, _save(_folding)), isFalse);
        await tap(tester, _reset(_folding));
        await expectPersisted(_folding, false, SettingValueSource.defaultValue);
        expect(settingsFile().readAsStringSync(), isNot(contains(_folding)));
        expect(find.text(_restart), findsOneWidget);
        await unmount(tester);
      });
    },
    skip: !Platform.isLinux,
  );
}

// Gate admission deterministically while retaining real native persistence.
final class _GatedSettingsService extends GlobalSettingsService {
  _GatedSettingsService({required super.catalog, required super.roots});

  Future<void>? gate;
  int loads = 0;
  int saves = 0;
  int resets = 0;

  @override
  Future<GlobalSettingsView> load() async {
    loads++;
    await gate;
    return super.load();
  }

  @override
  Future<GlobalSettingsView> save(
    GlobalSettingsView expected,
    SettingId id,
    Object value,
  ) async {
    saves++;
    await gate;
    return super.save(expected, id, value);
  }

  @override
  Future<GlobalSettingsView> reset(
    GlobalSettingsView expected,
    SettingId id,
  ) async {
    resets++;
    await gate;
    return super.reset(expected, id);
  }
}

// Model a cleanup/transport failure after the real native transaction commits.
final class _LostAcknowledgementService extends GlobalSettingsService {
  _LostAcknowledgementService({required super.catalog, required super.roots});

  @override
  Future<GlobalSettingsView> save(
    GlobalSettingsView expected,
    SettingId id,
    Object value,
  ) async {
    await super.save(expected, id, value);
    throw FileSystemException('Commit acknowledgement was lost.', filePath);
  }
}

SettingDefinition<T> _definition<T extends Object>(
  String id,
  SettingType<T> type,
  T value, {
  required String label,
  String category = 'Editor',
  String section = 'Display',
  String? description,
}) => SettingDefinition<T>(
  id: SettingId(id),
  owner: SettingOwnerId(_owner),
  label: label,
  category: category,
  section: section,
  description: description,
  type: type,
  defaultValue: value,
);

final _search = find.byKey(const ValueKey('settings-search'));
final _reload = find.byKey(const ValueKey('settings-reload'));

Finder _row(String id) => find.byKey(ValueKey('setting-$id'));
Finder _input(String id) => find.byKey(ValueKey('setting-input-$id'));
Finder _save(String id) => find.byKey(ValueKey('setting-save-$id'));
Finder _reset(String id) => find.byKey(ValueKey('setting-reset-$id'));
Finder _rowText(String id, String text) =>
    find.descendant(of: _row(id), matching: find.text(text));

bool _buttonEnabled(WidgetTester tester, Finder finder) {
  if (finder.evaluate().isEmpty) return false;
  return switch (tester.widget(finder)) {
    ButtonStyleButton(:final onPressed) => onPressed != null,
    IconButton(:final onPressed) => onPressed != null,
    _ => throw StateError('Expected a button: $finder'),
  };
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String reason,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}
