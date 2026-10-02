import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:adele_desktop/editor/native_code_editor.dart';
import 'package:adele_desktop/frontend/code_editor_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../../tools/code_editor_probe/smoke_settlement.dart';

const _library = 'package:code_editor_probe/main.dart';
const _initial = 'void main() {\n  print("ADELE");\n}\n';
const _reference =
    '// Read-only, independent native buffer.\nfinal answer = 42;\n';
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
  final editable = NativeCodeBuffer(text: _initial);
  final reference = NativeCodeBuffer(text: _reference);
  try {
    _require(
      !Platform.environment.containsKey(
        'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR',
      ),
      'The packaged editor must not use an FRB loader override.',
    );
  } catch (error, stack) {
    settlement.recordFailure('CODEFORGE_BUNDLE_FAILED', error, stack);
    await settlement.settle();
    return;
  }
  try {
    await editable.initialize();
  } catch (error, stack) {
    settlement.recordFailure('CODEFORGE_INIT_FAILED', error, stack);
    await settlement.settle();
    return;
  }
  stdout.writeln('CODEFORGE_FRB_INIT_RETURNED');
  try {
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
  } catch (error, stack) {
    settlement.recordFailure('CODEFORGE_BUNDLE_FAILED', error, stack);
    await settlement.settle();
    return;
  }

  NativeCodeView? editableView;
  NativeCodeView? referenceView;
  try {
    await reference.initialize();
    editableView = NativeCodeView(buffer: editable);
    referenceView = NativeCodeView(buffer: reference, readOnly: true);
    final artifact = File(
      '${File(Platform.resolvedExecutable).parent.path}/data/editor_frontend.evc',
    );
    final editableFrontend = await _load(artifact);
    final referenceFrontend = await _load(artifact);
    final hostKey = GlobalKey<_SmokeHostState>();
    runApp(
      _SmokeHost(
        key: hostKey,
        artifact: artifact,
        editable: editableView,
        reference: referenceView,
        editableFrontend: editableFrontend,
        referenceFrontend: referenceFrontend,
        disposeBuffers: () {
          editable.dispose();
          reference.dispose();
        },
      ),
    );
    await _frames();
    if (arguments.contains('--interactive')) {
      // Owners outlive the fixture. Manual close has an explicit teardown path.
      stdout.writeln('ADELE_EDITOR_INTERACTIVE_READY');
      return;
    }
    try {
      await _exercise(hostKey.currentState!, binding, editable, reference);
    } finally {
      runApp(const SizedBox.shrink());
      await _frames();
      editableFrontend.invalidate();
      referenceFrontend.invalidate();
    }
  } catch (error, stack) {
    settlement.recordFailure('CODEFORGE_SMOKE_FAILED', error, stack);
  }
  editableView?.dispose();
  referenceView?.dispose();
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
    required this.disposeBuffers,
  });

  final File artifact;
  final NativeCodeView editable;
  final NativeCodeView reference;
  final PreparedFrontend editableFrontend;
  final PreparedFrontend referenceFrontend;
  final VoidCallback disposeBuffers;

  @override
  State<_SmokeHost> createState() => _SmokeHostState();
}

class _SmokeHostState extends State<_SmokeHost> {
  final editableKey = GlobalKey();
  final referenceKey = GlobalKey();
  PreparedFrontend? _editableFrontend;
  Widget? _editableBody;
  late Widget _referenceBody;
  bool _changing = false;

  @override
  void initState() {
    super.initState();
    _editableFrontend = widget.editableFrontend;
    _editableBody = _presentation(_editableFrontend!, widget.editable);
    _referenceBody = _presentation(widget.referenceFrontend, widget.reference);
  }

  Widget _presentation(PreparedFrontend frontend, NativeCodeView view) =>
      frontend.createPresentation(
        library: _library,
        entrypoint: 'buildView',
        createBridge: () =>
            CodeEditorBridge(view: view, isActive: () => mounted),
      );

