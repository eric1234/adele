import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';

/// A host-issued action choice capturing both exact owner and view context.
final class ConsoleActionBinding {
  ConsoleActionBinding._(
    this._controller,
    this._owner,
    this._action,
    this._context,
  );

  final ConsoleController _controller;
  final ExtensionBinding<ConsoleContribution> _owner;
  final ConsoleCreationAction _action;
  final Object _context;

  ExtensionId get contributionId => _owner.id;
  String get id => _action.id;
  String get label => _action.label;
  bool get isActive => _controller._canInvoke(this);
  bool get isPending => _controller._creating.containsKey(this);
}

/// Native tab identity is deliberately distinct from either public access type.
final class ConsoleTab {
  ConsoleTab._(this._controller, this._owner, this._content)
    : _metadata = _content.metadata;

  final ConsoleController _controller;
  final ExtensionBinding<ConsoleContribution> _owner;
  final ConsoleContent _content;
  ConsoleMetadata _metadata;
  bool _active = true;
  Future<void>? _removal;
  Completer<void>? _confirmation;

  ConsoleMetadata get metadata => _metadata;
  bool get isActive => _active && !_controller._closed && _isLive(_owner);
}

/// Window-local console state. Closing synchronously fences authority, then
/// joins bounded cleanup; neither widgets nor plugin advice own resource release.
final class ConsoleController extends ChangeNotifier {
  ConsoleController(
    this._extensions, {
    this.cleanupTimeout = const Duration(seconds: 2),
  }) {
    if (cleanupTimeout <= Duration.zero) {
      throw ArgumentError.value(cleanupTimeout, 'cleanupTimeout');
    }
    _refreshActions();
    _changes = _extensions.changes.listen((_) => _registryChanged());
  }

  final ExtensionRegistry _extensions;
  final Duration cleanupTimeout;
  late final StreamSubscription<void> _changes;
  final List<ConsoleTab> _tabs = [];
  final Map<SessionId, ConsoleTab> _selections = {};
  final Map<ConsoleActionBinding, Future<void>> _creating = {};
  final Set<Future<void>> _cleaning = {};
  final Expando<ConsoleTab> _transferred = Expando<ConsoleTab>();
  List<ConsoleActionBinding> _actions = [];
  Session? _session;
  ConsoleTab? _selected;
  bool _visible = true;
  bool _closed = false;
  bool _disposed = false;
  Object _context = Object();
  Object _view = Object();
  _PresentationAccess? _presentationAccess;
  Widget? _presentation;
  String? _warning;
  Future<void>? _closing;

  Session? get session => _session;
  bool get visible => _visible;
  bool get isClosed => _closed;
  String? get warning => _warning;

  List<ConsoleActionBinding> get actions =>
      List.unmodifiable(_actions.where((action) => action.isActive));

  List<ConsoleTab> get eligibleTabs =>
      List.unmodifiable(_tabs.where((tab) => _eligible(tab, _session)));

  ConsoleTab? get selectedTab =>
      _selected != null && _eligible(_selected!, _session) ? _selected : null;

  void setSession(Session? session) {
    if (_closed || identical(_session, session)) return;
    _revokePresentation();
    _session = session;
    _context = Object();
    _refreshActions();
    _restoreSelection();
    _notify();
  }

  void setVisible(bool visible) {
    if (_closed || _visible == visible) return;
    _visible = visible;
    _context = Object();
    _revokePresentation();
    _refreshActions();
    _notify();
  }

  void toggleVisibility() => setVisible(!_visible);

  void select(ConsoleTab tab) {
    if (_closed ||
        !_visible ||
        !_tabs.contains(tab) ||
        !_eligible(tab, _session) ||
        identical(_selected, tab)) {
      return;
    }
    _revokePresentation();
    _selected = tab;
    _selections[_session!.id] = tab;
    _notify();
  }

  Future<void> invoke(ConsoleActionBinding action) {
    if (!_canInvoke(action)) return Future.value();
    final pending = _creating[action];
    if (pending != null) return pending;
    final completion = Completer<void>();
    _creating[action] = completion.future;
    final access = _CreationAccess(this, action._owner, _session!, _context);
    // Invoke before notification: a listener may navigate, but cannot change the
    // admission of a callback that the host has already entered.
    Future<void>.sync(() => action._action.create(access)).then(
      (_) => _finishCreation(action, access, completion),
      onError: (Object error, StackTrace stack) {
        _warning = 'The console could not be created.';
        _finishCreation(action, access, completion);
      },
    );
    _notify();
    return completion.future;
  }

