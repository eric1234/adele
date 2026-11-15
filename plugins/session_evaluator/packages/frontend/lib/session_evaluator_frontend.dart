import 'package:adele_ui/command_bridge.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';

import 'src/read_prepared_handoff.dart';

Future<void> prepareEvaluationHandoff(String sessionId) async {
  final client = SessionEvaluationHandoffServiceClient(
    const OwningBackendRequestChannel(sessionEvaluationHandoffServiceId),
  );
  final result = await settleOwningBackendOperation(
    readPreparedHandoff(client.prepareSession(sessionId)),
  );
  if (result[0] != true) {
    showCommandFeedback('The evaluation handoff could not be prepared.');
    return;
  }
  final path = result[1] as String;
  if (await writeCommandClipboard(path)) {
    showCommandFeedback('Evaluation handoff README path copied to clipboard.');
  } else {
    showCommandFeedback(
      'Handoff prepared, but the path could not be copied:\n$path',
    );
  }
}
