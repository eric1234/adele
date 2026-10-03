import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/editor/native_code_editor.dart';
import 'package:adele_desktop/frontend/code_editor_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_eval/widgets.dart' show $StatefulWidget$bridge;

import '../../../tools/code_editor_smoke_support.dart';
import '../main_content_fixture.dart';

const _library = 'package:code_editor_smoke/main.dart';
const _initial = 'void main() {\n  print("ADELE");\n}\n';
const _reference = '// Independent read-only editor.\nfinal answer = 42;\n';
const _identity = String.fromEnvironment('ADELE_CODE_EDITOR_IDENTITY');
const _workspaceSourcePath = 'smoke_source.dart';
const _workspaceSourceText = 'const source = "workspace";\n';

Future<void> main(List<String> arguments) async {
  final settlement = SmokeSettlement(
    writeOutput: stdout.writeln,
    writeError: stderr.writeln,
    flushOutput: stdout.flush,
    flushError: stderr.flush,
    terminate: exit,
  );
  FlutterError.onError = (details) {
    settlement.recordFailure(
      'CODEFORGE_SMOKE_FAILED',
      details.exception,
      details.stack ?? StackTrace.current,
    );
    unawaited(settlement.settle());
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    settlement.recordFailure('CODEFORGE_SMOKE_FAILED', error, stack);
    unawaited(settlement.settle());
    return true;
  };
  final binding = _SmokeBinding();
  var failureMarker = 'CODEFORGE_BUNDLE_FAILED';
  try {
    _require(
      !Platform.environment.containsKey(
        'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR',
      ),
      'The packaged editor must not use an FRB loader override.',
    );
    failureMarker = 'CODEFORGE_INIT_FAILED';
    await NativeCodeEditor.initializeLibrary();
    stdout.writeln('CODEFORGE_FRB_INIT_RETURNED');
    failureMarker = 'CODEFORGE_BUNDLE_FAILED';
    final expected = File(
      '${File(Platform.resolvedExecutable).parent.path}/lib/libcode_forge.so',
    ).resolveSymbolicLinksSync();
    final mapping = RegExp(r'^\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(.+)$');
    final paths = File('/proc/self/maps')
        .readAsLinesSync()
        .map((line) => mapping.firstMatch(line)?.group(1))
        .whereType<String>()
        .where((path) => path.contains('/libcode_forge.so'))
        .toSet();
    _require(
      paths.length == 1 && paths.single == expected,
      'Expected bundled $expected; actually mapped $paths',
    );
    stdout.writeln('CODEFORGE_NATIVE_PATH=$expected');
    stdout.writeln('CODEFORGE_NATIVE_INITIALIZED');
    stdout.writeln('Dart ${Platform.version}');
  } catch (error, stack) {
    settlement.recordFailure(failureMarker, error, stack);
    await settlement.settle();
    return;
  }

  if (arguments.contains('--workspace') ||
      arguments.contains('--workspace-smoke')) {
    await _workspace(
      settlement,
      automated: arguments.contains('--workspace-smoke'),
    );
    return;
  }

  final editable = NativeCodeEditor(text: _initial);
  final reference = NativeCodeEditor(text: _reference, readOnly: true);
  PreparedFrontend? editableFrontend;
  PreparedFrontend? referenceFrontend;
  try {
    await editable.initialize();
    await reference.initialize();
    final artifact = File(
      '${File(Platform.resolvedExecutable).parent.path}/data/editor_frontend.evc',
    );
    editableFrontend = await _load(artifact);
    referenceFrontend = await _load(artifact);
    final hostKey = GlobalKey<_SmokeHostState>();
    runApp(
      _SmokeHost(
        key: hostKey,
        artifact: artifact,
        editable: editable,
        reference: reference,
        editableFrontend: editableFrontend,
        referenceFrontend: referenceFrontend,
      ),
    );
    await _frames();
    if (arguments.contains('--interactive')) {
      stdout.writeln('ADELE_EDITOR_INTERACTIVE_READY');
      return;
    }
    await _exercise(hostKey.currentState!, binding);
  } catch (error, stack) {
    settlement.recordFailure('CODEFORGE_SMOKE_FAILED', error, stack);
  }
  runApp(const SizedBox.shrink());
  await _frames();
  editableFrontend?.invalidate();
  referenceFrontend?.invalidate();
  editable.dispose();
  reference.dispose();
  stdout.writeln('CODEFORGE_NATIVE_DISPOSED');
  await settlement.settle();
}

