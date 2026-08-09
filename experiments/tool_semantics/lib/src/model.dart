import 'dart:async';
import 'dart:convert';

final class ToolId {
  const ToolId(this.value);

  final String value;

  @override
  bool operator ==(Object other) => other is ToolId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class BindingId {
  const BindingId({required this.provider, required this.generation});

  final String provider;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is BindingId &&
      other.provider == provider &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(provider, generation);

  @override
  String toString() => '$provider@$generation';
}

enum StaticEffect { readWorkspace, mutateWorkspace, spawnProcess, externalIo }

final class ToolDefinition {
  ToolDefinition({
    required this.id,
    required this.description,
    required Map<String, Object?> inputSchema,
    required Set<StaticEffect> staticEffects,
  }) : inputSchema = Map<String, Object?>.unmodifiable(inputSchema),
       staticEffects = Set<StaticEffect>.unmodifiable(staticEffects);

  final ToolId id;
  final String description;
  final Map<String, Object?> inputSchema;
  final Set<StaticEffect> staticEffects;
}

final class ModelToolDefinition {
  ModelToolDefinition({
    required this.name,
    required this.description,
    required Map<String, Object?> inputSchema,
  }) : inputSchema = Map<String, Object?>.unmodifiable(inputSchema);

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
}

final class RunContext {
  const RunContext({
    required this.runId,
    required this.sessionId,
    required this.agentId,
    required this.workflowId,
    this.workspaceId,
    this.environmentId,
  });

  final String runId;
  final String sessionId;
  final String agentId;
  final String workflowId;
  final String? workspaceId;
  final String? environmentId;
}

final class ResourceTarget {
  const ResourceTarget({required this.uri, this.version});

  final Uri uri;
  final String? version;
}

final class EffectDescription {
  EffectDescription({
    required Set<StaticEffect> effects,
    Iterable<ResourceTarget> targets = const <ResourceTarget>[],
    this.summary,
    this.uncertainty,
  }) : effects = Set<StaticEffect>.unmodifiable(effects),
       targets = List<ResourceTarget>.unmodifiable(targets);

  final Set<StaticEffect> effects;
  final List<ResourceTarget> targets;
  final String? summary;
  final String? uncertainty;
}

final class ToolContent {
  ToolContent({
    Iterable<ContentBlock> model = const <ContentBlock>[],
    Map<String, Object?> data = const <String, Object?>{},
    Iterable<RuntimeResourceRef> resources = const <RuntimeResourceRef>[],
    Iterable<ArtifactRef> artifacts = const <ArtifactRef>[],
    this.truncation,
  }) : model = List<ContentBlock>.unmodifiable(model),
       data = Map<String, Object?>.unmodifiable(data),
       resources = List<RuntimeResourceRef>.unmodifiable(resources),
       artifacts = List<ArtifactRef>.unmodifiable(artifacts);

  final List<ContentBlock> model;
  final Map<String, Object?> data;
  final List<RuntimeResourceRef> resources;
  final List<ArtifactRef> artifacts;
  final Truncation? truncation;
}

sealed class ContentBlock {
  const ContentBlock();
}

final class TextBlock extends ContentBlock {
  const TextBlock(this.text);

  final String text;
}

final class ResourceBlock extends ContentBlock {
  const ResourceBlock({required this.uri, required this.text, this.version});

  final Uri uri;
  final String text;
  final String? version;
}

final class JsonBlock extends ContentBlock {
  JsonBlock(Map<String, Object?> value)
    : value = Map<String, Object?>.unmodifiable(value);

  final Map<String, Object?> value;
}

final class Truncation {
  const Truncation({required this.returned, this.total, required this.reason});

  final int returned;
  final int? total;
  final String reason;
}

final class RuntimeResourceRef {
  const RuntimeResourceRef({
    required this.id,
    required this.kind,
    required this.environmentId,
    required this.owner,
  });

  final String id;
  final String kind;
  final String environmentId;
  final String owner;
}

final class ArtifactRef {
  const ArtifactRef({required this.id, required this.mediaType});

