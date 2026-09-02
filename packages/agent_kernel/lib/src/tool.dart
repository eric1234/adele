import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

import 'identifiers.dart';

final class ToolCatalog {
  final Map<ToolId, ToolRegistration> _registrations =
      <ToolId, ToolRegistration>{};

  void register(ToolRegistration registration) {
    _registrations[registration.definition.id] = registration;
  }

  bool remove(ToolId id) => _registrations.remove(id) != null;

  MaterializedToolSet materialize({Iterable<ToolId>? selected}) {
    final Iterable<ToolRegistration> registrations;
    if (selected == null) {
      registrations = _registrations.values;
    } else {
      registrations = selected.map((ToolId id) {
        final ToolRegistration? registration = _registrations[id];
        if (registration == null) {
          throw ToolMaterializationException('Tool $id is not registered.');
        }
        return registration;
      });
    }
    return MaterializedToolSet(
      registrations.map(
        (ToolRegistration registration) => MaterializedTool(
          definition: registration.definition,
          modelDefinition: registration.modelDefinition,
          executable: registration.executable,
        ),
      ),
    );
  }
}

/// Generic adapter from public plugin contributions to kernel registrations.
final class ModelToolComposer {
  const ModelToolComposer(this.registry);

  final ExtensionRegistry registry;

  Future<ToolCatalog> materialize(ModelToolHostContext context) async {
    final ToolCatalog catalog = ToolCatalog();
    final Set<ToolId> toolIds = <ToolId>{};
    for (final ExtensionBinding<ModelToolContribution> binding
        in registry.discover(modelToolContributions)) {
      final Iterable<ToolRegistration> registrations = await binding.value
          .materialize(context);
      binding.validate();
      for (final ToolRegistration registration in registrations) {
        if (!toolIds.add(registration.definition.id)) {
          throw ToolMaterializationException(
            'Tool ${registration.definition.id} is contributed more than once.',
          );
        }
        catalog.register(
          ToolRegistration(
            definition: registration.definition,
            modelDefinition: registration.modelDefinition,
            executable: _ExtensionBoundExecutable(
              binding: binding,
              delegate: registration.executable,
            ),
          ),
        );
      }
    }
    // Alias composition semantics belong to this extension point.
    catalog.materialize();
    return catalog;
  }
}

final class _ExtensionBoundExecutable implements ToolExecutable {
  const _ExtensionBoundExecutable({
    required ExtensionBinding<ModelToolContribution> binding,
    required ToolExecutable delegate,
  }) : _binding = binding,
       _delegate = delegate;

  final ExtensionBinding<ModelToolContribution> _binding;
  final ToolExecutable _delegate;

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) {
    _validateContribution();
    return _delegate.validateAndNormalize(proposedArguments);
  }

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) {
    _validateContribution();
    return _delegate.describe(arguments, context);
  }

  @override
  void validateBinding() {
    _validateContribution();
    _delegate.validateBinding();
  }

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    // Tool streams are lazy, so check the generation when execution starts.
    _validateContribution();
    yield* _delegate.execute(arguments, context);
  }

  void _validateContribution() {
    try {
      _binding.validate();
    } on StaleExtensionBinding catch (error) {
      throw StaleToolBindingException(
        'The model-tool contributor generation is stale.',
        cause: error,
      );
    }
  }
}

final class MaterializedTool {
  const MaterializedTool({
    required this.definition,
    required this.modelDefinition,
    required this.executable,
  });

  final ToolDefinition definition;
  final ModelToolDefinition modelDefinition;
  final ToolExecutable executable;
}

final class MaterializedToolSet {
  MaterializedToolSet(Iterable<MaterializedTool> tools)
    : tools = List<MaterializedTool>.unmodifiable(tools) {
    final Map<String, MaterializedTool> byAlias = <String, MaterializedTool>{};
    for (final MaterializedTool tool in this.tools) {
      final String alias = tool.modelDefinition.alias;
      if (byAlias.containsKey(alias)) {
        throw ToolMaterializationException(
          'Model tool alias is not unique in this materialization: $alias.',
        );
      }
      byAlias[alias] = tool;
    }
    _byAlias = Map<String, MaterializedTool>.unmodifiable(byAlias);
  }

  final List<MaterializedTool> tools;
  late final Map<String, MaterializedTool> _byAlias;

  MaterializedTool? byAlias(String alias) => _byAlias[alias];
}

