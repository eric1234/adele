import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../core/product_lifecycle.dart';
import '../terminal/environment_terminal_owner.dart';
import '../terminal/terminal_console_content.dart';
import 'environment_terminal_bridge.dart';
import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

/// Prepared operations admit content; presentations never own that content's
/// resource or retained policy. No evaluator callback survives an operation.
final class PreparedConsoleHost {
  PreparedConsoleHost({required this.store, required this.terminals});

  final InMemoryProductStore store;
  final EnvironmentTerminalCoordinator terminals;
  bool _closed = false;
  int _terminalSequence = 0;

  /// Passive canonical lookup, deliberately not the Task's primary Environment.
  Environment? environmentForSession(Session session) {
    if (_closed || !identical(store.session(session.id), session)) return null;
    final task = store.task(session.taskId);
    final authority = store.sessionAuthority(session.id);
    if (task == null ||
        store.project(task.projectId) == null ||
        authority == null ||
        authority.sessionId != session.id ||
        authority.taskId != task.id) {
      return null;
    }
    final environment = store.environment(authority.environmentId);
    return environment != null && environment.taskId == task.id
        ? environment
        : null;
  }

  ConsoleContribution createContribution({
    required PreparedFrontend generation,
    required PreparedConsolePresentation descriptor,
    required bool Function() isActive,
  }) => ConsoleContribution(
    actions: [
      for (final action in descriptor.actions)
        ConsoleCreationAction(
          id: action.id,
          label: action.label,
          create: (access) async {
            if (_closed || !access.isActive || !isActive()) {
              throw StateError('Console creation is unavailable.');
            }
            // Capture scope before the evaluator or provider can await. Once
            // admitted, navigation must not retarget or orphan the result.
            final environment = environmentForSession(access.session);
            await generation.invoke<void>(
              library: descriptor.library,
              entrypoint: action.entrypoint,
              createBridge: () => EnvironmentTerminalBridge(
                isActive: () => !_closed && access.isActive && isActive(),
                create: (policy) async {
                  if (environment == null ||
                      environmentForSession(access.session)?.id !=
                          environment.id) {
                    throw StateError('Session Environment is unavailable.');
                  }
                  await TerminalConsoleContent.open(
                    coordinator: terminals,
                    environmentId: environment.id,
                    access: access,
                    policy: policy,
                    fallbackTitle: '${policy.label} ${++_terminalSequence}',
                    generation: generation,
                    descriptor: descriptor,
                    isActive: () => !_closed && isActive(),
                    isEligible: (session) =>
                        environmentForSession(session)?.id == environment.id,
                  );
                },
              ),
              decodeResult: (value) {
                final result = copyStructuredBridgeData(value);
                if (result is! List ||
                    result.length != 2 ||
                    result[0] != true ||
                    result[1] != null) {
                  throw StateError('Console action did not complete.');
                }
              },
            );
          },
        ),
    ],
  );

  Future<void> close() async => _closed = true;
}