  final String id;
  final String mediaType;
}

enum ProgressKind { status, stdout, stderr, partialResult }

final class ToolProgress {
  ToolProgress({
    required this.kind,
    required this.sequence,
    Iterable<ContentBlock> content = const <ContentBlock>[],
  }) : content = List<ContentBlock>.unmodifiable(content);

  final ProgressKind kind;
  final int sequence;
  final List<ContentBlock> content;
}

enum OutcomeKind {
  success,
  invalidArguments,
  unavailable,
  staleBinding,
  policyDenied,
  userRejected,
  domainFailure,
  infrastructureFailure,
  cancelled,
  indeterminate,
  malformedResult,
}

final class ToolOutcome {
  ToolOutcome({
    required this.kind,
    this.content,
    this.code,
    this.message,
    this.effectMayHaveOccurred = false,
  });

  final OutcomeKind kind;
  final ToolContent? content;
  final String? code;
  final String? message;
  final bool effectMayHaveOccurred;

  bool get isSuccess => kind == OutcomeKind.success;
}

final class CancellationSignal {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

abstract interface class ToolExecutable {
  Future<EffectDescription> describe(
    Map<String, Object?> arguments,
    RunContext context,
  );

  Stream<ToolProgress> execute(
    Map<String, Object?> arguments,
    RunContext context,
    CancellationSignal cancellation,
  );

  Future<ToolOutcome> outcome(
    Map<String, Object?> arguments,
    RunContext context,
    CancellationSignal cancellation,
  );
}

final class ExecutableBinding {
  ExecutableBinding({required this.id, required ToolExecutable executable})
    : _executable = executable;

  final BindingId id;
  final ToolExecutable _executable;
  bool _active = true;

  bool get isActive => _active;

  ToolExecutable get executable => _executable;

  void invalidate() => _active = false;
}

final class ToolRegistration {
  ToolRegistration({
    required this.definition,
    required this.modelName,
    required this.binding,
  });

  final ToolDefinition definition;
  final String modelName;
  final ExecutableBinding binding;
}

final class ToolCatalog {
  final Map<ToolId, ToolRegistration> _registrations =
      <ToolId, ToolRegistration>{};

  void register(ToolRegistration registration) {
    _registrations[registration.definition.id] = registration;
  }

  void remove(ToolId id) => _registrations.remove(id)?.binding.invalidate();

  bool isAvailable(ToolId id) => _registrations[id]?.binding.isActive ?? false;

  MaterializedToolSet materialize(Iterable<ToolId> selected) {
    final List<MaterializedTool> tools = <MaterializedTool>[];
    for (final ToolId id in selected) {
      final ToolRegistration? registration = _registrations[id];
      if (registration == null || !registration.binding.isActive) {
        throw StateError('Tool $id is unavailable.');
      }
      tools.add(
        MaterializedTool(
          definition: registration.definition,
          modelDefinition: ModelToolDefinition(
            name: registration.modelName,
            description: registration.definition.description,
            inputSchema: registration.definition.inputSchema,
          ),
          binding: registration.binding,
        ),
      );
    }
    return MaterializedToolSet(tools);
  }
}

final class MaterializedTool {
  const MaterializedTool({
    required this.definition,
    required this.modelDefinition,
    required this.binding,
  });

  final ToolDefinition definition;
  final ModelToolDefinition modelDefinition;
  final ExecutableBinding binding;
}

final class MaterializedToolSet {
  MaterializedToolSet(Iterable<MaterializedTool> tools)
    : tools = List<MaterializedTool>.unmodifiable(tools),
      _byName = Map<String, MaterializedTool>.unmodifiable(
        <String, MaterializedTool>{
          for (final MaterializedTool tool in tools)
            tool.modelDefinition.name: tool,
        },
      );

  final List<MaterializedTool> tools;
  final Map<String, MaterializedTool> _byName;

