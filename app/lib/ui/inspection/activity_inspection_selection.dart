import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Widget;

/// Window navigation retains identities, never activity or execution objects.
sealed class InspectionTarget {
  const InspectionTarget({required this.sessionId});

  final SessionId sessionId;
}

sealed class ActivityInspectionTarget extends InspectionTarget {
  const ActivityInspectionTarget({
    required super.sessionId,
    required this.runId,
    required this.modelInvocationId,
  });

  final RunId runId;
  final ModelInvocationId modelInvocationId;
}

final class ActivityGroupInspectionTarget extends ActivityInspectionTarget {
  const ActivityGroupInspectionTarget({
    required super.sessionId,
    required super.runId,
    required super.modelInvocationId,
  });
}

final class ModelOutputInspectionTarget extends ActivityInspectionTarget {
  const ModelOutputInspectionTarget({
    required super.sessionId,
    required super.runId,
    required super.modelInvocationId,
    required this.outputSequence,
  });

  final int outputSequence;
}

/// A domain reference, without Run evidence, executable bindings or content data.
final class SessionContentInspectionTarget extends InspectionTarget {
  const SessionContentInspectionTarget({
    required super.sessionId,
    required this.kind,
    required this.occurrenceId,
  });

  final SessionContentKind kind;
  final SessionContentOccurrenceId occurrenceId;
}

/// One card's exact presentation selection, separate from its semantic target.
final class SelectedSessionContentInspection extends ChangeNotifier
    implements SessionContentInspectionContext {
  SelectedSessionContentInspection({
    required this.session,
    required this.kind,
    required this.occurrenceId,
    required this.presenter,
  }) {
    _detach = presenter.onRetire(retire);
  }

  void _capturePresentation() {
    presentation = Future<Widget>.sync(() {
      if (!_active) throw StateError('Content Inspection is retired.');
      return presenter.value.createPresentation(this);
    });
    // The card can be dismissed before it ever mounts. Keep factory failures
    // observed in that case; a mounted host still awaits the original result.
    presentation.ignore();
  }

  @override
  final Session session;
  @override
  final SessionContentKind kind;
  @override
  final SessionContentOccurrenceId occurrenceId;
  final ExtensionBinding<SessionContentInspectionContribution> presenter;
  void Function()? _detach;
  bool _active = true;

  @override
  bool get isActive => _active;

  /// Capture the factory result (and any prepared backend route) at admission,
  /// not widget mount. Remounting cannot retry or rediscover a provider.
  late final Future<Widget> presentation;

  void retire() {
    if (!_active) return;
    _active = false;
    _detach?.call();
    _detach = null;
    notifyListeners();
  }

  @override
  void dispose() {
    retire();
    super.dispose();
  }
}

/// Opaque identity for one opening, distinct even for identical targets.
final class InspectionCardId {
  InspectionCardId._();
}

@immutable
final class InspectionCard {
  const InspectionCard({
    required this.id,
    required this.target,
    this.content,
    this.isCollapsed = false,
  });

  final InspectionCardId id;
  final InspectionTarget target;
  final SelectedSessionContentInspection? content;
  final bool isCollapsed;
}

/// Owned by one application window. Every explicit open prepends a fresh card.
final class WindowInspection extends ChangeNotifier {
  Session? _session;
  List<InspectionCard> _cards = const [];
  bool _closed = false;

  List<InspectionCard> get cards => _cards;

  /// The mounted producer supplies a native captured Session, never a transported
  /// Session selector. Every opening resolves once; old cards never rediscover.
  bool inspectContent({
    required Session session,
    required SessionContentKind kind,
    required SessionContentOccurrenceId occurrenceId,
    required ExtensionRegistry extensions,
  }) {
    if (_closed || !identical(session, _session)) return false;
    final presenter = SessionContentInspectionResolver(
      extensions,
    ).resolve(kind);
    final content = SelectedSessionContentInspection(
      session: session,
      kind: kind,
      occurrenceId: occurrenceId,
      presenter: presenter,
    );
    _prepend(
      SessionContentInspectionTarget(
        sessionId: session.id,
        kind: kind,
        occurrenceId: occurrenceId,
      ),
      content: content,
    );
    return true;
  }

  void presentSession(Session? session) {
    if (_closed || identical(_session, session)) return;
    _session = session;
    clear();
  }

