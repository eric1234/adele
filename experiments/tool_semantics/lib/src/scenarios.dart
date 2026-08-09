import 'dart:async';

import 'model.dart';

final ToolId readFileId = ToolId('dev.adele.workspace.read-file/v1');
final ToolId searchTextId = ToolId('dev.adele.workspace.search-text/v1');
final ToolId applyPatchId = ToolId('dev.adele.workspace.apply-patch/v1');
final ToolId runCommandId = ToolId('dev.adele.environment.run-command/v1');
final ToolId startProcessId = ToolId('dev.adele.environment.start-process/v1');

ToolRegistration readFileTool() => _registration(
  id: readFileId,
  modelName: 'read_file',
  binding: BindingId(provider: 'builtin.workspace', generation: 4),
  effects: <StaticEffect>{StaticEffect.readWorkspace},
  required: <String>['uri'],
  executable: _FakeExecutable(
    describe: (Map<String, Object?> arguments, RunContext context) =>
        EffectDescription(
          effects: <StaticEffect>{StaticEffect.readWorkspace},
          targets: <ResourceTarget>[
            ResourceTarget(
              uri: Uri.parse(arguments['uri']! as String),
              version: arguments['version'] as String?,
            ),
          ],
        ),
    outcome: (Map<String, Object?> arguments, RunContext context) =>
        ToolOutcome(
          kind: OutcomeKind.success,
          content: ToolContent(
            model: <ContentBlock>[
              ResourceBlock(
                uri: Uri.parse(arguments['uri']! as String),
                version: arguments['version'] as String?,
                text: 'alpha\nbeta',
              ),
            ],
            data: <String, Object?>{
              'resource': <String, Object?>{
                'uri': arguments['uri'],
                'version': arguments['version'],
                'range': <String, Object?>{'startLine': 1, 'endLine': 2},
              },
            },
          ),
        ),
  ),
);

ToolRegistration searchTextTool() => _registration(
  id: searchTextId,
  modelName: 'search_text',
  binding: BindingId(provider: 'builtin.workspace', generation: 4),
  effects: <StaticEffect>{StaticEffect.readWorkspace},
  required: <String>['query'],
  executable: _FakeExecutable(
    describe: (Map<String, Object?> arguments, RunContext context) =>
        EffectDescription(
          effects: <StaticEffect>{StaticEffect.readWorkspace},
          summary: 'Search ${context.workspaceId} for ${arguments['query']}',
        ),
    progress: <ToolProgress>[
      ToolProgress(
        kind: ProgressKind.partialResult,
        sequence: 1,
        content: <ContentBlock>[const TextBlock('10 matches scanned')],
      ),
    ],
    outcome: (Map<String, Object?> arguments, RunContext context) =>
        ToolOutcome(
          kind: OutcomeKind.success,
          content: ToolContent(
            model: <ContentBlock>[const TextBlock('lib/a.dart:2: needle')],
            data: <String, Object?>{
              'matches': <Object?>[
                <String, Object?>{
                  'uri': 'workspace:///lib/a.dart',
                  'line': 2,
                  'startColumn': 4,
                  'endColumn': 10,
                  'preview': 'a needle here',
                },
              ],
            },
            truncation: const Truncation(
              returned: 1,
              total: 37,
              reason: 'result_limit',
            ),
          ),
        ),
  ),
);

ToolRegistration applyPatchTool({int generation = 7}) => _registration(
  id: applyPatchId,
  modelName: 'apply_patch',
  binding: BindingId(
    provider: 'capability.workspace-edit',
    generation: generation,
  ),
  effects: <StaticEffect>{StaticEffect.mutateWorkspace},
  required: <String>['patch', 'baseVersion'],
  executable: _FakeExecutable(
    describe: (Map<String, Object?> arguments, RunContext context) =>
        EffectDescription(
          effects: <StaticEffect>{StaticEffect.mutateWorkspace},
          targets: <ResourceTarget>[
            ResourceTarget(
              uri: Uri.parse('workspace:///lib/a.dart'),
              version: arguments['baseVersion']! as String,
            ),
          ],
          summary: 'Modify one workspace file',
        ),
    outcome: (Map<String, Object?> arguments, RunContext context) =>
        ToolOutcome(
          kind: OutcomeKind.success,
          content: ToolContent(
            model: <ContentBlock>[
              const TextBlock('Applied patch to 1 file (+1, -1).'),
            ],
            data: <String, Object?>{
              'changeSet': <String, Object?>{
                'baseVersion': arguments['baseVersion'],
                'newVersion': 'workspace-v13',
                'files': <Object?>['lib/a.dart'],
              },
            },
          ),
        ),
  ),
);

ToolRegistration runCommandTool() => _registration(
  id: runCommandId,
  modelName: 'run_command',
  binding: BindingId(provider: 'builtin.local-exec', generation: 2),
  effects: <StaticEffect>{
    StaticEffect.mutateWorkspace,
    StaticEffect.externalIo,
  },
  required: <String>['command'],
  executable: _CommandExecutable(),
);

ToolRegistration startProcessTool() => _registration(
  id: startProcessId,
  modelName: 'start_process',
  binding: BindingId(provider: 'builtin.local-exec', generation: 2),
  effects: <StaticEffect>{StaticEffect.spawnProcess, StaticEffect.externalIo},
  required: <String>['command'],
  executable: _FakeExecutable(
    describe: (Map<String, Object?> arguments, RunContext context) =>
        EffectDescription(
          effects: <StaticEffect>{
            StaticEffect.spawnProcess,
            StaticEffect.externalIo,
          },
          summary: 'Spawn ${arguments['command']} in ${context.environmentId}',
          uncertainty:
              'The child may modify resources reachable from the environment.',
        ),
    outcome: (Map<String, Object?> arguments, RunContext context) =>
        ToolOutcome(
          kind: OutcomeKind.success,
          content: ToolContent(
            model: <ContentBlock>[const TextBlock('Started process proc-9.')],
            data: <String, Object?>{'pid': 9012, 'state': 'running'},
            resources: <RuntimeResourceRef>[
              RuntimeResourceRef(
                id: 'proc-9',
                kind: 'process',
                environmentId: context.environmentId!,
                owner: 'execution-environment',
              ),
            ],
          ),
        ),
  ),
);

