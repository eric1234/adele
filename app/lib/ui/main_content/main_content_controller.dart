import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/inspection_display.dart';
import 'package:flutter/widgets.dart';

/// Current-Session ownership. The widget host reconciles before rendering, so
/// registry notification cannot detach views during exit retention.
final class MainContentController extends ChangeNotifier {
  MainContentController({
    required this.session,
    required this.extensions,
    required Widget strategyContent,
    required String strategyTitle,
    this.isCurrent,
  }) {
    _strategy = MainContentEntry._strategy(
      this,
      strategyContent,
      strategyTitle,
    );
    _changes = extensions.changes.listen((_) => _notify());
  }

  final Session session;
  final ExtensionRegistry extensions;
  final bool Function()? isCurrent;
  late final StreamSubscription<void> _changes;
  late final MainContentEntry _strategy;
  final List<_MainContentAccess> _groups = [];
  bool _closed = false;
  bool _retaining = false;
  bool _reconciling = false;
  bool _contextEnded = false;

  bool get _hasContext {
    if (_contextEnded) return false;
    try {
      if (isCurrent?.call() ?? true) return true;
    } on Object {
      // A failed context check cannot retain authority.
    }
    _contextEnded = true;
    return false;
  }

  void Function(MainContentEntry entry, bool keyboardFocus)? onFocus;

  /// The strategy is an adapter, not a second plugin registration. Its unique
  /// entry stays parented across title/widget updates and ordinary registry edits.
  /// Its ordering identity sorts lexically with contributions at order 100.
  List<MainContentEntry> get entries {
    if (_closed) return const [];
    final groups =
        [
          (
            order: 100,
            id: 'dev.adele.main-content.strategy',
            strategy: true,
            entries: [_strategy],
          ),
          for (final group in _groups)
            (
              order: group.order,
              id: group.binding.id.value,
              strategy: false,
              entries: group._entries,
            ),
        ]..sort((a, b) {
          final order = a.order.compareTo(b.order);
          if (order != 0) return order;
          final id = a.id.compareTo(b.id);
          if (id != 0) return id;
          return a.strategy == b.strategy ? 0 : (a.strategy ? -1 : 1);
        });
    return List.unmodifiable(groups.expand((group) => group.entries));
  }

  void updateStrategy({required Widget content, required String title}) {
    if (_closed || _retaining) return;
    _strategy._info = _strategyInfo(title);
    _strategy._presentation = content;
  }

  void reconcile() {
    if (_closed || _retaining || _reconciling) return;
    if (!_hasContext) {
      for (final group in _groups) {
        group._retire();
      }
      return;
    }
    _reconciling = true;
    try {
      final bindings = extensions.discover(mainContentContributions);
      for (final group in _groups.toList()) {
        if (!bindings.any(group.binding.isSameRegistration)) {
          _groups.remove(group);
          group._retire();
        }
      }
      for (final binding in bindings) {
        if (_closed || _retaining) break;
        if (_groups.any((group) => group.binding.isSameRegistration(binding))) {
          continue;
        }
        final MainContentContribution contribution;
        try {
          contribution = binding.value;
        } on StaleExtensionBinding {
          continue;
        }
        final group = _MainContentAccess(this, binding, contribution.order);
        _groups.add(group);
        unawaited(
          Future<void>.sync(() {
            group._validate();
            return contribution.attach(group);
          }).then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              // Keep the failed registration recorded: unrelated rebuilds do not
              // retry an attachment. Failure is local to this collection.
              if (_retaining) {
                group._retired = true;
              } else {
                group._retire();
              }
              _notify();
            },
          ),
        );
      }
    } finally {
      _reconciling = false;
    }
  }

  /// One-way shutdown retention preserves views, never executable authority.
  /// Resources are released when the retained host is disposed.
  void retainForShutdown() => _retaining = true;

  void _notify() {
    if (!_closed && !_retaining && !_reconciling) notifyListeners();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    onFocus = null;
    unawaited(_changes.cancel());
    for (final group in _groups) {
      group._retire();
    }
    _groups.clear();
    _strategy._remove();
    super.dispose();
  }
}

/// Stable app-private row identity and presentation/resource lifetime.
final class MainContentEntry {
  MainContentEntry._(this._controller, this._owner, MainContentPane pane)
    : _pane = pane,
      _info = MainContentPaneInfo(
        id: pane.id,
        title: pane.title,
        canClose: pane.onClose != null,
      );

  MainContentEntry._strategy(this._controller, Widget content, String title)
    : _owner = null,
      _pane = null,
      _presentation = content,
      _info = _strategyInfo(title);

