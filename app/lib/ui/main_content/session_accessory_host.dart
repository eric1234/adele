import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';

import '../../frontend/prepared_frontend.dart';

/// One ownership table per Main Content controller (one Session attachment).
final class SessionAccessoryMounts {
  final _owners = <SessionAccessoryLocation, _LocationState>{};
}

/// Supplies placement provenance, not a location. A pane that doesn't request
/// one never discovers, creates or displays any accessory.
class SessionAccessoryPaneScope extends InheritedWidget {
  const SessionAccessoryPaneScope({
    required this.mounts,
    required this.extensions,
    required this.owner,
    required this.isActive,
    required super.child,
  });

  final SessionAccessoryMounts mounts;
  final ExtensionRegistry extensions;
  final MainContentAccess owner;
  final bool Function() isActive;

  @override
  bool updateShouldNotify(SessionAccessoryPaneScope oldWidget) =>
      !identical(this, oldWidget);
}

class SessionAccessoryPlacement extends StatelessWidget {
  const SessionAccessoryPlacement({
    required this.owner,
    required this.location,
    this.isPresentationActive,
  });

  final MainContentAccess owner;
  final SessionAccessoryLocation location;
  final bool Function()? isPresentationActive;

  @override
  Widget build(BuildContext context) {
    final pane = context
        .dependOnInheritedWidgetOfExactType<SessionAccessoryPaneScope>();
    if (pane == null || !identical(pane.owner, owner)) {
      return const SizedBox.shrink();
    }
    return _Location(
      key: ValueKey((pane, location)),
      pane: pane,
      location: location,
      isPresentationActive: isPresentationActive,
    );
  }
}

class _Location extends StatefulWidget {
  const _Location({
    required super.key,
    required this.pane,
    required this.location,
    required this.isPresentationActive,
  });

  final SessionAccessoryPaneScope pane;
  final SessionAccessoryLocation location;
  final bool Function()? isPresentationActive;

  @override
  State<_Location> createState() => _LocationState();
}

class _LocationState extends State<_Location> {
  final _entries = <ExtensionId, _Accessory>{};
  Widget _display = const SizedBox.shrink();
  bool _live = true;
  late final _originActive = widget.isPresentationActive;
  bool _admitted = false;

  bool get _active {
    if (_live) {
      try {
        _live = widget.pane.isActive() && (_originActive?.call() ?? true);
      } on Object {
        _live = false;
      }
    }
    return _live;
  }

  @override
  void initState() {
    super.initState();
    final owners = widget.pane.mounts._owners;
    if (owners[widget.location]?._active ?? false) {
      _live = false; // A duplicate stays empty for its mount lifetime.
    } else if (_active) {
      owners[widget.location] = this;
      _admitted = true;
    }
  }

  Widget _compose() {
    final bindings = _active
        ? (widget.pane.extensions
              .discover(sessionAccessoryContributions)
              .where((b) => b.value.location == widget.location)
              .toList()
            ..sort((a, b) {
              final order = a.value.order.compareTo(b.value.order);
              return order != 0 ? order : a.id.value.compareTo(b.id.value);
            }))
        : const <ExtensionBinding<SessionAccessoryContribution>>[];
    for (final entry in _entries.values.toList()) {
      if (!bindings.any(entry.binding.isSameRegistration)) {
        _entries.remove(entry.binding.id);
        entry.retire();
      }
    }
    final children = <Widget>[];
    for (final binding in bindings) {
      if (!_active) break;
      try {
        final entry = _entries.putIfAbsent(
          binding.id,
          () => _Accessory(binding, widget.pane.owner.session, () => _active),
        );
        if (entry.isActive && entry.presentation != null) {
          children.add(
            KeyedSubtree(key: ObjectKey(entry), child: entry.presentation!),
          );
        }
      } on StaleExtensionBinding {
        // An earlier factory or detach callback may retire a later registration.
      }
    }
    return _display = children.isEmpty
        ? const SizedBox.shrink()
        : Wrap(spacing: 8, runSpacing: 4, children: children);
  }

  @override
  Widget build(BuildContext context) {
    if (!_admitted) return const SizedBox.shrink();
    final retaining = PreparedFrontendRetention.isRetaining(context);
    return StreamBuilder<void>(
      stream: widget.pane.extensions.changes,
      builder: (context, _) => retaining ? _display : _compose(),
    );
  }

  @override
  void dispose() {
    _live = false;
    final owners = widget.pane.mounts._owners;
    if (identical(owners[widget.location], this)) {
      owners.remove(widget.location);
    }
    for (final entry in _entries.values) {
      entry.retire();
    }
    _entries.clear();
    super.dispose();
  }
}

final class _Accessory implements SessionAccessoryAccess {
  _Accessory(this.binding, this._session, this._mountActive) {
    final contribution = binding.value;
    _detach = contribution.detach;
    try {
      presentation = contribution.createPresentation(this);
    } on Object {
      // Do not retry a failed factory on an unrelated registry notification.
      retire();
    }
  }

  final ExtensionBinding<SessionAccessoryContribution> binding;
  final Session _session;
  bool Function()? _mountActive;
  void Function(SessionAccessoryAccess)? _detach;
  Widget? presentation;

  @override
  bool get isActive {
    if (!(_mountActive?.call() ?? false)) return false;
    try {
      binding.validate();
      return true;
    } on StaleExtensionBinding {
      return false;
    }
  }

  @override
  Session get session {
    if (!isActive) throw StateError('Session accessory access is retired.');
    return _session;
  }

  void retire() {
    if (_mountActive == null) return;
    _mountActive = null;
    presentation = null;
    try {
      _detach?.call(this);
    } on Object {
      // One contribution's failed cleanup must not strand a sibling.
    } finally {
      _detach = null;
    }
  }
}
