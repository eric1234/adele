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
  ConsoleCloseRequest? _confirmation;
  _PreparedOpening? _prepared;
  int _lastSelected = 0;

  ConsoleMetadata get metadata => _metadata;
  bool get isActive => _active && !_controller._closed && _isLive(_owner);
}

/// One stably parented native presentation, separate from its lightweight tab.
final class ConsoleResidentPresentation {
  ConsoleResidentPresentation._(this.tab, this._access);

  final ConsoleTab tab;
  final _PresentationAccess _access;
  ConsolePresentationAccess get access => _access;
  late final Widget widget;
}

/// App-private identity for one confirmation, not permission to close content.
/// Withdrawal ends the question independently of either its answer or cleanup.
final class ConsoleCloseRequest {
  ConsoleCloseRequest._(this._tab, this._context, this._view);

  final ConsoleTab _tab;
  final Object _context;
  final Object _view;
  final _withdrawn = Completer<void>();
  final _completion = Completer<void>();
  late final String _message;

  String get message => _message;
  bool get isPending => !_withdrawn.isCompleted;
  Future<void> get withdrawn => _withdrawn.future;

  void _withdraw() {
    if (isPending) _withdrawn.complete();
  }
}

/// Window-local console state. Closing synchronously fences authority, then
/// joins bounded cleanup; neither widgets nor plugin advice own resource release.
final class ConsoleController extends ChangeNotifier {
  ConsoleController(
    this._extensions, {
    this.cleanupTimeout = const Duration(seconds: 2),
    this.presentationLimit = 4,
  }) {
    if (cleanupTimeout <= Duration.zero) {
      throw ArgumentError.value(cleanupTimeout, 'cleanupTimeout');
    }
    if (presentationLimit < 1) {
      throw ArgumentError.value(presentationLimit, 'presentationLimit');
    }
    _refreshActions();
    _changes = _extensions.changes.listen((_) => _registryChanged());
  }

  final ExtensionRegistry _extensions;
  final Duration cleanupTimeout;