Future<void> _workspace(
  SmokeSettlement settlement, {
  required bool automated,
}) async {
  final runtime = NativeAdeleRuntime();
  final root = GlobalKey();
  final resources = MainContentFixtureResources(
    environmentRuntime: runtime.lifecycle.environmentRuntime,
    confirm: (request) async {
      if (automated) return false;
      final navigator = _elements(root)
          .map((element) => element.widget)
          .whereType<MaterialApp>()
          .single
          .navigatorKey!
          .currentContext;
      if (navigator == null) return false;
      return await showDialog<bool>(
            context: navigator,
            builder: (context) => AlertDialog(
              title: Text(request['title'] as String),
              content: SingleChildScrollView(
                child: Text(request['message'] as String),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(request['cancelLabel'] as String),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(request['acceptLabel'] as String),
                ),
              ],
            ),
          ) ??
          false;
    },
  );
  final previousPicker = FileSelectorPlatform.instance;
  Directory? project;
  var interactive = false;
  try {
    _require(
      const bool.fromEnvironment('ADELE_CODE_EDITOR_WORKSPACE'),
      'Prepare this bundle with editor-smoke linux --workspace first.',
    );
    if (automated) {
      project = await Directory.systemTemp.createTemp(
        'adele-editor-workspace-',
      );
      await File(
        '${project.path}/$_workspaceSourcePath',
      ).writeAsString(_workspaceSourceText);
      for (final arguments in [
        ['init', '--initial-branch=main'],
        ['add', '--', _workspaceSourcePath],
        [
          '-c',
          'user.name=ADELE Smoke',
          '-c',
          'user.email=smoke@adele.invalid',
          '-c',
          'commit.gpgsign=false',
          'commit',
          '-m',
          'Temporary smoke baseline',
        ],
      ]) {
        final result = await Process.run(
          'git',
          arguments,
          workingDirectory: project.path,
        );
        _require(result.exitCode == 0, 'Fixture Git failed: ${result.stderr}');
      }
      FileSelectorPlatform.instance = _WorkspacePicker(project.path);
    }
    runApp(
      AdeleApplication(
        key: root,
        createRuntime: () => runtime,
        mainContentHost: resources.host,
        // This development route never needs or starts paid model execution.
        readChatGptConfiguration: () => null,
      ),
    );
    await _until(
      // Frontend selectors can appear before their backing providers are ready.
      () =>
          runtime.plugins.state == ApplicationPluginState.ready &&
          _buttons(root, 'Open Local Directory...').isNotEmpty,
      'Prepared normal application startup',
      timeout: const Duration(seconds: 30),
    );
    stdout.writeln('ADELE_EDITOR_WORKSPACE_READY');
    if (!automated) {
      interactive = true;
      return;
    }
    await _press(root, 'Open Local Directory...');
    await _until(() {
      final shell = _shell(root);
      _require(
        shell.projectError == null,
        'Project opening: ${shell.projectError}',
      );
      return shell.project != null;
    }, 'Normal Project opening');
    await _press(root, 'New Task');
    await _until(() => _texts(root).contains('Task title'), 'Task form');
    final title = _elements(
      root,
    ).map((element) => element.widget).whereType<TextField>().last;
    title.controller!.text = 'Synthetic editor workspace';
    title.onChanged?.call(title.controller!.text);
    await _press(root, 'Create Task');
    await _until(() => _shell(root).task != null, 'Normal Task creation');
    await _press(root, 'New Chat Session');
    await _until(
      () =>
          resources.editors.length == 1 &&
          resources.editors.single.isInitialized &&
          _texts(root).contains('Ask ADELE...') &&
          _texts(root).contains('Synthetic pane: editor-a'),
      'Prepared Chat and initial editor A',
    );
    final host = _elements(
      root,
    ).singleWhere((element) => element.widget is MainContentHost);
    final session = (host.widget as MainContentHost).session;
    final prompt = _elements(root).singleWhere(
      (element) =>
          element.widget is Text &&
          (element.widget as Text).data == 'Ask ADELE...',
    );
    Element? contributedChat;
    prompt.visitAncestorElements((element) {
      if (element.widget is $StatefulWidget$bridge) {
        contributedChat = element;
        return false;
      }
      return !identical(element, host);
    });
    _require(
      contributedChat != null,
      'Chat is not an interpreted contributed pane.',
    );
    final chat = contributedChat! as StatefulElement;
    final chatWidget = chat.widget as $StatefulWidget$bridge;
    final chatState = chat.state;
    final chatRuntime = chatWidget.$runtime;
    Element? composerElement;
    void findComposer(Element element) {
      if (element.widget is TextField) composerElement = element;
      element.visitChildren(findComposer);
    }

    chat.visitChildren(findComposer);
    _require(composerElement != null, 'Contributed Chat has no composer.');
    final composer = composerElement!;
    final composerController = (composer.widget as TextField).controller;
    bool chatRetained() =>
        host.mounted &&
        identical((host.widget as MainContentHost).session, session) &&
        chat.mounted &&
        identical(chat.widget, chatWidget) &&
        identical(chat.state, chatState) &&
        identical(
          (chat.widget as $StatefulWidget$bridge).$runtime,
          chatRuntime,
        ) &&
        composer.mounted &&
        identical(
          (composer.widget as TextField).controller,
          composerController,
        );
    final a = resources.editor(session.id, 'editor-a')!;
    _require(
      resources.editor(session.id, 'editor-b') == null,
      'B opened early.',
    );
    await _press(root, 'Open B');
    await _until(
      () =>
          resources.editor(session.id, 'editor-b')?.isInitialized == true &&
          _texts(root).contains('Synthetic pane: editor-b'),
      'Prepared editor B',
    );
    final b = resources.editor(session.id, 'editor-b')!;
    _require(!identical(a, b), 'Editor panes share a native owner.');
    RenderBox editorBox(NativeCodeEditor editor) =>
        _elements(root)
                .singleWhere(
                  (element) => element.widget.key == ObjectKey(editor),
                )
                .findRenderObject()!
            as RenderBox;
    final hostBox = host.findRenderObject()! as RenderBox;
    for (final editor in [a, b]) {
      final size = editorBox(editor).size;
      _require(
        size.width.isFinite &&
            size.width > 0 &&
            size.height.isFinite &&
            size.height > 0 &&
            size.height <= hostBox.size.height,
        'Editor geometry is not bounded: $size.',
      );
    }
    _require(
      (editorBox(a).size.width - editorBox(b).size.width).abs() < 1,
      'Editor panes do not share equal width.',
    );
    await _press(root, 'Focus B');
    await _until(() => _editorFocused(b), 'Interpreted focus B');
    await _press(root, 'Rename B');
    await _until(() => _texts(root).contains('Renamed B'), 'Interpreted title');
    await _press(root, 'Reverse editors');
    await _until(
      () =>
          editorBox(b).localToGlobal(Offset.zero).dx <
          editorBox(a).localToGlobal(Offset.zero).dx,
      'Interpreted ordering',
    );
    _require(
      identical(resources.editor(session.id, 'editor-a'), a) &&
          identical(resources.editor(session.id, 'editor-b'), b) &&
          chatRetained() &&
          _elements(root).contains(chat),
      'Title/order/focus replaced a native owner or Chat presentation.',
    );
    await _press(root, 'Remove B');
    await _until(
      () => b.isDisposed && resources.editors.length == 1,
      'Remove B',
    );
    _require(
      !a.isDisposed && chatRetained(),
      'Removing B disturbed A or Chat.',
    );

    // Stock Source uses the canonical Session Environment, not the Project root
    // or the synthetic editors supplied by this development host.
    final authority = runtime.store.requireSessionAuthority(session.id);
    final environment = await runtime.lifecycle.environmentRuntime.materialize(
      authority.environmentId,
    );
    await _press(root, 'Open Source...');
    final input = _elements(root).singleWhere(
      (element) =>
          element.widget is TextField &&
          element.findAncestorWidgetOfExactType<Dialog>() != null,
    );
    (input.widget as TextField).onChanged!(_workspaceSourcePath);
    await _press(root, 'Open');
    await _until(
      () => _texts(root).contains('Source Document opened.'),
      'Stock Open Source action',
    );
    _elements(root)
        .map((element) => element.widget)
        .whereType<IconButton>()
        .singleWhere((button) => button.tooltip == 'Close input')
        .onPressed!();
    List<NativeCodeEditor> sourceEditors() => [
      for (final element in _elements(root))
        if (element.widget.key case ObjectKey(
          value: final NativeCodeEditor editor,
        ))
          if (!resources.editors.contains(editor)) editor,
    ];
    await _until(
      () => sourceEditors().length == 1,
      'Stock Source native editor',
    );
    final source = sourceEditors().single;
    _require(
      source.snapshot()['text'] == _workspaceSourceText && chatRetained(),
      'Opening Source replaced Chat or read the wrong file.',
    );
    final duplicate = await DisplaySourceFileResolver(
      runtime.extensions,
    ).display('./$_workspaceSourcePath');
    await _frames();
    _require(
      duplicate['ok'] == true && identical(sourceEditors().single, source),
      'Public Source display did not reuse the stock document: $duplicate',
    );
    _require(source.requestFocus(), 'Source focus refused.');
    await _frames();
    await _key(
      LogicalKeyboardKey.home,
      PhysicalKeyboardKey.home,
      control: true,
    );
    await _key(LogicalKeyboardKey.delete, PhysicalKeyboardKey.delete);
    final editedSource = _workspaceSourceText.substring(1);
    _require(
      source.snapshot()['text'] == editedSource,
      'Source native edit failed.',
    );
    environment.validateBinding();
    _require(
      (await environment.provider.readFile(
            authority.environmentId,
            _workspaceSourcePath,
          )).text ==
          _workspaceSourceText,
      'Source wrote without explicit Save.',
    );
    await _press(root, 'Save');
    await resources.host.drainOperations().timeout(const Duration(seconds: 10));
    environment.validateBinding();
    _require(
      (await environment.provider.readFile(
                authority.environmentId,
                _workspaceSourcePath,
              )).text ==
              editedSource &&
          await File('${project!.path}/$_workspaceSourcePath').readAsString() ==
              _workspaceSourceText,
      'Source Save missed its Environment or changed the Project root copy.',
    );
    final departure = _elements(root)
        .map((element) => element.widget)
        .whereType<TextButton>()
        .singleWhere(
          (button) => button.key == const ValueKey('task-breadcrumb'),
        );
    departure.onPressed!();
    await _until(
      () => resources.editors.isEmpty && a.isDisposed && !chat.mounted,
      'Session departure discards synthetic owners',
    );
    _require(
      !source.isDisposed && source.snapshot()['text'] == editedSource,
      'Task Browser departure discarded the stock Source owner.',
    );
    List<ListTile> sessionRows() => [
      for (final element in _elements(root))
        if (element.widget case final ListTile row)
          if (row.enabled &&
              row.onTap != null &&
              row.subtitle is Text &&
              ((row.subtitle! as Text).data ?? '').startsWith(
                'Session: ${session.id.value}\n',
              ))
            row,
    ];
    await _until(() => sessionRows().isNotEmpty, 'Stock Session browser row');
    sessionRows().single.onTap!();
    await _until(
      () => sourceEditors().contains(source) && source.requestFocus(),
      'Retained Source after Session reopening',
    );
    _require(
      source.snapshot()['text'] == editedSource,
      'Source text changed on remount.',
    );
    await _frames();
    await _key(
      LogicalKeyboardKey.keyZ,
      PhysicalKeyboardKey.keyZ,
      control: true,
    );
    _require(
      source.snapshot()['text'] == _workspaceSourceText,
      'Source undo history was not retained.',
    );
    await _key(
      LogicalKeyboardKey.keyY,
      PhysicalKeyboardKey.keyY,
      control: true,
    );
    _require(
      source.snapshot()['text'] == editedSource,
      'Source redo did not restore the saved text.',
    );
    await _press(root, 'Close');
    await _until(
      () => source.isDisposed,
      'Saved Source closes without discard',
    );
    _require(
      runtime.store.runsForSession(session.id).isEmpty,
      'Source roundtrip unexpectedly started a Run.',
    );
    stdout.writeln('ADELE_SOURCE_WORKSPACE_COMPLETE');
    stdout.writeln('ADELE_EDITOR_WORKSPACE_COMPLETE');
  } catch (error, stack) {
    settlement.recordFailure('CODEFORGE_SMOKE_FAILED', error, stack);
  } finally {
    if (!interactive) {
      await WidgetsBinding.instance.handleRequestAppExit();
      runApp(const SizedBox.shrink());
      await _frames();
      await runtime.close();
      resources.dispose();
      FileSelectorPlatform.instance = previousPicker;
      await project?.delete(recursive: true);
      stdout.writeln('CODEFORGE_NATIVE_DISPOSED');
      await settlement.settle();
    }
  }
}

