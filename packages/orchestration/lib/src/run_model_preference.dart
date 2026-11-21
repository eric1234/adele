import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';

final runModelPreferencesExtensionPoint =
    ExtensionPoint<RunModelPreferenceContribution>(
      'dev.adele.extension.run-model-preferences',
    );

/// A semantic request, not a provider binding, credential, or authority to run.
final class RunModelPreference {
  RunModelPreference({
    required this.providerId,
    required this.modelId,
    this.reasoningEffort,
  }) {
    if (providerId.value.length > maxProviderIdLength ||
        modelId.length > modelCatalogMaxModelIdLength ||
        modelId.trim().isEmpty ||
        modelId.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw const RunModelPreferenceFailure(
        RunModelPreferenceFailureKind.malformed,
      );
    }
  }

  /// Transport bound in addition to the ordinary [ProviderId] grammar.
  static const maxProviderIdLength = 1024;

  final ProviderId providerId;

  /// Exact provider-local identifier. Validation never rewrites the string.
  final String modelId;

  /// Null leaves effort unspecified; [ModelReasoningEffort.none] requests none.
  final ModelReasoningEffort? reasoningEffort;
}

final class RunModelPreferenceContribution {
  const RunModelPreferenceContribution({required this.captureRun});

  /// Called once during preparation of a new Run. Only an explicit null result
  /// means no preference. Read or validation failures must not return null.
  final Future<RunModelPreference?> Function(Session session, RunId runId)
  captureRun;
}

enum RunModelPreferenceFailureKind { malformed, unavailable, ambiguous, failed }

/// Value-free diagnostic. Never retains a source exception or a wire payload.
final class RunModelPreferenceFailure implements Exception {
  const RunModelPreferenceFailure(this.kind);

  final RunModelPreferenceFailureKind kind;

  @override
  String toString() => switch (kind) {
    RunModelPreferenceFailureKind.malformed =>
      'Malformed Run model preference.',
    RunModelPreferenceFailureKind.unavailable =>
      'Run model preference source unavailable.',
    RunModelPreferenceFailureKind.ambiguous =>
      'Ambiguous Run model preference sources.',
    RunModelPreferenceFailureKind.failed =>
      'Run model preference capture failed.',
  };
}

/// Selects at admission without invoking a contributor. No ranking or retries.
final class RunModelPreferenceResolver {
  const RunModelPreferenceResolver(this._registry, {this.captureExpected});

  final ExtensionRegistry _registry;

  /// Optional host provenance check. Verifies any known expected participants
  /// against these exact registrations (including the empty list), then returns
  /// a validator of the captured origins, not a new discovery operation.
  final void Function() Function(
    List<ExtensionBinding<RunModelPreferenceContribution>> bindings,
  )?
  captureExpected;

  /// Null means no registrations *and* no missing expected participant.
  /// Failures are snapshots too, so a host can reserve a Run synchronously
  /// and report the failure during preparation without consulting newer state.
  ResolvedRunModelPreference? resolve() {
    try {
      final bindings = _registry.discover(runModelPreferencesExtensionPoint);
      final validateExpected = captureExpected?.call(bindings);
      if (bindings.isEmpty) return null;
      if (bindings.length > 1) {
        return const ResolvedRunModelPreference._failed(
          RunModelPreferenceFailure(RunModelPreferenceFailureKind.ambiguous),
        );
      }
      return ResolvedRunModelPreference._(bindings.single, validateExpected);
    } on Object {
      // Neither malformed registry metadata nor an unverifiable expected
      // participant establishes a successful absence.
      return const ResolvedRunModelPreference._failed(
        RunModelPreferenceFailure(RunModelPreferenceFailureKind.unavailable),
      );
    }
  }
}

/// An exact contributor or an initial composition failure; never a lookup key.
final class ResolvedRunModelPreference {
  const ResolvedRunModelPreference._(this._binding, this._validateExpected)
    : failure = null;

  const ResolvedRunModelPreference._failed(this.failure)
    : _binding = null,
      _validateExpected = null;

  final ExtensionBinding<RunModelPreferenceContribution>? _binding;
  final void Function()? _validateExpected;
  final RunModelPreferenceFailure? failure;

  Future<RunModelPreference?> captureRun(Session session, RunId runId) async {
    if (failure case final error?) throw error;
    final binding = _binding!;
    void validate() {
      try {
        binding.validate();
        _validateExpected?.call();
      } on Object {
        throw const RunModelPreferenceFailure(
          RunModelPreferenceFailureKind.unavailable,
        );
      }
    }

    validate();
    try {
      return await binding.value.captureRun(session, runId);
    } on RunModelPreferenceFailure {
      rethrow;
    } on InvalidCapabilityIdentity {
      // A contributor may be constructing ProviderId from authored data.
      throw const RunModelPreferenceFailure(
        RunModelPreferenceFailureKind.malformed,
      );
    } on Object {
      throw const RunModelPreferenceFailure(
        RunModelPreferenceFailureKind.failed,
      );
    } finally {
      // Retirement invalidates either a late value (including null) or a late
      // failure from this capture. Never retry against a replacement source.
      validate();
    }
  }
}