  Future<void> unmountEditable() async {
    final frontend = _editableFrontend;
    _require(frontend != null, 'Editable presentation is already unmounted.');
    setState(() {
      _editableBody = null;
      _editableFrontend = null;
    });
    await _frames();
    frontend!.invalidate();
  }

  Future<void> remountEditable() async {
    _require(_editableFrontend == null, 'Unmount before loading a fresh EVC.');
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

  Future<void> _toggleEditable() async {
    setState(() => _changing = true);
    try {
      if (_editableFrontend == null) {
        await remountEditable();
      } else {
        await unmountEditable();
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
    widget.disposeBuffers();
    exit(0);
  }

  @override
  void dispose() {
    _editableFrontend?.invalidate();
    widget.referenceFrontend.invalidate();
    super.dispose();
  }

  Widget _pane(String label, GlobalKey key, Widget? body) => SizedBox(
    height: 540,
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
                child: RepaintBoundary(
                  key: key,
                  child: SingleChildScrollView(child: body),
                ),
              )
            else
              const Text('Fully unmounted. Buffer and undo are retained.'),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(title: const Text('ADELE / Prepared Native Editor')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(_identity),
          const SizedBox(height: 8),
          const Text(
            'Synthetic text only. No files, save, LSP, or network. '
            'Both panes are independent prepared EVC presentations.',
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
                onPressed: _changing ? null : _toggleEditable,
                child: Text(
                  _editableFrontend == null
                      ? 'Remount editable'
                      : 'Unmount editable',
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
              final editable = _pane('Editable', editableKey, _editableBody);
              final reference = _pane(
                'Read-only',
                referenceKey,
                _referenceBody,
              );
              return constraints.maxWidth >= 1000
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: editable),
                        Expanded(child: reference),
                      ],
                    )
                  : Column(children: [editable, reference]);
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> _exercise(
  _SmokeHostState host,
  _SmokeBinding binding,
  NativeCodeBuffer editable,
  NativeCodeBuffer reference,
) async {
  final notices = await rootBundle.loadString(
    'packages/code_forge/assets/adele/NOTICES.txt',
  );
  final inventory = jsonDecode(
    await rootBundle.loadString(
      'packages/code_forge/assets/adele/inventory.json',
    ),
  );
  final fonts = await rootBundle.loadString('FontManifest.json');
  _require(
    notices.contains('Athul') &&
        notices.contains('Zed') &&
        inventory is Map &&
        sha256.convert(utf8.encode(notices)).toString() ==
            inventory['noticesFile']['sha256'] &&
        !fonts.contains('packages/code_forge/assets/icons/'),
    'Packaged editor notices or excluded optional fonts are incorrect.',
  );
  stdout.writeln('CODEFORGE_NOTICES_BUNDLED');
  await _until(
    () => _texts(
      host.editableKey,
    ).any((text) => text.contains('ready=true readOnly=false')),
    'Editable EVC readiness',
  );
  await _until(
    () => _texts(
      host.referenceKey,
    ).any((text) => text.contains('ready=true readOnly=true')),
    'Read-only EVC readiness',
  );
  _require(
    _texts(host.editableKey).contains('Snapshot text: (not requested)'),
    'Snapshot must be explicit, not part of the version observer.',
  );
  _require(
    host.widget.editable.requestFocus(),
    'Editable focus request refused.',
  );
  await _frames();
  await _key(LogicalKeyboardKey.home, PhysicalKeyboardKey.home, control: true);
  _require(
    host.widget.editable.readState()['focused'] == true &&
        host.widget.reference.readState()['focused'] == false,
    'Native focus is not isolated to the editable view.',
  );
  final version = editable.version;
  final notifications = _notifications(host.editableKey);
  const insertion = '// \u{1f600} prepared\n';
  await _Input.capture(binding.messenger).insert(binding, insertion);
  await _until(() => editable.version > version, 'Native input version');
  await _until(
    () => _notifications(host.editableKey) > notifications,
    'Interpreted change observer',
  );
  await _snapshot(host.editableKey, '$insertion$_initial', editable.version);
  _require(
    reference.snapshot()['text'] == _reference,
    'Reference buffer changed.',
  );
  stdout.writeln('CODEFORGE_PLATFORM_INPUT_OK');

  await _key(LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ, control: true);
  await _snapshot(host.editableKey, _initial, editable.version);
  await _key(LogicalKeyboardKey.keyY, PhysicalKeyboardKey.keyY, control: true);
  await _snapshot(host.editableKey, '$insertion$_initial', editable.version);

  final departedEditableClient = _Input.capture(binding.messenger);
  _require(host.widget.reference.requestFocus(), 'Read-only focus refused.');
  await _frames();
  _require(
    host.widget.reference.readState()['focused'] == true &&
        host.widget.editable.readState()['focused'] == false,
    'Native focus is not isolated to the read-only view.',
  );
  await _key(LogicalKeyboardKey.keyA, PhysicalKeyboardKey.keyA, control: true);
  await _key(LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC, control: true);
  await _until(() => binding.messenger.copied == _reference, 'Read-only copy');
  final copied = await Clipboard.getData(Clipboard.kTextPlain);
  _require(
    copied?.text == _reference,
    'Native clipboard did not receive copy.',
  );
  final readVersion = reference.version;
  _require(
    binding.messenger.client == null,
    'Read-only view attached an editable input client.',
  );
  await departedEditableClient.insert(binding, 'blocked');
  await _key(LogicalKeyboardKey.backspace, PhysicalKeyboardKey.backspace);
  await _key(LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV, control: true);
  await _key(LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ, control: true);
  await _frames();
  await _snapshot(host.referenceKey, _reference, readVersion);
  _require(
    reference.version == readVersion,
    'Read-only input mutated version.',
  );

  _require(host.widget.editable.requestFocus(), 'Editable refocus refused.');
  await _frames();
  await _key(LogicalKeyboardKey.end, PhysicalKeyboardKey.end, control: true);
  await Clipboard.setData(const ClipboardData(text: '// pasted\n'));
  final beforePaste = editable.version;
  await _key(LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV, control: true);
  final edited = '$insertion$_initial// pasted\n';
  await _until(() => editable.version > beforePaste, 'Native paste');
  await _snapshot(host.editableKey, edited, editable.version);
  stdout.writeln('CODEFORGE_CLIPBOARD_READONLY_OK');

  await _frames();
  for (final key in [host.editableKey, host.referenceKey]) {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    _require(
      boundary.hasSize && !boundary.size.isEmpty,
      'Empty editor layout.',
    );
    final image = await boundary.toImage();
    _require(
      image.width > 0 && image.height > 0,
      'Empty rendered editor image.',
    );
    stdout.writeln('CODEFORGE_FRAME=${image.width}x${image.height}');
    image.dispose();
  }
  stdout.writeln('CODEFORGE_RENDERED');

  await _key(LogicalKeyboardKey.home, PhysicalKeyboardKey.home, control: true);
  for (var i = 0; i < 4; i++) {
    await _key(LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
  }
  await _key(
    LogicalKeyboardKey.arrowRight,
    PhysicalKeyboardKey.arrowRight,
    shift: true,
  );
  await _snapshot(
    host.editableKey,
    edited,
    editable.version,
    selection: (5, 6),
  );
  final oldElement = host.editableKey.currentContext! as Element;
  final oldClient = _Input.capture(binding.messenger);
  final retainedVersion = editable.version;
  await host.unmountEditable();
  _require(
    !oldElement.mounted && host.editableKey.currentContext == null,
    'Editable presentation was not completely unmounted.',
  );
  _require(
    !editable.isDisposed && editable.snapshot()['text'] == edited,
    'Full unmount discarded buffer ownership.',
  );
  await oldClient.insert(binding, 'stale');
  _require(
    editable.version == retainedVersion,
    'Old input access remained active.',
  );
  stdout.writeln('CODEFORGE_UNMOUNTED_OWNER_RETAINED');
  await host.remountEditable();
  await _until(
    () => _texts(
      host.editableKey,
    ).any((text) => text.contains('ready=true readOnly=false')),
    'Remounted EVC readiness',
  );
  await _snapshot(host.editableKey, edited, retainedVersion, selection: (5, 6));
  _require(
    !identical(host.editableKey.currentContext, oldElement),
    'Remount retained the old presentation element.',
  );
  _require(host.widget.editable.requestFocus(), 'Remounted focus refused.');
  await _frames();
  await oldClient.insert(binding, 'stale after replacement');
  _require(
    editable.version == retainedVersion,
    'Old access migrated to fresh EVC.',
  );
  await _key(LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ, control: true);
  await _snapshot(host.editableKey, '$insertion$_initial', editable.version);
  await _key(LogicalKeyboardKey.keyY, PhysicalKeyboardKey.keyY, control: true);
  await _snapshot(host.editableKey, edited, editable.version);
  stdout.writeln('CODEFORGE_PREPARED_REMOUNT_OK');
}

Iterable<Element> _elements(GlobalKey key) sync* {
  final root = key.currentContext;
  if (root == null) return;
  final elements = <Element>[];
  void visit(Element element) {
    elements.add(element);
    element.visitChildren(visit);
  }

  visit(root as Element);
  yield* elements;
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
  String expected,
  int version, {
  (int, int)? selection,
}) async {
  final button = _elements(key)
      .map((element) => element.widget)
      .whereType<TextButton>()
      .singleWhere(
        (button) =>
            button.child is Text && (button.child! as Text).data == 'Snapshot',
      );
  // Invokes the real native callback installed by the interpreted fixture.
  // No native snapshot is substituted for this prepared-EVC round trip.
  button.onPressed!();
  await _until(
    () =>
        _texts(key).contains('Snapshot text: $expected') &&
        _texts(key).contains('Snapshot version: $version') &&
        (selection == null ||
            _texts(
              key,
            ).contains('Snapshot selection: ${selection.$1}:${selection.$2}')),
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
  bool shift = false,
}) async {
  void send(
    LogicalKeyboardKey key,
    PhysicalKeyboardKey scan,
    ui.KeyEventType type,
  ) {
    // This fixture injects engine key records, not a real OS keyboard event.
    // Synthesized records dispatch immediately without a duplicate legacy event.
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

  if (control) {
    send(
      LogicalKeyboardKey.controlLeft,
      PhysicalKeyboardKey.controlLeft,
      ui.KeyEventType.down,
    );
  }
  if (shift) {
    send(
      LogicalKeyboardKey.shiftLeft,
      PhysicalKeyboardKey.shiftLeft,
      ui.KeyEventType.down,
    );
  }
  try {
    send(logical, physical, ui.KeyEventType.down);
    send(logical, physical, ui.KeyEventType.up);
  } finally {
    if (shift) {
      send(
        LogicalKeyboardKey.shiftLeft,
        PhysicalKeyboardKey.shiftLeft,
        ui.KeyEventType.up,
      );
    }
    if (control) {
      send(
        LogicalKeyboardKey.controlLeft,
        PhysicalKeyboardKey.controlLeft,
        ui.KeyEventType.up,
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

/// Passive observer: every message still goes to the real desktop embedder.
class _ObservedMessenger implements BinaryMessenger {
  _ObservedMessenger(this.delegate);
  final BinaryMessenger delegate;
  int? client;
  bool deltaModel = false;
  TextEditingValue? editingValue;
  String? copied;

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
    } else if (channel == SystemChannels.platform.name && message != null) {
      final call = SystemChannels.platform.codec.decodeMethodCall(message);
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
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

class _Input {
  _Input(this.client, this.value);

  factory _Input.capture(_ObservedMessenger messenger) {
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
    return _Input(messenger.client!, value);
  }

  final int client;
  final TextEditingValue value;

  Future<void> insert(_SmokeBinding binding, String text) async {
    final reply = Completer<ByteData?>();
    final start = value.selection.start;
    binding.channelBuffers.push(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInputClient.updateEditingStateWithDeltas', [
          client,
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
}
