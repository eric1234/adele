import 'package:adele_orchestration/adele_orchestration.dart';

import 'model_tool_host.dart';
import 'product_lifecycle.dart';

/// One inference's services, scoped to the canonical Session's authority.
final class SessionInferenceContextSourceContext
    implements InferenceContextSourceContext {
  SessionInferenceContextSourceContext({
    required this.session,
    required this.runId,
    required EnvironmentRuntime environmentRuntime,
  }) : _services = SessionModelToolHostContext(
         sessionId: session.id,
         environmentRuntime: environmentRuntime,
       ) {
    if (!identical(environmentRuntime.store.session(session.id), session)) {
      throw ArgumentError('Context sources require the canonical Session.');
    }
  }

  @override
  final Session session;

  @override
  final RunId runId;

  final SessionModelToolHostContext _services;

  @override
  Future<T> requireHostService<T extends Object>() =>
      _services.requireHostService<T>();
}
