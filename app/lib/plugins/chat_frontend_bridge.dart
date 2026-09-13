import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';

final class ChatPresentationEntry {
  const ChatPresentationEntry({required this.role, required this.content});

  final String role;
  final String content;
}

final class ChatPresentationSnapshot {
  ChatPresentationSnapshot({
    required List<ChatPresentationEntry> entries,
    required this.canSubmit,
  }) : entries = List<ChatPresentationEntry>.unmodifiable(entries);

  final List<ChatPresentationEntry> entries;
  final bool canSubmit;
}

abstract interface class ChatFrontendSource implements Listenable {
  ChatPresentationSnapshot get snapshot;
  bool submit(String prompt);
}

extension ChatFrontendPresentation on PreparedFrontend {
  Widget createChatPresentation({
    required ChatFrontendSource source,
    required bool Function() isActive,
    Key? key,
  }) => KeyedSubtree(
    key: key,
    child: createPresentation(
      key: ValueKey((this, source)),
      library: chatFrontendLibrary,
      entrypoint: 'buildChat',
      createBridge: () =>
          ChatFrontendBridge(source: source, isActive: isActive),
    ),
  );
}

const String chatFrontendLibrary =
    'package:chat_strategy_frontend/chat_strategy_frontend.dart';
const String _bridgeLibrary =
    'package:chat_strategy_frontend/src/chat_frontend_bridge.dart';

/// Build-time declarations require neither a presentation source nor a runtime.
class ChatFrontendDeclarations implements EvalPlugin {
  const ChatFrontendDeclarations();

  @override
  String get identifier => 'package:chat_strategy_frontend';

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry
      ..defineBridgeClass(_ChatEntry.$declaration)
      ..defineBridgeClass(_ChatSnapshot.$declaration)
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          _bridgeLibrary,
          'readChatSnapshot',
          BridgeFunctionDef(returns: BridgeTypeAnnotation(_ChatSnapshot.$type)),
        ),
      )
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          _bridgeLibrary,
          'submitChatPrompt',
          BridgeFunctionDef(
            returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
            params: [
              BridgeParameter(
                'prompt',
                BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
                false,
              ),
            ],
          ),
        ),
      )
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          _bridgeLibrary,
          'subscribeChatChanges',
          BridgeFunctionDef(
            returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType)),
            params: [
              BridgeParameter(
                'callback',
                BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.function)),
                false,
              ),
            ],
          ),
        ),
      )
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          _bridgeLibrary,
          'unsubscribeChatChanges',
          BridgeFunctionDef(
            returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType)),
          ),
        ),
      );
  }

  @override
  void configureForRuntime(Runtime runtime) {
    throw UnsupportedError('Use a per-presentation ChatFrontendBridge.');
  }
}

final class ChatFrontendBridge extends ChatFrontendDeclarations
    implements PreparedFrontendBridge {
  ChatFrontendBridge({
    required ChatFrontendSource source,
    required bool Function() isActive,
  }) : _source = source,
       _isActive = isActive;

  final ChatFrontendSource _source;
  final bool Function() _isActive;
  bool _active = true;
  bool _scheduled = false;
  VoidCallback? _callback;

  bool get _available => _active && _isActive();

  @override
  void configureForRuntime(Runtime runtime) {
    runtime
      ..registerBridgeFunc(_bridgeLibrary, 'readChatSnapshot', (_, _, _) {
        return _ChatSnapshot(
          _available
              ? _source.snapshot
              : ChatPresentationSnapshot(entries: const [], canSubmit: false),
        );
      })
      ..registerBridgeFunc(_bridgeLibrary, 'submitChatPrompt', (_, _, args) {
        final String prompt = args.single!.$value as String;
        return $bool(
          _available &&
              prompt.trim().isNotEmpty &&
              _source.snapshot.canSubmit &&
              _source.submit(prompt),
        );
      })
      ..registerBridgeFunc(_bridgeLibrary, 'subscribeChatChanges', (
        _,
        _,
        args,
      ) {
        _unsubscribe();
        if (!_available) return null;
        final EvalCallable callback = args.single! as EvalCallable;
        _callback = () => callback.call(runtime, null, const []);
        _source.addListener(_changed);
        return null;
      })
      ..registerBridgeFunc(_bridgeLibrary, 'unsubscribeChatChanges', (_, _, _) {
        _unsubscribe();
        return null;
      });
  }

  void _changed() {
    if (!_active || _callback == null || _scheduled) return;
    _scheduled = true;
    // Never enter eval again during a synchronous submit or a host build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_available) _callback?.call();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _unsubscribe() {
    if (_callback == null) return;
    _source.removeListener(_changed);
    _callback = null;
  }

  @override
  void invalidate() {
    if (!_active) return;
    _active = false;
    _unsubscribe();
  }
}

final class _ChatEntry implements $Instance {
  const _ChatEntry(this.data);

  static const BridgeTypeRef $type = BridgeTypeRef(
    BridgeTypeSpec(_bridgeLibrary, 'ChatPresentationEntry'),
  );
  static const BridgeClassDef $declaration = BridgeClassDef(
    BridgeClassType($type),
    constructors: {},
    getters: {
      'role': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
        ),
      ),
      'content': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
        ),
      ),
    },
    wrap: true,
  );

  final ChatPresentationEntry data;

  @override
  Object get $value => data;
  @override
  Object get $reified => data;
  @override
  int $getRuntimeType(Runtime runtime) => runtime.lookupType($type.spec!);
  @override
  $Value? $getProperty(Runtime runtime, String identifier) =>
      switch (identifier) {
        'role' => $String(data.role),
        'content' => $String(data.content),
        _ => throw UnsupportedError(identifier),
      };
  @override
  void $setProperty(Runtime runtime, String identifier, $Value value) {
    throw UnsupportedError('Chat presentation entries are immutable.');
  }
}

final class _ChatSnapshot implements $Instance {
  const _ChatSnapshot(this.data);

  static const BridgeTypeRef $type = BridgeTypeRef(
    BridgeTypeSpec(_bridgeLibrary, 'ChatPresentationSnapshot'),
  );
  static const BridgeClassDef $declaration = BridgeClassDef(
    BridgeClassType($type),
    constructors: {},
    getters: {
      'entries': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.list, [
              BridgeTypeAnnotation(_ChatEntry.$type),
            ]),
          ),
        ),
      ),
      'canSubmit': BridgeMethodDef(
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
        ),
      ),
    },
    wrap: true,
  );

  final ChatPresentationSnapshot data;

  @override
  Object get $value => data;
  @override
  Object get $reified => data;
  @override
  int $getRuntimeType(Runtime runtime) => runtime.lookupType($type.spec!);
  @override
  $Value? $getProperty(Runtime runtime, String identifier) =>
      switch (identifier) {
        'entries' => $List.wrap(
          List<$Value>.unmodifiable(data.entries.map(_ChatEntry.new)),
        ),
        'canSubmit' => $bool(data.canSubmit),
        _ => throw UnsupportedError(identifier),
      };
  @override
  void $setProperty(Runtime runtime, String identifier, $Value value) {
    throw UnsupportedError('Chat presentation snapshots are immutable.');
  }
}
