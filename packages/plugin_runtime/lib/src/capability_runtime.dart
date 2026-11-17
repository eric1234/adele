import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';

import 'backend_connection.dart';

final class AdeleRequestChannelEndpoint implements CapabilityEndpoint {
  const AdeleRequestChannelEndpoint({
    required this.channel,
    required this.serviceId,
    required bool Function() isAvailable,
  }) : _isAvailable = isAvailable;

  final AdeleRequestChannel channel;
  final bool Function() _isAvailable;
  @override
  final String serviceId;
  @override
  bool get isAvailable => _isAvailable();
}

final class PluginCapabilityExposure {
  PluginCapabilityExposure({
    required this.provider,
    required this.configurationContext,
    this.association,
    this.environmentBound = false,
    List<AdeleEnvironmentHostService> environmentHostServices = const [],
  }) : environmentHostServices = List.unmodifiable(environmentHostServices);

  final ProviderDescriptor provider;
  final ConfigurationContextId configurationContext;
  final AdeleProviderAssociation? association;

  /// Independent Environment binding, mutually exclusive with [association].
  /// Registration validates this declaration; it grants no authority.
  final bool environmentBound;

  /// Explicit service opt-ins; registration never grants invocation authority.
  final List<AdeleEnvironmentHostService> environmentHostServices;

  AdeleCapabilityExposure? _advertisement;
}

extension ProviderBindingRequestChannel on ProviderBinding {
  AdeleRequestChannel get requestChannel =>
      endpointAs<AdeleRequestChannelEndpoint>().channel;

  AdeleStreamChannel get streamChannel {
    final AdeleRequestChannel channel = requestChannel;
    if (channel is! AdeleStreamChannel) {
      throw StateError('The provider does not support generated streaming.');
    }
    return channel;
  }
}

/// One exact group incarnation. Only its owning activation can mutate it.
/// Retirement never follows semantic IDs to a replacement group.
final class PluginCapabilityGroup {
  PluginCapabilityGroup._(this._owner, this._members) {
    for (final member in _members) {
      _registrations.add(member.registration);
      member.group = this;
    }
  }

  final Object _owner;
  final List<_CapabilityMember> _members;
  final CapabilityRegistrationGroup _registrations =
      CapabilityRegistrationGroup();
  Future<void>? _retiring;
  bool _retired = false;

  /// Also true when individual retirement has invalidated a member of this group.
  bool get isRetired =>
      _retired || _members.any((member) => member.registration.isClosed);
}

final class _CapabilityMember {
  _CapabilityMember(this.exposure, this.registration)
    : binding = registration.binding;

  final PluginCapabilityExposure exposure;
  final CapabilityRegistration registration;
  final ProviderBinding binding;
  ProviderBinding? association;
  PluginCapabilityGroup? group;
}

final class PluginCapabilityActivation {
  PluginCapabilityActivation._(this.connection, this._registry);

  final PluginBackendConnection connection;
  final CapabilityRegistrationGroup registrations =
      CapabilityRegistrationGroup();
  final CapabilityRegistry _registry;
  final Object _groupOwner = Object();
  final Set<_CapabilityMember> _members = {};
  final Set<PluginCapabilityGroup> _groups = {};
  Future<void> _mutations = Future<void>.value();
  Future<void>? _retiring;
  bool _admissionFenced = false;

  /// Permanently stops executable admission without closing registrations or
  /// invoking observers. A composite owner must still call [retire] for cleanup.
  void fenceAdmission() => _admissionFenced = true;

  bool owns(ProviderBinding binding) {
    binding.endpointAs<CapabilityEndpoint>();
    return !_admissionFenced &&
        !connection.isClosed &&
        registrations.owns(binding);
  }

  /// Retires only this exact owned provider; the connection and siblings survive.
  /// Unlike executable access, retirement does not require a healthy endpoint.
  Future<void> retireProvider(ProviderBinding binding) {
    if (_admissionFenced ||
        connection.isClosed ||
        !registrations.owns(binding)) {
      throw const InvalidProviderRegistration(
        'The provider is not owned by this live activation.',
      );
    }
    return registrations.retire(binding);
  }