  void _finishCreation(
    ConsoleActionBinding action,
    _CreationAccess access,
    Completer<void> completion,
  ) {
    access._active = false;
    _creating.remove(action);
    completion.complete();
    _notify();
  }

  bool _canInvoke(ConsoleActionBinding action) =>
      !_closed &&
      _visible &&
      _session != null &&
      identical(action._controller, this) &&
      identical(action._context, _context) &&
      _actions.contains(action) &&
      _isLive(action._owner);

  ConsoleTabRegistration _open(_CreationAccess access, ConsoleContent content) {
    if (_transferred[content] != null) {
      throw StateError('Console content has already been transferred.');
    }
    final tab = ConsoleTab._(this, access._owner, content);
    _transferred[content] = tab;
    final registration = _TabRegistration(tab);
    if (!access.isActive || !_eligible(tab, access.session)) {
      unawaited(_remove(tab));
      return registration;
    }
    _tabs.add(tab);
    if (identical(access._context, _context) &&
        _visible &&
        _eligible(tab, _session)) {
      _revokePresentation();
      _selected = tab;
      _selections[_session!.id] = tab;
    } else {
      // An admitted background result must not steal the new context's view.
      _selections.putIfAbsent(access.session.id, () => tab);
    }
    _notify();
    return registration;
  }

  Future<void> closeTab(ConsoleTab tab, Future<bool> Function(String) confirm) {
    if (!identical(tab._controller, this)) return Future.value();
    if (tab._removal case final removal?) return removal;
    if (_closed ||
        !_visible ||
        !_tabs.contains(tab) ||
        !_eligible(tab, _session)) {
      return Future.value();
    }
    if (tab._confirmation case final pending?) return pending.future;
    final completion = Completer<void>();
    tab._confirmation = completion;
    unawaited(
      _confirmClose(tab, confirm).whenComplete(() {
        if (identical(tab._confirmation, completion)) tab._confirmation = null;
        if (!completion.isCompleted) completion.complete();
      }),
    );
    return completion.future;
  }

  Future<void> _confirmClose(
    ConsoleTab tab,
    Future<bool> Function(String) confirm,
  ) async {
    final context = _context;
    final view = _view;
    ConsoleCloseAdvice? advice;
    try {
      advice = tab._content.closeAdvice?.call();
    } on Object {
      // Unknown advice asks the host's generic question; it never vetoes close.
    }
    if (advice == null || advice.message != null) {
      bool accepted;
      try {
        accepted = await confirm(advice?.message ?? 'Close this console?');
      } on Object {
        return;
      }
      if (!accepted) return;
    }
    if (!identical(context, _context) ||
        !identical(view, _view) ||
        !_visible ||
        !_tabs.contains(tab) ||
        !_eligible(tab, _session)) {
      return;
    }
    await _remove(tab);
  }

  Future<void> _remove(ConsoleTab tab) {
    if (tab._removal case final pending?) return pending;
    final completion = Completer<void>();
    tab._removal = completion.future;
    _cleaning.add(completion.future);
    final index = _tabs.indexOf(tab);
    final neighbors = <ConsoleTab>[
      if (index >= 0) ...[
        ..._tabs.skip(index + 1),
        ..._tabs.take(index).toList().reversed,
      ],
    ];
    tab._active = false;
    _tabs.remove(tab);
    _selections.removeWhere((_, selected) => identical(selected, tab));
    if (identical(_selected, tab)) {
      _revokePresentation();
      // Prefer the next eligible neighbor, then the previous one. Closing an
      // unrelated tab never changes selection or constructs a presentation.
      _selected = _closed
          ? null
          : neighbors
                .where((candidate) => _eligible(candidate, _session))
                .firstOrNull;
      if (!_closed) _restoreSelection();
    }
    _notify();
    unawaited(
      _release(tab).whenComplete(() {
        _cleaning.remove(completion.future);
        completion.complete();
        final confirmation = tab._confirmation;
        tab._confirmation = null;
        if (confirmation != null && !confirmation.isCompleted) {
          confirmation.complete();
        }
      }),
    );
    return completion.future;
  }

  Future<void> _release(ConsoleTab tab) async {
    try {
      final result = await Future<ConsoleCleanupResult>.sync(
        tab._content.release,
      ).timeout(cleanupTimeout);
      if (result.warning case final warning? when warning.isNotEmpty) {
        _warning = warning;
      }
    } on TimeoutException {
      _warning = 'Console cleanup timed out. Some resources may remain active.';
    } on Object {
      _warning = 'Console cleanup failed. Some resources may remain active.';
    }
    _notify();
  }

