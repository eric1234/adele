import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/widgets.dart';

/// Additive, independent collections of panes for the presented Session.
/// Collections sort by [MainContentContribution.order], then ExtensionId text.
final ExtensionPoint<MainContentContribution> mainContentContributions =
    ExtensionPoint<MainContentContribution>('dev.adele.extension.main-content');

final class MainContentContribution {
  const MainContentContribution({required this.order, required this.attach});

  final int order;

  /// Called once per exact registration and current canonical Session attachment.
  /// Returning does not revoke access; departure, retirement, or host shutdown do.
  /// Returning to a Session creates fresh access, never revives an earlier handle.
  final FutureOr<void> Function(MainContentAccess) attach;
}

abstract interface class MainContentAccess {
  /// The captured canonical Session, never retargeted through its semantic ID.
  Session get session;

  /// The only operation permitted after retirement; all others throw StateError.
  bool get isActive;

  /// Immutable, ordered snapshots of this collection only.
  List<MainContentPaneInfo> get panes;

  /// Appends a new local ID without focusing. An existing ID throws ArgumentError
  /// without replacing content/metadata or transferring ownership of the object.
  void open(MainContentPane pane);

  void setTitle(String id, String title);

  /// Requires a complete permutation of current local IDs, without duplicates.
  void setOrder(List<String> ids);

  /// Removes owned content without invoking onClose. A missing ID is a no-op.
  void remove(String id);

  /// Reveals only the Main Content horizontal scroller. Keyboard focus is opt-in
  /// and uses requestFocus when supplied, otherwise ordinary content traversal.
  /// Like setTitle, an unknown ID throws ArgumentError.
  void focus(String id, {bool keyboardFocus = false});
}

final class MainContentPane {
  MainContentPane({
    required String id,
    required String title,
    required this.createPresentation,
    this.requestFocus,
    this.onClose,
    this.release,
  }) : _info = MainContentPaneInfo(
         id: id,
         title: title,
         canClose: onClose != null,
       );

  final MainContentPaneInfo _info;
  String get id => _info.id;
  String get title => _info.title;

  /// Constructed at most once per admitted pane, including failed construction.
  final Widget Function() createPresentation;
  final VoidCallback? requestFocus;

  /// Chrome requests closure; the owner decides when to call access.remove(id).
  final VoidCallback? onClose;

  /// Called synchronously once on logical removal, retirement, or departure.
  /// Owners must defer physical resource teardown while a view is still attached.
  /// A rejected duplicate open does not transfer this cleanup responsibility.
  final VoidCallback? release;
}

@immutable
final class MainContentPaneInfo {
  MainContentPaneInfo({
    required this.id,
    required this.title,
    required this.canClose,
  }) {
    if (id.isEmpty ||
        id.length > 128 ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$').hasMatch(id)) {
      throw ArgumentError('Main Content pane ID must be bounded ASCII.');
    }
    if (title.trim().isEmpty ||
        title.length > 160 ||
        title.contains(
          RegExp(r'[\x00-\x1f\x7f-\x9f\u2028-\u202e\u2066-\u2069]'),
        )) {
      throw ArgumentError('Main Content title must be bounded ordinary text.');
    }
  }

  final String id;
  final String title;
  final bool canClose;
}
