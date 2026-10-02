import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:adele_desktop/editor/native_code_editor.dart';
import 'package:adele_desktop/frontend/code_editor_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../tools/code_editor_probe/smoke_settlement.dart';

const _library = 'package:code_editor_probe/main.dart';
const _initial = 'void main() {\n  print("ADELE");\n}\n';
const _reference = '// Independent read-only editor.\nfinal answer = 42;\n';
const _identity = String.fromEnvironment('ADELE_CODE_EDITOR_IDENTITY');

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

Future<void> _until(bool Function() predicate, String label) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    _require(watch.elapsed < const Duration(seconds: 10), '$label timed out.');
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
