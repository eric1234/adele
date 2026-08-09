import 'package:test/test.dart';
import 'package:tool_semantics_experiment/tool_semantics.dart';

const RunContext context = RunContext(
  runId: 'run-1',
  sessionId: 'session-1',
  agentId: 'agent-1',
  workflowId: 'workflow-1',
  workspaceId: 'workspace-1',
  environmentId: 'environment-1',
);

void main() {
  group('six representative lifecycle traces', () {
    test(
      'read_file separates semantic identity, model name, and resource data',
      () async {
        final ToolCatalog catalog = ToolCatalog()..register(readFileTool());
        final MaterializedToolSet snapshot = catalog.materialize(<ToolId>[
          readFileId,
        ]);

        expect(
          snapshot.tools.single.definition.id.value,
          contains('read-file'),
        );
        expect(snapshot.tools.single.modelDefinition.name, 'read_file');
        final InvocationTerminal terminal = await _runAllowed(
          snapshot,
          ProviderToolCall(
            callId: 'provider-1',
            name: 'read_file',
            arguments: <String, Object?>{
              'uri': 'workspace:///lib/a.dart',
              'version': 'sha256:abc',
            },
          ),
        );

        expect(terminal.outcome.kind, OutcomeKind.success);
        expect(terminal.outcome.content!.model.single, isA<ResourceBlock>());
        expect(
          terminal.outcome.content!.data['resource'],
          isA<Map<String, Object?>>(),
        );
        expect(
          terminal.invocation.effects!.targets.single.version,
          'sha256:abc',
        );
      },
    );

    test(
      'search_text keeps structured matches and truncation outside prose',
      () async {
        final ToolCatalog catalog = ToolCatalog()..register(searchTextTool());
        final InvocationTerminal terminal = await _runAllowed(
          catalog.materialize(<ToolId>[searchTextId]),
          ProviderToolCall(
            callId: 'provider-2',
            name: 'search_text',
            arguments: <String, Object?>{'query': 'needle'},
          ),
        );

        expect(terminal.invocation.progress, hasLength(1));
        expect(terminal.outcome.content!.data['matches'], isA<List<Object?>>());
        expect(terminal.outcome.content!.truncation!.total, 37);
      },
    );

    test(
      'apply_patch approval binds identity, arguments, effects, and generation',
      () async {
        final ToolCatalog catalog = ToolCatalog()..register(applyPatchTool());
        final MaterializedToolSet snapshot = catalog.materialize(<ToolId>[
          applyPatchId,
        ]);
        final ToolLifecycle lifecycle = ToolLifecycle(
          policy: const AllowReadApproveEffectsPolicy(),
        );
        final Object proposed = await lifecycle.propose(
          tools: snapshot,
          call: ProviderToolCall(
            callId: 'provider-3',
            name: 'apply_patch',
            arguments: <String, Object?>{
              'patch': '*** patch',
              'baseVersion': 'workspace-v12',
            },
          ),
          context: context,
        );

        expect(proposed, isA<InvocationInterrupted>());
        final InvocationInterrupted interrupted =
            proposed as InvocationInterrupted;
        expect(interrupted.interruption.bindingId.generation, 7);
        expect(interrupted.interruption.argumentsDigest, isNotEmpty);
        expect(
          interrupted.interruption.effects.targets.single.version,
          'workspace-v12',
        );

        snapshot.tools.single.binding.invalidate();
        final InvocationTerminal stale = await lifecycle.decide(
          invocation: interrupted.invocation,
          decision: ApprovalDecision(
            interruption: interrupted.interruption,
            approved: true,
          ),
          context: context,
        );
        expect(stale.outcome.kind, OutcomeKind.staleBinding);
      },
    );

    test(
      'run_command streams progress and cancellation may follow effects',
      () async {
        final ToolCatalog catalog = ToolCatalog()..register(runCommandTool());
        final MaterializedToolSet snapshot = catalog.materialize(<ToolId>[
          runCommandId,
        ]);
        final ToolLifecycle lifecycle = ToolLifecycle(
          policy: const AllowReadApproveEffectsPolicy(),
        );
        final InvocationInterrupted proposed =
            await lifecycle.propose(
                  tools: snapshot,
                  call: ProviderToolCall(
                    callId: 'provider-4',
                    name: 'run_command',
                    arguments: <String, Object?>{
                      'command': 'dart test',
                      'cwd': '.',
                    },
                  ),
                  context: context,
                )
                as InvocationInterrupted;
        final InvocationTerminal terminal = await lifecycle.decide(
          invocation: proposed.invocation,
          decision: ApprovalDecision(
            interruption: proposed.interruption,
            approved: true,
          ),
          context: context,
        );

        expect(
          terminal.invocation.progress.map((ToolProgress p) => p.kind),
          <ProgressKind>[ProgressKind.stdout, ProgressKind.stderr],
        );
        expect(terminal.outcome.kind, OutcomeKind.cancelled);
        expect(terminal.outcome.effectMayHaveOccurred, isTrue);
      },
    );

    test(
      'start_process returns a resource owned beyond the invocation',
      () async {
        final ToolCatalog catalog = ToolCatalog()..register(startProcessTool());
        final ToolLifecycle lifecycle = ToolLifecycle(
          policy: const AllowReadApproveEffectsPolicy(),
        );
        final InvocationInterrupted proposed =
            await lifecycle.propose(
                  tools: catalog.materialize(<ToolId>[startProcessId]),
                  call: ProviderToolCall(
                    callId: 'provider-5',
                    name: 'start_process',
                    arguments: <String, Object?>{'command': 'server'},
                  ),
                  context: context,
                )
                as InvocationInterrupted;
        final InvocationTerminal terminal = await lifecycle.decide(
          invocation: proposed.invocation,
          decision: ApprovalDecision(
            interruption: proposed.interruption,
            approved: true,
          ),
          context: context,
        );

        final RuntimeResourceRef resource =
            terminal.outcome.content!.resources.single;
        expect(resource.kind, 'process');
        expect(resource.owner, 'execution-environment');
        expect(resource.environmentId, context.environmentId);
      },
    );

    test('dynamic MCP removal invalidates retained snapshot binding', () async {
      const ToolId mcpId = ToolId('mcp://server-42/tools/weather.lookup');
      final ToolCatalog catalog = ToolCatalog()
        ..register(mcpTool(generation: 11));
      final MaterializedToolSet oldSnapshot = catalog.materialize(<ToolId>[
        mcpId,
      ]);
      expect(
        oldSnapshot.tools.single.modelDefinition.name,
        'server_42__weather_lookup',
      );
      expect(oldSnapshot.tools.single.definition.id, isNot(mcpId.value));

      catalog.remove(mcpId);
      expect(catalog.isAvailable(mcpId), isFalse);
      final ToolLifecycle lifecycle = ToolLifecycle(
        policy: const AllowReadApproveEffectsPolicy(),
      );
      final InvocationInterrupted oldProposal =
          await lifecycle.propose(
                tools: oldSnapshot,
                call: ProviderToolCall(
                  callId: 'provider-6',
                  name: 'server_42__weather_lookup',
                  arguments: <String, Object?>{'city': 'Raleigh'},
                ),
                context: context,
              )
              as InvocationInterrupted;
      final InvocationTerminal stale = await lifecycle.decide(
        invocation: oldProposal.invocation,
        decision: ApprovalDecision(
          interruption: oldProposal.interruption,
          approved: true,
        ),
        context: context,
      );
      expect(stale.outcome.kind, OutcomeKind.staleBinding);

      catalog.register(mcpTool(generation: 12));
      final MaterializedToolSet replacement = catalog.materialize(<ToolId>[
        mcpId,
      ]);
      expect(replacement.tools.single.binding.id.generation, 12);
      expect(oldSnapshot.tools.single.binding.id.generation, 11);
    });
  });

  test(
    'central lifecycle returns generic structured content without casts',
    () async {
      final ToolCatalog catalog = ToolCatalog()
        ..register(readFileTool())
        ..register(searchTextTool());
      for (final ({ToolId id, String name, Map<String, Object?> arguments})
          caseData
          in <({ToolId id, String name, Map<String, Object?> arguments})>[
            (
              id: readFileId,
              name: 'read_file',
              arguments: <String, Object?>{'uri': 'workspace:///a'},
            ),
            (
              id: searchTextId,
              name: 'search_text',
              arguments: <String, Object?>{'query': 'x'},
            ),
          ]) {
        final InvocationTerminal terminal = await _runAllowed(
          catalog.materialize(<ToolId>[caseData.id]),
          ProviderToolCall(
            callId: caseData.name,
            name: caseData.name,
            arguments: caseData.arguments,
          ),
        );
        final ModelContinuation continuation = ModelContinuation(
          providerCallId: terminal.invocation.providerCallId,
          outcome: terminal.outcome,
        );
        expect(continuation.content, isNotEmpty);
        expect(terminal.outcome.content!.data, isNotEmpty);
      }
    },
  );

  test('invalid arguments are terminal model-visible outcomes', () async {
    final ToolCatalog catalog = ToolCatalog()..register(readFileTool());
    final Object result =
        await ToolLifecycle(
          policy: const AllowReadApproveEffectsPolicy(),
        ).propose(
          tools: catalog.materialize(<ToolId>[readFileId]),
          call: ProviderToolCall(
            callId: 'bad-call',
            name: 'read_file',
            arguments: <String, Object?>{},
          ),
          context: context,
        );

    expect(
      (result as InvocationTerminal).outcome.kind,
      OutcomeKind.invalidArguments,
    );
  });
}

Future<InvocationTerminal> _runAllowed(
  MaterializedToolSet tools,
  ProviderToolCall call,
) async {
  final ToolLifecycle lifecycle = ToolLifecycle(
    policy: const AllowReadApproveEffectsPolicy(),
  );
  final Object proposed = await lifecycle.propose(
    tools: tools,
    call: call,
    context: context,
  );
  expect(proposed, isA<InvocationPrepared>());
  return lifecycle.execute(
    invocation: (proposed as InvocationPrepared).invocation,
    context: context,
  );
}
