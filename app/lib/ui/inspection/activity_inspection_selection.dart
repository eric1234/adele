import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:flutter/foundation.dart';

/// Window navigation retains identities, never activity or execution objects.
sealed class InspectionTarget {
  const InspectionTarget({
    required this.sessionId,
    required this.runId,
    required this.modelInvocationId,
  });

  final SessionId sessionId;
  final RunId runId;
  final ModelInvocationId modelInvocationId;
}

final class ActivityGroupInspectionTarget extends InspectionTarget {
  const ActivityGroupInspectionTarget({
    required super.sessionId,
    required super.runId,
    required super.modelInvocationId,
  });
}

final class ModelOutputInspectionTarget extends InspectionTarget {
  const ModelOutputInspectionTarget({
    required super.sessionId,
    required super.runId,
    required super.modelInvocationId,
    required this.outputSequence,
  });

  final int outputSequence;
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
    this.isCollapsed = false,
  });

  final InspectionCardId id;
  final InspectionTarget target;
  final bool isCollapsed;
}

/// Owned by one application window. Every explicit open prepends a fresh card.
final class WindowInspection extends ChangeNotifier {
  Session? _session;
  List<InspectionCard> _cards = const [];
  bool _closed = false;

  List<InspectionCard> get cards => _cards;

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
        !_cards.any(
          (card) =>
              identical(card.id, originCardId) &&
              card.target is ActivityGroupInspectionTarget &&
              card.target.sessionId == session.id &&
              card.target.runId == activity.runId &&
              card.target.modelInvocationId == modelInvocationId,
        )) {
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

  void _prepend(InspectionTarget target) {
    _cards = List.unmodifiable([
      InspectionCard(id: InspectionCardId._(), target: target),
      ..._cards,
    ]);
    notifyListeners();
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
          InspectionCard(id: id, target: card.target, isCollapsed: collapsed)
        else
          retained,
    ]);
    notifyListeners();
    return true;
  }

  bool dismiss(InspectionCardId id) {
    if (_closed || !_cards.any((card) => identical(card.id, id))) return false;
    _cards = List.unmodifiable(_cards.where((card) => !identical(card.id, id)));
    notifyListeners();
    return true;
  }

  void clear() {
    if (_closed || _cards.isEmpty) return;
    _cards = const [];
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _session = null;
    _cards = const [];
    super.dispose();
  }
}
