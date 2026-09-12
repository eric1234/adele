import 'dart:collection';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';

import 'model.dart';

/// Zero-or-many instruction sources discovered anew for each inference.
final ExtensionPoint<InferenceContextSourceContribution>
inferenceContextSources = ExtensionPoint<InferenceContextSourceContribution>(
  'dev.adele.extension.inference-context-sources',
);

/// Host-supplied canonical execution context for one source capture.
abstract interface class InferenceContextSourceContext {
  Session get session;
  RunId get runId;

  /// Resolves a required typed host service or fails explicitly if unavailable.
  Future<T> requireHostService<T extends Object>();
}

/// Determines whether a source capture failure aborts composition.
enum InferenceContextFailureMode {
  /// Abort composition with [InferenceContextSourceFailed].
  required,

  /// Omit the entire source and retain its failure in the source result.
  optional,
}

/// A source's explicit failure policy and asynchronous material capture.
final class InferenceContextSourceContribution {
  const InferenceContextSourceContribution({
    required this.failureMode,
    required this.snapshot,
  });

  final InferenceContextFailureMode failureMode;

  /// Returns ordered material; an empty iterable is a successful empty result.
  ///
  /// Each new inference asks for current material according to this source's own
  /// freshness policy. Rereading, watching, caching, or reusing captured state is
  /// the source's choice, not a host refresh schedule.
  ///
  /// The host consumes and copies the entire iterable before accepting it.
  /// Callback failures, lazy iteration failures, invalid material, duplicate
  /// keys, and binding retirement all follow [failureMode], without partial data.
  final Future<Iterable<InferenceContextMaterial>> Function(
    InferenceContextSourceContext,
  )
  snapshot;
}

/// Provider-neutral source material; this slice supports instructions only.
sealed class InferenceContextMaterial {
  const InferenceContextMaterial();
}

/// Immutable instruction text identified by its source and exact [key].
///
/// Blank keys or text throw [FormatException]. Valid strings are retained
/// verbatim, without trimming or normalization.
final class InferenceInstructionMaterial extends InferenceContextMaterial {
  InferenceInstructionMaterial({
    required this.key,
    required this.text,
    this.revision,
  }) {
    if (key.trim().isEmpty) {
      throw const FormatException(
        'Inference instruction key must not be blank.',
      );
    }
    if (text.trim().isEmpty) {
      throw const FormatException(
        'Inference instruction text must not be blank.',
      );
    }
  }

  /// Identity is this exact string paired with the source's ExtensionId.
  /// Keep it stable across snapshots for the same logical material.
  final String key;
  final String text;

  /// Optional opaque revision metadata; never included in rendered instructions.
  final String? revision;
}

/// Typed strategy or source provenance within an inference snapshot.
sealed class InferenceInstructionGroup {
  const InferenceInstructionGroup._();
}

/// The strategy's exact instructions, retained even when the string is empty.
final class StrategyInstructionGroup extends InferenceInstructionGroup {
  const StrategyInstructionGroup._(this.instructions) : super._();

  final String instructions;
}

/// One successful nonempty source's copied materials, in source-local order.
final class SourceInstructionGroup extends InferenceInstructionGroup {
  const SourceInstructionGroup._(this.sourceId, this.materials) : super._();

  final ExtensionId sourceId;
  final List<InferenceInstructionMaterial> materials;
}

/// Distinguishes nonempty and empty success from optional source failure.
enum InferenceContextSourceStatus { contributed, empty, omitted }

/// Immutable evidence for one discovered source, without its live binding.
final class InferenceContextSourceResult {
  InferenceContextSourceResult._({
    required this.sourceId,
    required this.failureMode,
    Iterable<InferenceInstructionMaterial> materials =
        const <InferenceInstructionMaterial>[],
    this.failure,
  }) : materials = List<InferenceInstructionMaterial>.unmodifiable(materials);

  final ExtensionId sourceId;
  final InferenceContextFailureMode failureMode;

  /// Copied instructions, empty for both empty success and optional omission.
  final List<InferenceInstructionMaterial> materials;

  /// Present only for an optional omission; required failures are thrown instead.
  final InferenceContextSourceFailed? failure;

  InferenceContextSourceStatus get status => failure != null
      ? InferenceContextSourceStatus.omitted
      : materials.isEmpty
      ? InferenceContextSourceStatus.empty
      : InferenceContextSourceStatus.contributed;
}

/// Authoritative pure-data input for one inference, without executable bindings.
final class InferenceContextSnapshot {
  /// Captures strategy input and its instruction group without source discovery.
  InferenceContextSnapshot.fromStrategy(StrategyInferenceMaterial material)
    : this._(
        strategyMaterial: material,
        sourceResults: const <InferenceContextSourceResult>[],
      );

  InferenceContextSnapshot._({
    required StrategyInferenceMaterial strategyMaterial,
    required List<InferenceContextSourceResult> sourceResults,
  }) : input = List<SemanticModelInputItem>.unmodifiable(
         strategyMaterial.input,
       ),
       sourceResults = List<InferenceContextSourceResult>.unmodifiable(
         sourceResults,
       ),
       instructionGroups = List<InferenceInstructionGroup>.unmodifiable(
         <InferenceInstructionGroup>[
           StrategyInstructionGroup._(strategyMaterial.instructions),
           for (final InferenceContextSourceResult result in sourceResults)
             if (result.status == InferenceContextSourceStatus.contributed)
               SourceInstructionGroup._(result.sourceId, result.materials),
         ],
       );