  /// Called only by the native host for the selected visible content. Retained
  /// across ordinary rebuilds; never used to inspect or close unselected tabs.
  Widget? get selectedPresentation {
    final tab = selectedTab;
    if (_closed || !_visible || tab == null) {
      if (_presentationAccess != null) _revokePresentation();
      return null;
    }
    if (_presentation != null) return _presentation;
    final access = _PresentationAccess(this, tab);
    _presentationAccess = access;
    Widget presentation;
    try {
      presentation = tab._content.createPresentation(access);
      if (!access.isActive) return null;
    } on Object {
      access._active = false;
      presentation = const Center(
        child: Text('Console presentation is unavailable.'),
      );
    }
    _presentation = KeyedSubtree(key: UniqueKey(), child: presentation);
    return _presentation;
  }

  void unmountPresentation() => _revokePresentation();

  void _revokePresentation() {
    _presentationAccess?._active = false;
    _presentationAccess = null;
    _presentation = null;
    _view = Object();
  }

  bool _eligible(ConsoleTab tab, Session? session) {
    if (session == null || !tab.isActive) return false;
    try {
      return tab._content.isEligible(session) && tab.isActive;
    } on Object {
      return false;
    }
  }

  void _restoreSelection() {
    final session = _session;
    final remembered = session == null ? null : _selections[session.id];
    final eligible = eligibleTabs;
    _selected = remembered != null && eligible.contains(remembered)
        ? remembered
        : eligible.contains(_selected)
        ? _selected
        : eligible.firstOrNull;
    if (session != null && _selected != null) {
      _selections[session.id] = _selected!;
    }
  }

  void _refreshActions() {
    final previous = _actions;
    _actions = [];
    if (_closed || !_visible || _session == null) return;
    final owners = _extensions.discover(consoleContributions).toList()
      ..sort((a, b) => a.id.value.compareTo(b.id.value));
    for (final owner in owners) {
      final actions = owner.value.actions.toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      for (final action in actions) {
        _actions.add(
          previous
                  .where(
                    (old) =>
                        identical(old._context, _context) &&
                        old._owner.isSameRegistration(owner) &&
                        identical(old._action, action),
                  )
                  .firstOrNull ??
              ConsoleActionBinding._(this, owner, action, _context),
        );
      }
    }
  }

  void _registryChanged() {
    if (_closed) return;
    _refreshActions();
    for (final tab in _tabs.toList()) {
      if (!_isLive(tab._owner)) unawaited(_remove(tab));
    }
    _notify();
  }

  Future<void> close() {
    if (_closing case final closing?) return closing;
    final completion = Completer<void>();
    _closing = completion.future;
    _closed = true;
    _context = Object();
    _actions = [];
    _revokePresentation();
    unawaited(_changes.cancel());
    for (final tab in _tabs.toList()) {
      unawaited(_remove(tab));
    }
    _notify();
    // Do not wait for plugin creation or a dialog. Any later open is fenced and
    // released separately; no stalled callback can hold window shutdown hostage.
    Future.wait(_cleaning.toList()).then((_) => completion.complete());
    return completion.future;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}

final class _CreationAccess implements ConsoleCreationAccess {
  _CreationAccess(this._controller, this._owner, this.session, this._context);

  final ConsoleController _controller;
  final ExtensionBinding<ConsoleContribution> _owner;
  final Object _context;
  bool _active = true;
  @override
  final Session session;

  @override
  bool get isActive => _active && !_controller._closed && _isLive(_owner);

  @override
  ConsoleTabRegistration open(ConsoleContent content) =>
      _controller._open(this, content);
}

final class _TabRegistration implements ConsoleTabRegistration {
  _TabRegistration(this._tab);

  final ConsoleTab _tab;

  @override
  bool get isActive => _tab.isActive;

  @override
  void updateMetadata(ConsoleMetadata metadata) {
    if (!isActive) return;
    _tab._metadata = metadata;
    _tab._controller._notify();
  }

  @override
  Future<void> requestRemoval() => _tab._controller._remove(_tab);
}

final class _PresentationAccess implements ConsolePresentationAccess {
  _PresentationAccess(this._controller, this._tab);

  final ConsoleController _controller;
  final ConsoleTab _tab;
  bool _active = true;

  @override
  bool get isActive =>
      _active &&
      _tab.isActive &&
      _controller._visible &&
      identical(_controller._presentationAccess, this) &&
      identical(_controller.selectedTab, _tab);
}

bool _isLive(ExtensionBinding<ConsoleContribution> binding) {
  try {
    binding.validate();
    return true;
  } on StaleExtensionBinding {
    return false;
  }
}