  /// Includes selected-only and initializing presentations, not unvisited tabs.
  final int presentationLimit;
  late final StreamSubscription<void> _changes;
  final List<ConsoleTab> _tabs = [];
  final Map<SessionId, ConsoleTab> _selections = {};
  final Map<ConsoleActionBinding, Future<void>> _creating = {};
  final List<_PreparedOpening> _prepared = [];
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
  final Map<ConsoleTab, ConsoleResidentPresentation> _residents = {};
  int _selectionSequence = 0;
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
    if (_changeVisibility(visible)) _notify();
  }

  bool _changeVisibility(bool visible) {
    if (_closed || _visible == visible) return false;
    _visible = visible;
    _context = Object();
    _revokePresentation();
    _refreshActions();
    return true;
  }

  void toggleVisibility() => setVisible(!_visible);

  void select(ConsoleTab tab) {
    if (_closed ||
        !_visible ||
        !_tabs.contains(tab) ||
        !_eligible(tab, _session)) {
      return;
    }
    if (identical(_selected, tab)) {
      tab._lastSelected = ++_selectionSequence;
      return;
    }
    _endSelection();
    _selected = tab;
    _activateSelection();
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

  /// Native admission from an authorized presentation. The canonical Session is
  /// checked by its host before entry; this controller never resolves IDs.
  Future<void> openOrFocus({
    required ExtensionBinding<ConsoleContribution> owner,
    required Session session,
    required ConsoleContentDescriptor descriptor,
  }) {
    if (_closed ||
        !identical(session, _session) ||
        !_isLive(owner) ||
        !_extensions
            .discover(consoleContributions)
            .any(owner.isSameRegistration)) {
      return Future.error(StateError('Prepared console is unavailable.'));
    }
    final create = owner.value.openPrepared;
    if (create == null) {
      return Future.error(StateError('Prepared console is unavailable.'));
    }
    // Capture/admit before publishing reveal, as invoke does. A synchronous
    // listener may retire the owner or navigate, including back to this Session.
    final revealed = _changeVisibility(true);
    final existing = _prepared
        .where(
          (entry) =>
              entry.active &&
              entry.owner.isSameRegistration(owner) &&
              identical(entry.session, session) &&
              entry.key == descriptor.key,
        )
        .firstOrNull;
    if (existing != null) {
      existing.context = _context;
      existing.view = _view;
      if (existing.tab case final tab?) select(tab);
      if (revealed) _notify();
      return existing.completion.future;
    }
    final entry = _PreparedOpening(
      owner,
      session,
      descriptor.key,
      _context,
      _view,
    );
    _prepared.add(entry);
    final access = _CreationAccess(
      this,
      owner,
      session,
      _context,
      prepared: entry,
    );
    Future<void>.sync(() => create(access, descriptor)).then(
      (_) {
        access._active = false;
        if (entry.tab == null) {
          entry.active = false;
          _prepared.remove(entry);
          entry.completion.completeError(
            StateError('No console content admitted.'),
          );
        } else {
          entry.completion.complete();
        }
      },
      onError: (Object error, StackTrace stack) {
        access._active = false;
        if (entry.tab == null) {
          entry.active = false;
          _prepared.remove(entry);
        }
        entry.completion.completeError(error, stack);
      },
    );
    if (revealed) _notify();
    return entry.completion.future;
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
    if (access._prepared case final prepared?) {
      if (prepared.tab != null) {
        // A prepared request admits one content. Additional or late transfers
        // still receive the normal bounded release, never replace that content.
        unawaited(_remove(tab));
        return registration;
      }
      prepared.tab = tab;
      tab._prepared = prepared;
    }
    if (!access.isActive || !_eligible(tab, access.session)) {
      unawaited(_remove(tab));
      return registration;
    }
    _tabs.add(tab);
    if (identical(access._prepared?.context ?? access._context, _context) &&
        (access._prepared == null ||
            identical(access._prepared!.view, _view)) &&
        _visible &&
        _eligible(tab, _session)) {
      _endSelection();
      _selected = tab;
      _activateSelection();
      _selections[_session!.id] = tab;
    } else {
      // An admitted background result must not steal the new context's view.
      _selections.putIfAbsent(access.session.id, () => tab);
    }
    _notify();
    return registration;
  }

  Future<void> closeTab(
    ConsoleTab tab,
    Future<bool> Function(ConsoleCloseRequest) confirm,
  ) {
    if (!identical(tab._controller, this)) return Future.value();
    if (tab._removal case final removal?) return removal;
    if (_closed ||
        !_visible ||
        !_tabs.contains(tab) ||
        !_eligible(tab, _session)) {
      return Future.value();
    }
    if (tab._confirmation case final pending?) {
      return pending._completion.future;
    }
    final request = ConsoleCloseRequest._(tab, _context, _view);
    tab._confirmation = request;
    unawaited(
      _confirmClose(request, confirm).whenComplete(() => _settle(request)),
    );
    return request._completion.future;
  }

  void _settle(ConsoleCloseRequest request) {
    if (identical(request._tab._confirmation, request)) {
      request._tab._confirmation = null;
    }
    request._withdraw();
    if (!request._completion.isCompleted) request._completion.complete();
  }

  Future<void> _confirmClose(
    ConsoleCloseRequest request,
    Future<bool> Function(ConsoleCloseRequest) confirm,
  ) async {
    final tab = request._tab;
    ConsoleCloseAdvice? advice;
    try {
      advice = tab._content.closeAdvice?.call();
    } on Object {
      // Unknown advice asks the host's generic question; it never vetoes close.
    }
    if (!request.isPending) return;
    if (advice == null || advice.message != null) {
      request._message = advice?.message ?? 'Close this console?';
      bool accepted;
      try {
        accepted = await Future.any([
          Future<bool>.sync(() => confirm(request)),
          request.withdrawn.then((_) => false),
        ]);
      } on Object {
        return;
      }
      if (!accepted) return;
    }
    if (!request.isPending ||
        !identical(tab._confirmation, request) ||
        !identical(request._context, _context) ||
        !identical(request._view, _view) ||
        !_visible ||
        !_tabs.contains(tab) ||
        !_eligible(tab, _session)) {
      return;
    }
    // Acceptance ends the question. Subsequent context changes must not cancel
    // the admitted cleanup or complete its Future before cleanup settles.
    tab._confirmation = null;
    request._withdraw();
    await _remove(tab);
  }

  Future<void> _remove(ConsoleTab tab) {
    if (tab._removal case final pending?) return pending;
    final completion = Completer<void>();
    tab._removal = completion.future;
    _cleaning.add(completion.future);
    if (tab._confirmation case final request?) _settle(request);
    final index = _tabs.indexOf(tab);
    final neighbors = <ConsoleTab>[
      if (index >= 0) ...[
        ..._tabs.skip(index + 1),
        ..._tabs.take(index).toList().reversed,
      ],
    ];
    if (identical(_selected, tab)) _endSelection();
    _evict(tab);
    tab._active = false;
    if (tab._prepared case final prepared?) {
      prepared.active = false;
      _prepared.remove(prepared);
    }
    _tabs.remove(tab);
    _selections.removeWhere((_, selected) => identical(selected, tab));
    if (identical(_selected, tab)) {
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

  /// Constructs only selected content, sharing the same resident used by the
  /// workbench collection. Reading tab metadata never calls a factory.
  Widget? get selectedPresentation {
    final tab = selectedTab;
    if (_closed || !_visible || tab == null) {
      return null;
    }
    final existing = _residents[tab];
    if (existing != null) return existing.widget;
    while (_residents.length >= presentationLimit) {
      final hidden = _residents.keys.where((other) => !identical(other, tab));
      final oldest = hidden.reduce(
        (a, b) => a._lastSelected < b._lastSelected ? a : b,
      );
      _evict(oldest);
    }
    final access = _PresentationAccess(this, tab);
    final resident = ConsoleResidentPresentation._(tab, access);
    _residents[tab] = resident;
    access._select();
    Widget presentation;
    try {
      presentation = tab._content.createPresentation(access);
      if (!identical(_residents[tab], resident)) return null;
    } on Object {
      access._revoke();
      presentation = const Center(
        child: Text('Console presentation is unavailable.'),
      );
    }
    resident.widget = KeyedSubtree(key: ObjectKey(access), child: presentation);
    return resident.widget;
  }

  List<ConsoleResidentPresentation> get residentPresentations {
    selectedPresentation;
    return List.unmodifiable(_residents.values);
  }

  void unmountPresentation() => _revokePresentation();

  void _revokePresentation() {
    _endSelection();
    for (final tab in _residents.keys.toList()) {
      _evict(tab);
    }
  }

  void _evict(ConsoleTab tab) {
    // Remove before notifying: reentrant listeners cannot find a revoked entry.
    _residents.remove(tab)?._access._revoke();
  }

  void _endSelection() {
    final tab = _selected;
    if (tab != null) {
      _residents[tab]?._access._deselect();
      if (!tab._content.keepAlive) _evict(tab);
    }
    _view = Object();
    for (final tab in _tabs) {
      if (tab._confirmation case final request?) _settle(request);
    }
  }

  void _activateSelection() {
    final tab = _selected;
    if (tab == null) return;
    tab._lastSelected = ++_selectionSequence;
    if (_visible) _residents[tab]?._access._select();
  }

  bool _eligible(ConsoleTab tab, Session? session) {
    if (session == null || !tab.isActive) return false;
    if (tab._prepared case final prepared?
        when !identical(prepared.session, session)) {
      return false;
    }
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
    _activateSelection();
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
    _prepared.removeWhere((entry) {
      if (_isLive(entry.owner)) return false;
      entry.active = false;
      return true;
    });
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
    for (final entry in _prepared) {
      entry.active = false;
    }
    _prepared.clear();
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
  _CreationAccess(
    this._controller,
    this._owner,
    this.session,
    this._context, {
    _PreparedOpening? prepared,
  }) : _prepared = prepared;

  final ConsoleController _controller;
  final ExtensionBinding<ConsoleContribution> _owner;
  final Object _context;
  final _PreparedOpening? _prepared;
  bool _active = true;
  @override
  final Session session;

  @override
  bool get isActive =>
      _active &&
      (_prepared?.active ?? true) &&
      !_controller._closed &&
      _isLive(_owner);

  @override
  ConsoleTabRegistration open(ConsoleContent content) =>
      _controller._open(this, content);
}

final class _PreparedOpening {
  _PreparedOpening(this.owner, this.session, this.key, this.context, this.view);

  final ExtensionBinding<ConsoleContribution> owner;
  final Session session;
  final String key;
  Object context;
  Object view;
  final completion = Completer<void>();
  bool active = true;
  ConsoleTab? tab;
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

final class _PresentationAccess extends ChangeNotifier
    implements ConsolePresentationAccess {
  _PresentationAccess(this._controller, this._tab);

  final ConsoleController _controller;
  final ConsoleTab _tab;
  bool _active = true;
  _InteractionAccess? _interaction;

  @override
  Listenable get changes => this;

  @override
  ConsoleInteractionAccess? get interaction =>
      _interaction?.isActive == true ? _interaction : null;

  void _select() {
    if (!_active || _interaction != null) return;
    _interaction = _InteractionAccess(this);
    notifyListeners();
  }

  void _deselect() {
    if (_interaction == null) return;
    _interaction = null;
    notifyListeners();
  }

  void _revoke() {
    if (!_active) return;
    _active = false;
    _interaction = null;
    notifyListeners();
  }

  @override
  bool get isActive =>
      _active &&
      _tab.isActive &&
      _controller._visible &&
      identical(_controller._residents[_tab]?._access, this);
}

final class _InteractionAccess implements ConsoleInteractionAccess {
  _InteractionAccess(this._presentation);

  final _PresentationAccess _presentation;

  @override
  bool get isActive =>
      _presentation.isActive &&
      identical(_presentation._interaction, this) &&
      identical(_presentation._controller.selectedTab, _presentation._tab);
}

bool _isLive(ExtensionBinding<ConsoleContribution> binding) {
  try {
    binding.validate();
    return true;
  } on StaleExtensionBinding {
    return false;
  }
}
