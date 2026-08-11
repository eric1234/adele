import 'package:agent_kernel/agent_kernel.dart';

final class TestExecutable implements ToolExecutable {
  TestExecutable({
    this.provider = 'generation-a',
    this.plainFormatFailure = false,
    this.descriptionFailure = false,
  });

  final String provider;
  final bool plainFormatFailure;
  final bool descriptionFailure;
  bool active = true;
  int descriptions = 0;
  int executions = 0;

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    if (descriptionFailure) throw StateError('description failed');
    descriptions++;
    final Uri uri = Uri.parse(arguments.snapshot['uri']! as String);
    return EffectDescription(
      effects: const <ToolEffect>[ToolEffect.resourceInspection],
      targets: <EffectTarget>[EffectTarget(uri: uri)],
      summary: 'Inspect $uri.',
    );
  }

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    validateBinding();
    executions++;
    final Uri uri = Uri.parse(arguments.snapshot['uri']! as String);
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Inspected $uri.',
        hostData: <String, Object?>{
          'resource': uri.toString(),
          'provider': provider,
        },
      ),
    );
  }

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) {
    if (plainFormatFailure) {
      throw const FormatException('plain format failure');
    }
    if (proposedArguments.length != 1 || proposedArguments['uri'] is! String) {
      throw const ToolArgumentValidationException(
        'Expected exactly one string uri.',
      );
    }
    final Uri uri = Uri.parse(proposedArguments['uri']! as String);
    if (!uri.isAbsolute) {
      throw const ToolArgumentValidationException('Expected an absolute uri.');
    }
    return CanonicalToolArguments(<String, Object?>{'uri': uri.toString()});
  }

  @override
  void validateBinding() {
    if (!active) {
      throw const StaleToolBindingException('The test binding is stale.');
    }
  }
}

final class DecisionPolicy implements ToolPolicy {
  const DecisionPolicy(this.decision);

  final ToolPolicyDecision decision;

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => decision;
}

final class ThrowingPolicy implements ToolPolicy {
  const ThrowingPolicy();

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) {
    throw StateError('policy failed');
  }
}

ToolRegistration testRegistration(
  TestExecutable executable, {
  String id = 'dev.adele.tool.resource-inspection',
  String alias = 'inspect_resource',
}) => ToolRegistration(
  definition: ToolDefinition(
    id: ToolId(id),
    description: 'Inspect one resource.',
  ),
  modelDefinition: ModelToolDefinition(
    alias: alias,
    description: 'Inspect one resource.',
    argumentsSchema: const <String, Object?>{
      'type': 'object',
      'required': <Object?>['uri'],
    },
  ),
  executable: executable,
);

ToolInvocation testInvocation(
  TestExecutable executable, {
  String invocationId = 'tool-1',
}) {
  final ToolCatalog catalog = ToolCatalog()
    ..register(testRegistration(executable));
  final ToolProposalResolution resolution = const ToolInvocationResolver()
      .resolve(
        invocationId: ToolInvocationId(invocationId),
        proposal: ProviderToolProposal(
          providerCallId: 'provider-1',
          alias: 'inspect_resource',
          arguments: const <String, Object?>{'uri': 'file:///tmp/example.dart'},
        ),
        tools: catalog.materialize(),
        context: testExecutionContext(),
      );
  return (resolution as ResolvedToolProposal).invocation;
}

ToolExecutionContext testExecutionContext() => ToolExecutionContext(
  runId: RunId('run-1'),
  sessionId: SessionId('session-1'),
);
