import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:flutter/foundation.dart';

/// A window-local selection, not retained Session history or Run state.
final class ActivityInspectionSelection {
  const ActivityInspectionSelection({
    required this.sessionId,
    required this.runId,
    required this.modelInvocationId,
  });

  final SessionId sessionId;
  final RunId runId;
  final ModelInvocationId modelInvocationId;
}

/// Owned by one application window. It retains identities, never activity copies.
final class WindowInspection extends ChangeNotifier {
  Session? _session;
  ActivityInspectionSelection? _selection;
  bool _closed = false;

  ActivityInspectionSelection? get selection => _selection;

  void presentSession(Session? session) {
    if (_closed || identical(_session, session)) return;
    _session = session;
    clear();
  }

  /// The stock adapter supplies retained evidence, not frontend-created objects.
  bool inspectActivity({
    required Session session,
    required RunActivitySnapshot activity,
    required ModelInvocationId modelInvocationId,
  }) {
    if (_closed ||
        !identical(session, _session) ||
        activity.sessionId != session.id ||
        !activity.models.any(
          (model) =>
              model.id == modelInvocationId &&
              model.settlement == ModelSettlement.completed &&
              model.failure == null &&
              model.outputs.any(
                (output) => output.item is ModelToolProposalOutput,
              ),
        )) {
      return false;
    }
    if (_selection?.runId == activity.runId &&
        _selection?.modelInvocationId == modelInvocationId) {
      return true;
    }
    _selection = ActivityInspectionSelection(
      sessionId: session.id,
      runId: activity.runId,
      modelInvocationId: modelInvocationId,
    );
    notifyListeners();
    return true;
  }

  void clear() {
    if (_selection == null) return;
    _selection = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _session = null;
    _selection = null;
    super.dispose();
  }
}