  /// Returns an exact live sibling, or null for an unassociated/foreign binding.
  /// Retirement fails validation; semantic IDs never re-resolve the target.
  ProviderBinding? associationFor(ProviderBinding binding) {
    if (!owns(binding)) return null;
    for (final member in _members) {
      if (member.registration.owns(binding)) {
        final target = member.association;
        if (target == null || !owns(target)) return null;
        return target;
      }
    }
    return null;
  }

  /// Returns the opt-in for this exact live registration, false if foreign.
  /// Retirement fails validation, as for [associationFor]. No authority is granted.
  bool isEnvironmentBound(ProviderBinding binding) {
    if (!owns(binding)) return false;
    return _members.any(
      (member) =>
          member.registration.owns(binding) && member.exposure.environmentBound,
    );
  }

  /// Checks an explicit declaration on this exact live owned registration.
  /// This does not grant authority or change legacy read admission behavior.
  bool allowsEnvironmentHostService(
    ProviderBinding binding,
    AdeleEnvironmentHostService service,
  ) {
    if (!owns(binding)) return false;
    for (final member in _members) {
      if (member.registration.owns(binding)) {
        return member.exposure.environmentHostServices.contains(service);
      }
    }
    return false;
  }

  /// Uses registry ordering only among exact siblings of [associatedWith].
  ProviderBinding resolveAssociatedProvider(
    CapabilityKey capability, {
    required ProviderBinding associatedWith,
    ProviderId? providerId,
  }) {
    if (!owns(associatedWith)) {
      throw const InvalidProviderRegistration(
        'The associated binding is not owned by this activation.',
      );
    }
    final eligible = <ProviderBinding>[];
    for (final provider in _registry.providersFor(capability)) {
      final binding = _registry.resolve(capability, providerId: provider.id);
      for (final member in _members) {
        if (member.registration.owns(binding) &&
            (member.association?.isSameRegistration(associatedWith) ?? false) &&
            associationFor(binding) != null) {
          eligible.add(binding);
          break;
        }
      }
    }
    if (providerId != null) {
      for (final binding in eligible) {
        if (binding.provider.id == providerId) return binding;
      }
      throw ProviderUnavailable(
        capability: capability,
        providerId: providerId,
        availableProviderIds: eligible.map((binding) => binding.provider.id),
      );
    }
    if (eligible.isEmpty) throw CapabilityUnavailable(capability);
    return eligible.first;
  }

  static Future<PluginCapabilityActivation> registerAdvertised({
    required PluginBackendConnection connection,
    required CapabilityRegistry registry,
    void Function()? beforeRollback,
  }) => register(
    connection: connection,
    registry: registry,
    beforeRollback: beforeRollback,
    exposures: connection.capabilityExposures.map(
      (exposure) => _adapt(connection, exposure),
    ),
  );

  static PluginCapabilityExposure _adapt(
    PluginBackendConnection connection,
    AdeleCapabilityExposure exposure,
  ) => PluginCapabilityExposure(
    provider: ProviderDescriptor(
      id: ProviderId(exposure.providerId),
      capability: CapabilityKey(
        id: CapabilityId(exposure.capabilityId),
        majorVersion: exposure.capabilityMajorVersion,
      ),
      pluginId: connection.pluginId,
      displayName: exposure.displayName,
      serviceId: exposure.serviceId,
      rank: exposure.rank,
    ),
    configurationContext: connection.configurationContext(
      exposure.configurationContext,
    ),
    association: exposure.association,
    environmentBound: exposure.environmentBound,
    environmentHostServices: exposure.environmentHostServices,
  ).._advertisement = exposure;

