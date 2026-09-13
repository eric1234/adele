import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/read_only_tool_policy.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
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
  late ExtensionRegistry extensions;
  late ChatStrategyPlugin chat;
  late OrchestrationTestLifecycle topology;
  late Session session;
  late ToolExecutionContext context;
  late ToolCatalog catalog;

  setUp(() async {
    extensions = ExtensionRegistry();
    chat = ChatStrategyPlugin();
    addTearDown(chat.activate(extensions).close);
    addTearDown(const FilesystemToolsPlugin().activate(extensions).close);
    addTearDown(const SearchToolsPlugin().activate(extensions).close);
    addTearDown(const CommandToolsPlugin().activate(extensions).close);
    topology = await OrchestrationTestLifecycle.create(
      extensions,
      SessionId('read-only-session'),
    );
    session = topology.createSession(chatStrategyId);
    context = ToolExecutionContext(
      runId: RunId('read-only-run'),
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
      final ToolInvocation invocation = _resolve(
        catalog.materialize(),
        context,
        entry.key,
        _stockArguments[entry.key]!,
      );
      final ToolPolicyGateResult result = await const ToolPolicyGate().evaluate(
        invocation: invocation,
        policy: const ReadOnlyToolPolicy(),
        interruptionId: RunInterruptionId('unused-approval'),
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
        expect(result, isA<ToolExecutionDenied>());
        final ToolOutcome outcome = (result as ToolExecutionDenied).outcome;
        expect(outcome.disposition, ToolOutcomeDisposition.policyDenied);
        expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
      }
    });
  }

  test('only certain source reads pass for every effect set and alias', () {
    final MaterializedTool read = catalog.materialize().byAlias('read_file')!;
    for (final String alias in <String>[
      'read_file',
      'search',
      'run_command',
      'unfamiliar_alias',
    ]) {
      final ToolInvocation invocation = _resolve(
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
        for (final EffectUncertainty uncertainty in EffectUncertainty.values) {
          final ToolPolicyDecision decision = const ReadOnlyToolPolicy()
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
          expect(
            decision,
            certainRead ? ToolPolicyDecision.allow : ToolPolicyDecision.deny,
            reason: '$alias: $effects, $uncertainty',
          );
        }
      }
    }
  });

  test(
    'Chat continues all stock denials without execution or approval',
    () async {
      final List<_CountingExecutable> executables = <_CountingExecutable>[];
      for (final MaterializedTool tool in catalog.materialize().tools) {
        final _CountingExecutable executable = _CountingExecutable(
          tool.executable,
        );
        executables.add(executable);
        catalog.register(
          ToolRegistration(
            definition: tool.definition,
            modelDefinition: tool.modelDefinition,
            executable: executable,
          ),
        );
      }
      final List<ProviderToolProposal> proposals = <ProviderToolProposal>[
        for (final String alias in <String>[
          'apply_patch',
          'create_file',
          'delete_file',
          'run_command',
        ])
          ProviderToolProposal(
            providerCallId: 'call-$alias',
            alias: alias,
            arguments: _stockArguments[alias]!,
          ),
      ];
      final _ProposingModel model = _ProposingModel(proposals);
      final ChatSessionState history = chat.sessions.obtain(session.id)
        ..maxModelInvocations = 2
        ..append(ChatUserMessage('Attempt the proposed operations.'));
      final SessionOrchestrationRun execution = createSessionOrchestrationRun(
        lifecycle: topology.lifecycle,
        sessionId: session.id,
        runId: context.runId,
        contextComposer: InferenceContextComposer(extensions),
        model: model,
        toolCatalog: catalog,
        policy: const ReadOnlyToolPolicy(),
      );

      await execution.start();

      expect(execution.run.state, RunState.completed);
      expect(
        executables.map((executable) => executable.executions),
        everyElement(0),
      );
      expect(model.requests, hasLength(2));
      final Iterable<ExecutionEvent> events = execution.run.journal.records.map(
        (record) => record.event,
      );
      expect(events.whereType<ToolExecutionStarted>(), isEmpty);
      expect(events.whereType<ToolExecutionCompleted>(), isEmpty);
      expect(events.whereType<ToolProgressObserved>(), isEmpty);
      expect(events.whereType<RunInterrupted>(), isEmpty);
      expect(events.whereType<RunInterruptionResolved>(), isEmpty);
      expect(events.whereType<ToolInvocationPrepared>(), hasLength(4));
      final List<ToolPolicyEvaluated> decisions = events
          .whereType<ToolPolicyEvaluated>()
          .toList();
      expect(decisions, hasLength(4));
      expect(
        decisions.map((event) => event.decision),
        everyElement(ToolPolicyDecision.deny),
      );
      final List<ToolInvocationCompleted> completions = events
          .whereType<ToolInvocationCompleted>()
          .toList();
      expect(completions, hasLength(4));
      final SemanticModelRequest continuation = model.requests.last;
      expect(
        continuation.input.whereType<SemanticToolProposalInput>().map(
          (item) => item.proposal,
        ),
        orderedEquals(proposals),
      );
      final List<SemanticToolOutcomeInput> outcomes = continuation.input
          .whereType<SemanticToolOutcomeInput>()
          .toList();
      expect(outcomes, hasLength(4));
      for (int index = 0; index < outcomes.length; index++) {
        final SemanticToolOutcomeInput item = outcomes[index];
        expect(item.providerCallId, proposals[index].providerCallId);
        expect(item.outcome, same(completions[index].outcome));
        expect(item.outcome.disposition, ToolOutcomeDisposition.policyDenied);
        expect(item.outcome.effectCertainty, EffectCertainty.knownNotOccurred);
        expect(item.outcome.modelContent, 'Tool invocation denied by policy.');
      }
      expect(history.snapshot().entries.map((entry) => entry.content), <String>[
        'Attempt the proposed operations.',
        'The operations were denied.',
      ]);
    },
  );
}

ToolInvocation _resolve(
  MaterializedToolSet tools,
  ToolExecutionContext context,
  String alias,
  Map<String, Object?> arguments,
) {
  final ToolProposalResolution resolution = const ToolInvocationResolver()
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

final class _CountingExecutable implements ToolExecutable {
  _CountingExecutable(this.delegate);

  final ToolExecutable delegate;
  int executions = 0;

  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) =>
      delegate.validateAndNormalize(arguments);

  @override
  void validateBinding() => delegate.validateBinding();

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) => delegate.describe(arguments, context);

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) {
    executions++;
    return delegate.execute(arguments, context);
  }
}

final class _ProposingModel implements ModelPort {
  _ProposingModel(this.proposals);

  final List<ProviderToolProposal> proposals;
  final List<SemanticModelRequest> requests = <SemanticModelRequest>[];

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    requests.add(request);
    if (requests.length == 1) {
      for (final ProviderToolProposal proposal in proposals) {
        yield ModelOutputItemCompleted(
          invocationId: request.invocationId,
          item: ModelToolProposalOutput(proposal),
        );
      }
    } else {
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelTextOutput('The operations were denied.'),
      );
    }
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.completed,
      metadata: ModelTerminalMetadata(effectiveModel: 'fixture'),
    );
  }
}
