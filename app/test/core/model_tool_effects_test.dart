import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_backend/chat_strategy_backend.dart';
import 'package:command_tools_contract/command_tools_contract.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';

import '../support/fixed_tool_policy.dart';
import '../support/orchestration_test_lifecycle.dart';

const Map<String, Map<String, Object?>> _stockArguments = {
  'read_file': {'relativePath': 'source.dart'},
  'search': {'pattern': 'needle'},
  'glob': {'pattern': '**/*.dart'},
  'apply_patch': {
    'relativePath': 'source.dart',
    'expectedRevision': 'observed-revision',
    'edits': [
      {'search': 'before', 'replace': 'after'},
    ],
  },
  'create_file': {'relativePath': 'new.dart', 'content': 'new source'},
  'delete_file': {
    'relativePath': 'source.dart',
    'expectedRevision': 'observed-revision',
  },
  'run_command': {
    'program': 'git',
    'arguments': ['diff', '--check'],
  },
};

void main() {
  late Session session;
  late ToolExecutionContext context;
  late ToolCatalog catalog;

  setUp(() async {
    final ExtensionRegistry extensions = ExtensionRegistry();
    final ChatStrategyPlugin chat = ChatStrategyPlugin(maxModelInvocations: 8);
    addTearDown(chat.activate(extensions).close);
    addTearDown(const FilesystemToolsPlugin().activate(extensions).close);
    addTearDown(const SearchToolsPlugin().activate(extensions).close);
    addTearDown(const CommandToolsPlugin().activate(extensions).close);
    final OrchestrationTestLifecycle topology =
        await OrchestrationTestLifecycle.create(
          extensions,
          SessionId('approval-gated-session'),
        );
    session = topology.createSession(chatStrategyId);
    context = ToolExecutionContext(
      runId: RunId('approval-gated-run'),
      sessionId: session.id,
      toolInvocationId: 'policy-invocation',
    );
    catalog = await buildModelToolCatalogForSession(
      sessionId: session.id,
      environmentRuntime: topology.lifecycle.environmentRuntime,
      extensions: extensions,
    );
  });

  for (final entry in <String, ToolEffect>{
    'read_file': ToolEffect.sourceRead,
    'search': ToolEffect.sourceRead,
    'glob': ToolEffect.sourceRead,
    'apply_patch': ToolEffect.sourceMutation,
    'create_file': ToolEffect.sourceMutation,
    'delete_file': ToolEffect.sourceMutation,
    'run_command': ToolEffect.processExecution,
  }.entries) {
    test('gate retains stock ${entry.key} described effects', () async {
      final ToolInvocation invocation = await _resolve(
        catalog.materialize(),
        context,
        entry.key,
        _stockArguments[entry.key]!,
      );
      final ToolPolicyGateResult result = await const ToolPolicyGate().evaluate(
        invocation: invocation,
        policy: const FixedToolPolicy(ToolPolicyDecision.ask),
        interruptionId: RunInterruptionId('approval-${entry.key}'),
      );

      expect(result.effects.effects, <ToolEffect>{entry.value});
      expect(
        result.effects.uncertainty,
        entry.value == ToolEffect.processExecution
            ? EffectUncertainty.uncertain
            : EffectUncertainty.none,
      );
      expect(result.effects.targets, hasLength(1));
      expect(
        result.effects.targets.single.uri.pathSegments,
        contains('environment-${session.id.value}'),
      );
      expect(result, isA<ToolApprovalRequired>());
      final interruption = (result as ToolApprovalRequired).interruption;
      expect(interruption.id, RunInterruptionId('approval-${entry.key}'));
      expect(interruption.invocation, same(invocation));
      expect(interruption.effects, same(result.effects));
    });
  }

  test(
    'retained output inspection describes its target without reading output',
    () async {
      catalog.register(
        searchCommandOutputToolRegistration(
          CommandOutputSearch(_UnreadCommandOutput()),
        ),
      );
      final invocation = await _resolve(
        catalog.materialize(),
        context,
        'search_command_output',
        {
          'runId': 'earlier-run',
          'toolInvocationId': 'earlier-invocation',
          'pattern': 'diagnostic',
        },
      );
      final effects = await invocation.tool.executable.describe(
        invocation.arguments,
        invocation.context,
      );
      expect(effects.effects, {ToolEffect.resourceInspection});
      expect(effects.uncertainty, EffectUncertainty.none);
      expect(effects.targets.single.uri.toString(), contains('earlier-run'));
      expect(
        effects.targets.single.uri.toString(),
        contains('earlier-invocation'),
      );
      expect(effects.targets.single.uri.scheme, isNot('adele-environment'));
    },
  );
}

final class _UnreadCommandOutput implements CommandOutputService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Policy description must not read command output.');
}

Future<ToolInvocation> _resolve(
  MaterializedToolSet tools,
  ToolExecutionContext context,
  String alias,
  Map<String, Object?> arguments,
) async {
  final ToolProposalResolution resolution = await const ToolInvocationResolver()
      .resolve(
        invocationId: ToolInvocationId('invocation-$alias'),
        proposal: ProviderToolProposal(
          providerCallId: 'call-$alias',
          alias: alias,
          arguments: arguments,
        ),
        tools: tools,
        runId: context.runId,
        sessionId: context.sessionId,
      );
  expect(resolution, isA<ResolvedToolProposal>());
  return (resolution as ResolvedToolProposal).invocation;
}
