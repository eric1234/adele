const String codegenEntrypoint =
    'packages/contract_codegen/bin/contract_codegen.dart';
const String workerEntrypoint = 'tools/desktop_build_inputs_worker.dart';
const toolStages = {
  'contract-codegen-compilation': codegenEntrypoint,
  'desktop-inputs-compilation': workerEntrypoint,
};
List<String> get toolCompilationEvents => [
  for (final entrypoint in [codegenEntrypoint, workerEntrypoint]) ...[
    'compile|$entrypoint',
    'compiled|$entrypoint',
  ],
];
const generatorSource = 'packages/contract_codegen/lib/generator.dart';
const analyzerSource =
    r'external packages/analyzer/custom lib/escaped\ file.dart';
const yamlSource = 'external packages/yaml/lib/yaml.dart';
const transitiveSource = 'external packages/collection/lib/collection.dart';
const unusedDevSource = 'external packages/unused_test/lib/test.dart';
const String hostEntrypoint =
    'packages/plugin_backend_host/bin/adele_backend_host.dart';
const String gitEntrypoint =
    'plugins/git/packages/backend/bin/git_backend.dart';
const String openaiEntrypoint =
    'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart';
const modelPresetSchema = 'plugins/model_configuration/records.schema.json';
const stockInstallationDirectories = [
  'agent-configuration',
  'model-configuration',
  'git',
  'openai',
  'agents-md',
  'conservative-tool-policy',
  'search-tools',
  'chat-strategy',
  'filesystem-tools',
  'command-tools',
  'local-directory-project',
  'task-browser',
  'terminal',
  'source-editor',
  'diff-viewer',
  'session-evaluator',
];
const String agentsMdEntrypoint =
    'plugins/agents_md/packages/backend/bin/agents_md_backend.dart';
const String agentConfigurationEntrypoint =
    'plugins/agent_configuration/packages/backend/bin/agent_configuration_backend.dart';
const String modelConfigurationEntrypoint =
    'plugins/model_configuration/packages/backend/bin/model_configuration_backend.dart';
const String conservativeToolPolicyEntrypoint =
    'plugins/conservative_tool_policy/packages/backend/bin/conservative_tool_policy_backend.dart';
const String searchToolsEntrypoint =
    'plugins/search_tools/packages/backend/bin/search_tools_backend.dart';
const String filesystemToolsEntrypoint =
    'plugins/filesystem_tools/packages/backend/bin/filesystem_tools_backend.dart';
const String commandToolsEntrypoint =
    'plugins/command_tools/packages/backend/bin/command_tools_backend.dart';
const String chatEntrypoint =
    'plugins/chat_strategy/packages/backend/bin/chat_strategy_backend.dart';
const String localDirectoryProjectEntrypoint =
    'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart';
const String sessionEvaluatorEntrypoint =
    'plugins/session_evaluator/packages/backend/bin/session_evaluator_backend.dart';
const String diffViewerEntrypoint =
    'plugins/diff_viewer/packages/backend/bin/diff_viewer_backend.dart';
const backendEntrypoints = [
  hostEntrypoint,
  gitEntrypoint,
  openaiEntrypoint,
  agentsMdEntrypoint,
  agentConfigurationEntrypoint,
  modelConfigurationEntrypoint,
  conservativeToolPolicyEntrypoint,
  searchToolsEntrypoint,
  filesystemToolsEntrypoint,
  commandToolsEntrypoint,
  chatEntrypoint,
  localDirectoryProjectEntrypoint,
  sessionEvaluatorEntrypoint,
  diffViewerEntrypoint,
];
const String frontendHarness = 'tool/compile_chat_frontend.dart';
const String toolFrontendHarness =
    'tool/compile_tool_inspection_frontends.dart';
const String openaiFrontendHarness =
    'tool/compile_openai_activity_frontend.dart';
const String agentConfigurationFrontendHarness =
    'tool/compile_agent_configuration_frontend.dart';
const String modelConfigurationFrontendHarness =
    'tool/compile_model_configuration_frontend.dart';
const String sessionEvaluatorFrontendHarness =
    'tool/compile_session_evaluator_frontend.dart';
const String localDirectoryProjectFrontendHarness =
    'tool/compile_local_directory_project_frontend.dart';
const String taskBrowserFrontendHarness =
    'tool/compile_task_browser_frontend.dart';
const String terminalFrontendHarness = 'tool/compile_terminal_frontend.dart';
const String sourceEditorFrontendHarness =
    'tool/compile_source_editor_frontend.dart';
const String diffViewerFrontendHarness =
    'tool/compile_diff_viewer_frontend.dart';
const backendStages = {
  'backend-host-compilation': hostEntrypoint,
  'git-compilation': gitEntrypoint,
  'openai-compilation': openaiEntrypoint,
  'agents-md-compilation': agentsMdEntrypoint,
  'agent-configuration-compilation': agentConfigurationEntrypoint,
  'model-configuration-compilation': modelConfigurationEntrypoint,
  'conservative-tool-policy-compilation': conservativeToolPolicyEntrypoint,
  'search-tools-compilation': searchToolsEntrypoint,
  'filesystem-tools-compilation': filesystemToolsEntrypoint,
  'command-tools-compilation': commandToolsEntrypoint,
  'chat-strategy-compilation': chatEntrypoint,
  'local-directory-project-compilation': localDirectoryProjectEntrypoint,
  'session-evaluator-compilation': sessionEvaluatorEntrypoint,
  'diff-viewer-compilation': diffViewerEntrypoint,
};
const frontendCompilations = {
  'chat': frontendHarness,
  'filesystem': '$toolFrontendHarness|filesystem',
  'command': '$toolFrontendHarness|command',
  'openai': openaiFrontendHarness,
  'agent-configuration': agentConfigurationFrontendHarness,
  'model-configuration': modelConfigurationFrontendHarness,
  'session-evaluator': sessionEvaluatorFrontendHarness,
  'local-directory-project': localDirectoryProjectFrontendHarness,
  'task-browser': taskBrowserFrontendHarness,
  'terminal': terminalFrontendHarness,
  'source-editor': sourceEditorFrontendHarness,
  'diff-viewer': diffViewerFrontendHarness,
};
const sharedSource = 'packages/plugin_api/lib/shared.dart';
const frontendBridge = 'packages/ui/lib/fixture_bridge.dart';
const chatSource =
    'plugins/chat_strategy/packages/frontend/lib/chat_strategy_frontend.dart';
const chatCompiler = 'app/tool/chat_frontend_compiler.dart';
const nativeSource = 'plugins/git/packages/backend/native/git_pty_helper.c';
const nativeHeader = 'native/include/fixture.h';
