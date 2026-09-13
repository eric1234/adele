import 'package:adele_desktop/ui/chat/chat_controller.dart';
import 'package:adele_desktop/ui/execution/run_execution_status.dart';
import 'package:flutter/widgets.dart';

/// Provisional controller adapter; the common approval UI receives no Chat data.
final class StockChatExecutionStatus extends StatelessWidget {
  const StockChatExecutionStatus({super.key, required this.controller});

  final ChatController controller;

  @override
  Widget build(BuildContext context) => RunExecutionStatus(
    pendingApproval: controller.pendingApproval,
    enabled: !controller.isAdvancing && !controller.isClosed,
    isAdvancing: controller.isAdvancing,
    failureMessage: controller.failureMessage,
    unavailableReason: controller.unavailableReason,
    onDecision: (approval, approved) =>
        controller.resolveApproval(approval, approved: approved),
  );
}