  MaterializedTool? byModelName(String name) => _byName[name];
}

final class ProviderToolCall {
  ProviderToolCall({
    required this.callId,
    required this.name,
    required Map<String, Object?> arguments,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments);

  final String callId;
  final String name;
  final Map<String, Object?> arguments;
}

enum InvocationState { proposed, validated, interrupted, executing, terminal }

final class ToolInvocation {
  ToolInvocation({
    required this.id,
    required this.providerCallId,
    required this.tool,
    required Map<String, Object?> arguments,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments);

  final String id;
  final String providerCallId;
  final MaterializedTool tool;
  final Map<String, Object?> arguments;
  InvocationState state = InvocationState.proposed;
  EffectDescription? effects;
  ApprovalInterruption? interruption;
  ToolOutcome? terminalOutcome;
  final List<ToolProgress> progress = <ToolProgress>[];
}

final class PolicyInput {
  const PolicyInput({
    required this.toolId,
    required this.bindingId,
    required this.arguments,
    required this.context,
    required this.staticEffects,
    required this.derivedEffects,
  });

  final ToolId toolId;
  final BindingId bindingId;
  final Map<String, Object?> arguments;
  final RunContext context;
  final Set<StaticEffect> staticEffects;
  final EffectDescription derivedEffects;
}

enum PolicyDecision { allow, requireApproval, deny }

abstract interface class ToolPolicy {
  PolicyDecision evaluate(PolicyInput input);
}

final class ApprovalInterruption {
  const ApprovalInterruption({
    required this.invocationId,
    required this.toolId,
    required this.bindingId,
    required this.argumentsDigest,
    required this.effects,
  });

  final String invocationId;
  final ToolId toolId;
  final BindingId bindingId;
  final String argumentsDigest;
  final EffectDescription effects;
}

final class ApprovalDecision {
  const ApprovalDecision({required this.interruption, required this.approved});

  final ApprovalInterruption interruption;
  final bool approved;
}

final class InvocationPrepared {
  const InvocationPrepared(this.invocation);

  final ToolInvocation invocation;
}

final class InvocationInterrupted {
  const InvocationInterrupted(this.invocation, this.interruption);

  final ToolInvocation invocation;
  final ApprovalInterruption interruption;
}

final class InvocationTerminal {
  const InvocationTerminal(this.invocation, this.outcome);

  final ToolInvocation invocation;
  final ToolOutcome outcome;
}

final class ToolLifecycle {
  ToolLifecycle({required this.policy});

  final ToolPolicy policy;
  int _nextInvocation = 1;

  Future<Object> propose({
    required MaterializedToolSet tools,
    required ProviderToolCall call,
    required RunContext context,
  }) async {
    final MaterializedTool? tool = tools.byModelName(call.name);
    if (tool == null) {
      return InvocationTerminal(
        ToolInvocation(
          id: 'inv-${_nextInvocation++}',
          providerCallId: call.callId,
          tool: tools.tools.first,
          arguments: call.arguments,
        ),
        ToolOutcome(
          kind: OutcomeKind.unavailable,
          code: 'unknown_model_tool',
          message: 'The proposed model-visible tool is not in this snapshot.',
        ),
      );
    }
    final ToolInvocation invocation = ToolInvocation(
      id: 'inv-${_nextInvocation++}',
      providerCallId: call.callId,
      tool: tool,
      arguments: call.arguments,
    );
    final String? validationError = _validate(tool.definition, call.arguments);
    if (validationError != null) {
      return _terminal(
        invocation,
        ToolOutcome(
          kind: OutcomeKind.invalidArguments,
          code: 'schema_validation',
          message: validationError,
        ),
      );
    }
    invocation.state = InvocationState.validated;
    final EffectDescription effects = await tool.binding.executable.describe(
      invocation.arguments,
      context,
    );
    invocation.effects = effects;
    final PolicyDecision decision = policy.evaluate(
      PolicyInput(
        toolId: tool.definition.id,
        bindingId: tool.binding.id,
        arguments: invocation.arguments,
        context: context,
        staticEffects: tool.definition.staticEffects,
        derivedEffects: effects,
      ),
    );
    if (decision == PolicyDecision.deny) {
      return _terminal(
        invocation,
        ToolOutcome(kind: OutcomeKind.policyDenied, code: 'policy_denied'),
      );
    }
    if (decision == PolicyDecision.requireApproval) {
      final ApprovalInterruption interruption = ApprovalInterruption(
        invocationId: invocation.id,
        toolId: tool.definition.id,
        bindingId: tool.binding.id,
        argumentsDigest: _argumentsDigest(invocation.arguments),
        effects: effects,
      );
      invocation
        ..state = InvocationState.interrupted
        ..interruption = interruption;
      return InvocationInterrupted(invocation, interruption);
    }
    return InvocationPrepared(invocation);
  }

