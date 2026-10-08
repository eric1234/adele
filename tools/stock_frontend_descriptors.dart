/// Build-time stock presentation metadata, keyed by owning PluginId.
/// Keep this SDK-only so the launcher and prepared-installation fixtures share it.
const Map<String, List<Map<String, Object?>>> stockFrontendDescriptors = {
  'dev.adele.source-editor': [
    {
      'role': 'mainContent',
      'extensionId': 'dev.adele.source-editor.main-content',
      'library': 'package:source_editor_frontend/main.dart',
      'initialize': 'initializeSource',
      'entrypoint': 'sourcePane',
      'order': 300,
      'actions': [
        {
          'id': 'open',
          'label': 'Open Source...',
          'entrypoint': 'openSourceInput',
        },
      ],
      'operations': {
        'display': 'displaySource',
        'save': 'saveSource',
        'close': 'closeSource',
        'exit': 'closeSources',
      },
      'closeOperation': 'close',
      'exitOperation': 'exit',
      'displaySourceFileOperation': 'display',
      'retainedData': true,
      'nativeCodeEditor': true,
      'environmentTextFiles': true,
    },
  ],
  'dev.adele.plugin.terminal': [
    {
      'role': 'console',
      'extensionId': 'dev.adele.plugin.terminal.console',
      'library': 'package:terminal_frontend/terminal_frontend.dart',
      'entrypoint': 'buildTerminal',
      'actions': [
        {
          'id': 'new-terminal',
          'label': 'New Terminal',
          'entrypoint': 'newTerminal',
        },
      ],
    },
  ],
  'dev.adele.plugin.task-browser': [
    {
      'role': 'taskBrowser',
      'library': 'package:task_browser_frontend/task_browser_frontend.dart',
      'extensionId': 'dev.adele.plugin.task-browser.task-browser',
      'displayName': 'Task Browser',
      'entrypoint': 'createTaskBrowser',
    },
  ],
  'dev.adele.plugin.chat-strategy': [
    {
      'role': 'mainContent',
      'library': 'package:chat_strategy_frontend/chat_strategy_frontend.dart',
      'extensionId': 'dev.adele.plugin.chat-strategy.presentation',
      'order': 100,
      'initialize': 'initializeChatMainContent',
      'entrypoint': 'buildChat',
      'sessionExecution': true,
      'backendServices': ['chat.session'],
      'strategyAffinity': 'owningBackend',
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
      'backendServices': ['command.output'],
      'consoleExtensions': ['dev.adele.plugin.command-tools.output'],
    },
    {
      'role': 'console',
      'extensionId': 'dev.adele.plugin.command-tools.output',
      'library': 'package:command_tools_frontend/command_output_view.dart',
      'entrypoint': 'buildRunCommandOutput',
      'readOnly': true,
      'keepAlive': true,
      'backendServices': ['command.output'],
      'actions': [],
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

/// Build-time non-presentation extension metadata, keyed by owning PluginId.
const Map<String, List<Map<String, Object?>>>
stockFrontendExtensionDescriptors = {
  'dev.adele.source-editor': [
    {
      'kind': 'mainContentActionCommand',
      'extensionId': 'dev.adele.source-editor.command.open-source',
      'commandId': 'dev.adele.source-editor.open-source',
      'mainContentExtensionId': 'dev.adele.source-editor.main-content',
      'actionId': 'open',
    },
  ],
  'dev.adele.plugin.terminal': [
    {
      'kind': 'consoleActionCommand',
      'extensionId': 'dev.adele.plugin.terminal.command.new-terminal',
      'commandId': 'dev.adele.plugin.terminal.new-terminal',
      'consoleExtensionId': 'dev.adele.plugin.terminal.console',
      'actionId': 'new-terminal',
    },
  ],
  'dev.adele.plugin.local-directory-project': [
    {
      'kind': 'projectSelector',
      'extensionId':
          'dev.adele.plugin.local-directory-project.project-selector',
      'projectProviderId': 'dev.adele.project.local-directory',
      'displayName': 'Open Local Directory...',
      'library':
          'package:local_directory_project_frontend/local_directory_project_frontend.dart',
      'entrypoint': 'selectProject',
    },
  ],
};