  final MainContentController _controller;
  final _MainContentAccess? _owner;
  final MainContentPane? _pane;
  MainContentPaneInfo _info;
  Widget? _presentation;
  bool _removed = false;

  MainContentPaneInfo get info => _info;
  bool get isActive =>
      !_removed &&
      !_controller._closed &&
      !_controller._retaining &&
      _controller._hasContext &&
      (_owner?.isActive ?? true);

  Widget get presentation {
    if (_presentation case final retained?) return retained;
    try {
      if (!isActive) throw StateError('Main Content pane is retired.');
      final created = _pane!.createPresentation();
      if (!isActive) throw StateError('Main Content pane is retired.');
      return _presentation = created;
    } on Object {
      return _presentation = const Center(
        child: Text('Main Content presentation is unavailable.'),
      );
    }
  }

  void requestClose() {
    if (!isActive) return;
    try {
      _pane?.onClose?.call();
    } on Object {
      // Owner failure does not close the pane or affect its siblings.
    }
  }

  void requestKeyboardFocus(VoidCallback ordinaryFocus) {
    if (!isActive) return;
    try {
      (_pane?.requestFocus ?? ordinaryFocus)();
    } on Object {
      // Native focus failure must not affect other mounted panes.
    }
  }

  void _remove() {
    if (_removed) return;
    _removed = true;
    try {
      _pane?.release?.call();
    } on Object {
      // Removal is final even if cleanup fails; other owners still release.
    }
  }
}

final class _MainContentAccess implements MainContentAccess {
  _MainContentAccess(this.controller, this.binding, this.order);

  final MainContentController controller;
  final ExtensionBinding<MainContentContribution> binding;
  final int order;
  final List<MainContentEntry> _entries = [];
  bool _retired = false;

  @override
  bool get isActive {
    if (_retired ||
        controller._closed ||
        controller._retaining ||
        !controller._hasContext) {
      return false;
    }
    try {
      binding.validate();
      return true;
    } on StaleExtensionBinding {
      return false;
    }
  }

  void _validate() {
    if (!isActive) throw StateError('Main Content access is retired.');
  }

  @override
  Session get session {
    _validate();
    return controller.session;
  }

  @override
  List<MainContentPaneInfo> get panes {
    _validate();
    return List.unmodifiable(_entries.map((entry) => entry.info));
  }

  @override
  void open(MainContentPane pane) {
    _validate();
    if (_entries.any((entry) => entry.info.id == pane.id)) {
      throw ArgumentError.value(pane.id, 'id', 'Duplicate Main Content pane.');
    }
    _entries.add(MainContentEntry._(controller, this, pane));
    controller._notify();
  }

  MainContentEntry _entry(String id) {
    _validate();
    for (final entry in _entries) {
      if (entry.info.id == id) return entry;
    }
    throw ArgumentError.value(id, 'id', 'Unknown Main Content pane.');
  }

  @override
  void setTitle(String id, String title) {
    final entry = _entry(id);
    entry._info = MainContentPaneInfo(
      id: id,
      title: title,
      canClose: entry.info.canClose,
    );
    controller._notify();
  }

  @override
  void setOrder(List<String> ids) {
    _validate();
    final byId = {for (final entry in _entries) entry.info.id: entry};
    if (ids.length != byId.length ||
        ids.toSet().length != ids.length ||
        ids.any((id) => !byId.containsKey(id))) {
      throw ArgumentError('Main Content order must be a complete permutation.');
    }
    final ordered = [for (final id in ids) byId[id]!];
    _entries
      ..clear()
      ..addAll(ordered);
    controller._notify();
  }

  @override
  void remove(String id) {
    _validate();
    final index = _entries.indexWhere((entry) => entry.info.id == id);
    if (index < 0) return;
    _entries.removeAt(index)._remove();
    controller._notify();
  }

  @override
  void focus(String id, {bool keyboardFocus = false}) {
    final entry = _entry(id);
    controller.onFocus?.call(entry, keyboardFocus);
  }

  void _retire() {
    _retired = true;
    final removed = _entries.toList();
    _entries.clear();
    for (final entry in removed) {
      entry._remove();
    }
  }
}

MainContentPaneInfo _strategyInfo(String title) {
  // Existing strategy display names have no pane-admission bounds. Adapt only
  // their chrome, using the same bounded display policy as other host labels.
  final display = compactDisplayText(title, maximumCharacters: 80);
  return MainContentPaneInfo(
    id: 'strategy',
    title: display.trim().isEmpty ? 'Session' : display,
    canClose: false,
  );
}