  Future<InvocationTerminal> decide({
    required ToolInvocation invocation,
    required ApprovalDecision decision,
    required RunContext context,
    CancellationSignal? cancellation,
  }) async {
    final ApprovalInterruption? expected = invocation.interruption;
    if (expected == null || !identical(expected, decision.interruption)) {
      return _terminal(
        invocation,
        ToolOutcome(
          kind: OutcomeKind.infrastructureFailure,
          code: 'approval_mismatch',
        ),
      );
    }
    if (!decision.approved) {
      return _terminal(
        invocation,
        ToolOutcome(kind: OutcomeKind.userRejected, code: 'user_rejected'),
      );
    }
    return execute(
      invocation: invocation,
      context: context,
      cancellation: cancellation,
    );
  }

  Future<InvocationTerminal> execute({
    required ToolInvocation invocation,
    required RunContext context,
    CancellationSignal? cancellation,
  }) async {
    if (!invocation.tool.binding.isActive) {
      return _terminal(
        invocation,
        ToolOutcome(kind: OutcomeKind.staleBinding, code: 'stale_binding'),
      );
    }
    final CancellationSignal signal = cancellation ?? CancellationSignal();
    invocation.state = InvocationState.executing;
    try {
      await for (final ToolProgress item
          in invocation.tool.binding.executable.execute(
            invocation.arguments,
            context,
            signal,
          )) {
        invocation.progress.add(item);
      }
      final ToolOutcome outcome = await invocation.tool.binding.executable
          .outcome(invocation.arguments, context, signal);
      return _terminal(invocation, outcome);
    } on Object catch (error) {
      return _terminal(
        invocation,
        ToolOutcome(
          kind: OutcomeKind.infrastructureFailure,
          code: 'executor_exception',
          message: error.toString(),
        ),
      );
    }
  }

  InvocationTerminal _terminal(ToolInvocation invocation, ToolOutcome outcome) {
    invocation
      ..state = InvocationState.terminal
      ..terminalOutcome = outcome;
    return InvocationTerminal(invocation, outcome);
  }
}

final class AllowReadApproveEffectsPolicy implements ToolPolicy {
  const AllowReadApproveEffectsPolicy();

  @override
  PolicyDecision evaluate(PolicyInput input) {
    if (input.derivedEffects.effects.contains(StaticEffect.mutateWorkspace) ||
        input.derivedEffects.effects.contains(StaticEffect.spawnProcess) ||
        input.derivedEffects.effects.contains(StaticEffect.externalIo)) {
      return PolicyDecision.requireApproval;
    }
    return PolicyDecision.allow;
  }
}

final class ModelContinuation {
  ModelContinuation({required this.providerCallId, required this.outcome});

  final String providerCallId;
  final ToolOutcome outcome;

  List<ContentBlock> get content =>
      outcome.content?.model ??
      <ContentBlock>[
        TextBlock(
          '${outcome.code ?? outcome.kind.name}: ${outcome.message ?? ''}',
        ),
      ];
}

String _argumentsDigest(Map<String, Object?> arguments) =>
    base64Url.encode(utf8.encode(jsonEncode(arguments)));

String? _validate(ToolDefinition definition, Map<String, Object?> arguments) {
  final Object? required = definition.inputSchema['required'];
  if (required is List<Object?>) {
    for (final Object? name in required) {
      if (name is String && !arguments.containsKey(name)) {
        return 'Missing required argument $name.';
      }
    }
  }
  return null;
}