  /// Failure rolls back only this attempt's registrations. A generation owner can
  /// supply [beforeRollback] to synchronously revoke before rollback cleanup.
  static Future<PluginCapabilityActivation> register({
    required PluginBackendConnection connection,
    required CapabilityRegistry registry,
    required Iterable<PluginCapabilityExposure> exposures,
    void Function()? beforeRollback,
  }) async {
    if (connection.isClosed) {
      throw InvalidProviderRegistration(
        'Plugin generation ${connection.pluginId} is inactive.',
      );
    }
    final activation = PluginCapabilityActivation._(connection, registry);
    final acquired = <_CapabilityMember>[];
    try {
      for (final PluginCapabilityExposure exposure in exposures) {
        acquired.add(activation._acquire(exposure));
      }
      // Keep exposure iteration lazy, then allow forward sibling references.
      activation._bindAssociations(acquired);
      activation._validateLive();
    } on Object {
      activation.fenceAdmission();
      try {
        try {
          beforeRollback?.call();
        } finally {
          await activation.retire();
        }
      } on Object {
        // Rollback must finish, but cannot replace the original activation error.
      }
      rethrow;
    }
    unawaited(
      connection.terminated
          .then((Object _) => activation.retire())
          .catchError((Object _) {}),
    );
    return activation;
  }

  void _validateLive() {
    if (_admissionFenced || registrations.isClosed || connection.isClosed) {
      throw const PluginConnectionClosed(
        'The capability activation is retired.',
      );
    }
  }

  AdeleRequestChannelEndpoint _endpoint(PluginCapabilityExposure exposure) {
    final provider = exposure.provider;
    if (exposure.environmentBound && exposure.association != null) {
      throw InvalidProviderRegistration(
        'Environment-bound provider ${provider.id} cannot declare a sibling association.',
      );
    }
    if (exposure.environmentHostServices.toSet().length !=
        exposure.environmentHostServices.length) {
      throw InvalidProviderRegistration(
        'Provider ${provider.id} declares duplicate Environment host services.',
      );
    }
    if (!exposure.environmentBound &&
        exposure.environmentHostServices.contains(
          AdeleEnvironmentHostService.bufferedProcess,
        )) {
      throw InvalidProviderRegistration(
        'Provider ${provider.id} must be Environment-bound to declare buffered process access.',
      );
    }
    if (provider.pluginId != connection.pluginId) {
      throw InvalidProviderRegistration(
        'Provider ${provider.id} belongs to ${provider.pluginId}, not ${connection.pluginId}.',
      );
    }
    return AdeleRequestChannelEndpoint(
      channel: connection.channelFor(
        exposure.configurationContext,
        provider.serviceId,
      ),
      serviceId: provider.serviceId,
      isAvailable: () => !_admissionFenced && !connection.isClosed,
    );
  }

  _CapabilityMember _acquire(PluginCapabilityExposure exposure) {
    _validateLive();
    final registration = _registry.register(
      provider: exposure.provider,
      endpoint: _endpoint(exposure),
    );
    // Attach every acquired occurrence to generation cleanup before any yield.
    registrations.add(registration);
    final member = _CapabilityMember(exposure, registration);
    _members.add(member);
    member.binding.onRetire(() {
      _members.remove(member);
      final group = member.group;
      if (group != null) {
        group._retired = true;
        if (group._members.every((entry) => entry.registration.isClosed)) {
          _groups.remove(group);
          group._members.clear();
        }
      }
    });
    return member;
  }