  /// A frozen copy of the strategy's ordered semantic input.
  final List<SemanticModelInputItem> input;

  /// Always starts with a [StrategyInstructionGroup], even for empty text,
  /// followed by nonempty source groups in lexicographic source-ID order.
  final List<InferenceInstructionGroup> instructionGroups;

  /// All source outcomes in lexicographic source-ID order, including empty
  /// successes and optional omissions.
  final List<InferenceContextSourceResult> sourceResults;
}

/// Joins instruction texts with blank lines, without rendering keys or revisions.
///
/// An empty strategy string is omitted only from this projection. Whitespace-only
/// strategy text is preserved, and zero sources render the exact strategy string.
String renderInferenceInstructions(InferenceContextSnapshot snapshot) =>
    <String>[
      for (final InferenceInstructionGroup group in snapshot.instructionGroups)
        ...switch (group) {
          StrategyInstructionGroup(:final instructions) => <String>[
            if (instructions.isNotEmpty) instructions,
          ],
          SourceInstructionGroup(:final materials) => materials.map(
            (InferenceInstructionMaterial material) => material.text,
          ),
        },
    ].join('\n\n');

/// Captures current instruction sources into a host-owned immutable snapshot.
final class InferenceContextComposer {
  const InferenceContextComposer(this._registry);

  final ExtensionRegistry _registry;

  /// Discovers once and captures every contribution and policy before awaits,
  /// then invokes sources in lexicographic binding-ID order.
  /// This is deterministic composition order, not semantic authority or priority.
  ///
  /// Each exact binding is validated before invocation and after complete
  /// iterable capture. Successful captures become pure data: subsequent source
  /// retirement does not invalidate them. No same-inference rediscovery or
  /// replacement fallback occurs. Required failures throw
  /// [InferenceContextSourceFailed]; optional failures retain omission evidence.
  Future<InferenceContextSnapshot> compose({
    required StrategyInferenceMaterial strategyMaterial,
    required InferenceContextSourceContext sourceContext,
  }) async {
    // Capture every policy before any callback or await can retire a binding.
    // Removing each entry also releases its executable dependency after capture.
    final pending = Queue.of(
      <
          ({
            ExtensionBinding<InferenceContextSourceContribution> binding,
            InferenceContextSourceContribution contribution,
          })
        >[
          for (final binding in _registry.discover(inferenceContextSources))
            (binding: binding, contribution: binding.value),
        ]
        ..sort((a, b) => a.binding.id.value.compareTo(b.binding.id.value)),
    );
    final List<InferenceContextSourceResult> results =
        <InferenceContextSourceResult>[];
    while (pending.isNotEmpty) {
      final source = pending.removeFirst();
      final ExtensionId sourceId = source.binding.id;
      final InferenceContextFailureMode failureMode =
          source.contribution.failureMode;
      try {
        source.binding.validate();
        final Iterable<InferenceContextMaterial> supplied = await source
            .contribution
            .snapshot(sourceContext);
        final List<InferenceInstructionMaterial> materials =
            <InferenceInstructionMaterial>[];
        final Set<String> keys = <String>{};
        for (final InferenceContextMaterial material in supplied) {
          final InferenceInstructionMaterial copied = switch (material) {
            InferenceInstructionMaterial(
              :final key,
              :final text,
              :final revision,
            ) =>
              InferenceInstructionMaterial(
                key: key,
                text: text,
                revision: revision,
              ),
          };
          if (!keys.add(copied.key)) {
            throw FormatException(
              'Duplicate inference instruction key ${copied.key} in $sourceId.',
            );
          }
          materials.add(copied);
        }
        // Lazy iteration is source execution too. Commit nothing until it ends.
        source.binding.validate();
        results.add(
          InferenceContextSourceResult._(
            sourceId: sourceId,
            failureMode: failureMode,
            materials: materials,
          ),
        );
      } catch (cause, stackTrace) {
        final InferenceContextSourceFailed failure =
            InferenceContextSourceFailed(sourceId, cause, stackTrace);
        if (failureMode == InferenceContextFailureMode.required) {
          Error.throwWithStackTrace(failure, stackTrace);
        }
        results.add(
          InferenceContextSourceResult._(
            sourceId: sourceId,
            failureMode: failureMode,
            failure: failure,
          ),
        );
      }
    }
    return InferenceContextSnapshot._(
      strategyMaterial: strategyMaterial,
      sourceResults: results,
    );
  }
}

/// A source capture failure retaining the original cause and stack trace.
///
/// Thrown for required sources and retained in optional omission results.
final class InferenceContextSourceFailed implements Exception {
  const InferenceContextSourceFailed(
    this.sourceId,
    this.cause,
    this.stackTrace,
  );

  final ExtensionId sourceId;
  final Object cause;
  final StackTrace stackTrace;

  @override
  String toString() => 'InferenceContextSourceFailed: Source $sourceId: $cause';
}
