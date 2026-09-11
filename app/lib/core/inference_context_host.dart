import 'package:adele_environment/adele_environment.dart'
    show AuthorizedEnvironmentFileReadFacet;
import 'package:adele_orchestration/adele_orchestration.dart';

import 'model_tool_host.dart';
import 'product_lifecycle.dart';

/// One inference's read services, scoped to the canonical Session's authority.
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
  Future<T> requireHostService<T extends Object>() async {
    // Context capture may inspect state, not acquire model-tool effect authority.
    if (T == AuthorizedEnvironmentFileReadFacet) {
      return _services.requireHostService<T>();
    }
    throw StateError('No inference context host service is registered for $T.');
  }
}