  /// Resolves declarations only within this publication, never against global IDs.
  static Map<PluginCapabilityExposure, PluginCapabilityExposure>
  _associationTargets(Iterable<PluginCapabilityExposure> exposures) {
    final byKey = <(CapabilityKey, ProviderId), PluginCapabilityExposure>{};
    for (final exposure in exposures) {
      final key = (exposure.provider.capability, exposure.provider.id);
      if (byKey.containsKey(key)) {
        throw DuplicateProviderRegistration(
          'Duplicate provider ${key.$2} in capability group.',
        );
      }
      byKey[key] = exposure;
    }
    final targets = <PluginCapabilityExposure, PluginCapabilityExposure>{};
    for (final source in byKey.values) {
      final declaration = source.association;
      if (declaration == null) continue;
      final target =
          byKey[(
            CapabilityKey(
              id: CapabilityId(declaration.capabilityId),
              majorVersion: declaration.capabilityMajorVersion,
            ),
            ProviderId(declaration.providerId),
          )];
      if (target == null ||
          identical(source, target) ||
          target.association != null) {
        throw InvalidProviderRegistration(
          'Provider ${source.provider.id} association must name an unassociated direct sibling owned by this publication.',
        );
      }
      targets[source] = target;
    }
    return targets;
  }

  void _bindAssociations(List<_CapabilityMember> members) {
    final targets = _associationTargets(
      members.map((member) => member.exposure),
    );
    for (final source in members) {
      final targetExposure = targets[source.exposure];
      if (targetExposure == null) continue;
      final target = members.singleWhere(
        (member) => identical(member.exposure, targetExposure),
      );
      try {
        source.binding.endpointAs<CapabilityEndpoint>();
        target.binding.endpointAs<CapabilityEndpoint>();
      } on CapabilityException {
        throw InvalidProviderRegistration(
          'Provider ${source.binding.provider.id} association is unavailable.',
        );
      }
      source.association = target.binding;
    }
  }

  /// Adopts original ready registration occurrences without replacing bindings.
  /// Both ends of every association touching the subset must be included.
  PluginCapabilityGroup adoptAdvertisedCapabilityGroup({
    required List<AdeleCapabilityExposure> expected,
  }) {
    _validateLive();
    final selected = <_CapabilityMember>[];
    for (final exposure in expected) {
      final matches = _members.where((member) {
        final advertisement = member.exposure._advertisement;
        return advertisement != null &&
            _sameAdvertisement(advertisement, exposure);
      }).toList();
      if (matches.length != 1 ||
          matches.single.group != null ||
          selected.contains(matches.single)) {
        throw const InvalidProviderRegistration(
          'The advertised group is foreign, stale, mismatched or already adopted.',
        );
      }
      final member = matches.single;
      member.binding.endpointAs<CapabilityEndpoint>();
      selected.add(member);
    }
    for (final member in _members) {
      final target = member.association;
      if (target == null) continue;
      final sourceIncluded = selected.contains(member);
      final targetIncluded = selected.any(
        (entry) => entry.registration.owns(target),
      );
      if (sourceIncluded != targetIncluded) {
        throw const InvalidProviderRegistration(
          'An adopted group must be association-closed.',
        );
      }
    }
    return _group(selected);
  }

  static bool _sameAdvertisement(
    AdeleCapabilityExposure left,
    AdeleCapabilityExposure right,
  ) =>
      left.providerId == right.providerId &&
      left.capabilityId == right.capabilityId &&
      left.capabilityMajorVersion == right.capabilityMajorVersion &&
      left.serviceId == right.serviceId &&
      left.displayName == right.displayName &&
      left.configurationContext == right.configurationContext &&
      left.rank == right.rank &&
      left.environmentBound == right.environmentBound &&
      left.association?.providerId == right.association?.providerId &&
      left.association?.capabilityId == right.association?.capabilityId &&
      left.association?.capabilityMajorVersion ==
          right.association?.capabilityMajorVersion &&
      left.environmentHostServices.length ==
          right.environmentHostServices.length &&
      left.environmentHostServices.indexed.every(
        (entry) => entry.$2 == right.environmentHostServices[entry.$1],
      );

  PluginCapabilityGroup _group(List<_CapabilityMember> members) {
    final group = PluginCapabilityGroup._(_groupOwner, members);
    _groups.add(group);
    return group;
  }

