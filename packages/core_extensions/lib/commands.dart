import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';

/// Stable semantic identity, distinct from an extension registration identity.
final class CommandId {
  factory CommandId(String value) {
    validateAdelePublicId(value, label: 'command ID');
    return CommandId._(value);
  }

  const CommandId._(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CommandId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Independent commands, with no default or priority. Duplicate [CommandId]s
/// are ambiguous regardless of their current availability.
final ExtensionPoint<CommandContribution> commandContributions =
    ExtensionPoint<CommandContribution>('dev.adele.extension.commands');

enum CommandAvailability { hidden, disabled, enabled }

final class CommandContribution {
  CommandContribution({
    required this.id,
    required this.label,
    required this.availability,
    required this.invoke,
  }) {
    if (label.trim().isEmpty ||
        label.length > 160 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(label)) {
      throw ArgumentError.value(
        label,
        'label',
        'Must be nonblank, at most 160 UTF-16 code units, and contain no '
            'control characters or line breaks.',
      );
    }
  }

  final CommandId id;

  /// A single-line display label, limited to 160 UTF-16 code units.
  final String label;

  /// A cheap, synchronous, read-only evaluation of current owner state.
  /// State changes do not notify consumers; hosts reevaluate when presenting or
  /// invoking commands, and observe [ExtensionRegistry.changes] for membership.
  final CommandAvailability Function() availability;

  /// Concrete domain behavior. Consumers use [ResolvedCommand.invoke] to enforce
  /// current availability and exact registration admission.
  final FutureOr<void> Function() invoke;
}

final class CommandResolver {
  const CommandResolver(this._registry);

  final ExtensionRegistry _registry;

  /// Captures uniquely identified commands without evaluating availability.
  /// Hidden and disabled commands remain discoverable; ambiguous IDs are omitted
  /// entirely. Results sort by case-insensitive label, then stable command ID.
  List<ResolvedCommand> discover() {
    final unique = <CommandId, ExtensionBinding<CommandContribution>?>{};
    for (final binding in _registry.discover(commandContributions)) {
      final id = binding.value.id;
      unique[id] = unique.containsKey(id) ? null : binding;
    }
    final commands =
        <ResolvedCommand>[
          for (final binding in unique.values)
            if (binding != null) ResolvedCommand._(this, binding),
        ]..sort((a, b) {
          final byLabel = a.label.toLowerCase().compareTo(
            b.label.toLowerCase(),
          );
          return byLabel != 0 ? byLabel : a.id.value.compareTo(b.id.value);
        });
    return List<ResolvedCommand>.unmodifiable(commands);
  }

  ResolvedCommand resolve(CommandId id) {
    final matches = <ExtensionBinding<CommandContribution>>[
      for (final binding in _registry.discover(commandContributions))
        if (binding.value.id == id) binding,
    ];
    if (matches.isEmpty) throw CommandNotFound(id);
    if (matches.length > 1) {
      throw AmbiguousCommand(id, matches.map((binding) => binding.id));
    }
    return ResolvedCommand._(this, matches.single);
  }
}

/// Captures one exact registration and never retargets a replacement.
final class ResolvedCommand {
  ResolvedCommand._(this._resolver, this.binding)
    : id = binding.value.id,
      label = binding.value.label;

  final CommandResolver _resolver;
  final CommandId id;
  final String label;
  final ExtensionBinding<CommandContribution> binding;

  /// Fails closed on evaluation errors, retirement, or identity conflicts.
  CommandAvailability get availability {
    try {
      return _checkedAvailability();
    } on Object {
      return CommandAvailability.disabled;
    }
  }

  /// Revalidates liveness, unique exact resolution, and current availability
  /// synchronously before entering the callback. An admitted asynchronous action
  /// may finish after retirement; completion is neither cancelled nor revalidated.
  /// Implementation failures propagate unchanged for caller-owned containment.
  Future<void> invoke() async {
    if (_checkedAvailability() != CommandAvailability.enabled) {
      throw CommandUnavailable(id);
    }
    await binding.value.invoke();
  }

  CommandAvailability _checkedAvailability() {
    _validateBinding();
    CommandAvailability current;
    try {
      current = binding.value.availability();
    } on Object {
      current = CommandAvailability.disabled;
    }
    // Contribution code must not invalidate admission while being evaluated.
    _validateBinding();
    return current;
  }

  void _validateBinding() {
    binding.validate();
    final current = _resolver.resolve(id);
    if (!binding.isSameRegistration(current.binding)) {
      throw StaleExtensionBinding(binding.id);
    }
  }
}

final class CommandNotFound implements Exception {
  const CommandNotFound(this.id);

  final CommandId id;

  @override
  String toString() => 'CommandNotFound: Command $id is not registered.';
}

final class AmbiguousCommand implements Exception {
  AmbiguousCommand(this.id, Iterable<ExtensionId> extensionIds)
    : extensionIds = List<ExtensionId>.unmodifiable(
        List<ExtensionId>.of(extensionIds)
          ..sort((a, b) => a.value.compareTo(b.value)),
      );

  final CommandId id;
  final List<ExtensionId> extensionIds;

  @override
  String toString() =>
      'AmbiguousCommand: Command $id is contributed by '
      '${extensionIds.join(', ')}.';
}

final class CommandUnavailable implements Exception {
  const CommandUnavailable(this.id);

  final CommandId id;

  @override
  String toString() => 'CommandUnavailable: Command $id is not enabled.';
}
