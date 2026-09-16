/// Build-time stock presentation metadata, keyed by owning PluginId.
/// Keep this SDK-only so the launcher and prepared-installation fixtures share it.
const Map<String, List<Map<String, Object?>>> stockFrontendDescriptors = {
  'dev.adele.plugin.chat-strategy': [
    {
      'role': 'session',
      'library': 'package:chat_strategy_frontend/chat_strategy_frontend.dart',
      'extensionId': 'dev.adele.plugin.chat-strategy.presentation',
      'strategyId': 'dev.adele.strategy.chat',
      'entrypoint': 'buildChat',
      'hostAdapter': 'stock-chat-controller-v1',
    },
  ],
  'dev.adele.plugin.filesystem-tools': [
    {
      'role': 'toolActivity',
      'library':
          'package:filesystem_tools_frontend/filesystem_tools_frontend.dart',
      'inspectionExtensionId': 'dev.adele.plugin.filesystem-tools.inspection',
      'compactExtensionId': 'dev.adele.plugin.filesystem-tools.compact',
      'toolId': 'dev.adele.plugin.filesystem-tools.apply-patch',
      'inspectionEntrypoint': 'buildApplyPatchInspection',
      'compactEntrypoint': 'buildApplyPatchCompact',
    },
  ],
  'dev.adele.plugin.command-tools': [
    {
      'role': 'toolActivity',
      'library': 'package:command_tools_frontend/command_tools_frontend.dart',
      'inspectionExtensionId': 'dev.adele.plugin.command-tools.inspection',
      'compactExtensionId': 'dev.adele.plugin.command-tools.compact',
      'toolId': 'dev.adele.plugin.command-tools.run-command',
      'inspectionEntrypoint': 'buildRunCommandInspection',
      'compactEntrypoint': 'buildRunCommandCompact',
    },
  ],
  'dev.adele.openai': [
    {
      'role': 'modelNativeActivity',
      'library': 'package:openai_frontend/openai_frontend.dart',
      'inspectionExtensionId': 'dev.adele.plugin.openai.activity-presentation',
      'compactExtensionId': 'dev.adele.plugin.openai.activity-compact',
      'presentationKind': 'openai.responses.reasoning-summary.v1',
      'inspectionEntrypoint': 'buildOpenAiReasoningInspection',
      'compactEntrypoint': 'buildOpenAiReasoningCompact',
    },
  ],
};