  void _validateGroup(
    PluginCapabilityGroup expected, {
    bool requireLive = true,
  }) {
    if (!identical(expected._owner, _groupOwner)) {
      throw const InvalidProviderRegistration(
        'The capability group belongs to another activation.',
      );
    }
    if (requireLive && (expected.isRetired || !_groups.contains(expected))) {
      throw const InvalidProviderRegistration(
        'The capability group is retired.',
      );
    }
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    _validateLive();
    final result = _mutations
        .then((_) {
          _validateLive();
          return operation();
        })
        .then((value) {
          _validateLive();
          return value;
        });
    _mutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<PluginCapabilityGroup> publishCapabilityGroup({
    required List<AdeleCapabilityExposure> exposures,
  }) {
    final snapshot = List<AdeleCapabilityExposure>.of(exposures);
    return _serialize(() => _publish(snapshot));
  }

  Future<PluginCapabilityGroup> replaceCapabilityGroup({
    required PluginCapabilityGroup expected,
    required List<AdeleCapabilityExposure> exposures,
  }) {
    _validateGroup(expected);
    final snapshot = List<AdeleCapabilityExposure>.of(exposures);
    return _serialize(() => _publish(snapshot, expected: expected));
  }

  Future<PluginCapabilityGroup> _publish(
    List<AdeleCapabilityExposure> advertisements, {
    PluginCapabilityGroup? expected,
  }) async {
    _validateLive();
    if (expected != null) _validateGroup(expected);
    final exposures = advertisements
        .map((exposure) => _adapt(connection, exposure))
        .toList();
    _associationTargets(exposures);
    for (final exposure in exposures) {
      _registry.validateRegistration(
        provider: exposure.provider,
        endpoint: _endpoint(exposure),
        replacing:
            expected?._members.map((member) => member.binding) ?? const [],
      );
    }
    if (expected != null) {
      await _retireGroup(expected);
      _validateLive();
    }
    final acquired = <_CapabilityMember>[];
    try {
      for (final exposure in exposures) {
        // Dynamic members are not eligible for initial-ready adoption.
        exposure._advertisement = null;
        acquired.add(_acquire(exposure));
      }
      _bindAssociations(acquired);
      _validateLive();
      return _group(acquired);
    } on Object {
      final rollback = CapabilityRegistrationGroup();
      for (final member in acquired) {
        if (!member.registration.isClosed) rollback.add(member.registration);
      }
      try {
        await rollback.close();
      } on Object {
        // Only the new attempt rolls back; a retired group is never revived.
      }
      rethrow;
    }
  }

  Future<void> retireCapabilityGroup(PluginCapabilityGroup expected) {
    _validateGroup(expected, requireLive: false);
    final retiring = expected._retiring;
    if (retiring != null) return retiring;
    if (expected.isRetired && expected._members.isEmpty) {
      return _retireGroup(expected);
    }
    return _serialize(() => _retireGroup(expected));
  }

  Future<void> _retireGroup(PluginCapabilityGroup group) {
    final retiring = group._retiring;
    if (retiring != null) return retiring;
    final completion = Completer<void>();
    group._retiring = completion.future;
    group._retired = true;
    _groups.remove(group);
    group._members.clear();
    completion.complete(group._registrations.close());
    return completion.future;
  }

  Future<void> retire() {
    final retiring = _retiring;
    if (retiring != null) return retiring;
    fenceAdmission();
    final completion = Completer<void>();
    // Fence selection and join reentrant calls before synchronous observers run.
    _retiring = completion.future;
    for (final group in _groups) {
      group._retired = true;
      group._retiring = completion.future;
      group._members.clear();
    }
    _groups.clear();
    completion.complete(
      Future.wait<void>([registrations.close(), _mutations]).then<void>((_) {}),
    );
    return completion.future;
  }

  Future<void> close() async {
    fenceAdmission();
    connection.revokeInfrastructureContext();
    Object? firstError;
    StackTrace? firstStack;
    try {
      await retire();
    } catch (error, stack) {
      firstError = error;
      firstStack = stack;
    }
    try {
      if (!connection.isClosed) await connection.close();
    } catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    // Complete both obligations; a later shutdown error must not mask retirement.
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}
