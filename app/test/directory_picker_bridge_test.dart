import 'dart:async';
import 'dart:io';

import 'package:adele_desktop/frontend/directory_picker_bridge.dart';
import 'package:adele_desktop/frontend/model_native_activity_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

const _library = 'package:picker_probe/main.dart';

void main() {
  late Directory temporary;
  late PreparedFrontend generation;
  late _Picker picker;
  late FileSelectorPlatform original;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-picker-bridge-');
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const DirectoryPickerDeclarations())
      ..entrypoints.add(_library);
    final program = compiler.compile({
      'picker_probe': {
        'main.dart': '''
import 'package:flutter/material.dart';
import 'package:adele_ui/directory_picker_bridge.dart';
int calls = 0;
Future<String?> select() async {
  calls++;
  if (calls != 1) throw StateError('Runtime reused');
  return await pickDirectory();
}
Future<String?> twice() async {
  await pickDirectory();
  return await pickDirectory();
}
Future<String?> detachedTwice() async {
  await pickDirectory();
  pickDirectory();
  return 'file:///must-not-succeed/';
}
Future<String?> detachedResult() async {
  pickDirectory().then((path) => path);
  return null;
}
Future<String?> detachedFailure() async {
  pickDirectory().then((path) => path);
  await Future.delayed(Duration(milliseconds: 0));
  return null;
}
Future<Widget> presentation() async {
  await pickDirectory();
  return Text('Picker access leaked');
}
''',
      },
      'adele_ui': {
        'directory_picker_bridge.dart': await File(
          '${Directory.current.parent.path}/packages/ui/lib/directory_picker_bridge.dart',
        ).readAsString(),
      },
    });
    await File('${temporary.path}/probe.evc').writeAsBytes(program.write());
  });
  tearDownAll(() => temporary.delete(recursive: true));

  setUp(() async {
    original = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = picker = _Picker();
    generation = await PreparedFrontend.load(
      File('${temporary.path}/probe.evc'),
    );
  });
  tearDown(() {
    generation.invalidate();
    FileSelectorPlatform.instance = original;
  });

  Future<String?> invoke({
    String entrypoint = 'select',
    DirectoryPickerBridge? bridge,
    void Function()? onDecode,
  }) {
    final operation = bridge ?? DirectoryPickerBridge(isActive: () => true);
    return generation.invoke<String?>(
      library: _library,
      entrypoint: entrypoint,
      createBridge: () => operation,
      decodeResult: (value) {
        onDecode?.call();
        operation.validateResult();
        return switch (value) {
          null || $null() => null,
          String() => value,
          $String() => value.$value,
          _ => throw const FormatException('Expected a string or null.'),
        };
      },
    );
  }

  test(
    'async non-Widget operation awaits one native path and releases bridge',
    () async {
      final pending = Completer<String?>();
      picker.pick = () => pending.future;
      final bridge = DirectoryPickerBridge(isActive: () => true);
      generation.validateOperation(library: _library, entrypoint: 'select');
      expect(picker.calls, 0);
      final result = invoke(bridge: bridge);
      expect(picker.calls, 1);
      pending.complete('/native/selected project');
      expect(await result, '/native/selected project');
      expect(bridge.validateResult, throwsStateError);
      expect(await invoke(), '/native/selected project');
      expect(picker.calls, 2);
    },
  );

  test(
    'cancellation and native errors cross async eval without poisoning generation',
    () async {
      expect(await invoke(), isNull);
      final error = StateError('native picker failed');
      picker.pick = () async => throw error;
      await expectLater(invoke(), throwsA(same(error)));
      picker.pick = () async => '/retry';
      expect(await invoke(), '/retry');
      expect(picker.calls, 3);
    },
  );

  for (final entrypoint in ['twice', 'detachedTwice']) {
    test(
      '$entrypoint cannot open a second picker; a fresh operation can',
      () async {
        picker.pick = () async => '/selected';
        var decoded = false;
        await expectLater(
          invoke(entrypoint: entrypoint, onDecode: () => decoded = true),
          throwsStateError,
        );
        expect(decoded, entrypoint == 'detachedTwice');
        expect(picker.calls, 1);
        expect(await invoke(), '/selected');
        expect(picker.calls, 2);
      },
    );
  }

  test(
    'late errors from discarded eval futures stay inside their settled operation',
    () async {
      final pending = Completer<String?>();
      picker.pick = () => pending.future;
      expect(await invoke(entrypoint: 'detachedResult'), isNull);
      pending.complete('/late');
      await Future<void>.delayed(Duration.zero);
      expect(picker.calls, 1);
      picker.pick = () async => '/next';
      expect(await invoke(), '/next');
    },
  );

  test(
    'uncaught eval callback errors fail and revoke only the outstanding operation',
    () async {
      final pending = Completer<String?>();
      picker.pick = () => pending.future;
      final bridge = DirectoryPickerBridge(isActive: () => true);
      var decoded = false;
      final result = invoke(
        entrypoint: 'detachedFailure',
        bridge: bridge,
        onDecode: () => decoded = true,
      );
      final failure = StateError('detached callback failed');
      pending.completeError(failure);
      await expectLater(result, throwsA(same(failure)));
      expect(bridge.validateResult, throwsStateError);
      expect(decoded, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(picker.calls, 1);
      picker.pick = () async => '/next';
      expect(await invoke(), '/next');
    },
  );

  test(
    'retirement rejects a pending native result without waiting for dialog close',
    () async {
      final pending = Completer<String?>();
      picker.pick = () => pending.future;
      final result = invoke();
      final rejected = expectLater(result, throwsStateError);
      generation.invalidate();
      pending.complete('/too-late');
      await rejected;
      await expectLater(invoke(), throwsStateError);
      expect(picker.calls, 1);
    },
  );

  testWidgets(
    'ordinary prepared presentations never receive directory picker access',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: generation.createPresentation(
            library: _library,
            entrypoint: 'presentation',
            createBridge: () => ModelNativeActivityBridge(
              presentation: ModelNativePresentation(
                kind: 'test.kind',
                compactText: 'test',
                data: const {},
              ),
              isActive: () => true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(picker.calls, 0);
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(find.text('Picker access leaked'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

final class _Picker extends FileSelectorPlatform {
  int calls = 0;
  Future<String?> Function() pick = () async => null;

  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) {
    calls++;
    return pick();
  }
}