AdeleShell _shell(GlobalKey root) => _elements(
  root,
).map((element) => element.widget).whereType<AdeleShell>().single;

List<ButtonStyleButton> _buttons(GlobalKey root, String label) => [
  for (final element in _elements(root))
    if (element.widget case final ButtonStyleButton button)
      if (button.onPressed != null &&
          button.child is Text &&
          (button.child! as Text).data == label)
        button,
];

Future<void> _press(GlobalKey root, String label) async {
  await _until(() => _buttons(root, label).isNotEmpty, 'Button $label');
  _buttons(root, label).single.onPressed!();
  await _frames();
}

bool _editorFocused(NativeCodeEditor editor) {
  var focused = false;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
    if (element.widget.key == ObjectKey(editor)) focused = true;
    return !focused;
  });
  return focused;
}

final class _WorkspacePicker extends FileSelectorPlatform {
  _WorkspacePicker(this.path);
  final String path;

  @override
  Future<String?> getDirectoryPathWithOptions(
    FileDialogOptions options,
  ) async => path;
}

Future<PreparedFrontend> _load(File artifact) async {
  final frontend = await PreparedFrontend.load(artifact);
  if (frontend.failure case final failure?) throw failure;
  return frontend;
}

class _SmokeHost extends StatefulWidget {
  const _SmokeHost({
    super.key,
    required this.artifact,
    required this.editable,
    required this.reference,
    required this.editableFrontend,
    required this.referenceFrontend,
  });
  final File artifact;
  final NativeCodeEditor editable;
  final NativeCodeEditor reference;
  final PreparedFrontend editableFrontend;
  final PreparedFrontend referenceFrontend;

