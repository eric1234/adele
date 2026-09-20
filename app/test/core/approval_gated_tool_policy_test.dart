import 'package:adele_desktop/core/approval_gated_tool_policy.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_backend/chat_strategy_backend.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';

import '../support/orchestration_test_lifecycle.dart';

const Map<String, Map<String, Object?>> _stockArguments = {
  'read_file': {'relativePath': 'source.dart'},
  'search': {'query': 'needle'},
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
    final ChatStrategyPlugin chat = ChatStrategyPlugin();
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
    'apply_patch': ToolEffect.sourceMutation,
    'create_file': ToolEffect.sourceMutation,
    'delete_file': ToolEffect.sourceMutation,
    'run_command': ToolEffect.processExecution,
  }.entries) {
    test('evaluates stock ${entry.key} described effects', () async {
      final ToolInvocation invocation = await _resolve(
        catalog.materialize(),
        context,
        entry.key,
        _stockArguments[entry.key]!,
      );
      final ToolPolicyGateResult result = await const ToolPolicyGate().evaluate(
        invocation: invocation,
        policy: const ApprovalGatedToolPolicy(),
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
      if (entry.value == ToolEffect.sourceRead) {
        expect(result, isA<ToolExecutionAllowed>());
      } else {
        expect(result, isA<ToolApprovalRequired>());
        final ToolApprovalInterruption interruption =
            (result as ToolApprovalRequired).interruption;
        expect(interruption.id, RunInterruptionId('approval-${entry.key}'));
        expect(interruption.invocation, same(invocation));
        expect(interruption.effects, same(result.effects));
      }
    });
  }

  test(
    'evaluates every effect set and uncertainty without alias authority',
    () async {
      final MaterializedTool read = catalog.materialize().byAlias('read_file')!;
      for (final String alias in <String>[
        ..._stockArguments.keys,
        'unfamiliar_alias',
      ]) {
        final ToolInvocation invocation = await _resolve(
          MaterializedToolSet(<MaterializedTool>[
            MaterializedTool(
              definition: read.definition,
              modelDefinition: ModelToolDefinition(
                alias: alias,
                description: read.modelDefinition.description,
                argumentsSchema: read.modelDefinition.argumentsSchema,
              ),
              executable: read.executable,
            ),
          ]),
          context,
          alias,
          _stockArguments['read_file']!,
        );
        // Includes empty/unspecified effects, each other effect, and every mix.
        for (int mask = 0; mask < (1 << ToolEffect.values.length); mask++) {
          final List<ToolEffect> effects = <ToolEffect>[
            for (int index = 0; index < ToolEffect.values.length; index++)
              if (mask & (1 << index) != 0) ToolEffect.values[index],
          ];
          for (final EffectUncertainty uncertainty
              in EffectUncertainty.values) {
            final ToolPolicyDecision decision = const ApprovalGatedToolPolicy()
                .evaluate(
                  ToolPolicyInput(
                    invocation: invocation,
                    context: context,
                    effects: EffectDescription(
                      effects: effects,
                      targets: const <EffectTarget>[],
                      summary: 'Read only; this text is not policy authority.',
                      uncertainty: uncertainty,
                    ),
                  ),
                );
            final bool certainRead =
                mask == (1 << ToolEffect.sourceRead.index) &&
                uncertainty == EffectUncertainty.none;
            final bool certainMutation =
                mask == (1 << ToolEffect.sourceMutation.index) &&
                uncertainty == EffectUncertainty.none;
            final bool processExecution =
                mask == (1 << ToolEffect.processExecution.index);
            expect(
              decision,
              certainRead
                  ? ToolPolicyDecision.allow
                  : certainMutation || processExecution
                  ? ToolPolicyDecision.ask
                  : ToolPolicyDecision.deny,
              reason: '$alias: $effects, $uncertainty',
            );
          }
        }
      }
    },
  );
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
        context: context,
      );
  expect(resolution, isA<ResolvedToolProposal>());
  return (resolution as ResolvedToolProposal).invocation;
}