ToolRegistration mcpTool({required int generation}) {
  const ToolId id = ToolId('mcp://server-42/tools/weather.lookup');
  return _registration(
    id: id,
    modelName: 'server_42__weather_lookup',
    binding: BindingId(
      provider: 'mcp.connection.server-42',
      generation: generation,
    ),
    effects: <StaticEffect>{StaticEffect.externalIo},
    required: <String>['city'],
    executable: _FakeExecutable(
      describe: (Map<String, Object?> arguments, RunContext context) =>
          EffectDescription(
            effects: <StaticEffect>{StaticEffect.externalIo},
            summary: 'Ask MCP server-42 for ${arguments['city']}',
          ),
      outcome: (Map<String, Object?> arguments, RunContext context) =>
          ToolOutcome(
            kind: OutcomeKind.success,
            content: ToolContent(
              model: <ContentBlock>[
                TextBlock('Weather for ${arguments['city']}: 22 C'),
                JsonBlock(<String, Object?>{'temperatureC': 22}),
              ],
              data: <String, Object?>{
                'mcp': <String, Object?>{
                  'serverId': 'server-42',
                  'toolName': 'weather.lookup',
                  'raw': <String, Object?>{'temperatureC': 22},
                },
              },
            ),
          ),
    ),
  );
}

ToolRegistration _registration({
  required ToolId id,
  required String modelName,
  required BindingId binding,
  required Set<StaticEffect> effects,
  required List<String> required,
  required ToolExecutable executable,
}) => ToolRegistration(
  definition: ToolDefinition(
    id: id,
    description: 'Experiment tool $id',
    inputSchema: <String, Object?>{'type': 'object', 'required': required},
    staticEffects: effects,
  ),
  modelName: modelName,
  binding: ExecutableBinding(id: binding, executable: executable),
);

typedef _Describe =
    EffectDescription Function(
      Map<String, Object?> arguments,
      RunContext context,
    );
typedef _Outcome =
    ToolOutcome Function(Map<String, Object?> arguments, RunContext context);

final class _FakeExecutable implements ToolExecutable {
  _FakeExecutable({
    required _Describe describe,
    required _Outcome outcome,
    this.progress = const <ToolProgress>[],
  }) : _describe = describe,
       _outcome = outcome;

  final _Describe _describe;
  final _Outcome _outcome;
  final List<ToolProgress> progress;

  @override
  Future<EffectDescription> describe(
    Map<String, Object?> arguments,
    RunContext context,
  ) async => _describe(arguments, context);

  @override
  Stream<ToolProgress> execute(
    Map<String, Object?> arguments,
    RunContext context,
    CancellationSignal cancellation,
  ) async* {
    for (final ToolProgress item in progress) {
      if (cancellation.isCancelled) return;
      yield item;
    }
  }

  @override
  Future<ToolOutcome> outcome(
    Map<String, Object?> arguments,
    RunContext context,
    CancellationSignal cancellation,
  ) async {
    if (cancellation.isCancelled) {
      return ToolOutcome(
        kind: OutcomeKind.cancelled,
        code: 'cancelled_before_effect',
      );
    }
    return _outcome(arguments, context);
  }
}

final class _CommandExecutable implements ToolExecutable {
  bool _effectStarted = false;

  @override
  Future<EffectDescription> describe(
    Map<String, Object?> arguments,
    RunContext context,
  ) async => EffectDescription(
    effects: <StaticEffect>{
      StaticEffect.mutateWorkspace,
      StaticEffect.externalIo,
    },
    summary: 'Run ${arguments['command']} in ${arguments['cwd'] ?? '.'}',
    uncertainty: 'Command effects cannot be fully inferred from arguments.',
  );

  @override
  Stream<ToolProgress> execute(
    Map<String, Object?> arguments,
    RunContext context,
    CancellationSignal cancellation,
  ) async* {
    if (cancellation.isCancelled) return;
    _effectStarted = true;
    yield ToolProgress(
      kind: ProgressKind.stdout,
      sequence: 1,
      content: <ContentBlock>[const TextBlock('building...\n')],
    );
    cancellation.cancel();
    yield ToolProgress(
      kind: ProgressKind.stderr,
      sequence: 2,
      content: <ContentBlock>[const TextBlock('termination requested\n')],
    );
  }

  @override
  Future<ToolOutcome> outcome(
    Map<String, Object?> arguments,
    RunContext context,
    CancellationSignal cancellation,
  ) async {
    if (cancellation.isCancelled && _effectStarted) {
      return ToolOutcome(
        kind: OutcomeKind.cancelled,
        code: 'cancelled_after_effect_started',
        message: 'Process termination was requested.',
        effectMayHaveOccurred: true,
        content: ToolContent(
          model: <ContentBlock>[
            const TextBlock('Command was cancelled after it started.'),
          ],
          data: <String, Object?>{
            'exitCode': null,
            'terminationRequested': true,
          },
        ),
      );
    }
    return ToolOutcome(
      kind: OutcomeKind.success,
      content: ToolContent(data: <String, Object?>{'exitCode': 0}),
    );
  }
}