final class ProviderToolProposal {
  ProviderToolProposal({
    required String providerCallId,
    required String alias,
    required Map<String, Object?> arguments,
  }) : providerCallId = _requireNonEmpty(providerCallId, 'Provider call ID'),
       alias = _requireNonEmpty(alias, 'Proposed model tool alias'),
       arguments = _freezeMap(arguments);

  final String providerCallId;
  final String alias;
  final Map<String, Object?> arguments;
}

final class ToolInvocation {
  ToolInvocation._({
    required this.id,
    required this.proposal,
    required this.tool,
    required this.arguments,
    required this.context,
  }) : canonicalArguments = _freezeMap(arguments.snapshot);

  final ToolInvocationId id;
  final ProviderToolProposal proposal;
  final MaterializedTool tool;
  final CanonicalToolArguments arguments;
  final ToolExecutionContext context;
  final Map<String, Object?> canonicalArguments;

  ToolId get toolId => tool.definition.id;
}

enum ToolProposalFailureKind { unknownAlias, invalidArguments }

final class ToolProposalFailure {
  ToolProposalFailure({
    required this.kind,
    required String providerCallId,
    required String alias,
    required String message,
    this.cause,
  }) : providerCallId = _requireNonEmpty(providerCallId, 'Provider call ID'),
       alias = _requireNonEmpty(alias, 'Proposed model tool alias'),
       message = _requireNonEmpty(message, 'Tool proposal failure message');

  final ToolProposalFailureKind kind;
  final String providerCallId;
  final String alias;
  final String message;
  final Object? cause;
}

sealed class ToolProposalResolution {
  const ToolProposalResolution();
}

final class ResolvedToolProposal extends ToolProposalResolution {
  const ResolvedToolProposal(this.invocation);

  final ToolInvocation invocation;
}

final class RejectedToolProposal extends ToolProposalResolution {
  const RejectedToolProposal(this.failure);

  final ToolProposalFailure failure;
}

final class ToolInvocationResolver {
  const ToolInvocationResolver();

  ToolProposalResolution resolve({
    required ToolInvocationId invocationId,
    required ProviderToolProposal proposal,
    required MaterializedToolSet tools,
    required ToolExecutionContext context,
  }) {
    final MaterializedTool? tool = tools.byAlias(proposal.alias);
    if (tool == null) {
      return RejectedToolProposal(
        ToolProposalFailure(
          kind: ToolProposalFailureKind.unknownAlias,
          providerCallId: proposal.providerCallId,
          alias: proposal.alias,
          message: 'The proposed model tool alias is not available.',
        ),
      );
    }
    try {
      return ResolvedToolProposal(
        ToolInvocation._(
          id: invocationId,
          proposal: proposal,
          tool: tool,
          arguments: tool.executable.validateAndNormalize(proposal.arguments),
          context: context,
        ),
      );
    } on FormatException catch (error) {
      return RejectedToolProposal(
        ToolProposalFailure(
          kind: ToolProposalFailureKind.invalidArguments,
          providerCallId: proposal.providerCallId,
          alias: proposal.alias,
          message: error.message.trim().isEmpty
              ? 'The proposed tool arguments are invalid.'
              : error.message,
          cause: error,
        ),
      );
    }
  }
}

final class ToolPolicyInput {
  const ToolPolicyInput({
    required this.invocation,
    required this.effects,
    required this.context,
  });

  final ToolInvocation invocation;
  final EffectDescription effects;
  final ToolExecutionContext context;
}

enum ToolPolicyDecision { allow, deny, ask }

abstract interface class ToolPolicy {
  ToolPolicyDecision evaluate(ToolPolicyInput input);
}

final class ToolExecutionAlreadyStarted implements Exception {
  const ToolExecutionAlreadyStarted(this.invocationId);

  final ToolInvocationId invocationId;

  @override
  String toString() =>
      'ToolExecutionAlreadyStarted: Tool invocation $invocationId already started.';
}

final class ToolMaterializationException implements Exception {
  const ToolMaterializationException(this.message);

  final String message;

  @override
  String toString() => 'ToolMaterializationException: $message';
}

String _requireNonEmpty(String value, String label) {
  if (value.trim().isEmpty) throw FormatException('$label must not be empty.');
  return value;
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable(
      source.map(
        (String key, Object? value) =>
            MapEntry<String, Object?>(key, _freezeValue(value)),
      ),
    );

Object? _freezeValue(Object? value) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException('Structured values require finite doubles.');
    }
    return value;
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_freezeValue));
  }
  if (value is Map<String, Object?>) return _freezeMap(value);
  throw FormatException('Unsupported structured value: ${value.runtimeType}.');
}
