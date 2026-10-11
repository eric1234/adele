import 'dart:async';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_product/adele_product.dart';

/// One window's selection source. Canonical validation and navigation settlement
/// belong to the application; only committed selection reaches [presentSession].
final class WindowSessionContextHost {
  late final WindowSessionContext context = _WindowSessionContext(this);
  WindowSessionSnapshot? _snapshot = const WindowSessionSnapshot(
    session: null,
    revision: 0,
  );
  final _observers = <Object, void Function(WindowSessionSnapshot)>{};
  bool _notifying = false;

  /// Application reads use the same source, including no selection after close.
  Session? get session => _snapshot?.session;

  void presentSession(Session? session) {
    final previous = context.snapshot;
    if (_notifying) throw StateError('Session publication is not reentrant.');
    if (identical(previous.session, session)) return;
    final next = WindowSessionSnapshot(
      session: session,
      revision: previous.revision + 1,
    );
    _snapshot = next;
    _notifying = true;
    try {
      for (final token in _observers.keys.toList()) {
        _observers[token]?.call(next);
      }
    } finally {
      _notifying = false;
    }
  }

  /// Synchronously fences all reads/subscriptions and drops selected identity.
  /// Captured immutable snapshots and independently admitted work are unaffected.
  void close() {
    _snapshot = null;
    _observers.clear();
  }
}

// Consumers receive a separate facade, not a publisher with a read-only type.
final class _WindowSessionContext implements WindowSessionContext {
  _WindowSessionContext(this._host);

  final WindowSessionContextHost _host;

  @override
  bool get isActive => _host._snapshot != null;

  @override
  WindowSessionSnapshot get snapshot =>
      _host._snapshot ??
      (throw StateError('Window Session context is closed.'));

  @override
  void Function() observe(void Function(WindowSessionSnapshot) listener) {
    if (!isActive) throw StateError('Window Session context is closed.');
    final token = Object();
    _host._observers[token] = Zone.current.bindUnaryCallbackGuarded(listener);
    return () => _host._observers.remove(token);
  }
}
