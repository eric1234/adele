import 'dart:io';

import 'package:adele_desktop/frontend/environment_terminal_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_desktop/frontend/terminal_surface_bridge.dart';
import 'package:adele_desktop/terminal/native_terminal_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_frontend/terminal_frontend.dart' as native;

import '../../../../../app/tool/terminal_frontend_compiler.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late PreparedFrontend frontend;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('stock-terminal-eval-');
    artifact = File('${temporary.path}/frontend.evc');
    await artifact.writeAsBytes(
      await compileTerminalFrontend(
        repositoryRoot: Directory.current.parent.parent.parent.parent,
      ),
    );
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async => frontend = await PreparedFrontend.load(artifact));
  tearDown(() => frontend.invalidate());

  test('public interpreted entrypoints do not provide native fallbacks', () {
    expect(native.newTerminal, throwsUnsupportedError);
    expect(native.buildTerminal, throwsUnsupportedError);
  });

  test(
    'actual stock action supplies retained close, title and exit policy',
    () async {
      TerminalContentPolicy? policy;
      frontend.validateOperation(
        library: terminalFrontendLibrary,
        entrypoint: 'newTerminal',
      );
      expect(policy, isNull);
      final result = await frontend.invoke<Object?>(
        library: terminalFrontendLibrary,
        entrypoint: 'newTerminal',
        createBridge: () => EnvironmentTerminalBridge(
          isActive: () => true,
          create: (value) async => policy = value,
        ),
        decodeResult: copyStructuredBridgeData,
      );
      expect(result, [true, null]);
      expect(policy!.label, 'Terminal');
      expect(policy!.liveCloseMessage, contains('may have running work'));
      expect(policy!.followTitle, isTrue);
      expect(policy!.removeAfterExit, isTrue);
    },
  );

  for (final retired in [false, true]) {
    test(
      'native ${retired ? 'retirement' : 'failure'} settles safely',
      () async {
        var called = false;
        final result = await frontend.invoke<Object?>(
          library: terminalFrontendLibrary,
          entrypoint: 'newTerminal',
          createBridge: () => EnvironmentTerminalBridge(
            isActive: () => !retired,
            create: (_) async {
              called = true;
              throw StateError('PRIVATE_DIAGNOSTIC');
            },
          ),
          decodeResult: copyStructuredBridgeData,
        );
        expect(result, [false, 'Terminal creation could not be completed.']);
        expect(called, !retired);
        expect(result.toString(), isNot(contains('PRIVATE_DIAGNOSTIC')));
      },
    );
  }

  testWidgets('actual stock content mounts only the selected native surface', (
    tester,
  ) async {
    final surface = NativeTerminalSurface();
    addTearDown(surface.dispose);
    surface.write('STOCK_CONTENT');
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 600,
          height: 240,
          child: frontend.createPresentation(
            library: terminalFrontendLibrary,
            entrypoint: 'buildTerminal',
            createBridge: () =>
                TerminalSurfaceBridge(surface: surface, isActive: () => true),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Frontend unavailable.'), findsNothing);
    expect(find.byType(TabBar), findsNothing);
    expect(surface.isDisposed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(surface.isDisposed, isFalse);
  });
}