  ModelInvocationActivity? _model(
    Session session,
    RunActivitySnapshot activity,
    ModelInvocationId modelInvocationId,
  ) {
    if (_closed ||
        !identical(session, _session) ||
        activity.sessionId != session.id) {
      return null;
    }
    return activity.models
        .where(
          (model) =>
              model.id == modelInvocationId &&
              model.settlement == ModelSettlement.completed &&
              model.failure == null,
        )
        .firstOrNull;
  }

  /// The caller first validates the emitted activity handle against retained evidence.
  bool inspectActivity({
    required Session session,
    required RunActivitySnapshot activity,
    required ModelInvocationId modelInvocationId,
  }) {
    if (_model(session, activity, modelInvocationId) == null) return false;
    _prepend(
      ActivityGroupInspectionTarget(
        sessionId: session.id,
        runId: activity.runId,
        modelInvocationId: modelInvocationId,
      ),
    );
    return true;
  }

  /// A group-row action supplies its original card ID so a dismissed or replaced
  /// Session's retained callback cannot repopulate this window.
  bool inspectOutput({
    required Session session,
    required RunActivitySnapshot activity,
    required ModelInvocationId modelInvocationId,
    required int outputSequence,
    InspectionCardId? originCardId,
  }) {
    final model = _model(session, activity, modelInvocationId);
    if (model == null) return false;
    if (originCardId != null &&
        !_cards.any((card) {
          final target = card.target;
          return identical(card.id, originCardId) &&
              target is ActivityGroupInspectionTarget &&
              target.sessionId == session.id &&
              target.runId == activity.runId &&
              target.modelInvocationId == modelInvocationId;
        })) {
      return false;
    }
    final output = model.outputs
        .where((output) => output.sequence == outputSequence)
        .firstOrNull;
    if (output == null ||
        switch (output.item) {
          ModelToolProposalOutput() => false,
          ModelNativeOutput(presentation: ModelNativePresentation()) => false,
          _ => true,
        }) {
      return false;
    }
    _prepend(
      ModelOutputInspectionTarget(
        sessionId: session.id,
        runId: activity.runId,
        modelInvocationId: modelInvocationId,
        outputSequence: outputSequence,
      ),
    );
    return true;
  }

  void _prepend(
    InspectionTarget target, {
    SelectedSessionContentInspection? content,
  }) {
    _cards = List.unmodifiable([
      InspectionCard(
        id: InspectionCardId._(),
        target: target,
        content: content,
      ),
      ..._cards,
    ]);
    content?._capturePresentation();
    if (!_closed) notifyListeners();
  }

  bool collapse(InspectionCardId id) => _setCollapsed(id, true);

  bool expand(InspectionCardId id) => _setCollapsed(id, false);

  bool _setCollapsed(InspectionCardId id, bool collapsed) {
    if (_closed) return false;
    final index = _cards.indexWhere((card) => identical(card.id, id));
    if (index < 0) return false;
    final card = _cards[index];
    if (card.isCollapsed == collapsed) return true;
    _cards = List.unmodifiable([
      for (final retained in _cards)
        if (identical(retained.id, id))
          InspectionCard(
            id: id,
            target: card.target,
            content: card.content,
            isCollapsed: collapsed,
          )
        else
          retained,
    ]);
    notifyListeners();
    return true;
  }

  bool dismiss(InspectionCardId id) {
    if (_closed || !_cards.any((card) => identical(card.id, id))) return false;
    _cards.firstWhere((card) => identical(card.id, id)).content?.dispose();
    _cards = List.unmodifiable(_cards.where((card) => !identical(card.id, id)));
    notifyListeners();
    return true;
  }

  void clear() {
    if (_closed || _cards.isEmpty) return;
    for (final card in _cards) {
      card.content?.dispose();
    }
    _cards = const [];
    notifyListeners();
  }

  /// Accepted window shutdown retains inert card identity while owners drain.
  /// Unlike departure, it need not remove the retained display immediately.
  void retire() {
    if (_closed) return;
    _closed = true;
    _session = null;
    for (final card in _cards) {
      card.content?.retire();
    }
  }

  @override
  void dispose() {
    retire();
    for (final card in _cards) {
      card.content?.dispose();
    }
    _cards = const [];
    super.dispose();
  }
}
