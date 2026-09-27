@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/terminal_surface_bridge.dart';
import 'package:adele_desktop/terminal/environment_terminal_owner.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:xterm2/xterm.dart';

import '../../tools/git_pty_artifact.dart';

const _gitPluginId = 'dev.adele.plugin.git-environment';
const _library = 'package:terminal_probe/main.dart';
const _deadline = Duration(seconds: 10);
// Advance only the native gesture window, never wait for a blinking cursor.
const _gestureFrame = Duration(milliseconds: 350);

void main() {
  if (!Platform.isLinux || Abi.current() != Abi.linuxX64) {
    test(
      'real Environment terminal',
      () {},
      skip: 'Requires Linux x64/devpts.',
    );
    return;
  }

  late Directory artifacts;
  late File hostArtifact;
  late File gitArtifact;
  late File helper;
  late File child;
  late File frontendArtifact;
  late String dartaotruntime;

  setUpAll(() async {
    final repository = Directory.current.parent;
    artifacts = await Directory.systemTemp.createTemp('adele-terminal-aot-');
    addTearDown(() => artifacts.delete(recursive: true));
    final dart = _dartExecutable();
    dartaotruntime = '${File(dart).parent.path}/dartaotruntime';
    hostArtifact = File('${artifacts.path}/host.aot');
    gitArtifact = File('${artifacts.path}/git.aot');
    helper = File('${artifacts.path}/git-pty-helper');
    child = File('${artifacts.path}/terminal-process');
    frontendArtifact = File('${artifacts.path}/terminal.evc');
    await prepareGitPtyHelper(repositoryRoot: repository, output: helper);
    await _run('cc', [
      '-std=c11',
      '-O2',
      '-Wall',
      '-Wextra',
      '-Werror',
      '${repository.path}/app/test/fixtures/terminal_process.c',
      '-o',
      child.path,
    ]);
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint:
            'plugins/git_environment/packages/backend/bin/git_environment_backend.dart',
        artifact: gitArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'environment-terminal-integration',
      );
    }
    final program =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const TerminalSurfaceDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'terminal_probe': {
                'main.dart': await File(
                  'test/fixtures/terminal_frontend.dart',
                ).readAsString(),
              },
              'adele_ui': {
                'terminal_surface_bridge.dart': await File(
                  '${repository.path}/packages/ui/lib/terminal_surface_bridge.dart',
                ).readAsString(),
              },
            });
    await frontendArtifact.writeAsBytes(program.write());
  });

  late Directory container;
  late Directory source;
  late Directory workingDirectory;
  late AdeleRuntime runtime;
  late PreparedFrontend frontend;
  late TaskCreationResult created;
  late EnvironmentTerminalOwner owner;

  setUp(() async {
    container = await Directory.systemTemp.createTemp('adele-terminal-live-');
    addTearDown(() => container.delete(recursive: true));
    final repository = Directory('${container.path}/repo');
    source = Directory('${repository.path}/packages/source');
    await Directory('${source.path}/probe').create(recursive: true);
    await child.copy('${source.path}/probe/terminal-process');
    await _run('chmod', ['700', '${source.path}/probe/terminal-process']);
    await _git(repository, ['init', '--initial-branch=main']);
    await _git(repository, ['add', '.']);
    await _git(repository, ['commit', '-m', 'Terminal fixture baseline']);

    final installation = await Directory(
      '${container.path}/installations/git',
    ).create(recursive: true);
    await gitArtifact.copy('${installation.path}/backend.aot');
    await helper.copy('${installation.path}/git-pty-helper');
    await _run('chmod', ['700', '${installation.path}/git-pty-helper']);
    await File(
      '${installation.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': _gitPluginId,
          'version': '1.0.0',
          'displayName': 'Real Git terminal',
        },
        'components': {
          'backend': {'artifact': 'backend.aot'},
        },
      }),
    );
    runtime = AdeleRuntime(
      ids: MonotonicProductIdSource(seed: 'terminal'),
      runIds: _NoRuns(),
    );
    addTearDown(runtime.close);
    await runtime.plugins
        .start(
          installationRoot: installation.parent.path,
          dartaotruntimeExecutable: dartaotruntime,
          hostArtifactPath: hostArtifact.path,
          startupArguments: {
            _gitPluginId: ['--pty-helper=${installation.path}/git-pty-helper'],
          },
        )
        .timeout(_deadline);
    expect(runtime.plugins.state, ApplicationPluginState.ready);
    expect(runtime.plugins.failure, isNull);
    expect(runtime.plugins.host, isA<PluginBackendHost>());
    expect(runtime.plugins.host!.isClosed, isFalse);
    expect(runtime.plugins.catalog!.issues, isEmpty);
    expect(runtime.plugins.backends.single.state, InstalledBackendState.active);
    expect(runtime.plugins.backends.single.connection!.pluginId, _gitPluginId);

    final project = runtime.lifecycle.createProject(source.uri);
    created = await runtime.lifecycle
        .createTask(
          projectId: project.id,
          title: 'Terminal without Session or Run',
        )
        .timeout(_deadline);
    expect(
      runtime.store.primaryEnvironmentFor(created.task.id),
      same(created.environment),
    );
    expect(
      created.environment.providerId.value,
      'dev.adele.environment.git-worktree',
    );
    expect(runtime.store.sessionsForTask(created.task.id), isEmpty);
    final state = created.environment.providerState!;
    expect(state['sourceRelativePath'], 'packages/source');
    final worktree = Directory.fromUri(
      source.uri.resolve(state['worktreeRelativePath']! as String),
    );
    expect(
      await _git(worktree, ['rev-parse', '--show-toplevel']),
      '${worktree.path}\n',
    );
    expect(
      await _git(worktree, ['rev-parse', 'HEAD']),
      await _git(repository, ['rev-parse', 'HEAD']),
    );
    workingDirectory = Directory('${worktree.path}/packages/source/probe');
    expect(
      await File('${workingDirectory.path}/terminal-process').exists(),
      isTrue,
    );

    owner = runtime.terminals.create(
      created.environment.id,
      request: EnvironmentTerminalRequest(
        program: './terminal-process',
        arguments: const [],
        relativeWorkingDirectory: 'probe',
        dimensions: EnvironmentTerminalDimensions(columns: 97, rows: 31),
      ),
    );
    expect(owner.state, EnvironmentTerminalState.idle);
    expect(
      await File('${workingDirectory.path}/launch-count').exists(),
      isFalse,
    );
    frontend = await PreparedFrontend.load(frontendArtifact);
    addTearDown(frontend.invalidate);
    expect(frontend.failure, isNull);
  });

  Widget presentation() => MaterialApp(
    home: Scaffold(
      body: frontend.createPresentation(
        library: _library,
        entrypoint: 'buildView',
        createBridge: () =>
            TerminalSurfaceBridge(surface: owner.surface, isActive: () => true),
      ),
    ),
  );

  Future<({Terminal engine, int pid, int helperPid, String nonce})> open(
    WidgetTester tester,
  ) async {
    await owner.open().timeout(_deadline);
    expect(owner.error, isNull);
    expect(owner.state, EnvironmentTerminalState.running);
    final materialization = runtime.lifecycle.environmentRuntime
        .currentMaterialization(created.environment.id)!;
    expect(materialization.provider, isA<GeneratedEnvironmentProvider>());
    expect(materialization.validateBinding, returnsNormally);
    // The child samples initial PTY dimensions before writing this barrier.
    // All terminal observations below come from the real emulator, not this file.
    await _until(tester, () async {
      final count = File('${workingDirectory.path}/launch-count');
      return await count.exists() && await count.readAsString() == '1\n';
    }, 'child startup barrier');
    await tester.pumpWidget(presentation());
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    final engine = view.terminal.buffer.terminal as Terminal;
    await _text(tester, engine, 'READY');
    final text = _bufferText(engine);
    expect(text, contains('TTY=1,1,1\nCTTY=1'));
    expect(text, contains('INITIAL=97,31'));
    expect(
      text,
      contains('CWD=${await workingDirectory.resolveSymbolicLinks()}'),
    );
    expect(text, contains('STDERR-MERGED'));
    expect(text, contains('SPAWNS=1'));
    final pid = int.parse(RegExp(r'PID=(\d+)').firstMatch(text)![1]!);
    final nonce = RegExp(r'BOOT=([0-9a-f]{16})').firstMatch(text)![1]!;
    final helperPid = await _parentPid(pid);
    expect(pid, isNot(runtime.plugins.host!.processId));
    expect(helperPid, isNot(runtime.plugins.host!.processId));
    expect(await _parentPid(helperPid), runtime.plugins.host!.processId);
    // This is native layout -> owner -> generated resize -> actual TIOCSWINSZ.
    await _text(
      tester,
      engine,
      'SIZE=${engine.viewWidth},${engine.viewHeight}',
    );
    return (engine: engine, pid: pid, helperPid: helperPid, nonce: nonce);
  }

  Future<void> expectNoRespawn() async {
    expect(
      await File('${workingDirectory.path}/launch-count').readAsString(),
      '1\n',
    );
    expect(await File('${source.path}/probe/launch-count').exists(), isFalse);
    expect(runtime.store.sessionsForTask(created.task.id), isEmpty);
    expect(runtime.terminals.forEnvironment(created.environment.id), [
      same(owner),
    ]);
  }

  testWidgets(
    'EVC native input, resize, hidden query and remount keep one real PTY',
    (tester) => tester.runAsync(() async {
      try {
        final process = await open(tester);
        final engine = process.engine;
        final oldElement = tester.element(find.byType(TerminalView));
        var clipboard = 'paste-one\n';
        var clipboardReads = 0;
        _mockClipboard(tester, () {
          clipboardReads++;
          return clipboard;
        });
        await _focus(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK, character: 'k');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _text(tester, engine, 'ACK=1:${process.nonce}:k');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        try {
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        } finally {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        }
        await _text(tester, engine, 'CONTROL=03');
        _paste(tester);
        await _text(tester, engine, 'ACK=2:${process.nonce}:paste-one');
        expect(clipboardReads, 1);

        final initialColumns = engine.viewWidth;
        await tester.tap(find.text('Resize'));
        await tester.pump(_gestureFrame);
        expect(engine.viewWidth, greaterThan(initialColumns));
        expect(tester.getSize(find.byType(TerminalView)).width, 560);
        await _text(
          tester,
          engine,
          'SIZE=${engine.viewWidth},${engine.viewHeight}',
        );

        // Remove the entire interpreted presentation, not Offstage/Visibility.
        await tester.pumpWidget(const SizedBox.shrink());
        expect(find.byType(TerminalView), findsNothing);
        expect(oldElement.mounted, isFalse);
        expect(engine.listeners, isEmpty);
        expect(owner.surface.isDisposed, isFalse);
        expect(owner.state, EnvironmentTerminalState.running);
        expect(await Directory('/proc/${process.pid}').exists(), isTrue);
        // Only trigger output out of band. The reply itself must traverse the
        // hidden emulator -> owner -> generated transport -> real PTY input.
        expect(Process.killPid(process.pid, ProcessSignal.sigusr1), isTrue);
        await _text(tester, engine, 'HIDDEN=${process.nonce}');
        await _text(tester, engine, 'REPLY=3,7:${process.nonce}');
        expect(find.byType(TerminalView), findsNothing);
        expect(engine.listeners, isEmpty);
        expect(owner.state, EnvironmentTerminalState.running);
        await expectNoRespawn();

        await tester.pumpWidget(presentation());
        expect(
          tester.element(find.byType(TerminalView)),
          isNot(same(oldElement)),
        );
        expect(
          tester
              .widget<TerminalView>(find.byType(TerminalView))
              .terminal
              .buffer
              .terminal,
          same(engine),
        );
        expect(engine.listeners, hasLength(1));
        expect(_bufferText(engine), contains('HIDDEN=${process.nonce}'));
        expect(_bufferText(engine), contains('REPLY=3,7:${process.nonce}'));
        await owner.open().timeout(_deadline);
        clipboard = 'ping\n';
        await _focus(tester);
        _paste(tester);
        await _text(tester, engine, 'ACK=3:${process.nonce}:ping');
        expect(clipboardReads, 2);
        await expectNoRespawn();

        await owner.close().timeout(_deadline);
        expect(owner.state, EnvironmentTerminalState.closed);
        expect(owner.error, isNull);
        expect(owner.cleanupError, isNull);
        expect(owner.surface.readOnly, isTrue);
        await _reaped(tester, [process.pid, process.helperPid]);
        await owner.open().timeout(_deadline);
        expect(owner.state, EnvironmentTerminalState.closed);
        expect(_bufferText(engine), contains('ACK=3:${process.nonce}:ping'));
        await expectNoRespawn();
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime.close().timeout(_deadline);
      }
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'normal PTY exit retains a completed read-only screen',
    (tester) => tester.runAsync(() async {
      try {
        final process = await open(tester);
        var reads = 0;
        _mockClipboard(tester, () {
          reads++;
          return 'exit\n';
        });
        await _focus(tester);
        _paste(tester);
        await _text(tester, process.engine, 'FINAL=${process.nonce}');
        await _until(
          tester,
          () => owner.state == EnvironmentTerminalState.completed,
          'normal terminal completion',
        );
        expect(
          owner.completion!.termination,
          EnvironmentTerminalTermination.exited,
        );
        expect(owner.completion!.exitCode, 37);
        expect(owner.error, isNull);
        await owner.close().timeout(_deadline);
        expect(owner.cleanupError, isNull);
        await _reaped(tester, [process.pid, process.helperPid]);
        expect(owner.surface.readOnly, isTrue);
        expect(owner.surface.isDisposed, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(presentation());
        final view = tester.widget<TerminalView>(find.byType(TerminalView));
        expect(view.terminal.buffer.terminal, same(process.engine));
        expect(view.readOnly, isTrue);
        await _focus(tester);
        final screen = _bufferText(process.engine);
        expect(screen, contains('FINAL=${process.nonce}'));
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK, character: 'k');
        _paste(tester);
        await tester.pump();
        expect(reads, 2);
        await owner.open().timeout(_deadline);
        expect(owner.state, EnvironmentTerminalState.completed);
        expect(_bufferText(process.engine), screen);
        await expectNoRespawn();
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime.close().timeout(_deadline);
      }
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'shared host loss disconnects without replacing the terminal',
    (tester) => tester.runAsync(() async {
      try {
        final process = await open(tester);
        final failed = runtime.plugins.changes
            .firstWhere((state) => state == ApplicationPluginState.failed)
            .timeout(_deadline);
        expect(
          Process.killPid(
            runtime.plugins.host!.processId,
            ProcessSignal.sigkill,
          ),
          isTrue,
        );
        await failed;
        await _until(
          tester,
          () => owner.state == EnvironmentTerminalState.disconnected,
          'exact provider retirement',
        );
        expect(owner.error, isNotNull);
        expect(owner.completion, isNull);
        expect(owner.surface.readOnly, isTrue);
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );
        await _reaped(tester, [process.pid, process.helperPid]);
        await owner.close().timeout(_deadline);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(presentation());
        final view = tester.widget<TerminalView>(find.byType(TerminalView));
        expect(view.terminal.buffer.terminal, same(process.engine));
        expect(view.readOnly, isTrue);
        expect(_bufferText(process.engine), contains('BOOT=${process.nonce}'));
        await owner.open().timeout(_deadline);
        expect(owner.state, EnvironmentTerminalState.disconnected);
        await expectNoRespawn();
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime.close().timeout(_deadline);
      }
      expect(tester.takeException(), isNull);
    }),
  );
}

final class _NoRuns implements RunIdSource {
  @override
  RunId nextRunId() =>
      throw StateError('An Environment terminal is not a Run.');
}

Future<void> _until(
  WidgetTester tester,
  FutureOr<bool> Function() ready,
  String description,
) async {
  final clock = Stopwatch()..start();
  while (!await ready()) {
    if (clock.elapsed >= _deadline) fail('Timed out: $description');
    // Yield real I/O inside runAsync; no sleep guesses or pumpAndSettle.
    await Future<void>.delayed(Duration.zero);
    await tester.pump();
  }
  await tester.pump();
}

Future<void> _text(WidgetTester tester, Terminal engine, String marker) async {
  try {
    await _until(
      tester,
      () => _bufferText(engine).contains('$marker\n'),
      'emulator marker $marker',
    );
  } on TestFailure {
    fail('Missing $marker in emulator screen:\n${_bufferText(engine)}');
  }
}

String _bufferText(Terminal engine) {
  final text = StringBuffer();
  final buffer = engine.buffer;
  for (var i = 0; i < buffer.height; i++) {
    final line = buffer.lines[i];
    if (i > 0 && !line.isWrapped) text.writeln();
    text.write(line.getText().trimRight());
  }
  return text.toString();
}

BuildContext _terminalContext(WidgetTester tester) => tester.element(
  find
      .descendant(
        of: find.byType(TerminalView),
        matching: find.byType(Scrollable),
      )
      .last,
);

Future<void> _focus(WidgetTester tester) async {
  await tester.tap(find.byType(TerminalView));
  await tester.pump(_gestureFrame);
  expect(Focus.of(_terminalContext(tester)).hasFocus, isTrue);
}

void _paste(WidgetTester tester) => Actions.invoke(
  _terminalContext(tester),
  const PasteTextIntent(SelectionChangedCause.keyboard),
);

void _mockClipboard(WidgetTester tester, String Function() read) {
  final messenger = tester.binding.defaultBinaryMessenger;
  final previous = messenger.allMessagesHandler;
  final channel = SystemChannels.platform;
  messenger.allMessagesHandler = (name, handler, message) {
    if (name == channel.name && message != null) {
      final call = channel.codec.decodeMethodCall(message);
      if (call.method == 'Clipboard.getData') {
        expect(call.arguments, Clipboard.kTextPlain);
        return Future.value(
          channel.codec.encodeSuccessEnvelope({'text': read()}),
        );
      }
    }
    if (previous != null) return previous(name, handler, message);
    return handler != null
        ? handler(message)
        : messenger.delegate.send(name, message);
  };
  addTearDown(() => messenger.allMessagesHandler = previous);
}

Future<int> _parentPid(int pid) async {
  final stat = await File('/proc/$pid/stat').readAsString();
  return int.parse(stat.substring(stat.lastIndexOf(')') + 2).split(' ')[1]);
}

Future<void> _reaped(WidgetTester tester, List<int> pids) =>
    _until(tester, () async {
      for (final pid in pids) {
        if (await Directory('/proc/$pid').exists()) return false;
      }
      return true;
    }, 'PTY child/helper reaped: $pids');

Future<String> _run(
  String program,
  List<String> arguments, {
  Directory? directory,
}) async {
  final process = await Process.start(
    program,
    arguments,
    workingDirectory: directory?.path,
  );
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  try {
    final code = await process.exitCode.timeout(const Duration(seconds: 30));
    final stdout = await output;
    final stderr = await errors;
    if (code != 0) {
      throw StateError('$program $arguments: $code\n$stdout\n$stderr');
    }
    return stdout;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await Future.wait([output, errors]);
    rethrow;
  }
}

Future<String> _git(Directory directory, List<String> arguments) =>
    _run('git', [
      '-c',
      'user.name=ADELE Test',
      '-c',
      'user.email=adele-test@example.invalid',
      '-c',
      'commit.gpgsign=false',
      ...arguments,
    ], directory: directory);

String _dartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final executable = File('$flutterRoot/bin/cache/dart-sdk/bin/dart');
    if (executable.existsSync()) return executable.path;
  }
  final executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith('/dart-sdk/bin')) return executable.path;
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}