  @override
  State<_SmokeHost> createState() => _SmokeHostState();
}

class _SmokeHostState extends State<_SmokeHost> {
  final editableKey = GlobalKey();
  final referenceKey = GlobalKey();
  PreparedFrontend? _editableFrontend;
  Widget? _editableBody;
  late final Widget _referenceBody;
  bool _changing = false;

  @override
  void initState() {
    super.initState();
    _editableFrontend = widget.editableFrontend;
    _editableBody = _presentation(_editableFrontend!, widget.editable);
    _referenceBody = _presentation(widget.referenceFrontend, widget.reference);
  }

  Widget _presentation(PreparedFrontend frontend, NativeCodeEditor editor) =>
      frontend.createPresentation(
        library: _library,
        entrypoint: 'buildView',
        createBridge: () =>
            CodeEditorBridge(editor: editor, isActive: () => mounted),
      );

  Future<void> toggleEditable() async {
    if (_changing) return;
    setState(() => _changing = true);
    try {
      if (_editableFrontend case final frontend?) {
        setState(() {
          _editableBody = null;
          _editableFrontend = null;
        });
        await _frames();
        frontend.invalidate();
      } else {
        final frontend = await _load(widget.artifact);
        if (!mounted) {
          frontend.invalidate();
          return;
        }
        setState(() {
          _editableFrontend = frontend;
          _editableBody = _presentation(frontend, widget.editable);
        });
        await _frames();
      }
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  Future<void> _close() async {
    runApp(const SizedBox.shrink());
    await _frames();
    widget.editable.dispose();
    widget.reference.dispose();
    exit(0);
  }

  @override
  void dispose() {
    _editableFrontend?.invalidate();
    widget.referenceFrontend.invalidate();
    super.dispose();
  }

  Widget _pane(String label, GlobalKey key, Widget? body) => SizedBox(
    height: 500,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (body != null)
              Expanded(
                child: SingleChildScrollView(key: key, child: body),
              )
            else
              const Text('Unbound. The editor still owns its text and undo.'),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(title: const Text('ADELE / $_identity')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(_identity),
          const Text(
            'Synthetic text only. No files, save, LSP, or network. Two independent prepared EVC panes.',
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () =>
                    Clipboard.setData(const ClipboardData(text: '\u{1f600}')),
                child: const Text('Copy synthetic emoji'),
              ),
              TextButton(
                onPressed: () =>
                    Clipboard.setData(const ClipboardData(text: 'a\r\nb')),
                child: const Text('Copy synthetic CRLF'),
              ),
              TextButton(
                onPressed: _editableFrontend == null
                    ? null
                    : () => widget.editable.requestFocus(),
                child: const Text('Focus editable'),
              ),
              TextButton(
                onPressed: () => widget.reference.requestFocus(),
                child: const Text('Focus read-only'),
              ),
              TextButton(
                onPressed: _changing ? null : toggleEditable,
                child: Text(
                  _editableFrontend == null
                      ? 'Rebind editable'
                      : 'Unbind editable',
                ),
              ),
              TextButton(
                onPressed: _close,
                child: const Text('Dispose and close'),
              ),
            ],
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final panes = [
                _pane('Editable', editableKey, _editableBody),
                _pane('Read-only', referenceKey, _referenceBody),
              ];
              return constraints.maxWidth >= 1000
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final pane in panes) Expanded(child: pane),
                      ],
                    )
                  : Column(children: panes);
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> _exercise(_SmokeHostState host, _SmokeBinding binding) async {
  final editable = host.widget.editable;
  final reference = host.widget.reference;
  for (final key in [host.editableKey, host.referenceKey]) {
    await _until(
      () => _texts(key).any((text) => text.contains('ready=true')),
      'Prepared EVC readiness',
    );
  }
  _require(
    _texts(host.editableKey).contains('Snapshot text: (not requested)'),
    'Snapshots must be explicit.',
  );
  _require(editable.requestFocus(), 'Editable focus request refused.');
  await _frames();
  await _key(LogicalKeyboardKey.home, PhysicalKeyboardKey.home, control: true);
  final revision = editable.readState()['revision'] as int;
  final notifications = _notifications(host.editableKey);
  const insertion = '// \u{1f600} prepared\n';
  const edited = '$insertion$_initial';
  await _insert(binding, insertion);
  await _until(
    () =>
        (editable.readState()['revision'] as int) > revision &&
        _notifications(host.editableKey) > notifications,
    'Native edit and EVC observation',
  );
  await _snapshot(host.editableKey, editable, edited);
  stdout.writeln('CODEFORGE_PLATFORM_INPUT_OK');

  _require(reference.requestFocus(), 'Read-only focus refused.');
  await _frames();
  await _key(LogicalKeyboardKey.keyA, PhysicalKeyboardKey.keyA, control: true);
  await _key(LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC, control: true);
  _require(
    (await Clipboard.getData(Clipboard.kTextPlain))?.text == _reference,
    'Native clipboard did not receive copy.',
  );
  await _key(LogicalKeyboardKey.backspace, PhysicalKeyboardKey.backspace);
  await _key(LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV, control: true);
  await _key(LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ, control: true);
  await _snapshot(host.referenceKey, reference, _reference);
  _require(editable.requestFocus(), 'Editable refocus refused.');
  await _frames();
  await _snapshot(host.editableKey, editable, edited);
  stdout.writeln('CODEFORGE_CLIPBOARD_READONLY_OK');

  final oldElement = host.editableKey.currentContext! as Element;
  await host.toggleEditable();
  _require(
    !oldElement.mounted && !editable.isDisposed,
    'Unbind must remove the view, not close its owner.',
  );
  stdout.writeln('CODEFORGE_UNMOUNTED_OWNER_RETAINED');
  await host.toggleEditable();
  await _snapshot(host.editableKey, editable, edited);
  _require(editable.requestFocus(), 'Remounted focus refused.');
  await _frames();
  await _key(LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ, control: true);
  await _snapshot(host.editableKey, editable, _initial);
  await _key(LogicalKeyboardKey.keyY, PhysicalKeyboardKey.keyY, control: true);
  await _snapshot(host.editableKey, editable, edited);
  stdout.writeln('CODEFORGE_PREPARED_REMOUNT_OK');
}

List<Element> _elements(GlobalKey key) {
  final elements = <Element>[];
  void visit(Element element) {
    elements.add(element);
    element.visitChildren(visit);
  }

  if (key.currentContext case final Element root) visit(root);
  return elements;
}

List<String> _texts(GlobalKey key) => [
  for (final element in _elements(key))
    if (element.widget case Text(data: final String data)) data,
];

int _notifications(GlobalKey key) => int.parse(
  _texts(
    key,
  ).singleWhere((text) => text.startsWith('Notifications: ')).split(': ').last,
);

Future<void> _snapshot(
  GlobalKey key,
  NativeCodeEditor editor,
  String expected,
) async {
  final button = _elements(key)
      .map((element) => element.widget)
      .whereType<TextButton>()
      .singleWhere(
        (button) =>
            button.child is Text && (button.child! as Text).data == 'Snapshot',
      );
  final revision = editor.readState()['revision'];
  // The interpreted callback performs the snapshot, not a native text read.
  button.onPressed!();
  await _until(
    () =>
        _texts(key).contains('Snapshot text: $expected') &&
        _texts(key).contains('Snapshot revision: $revision'),
    'Prepared EVC snapshot',
  );
}

Future<void> _frames() async {
  for (var i = 0; i < 2; i++) {
    WidgetsBinding.instance.ensureVisualUpdate();
    await WidgetsBinding.instance.endOfFrame;
  }
}

Future<void> _until(
  bool Function() predicate,
  String label, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    _require(watch.elapsed < timeout, '$label timed out.');
    await _frames();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _key(
  LogicalKeyboardKey logical,
  PhysicalKeyboardKey physical, {
  bool control = false,
}) async {
  final keys = [
    if (control)
      (LogicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlLeft),
    (logical, physical),
  ];
  for (final type in [ui.KeyEventType.down, ui.KeyEventType.up]) {
    for (final (key, scan)
        in type == ui.KeyEventType.down ? keys : keys.reversed) {
      // Engine key injection, not human OS keyboard/IME coverage.
      // ignore: deprecated_member_use
      ServicesBinding.instance.keyEventManager.handleKeyData(
        ui.KeyData(
          character: null,
          timeStamp: Duration(
            microseconds: DateTime.now().microsecondsSinceEpoch,
          ),
          type: type,
          physical: scan.usbHidUsage,
          logical: key.keyId,
          synthesized: true,
        ),
      );
    }
  }
  await _frames();
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class _SmokeBinding extends WidgetsFlutterBinding {
  late final _ObservedMessenger messenger;
  @override
  BinaryMessenger createBinaryMessenger() =>
      messenger = _ObservedMessenger(super.createBinaryMessenger());
}

/// Passive observer: all messages still reach the real desktop embedder.
class _ObservedMessenger implements BinaryMessenger {
  _ObservedMessenger(this.delegate);
  final BinaryMessenger delegate;
  int? client;
  bool deltaModel = false;
  TextEditingValue? editingValue;

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    if (channel == SystemChannels.textInput.name && message != null) {
      final call = SystemChannels.textInput.codec.decodeMethodCall(message);
      if (call.method == 'TextInput.setClient') {
        final args = call.arguments as List;
        client = args[0] as int;
        editingValue = null;
        deltaModel = (args[1] as Map)['enableDeltaModel'] == true;
      } else if (call.method == 'TextInput.setEditingState') {
        editingValue = TextEditingValue.fromJSON(
          Map<String, dynamic>.from(call.arguments as Map),
        );
      } else if (call.method == 'TextInput.clearClient') {
        client = null;
        editingValue = null;
      }
    }
    return delegate.send(channel, message);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      delegate.setMessageHandler(channel, handler);

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) async {
    ServicesBinding.instance.channelBuffers.push(
      channel,
      data,
      (response) => callback?.call(response),
    );
  }
}

Future<void> _insert(_SmokeBinding binding, String text) async {
  final messenger = binding.messenger;
  _require(
    messenger.client != null &&
        messenger.deltaModel &&
        messenger.editingValue != null,
    'No advertised native delta input client.',
  );
  final value = messenger.editingValue!;
  _require(
    value.selection.isValid &&
        value.selection.end <= value.text.length &&
        (!value.composing.isValid || value.composing.isCollapsed),
    'Invalid advertised selection or active composition.',
  );
  final start = value.selection.start;
  final reply = Completer<ByteData?>();
  binding.channelBuffers.push(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(
      MethodCall('TextInputClient.updateEditingStateWithDeltas', [
        messenger.client!,
        {
          'deltas': [
            {
              'oldText': value.text,
              'deltaText': text,
              'deltaStart': start,
              'deltaEnd': value.selection.end,
              'selectionBase': start + text.length,
              'selectionExtent': start + text.length,
              'selectionAffinity': 'TextAffinity.downstream',
              'selectionIsDirectional': false,
              'composingBase': -1,
              'composingExtent': -1,
            },
          ],
        },
      ]),
    ),
    reply.complete,
  );
  final response = await reply.future;
  _require(response != null, 'No native input response.');
  SystemChannels.textInput.codec.decodeEnvelope(response!);
  await _frames();
}
