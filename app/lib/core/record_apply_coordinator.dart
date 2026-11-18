import 'dart:async';

import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'application_plugin_bootstrap.dart';

typedef RecordApplyKey = ({
  RecordCollectionId collection,
  RecordTypeId type,
  ConfigurationRecordId id,
});

enum RecordApplyStatus {
  applying,
  applied,
  noChange,
  failed,
  unavailable,
  restartRequired,
  notApplied,
}

final class RecordApplyOutcome {
  const RecordApplyOutcome(
    this.status,
    this.code, {
    this.cleanupPending = false,
  });

  final RecordApplyStatus status;
  // A bounded machine discriminator, never rendered or used as error text.
  final String code;
  final bool cleanupPending;

  static final _code = RegExp(r'^[a-z]+(?:_[a-z]+)*$');

  static RecordApplyOutcome _decode(Object? value) {
    if (value case {
      'status': final String status,
      'code': final String code,
      'cleanupPending': final bool cleanup,
    } when value.length == 3 && code.length <= 64 && _code.hasMatch(code)) {
      final decoded = switch (status) {
        'applied' => RecordApplyStatus.applied,
        'noChange' => RecordApplyStatus.noChange,
        'failed' => RecordApplyStatus.failed,
        'unavailable' when code == 'publication_outcome_unknown' =>
          RecordApplyStatus.restartRequired,
        'unavailable' => RecordApplyStatus.unavailable,
        _ => null,
      };
      if (decoded != null) {
        return RecordApplyOutcome(decoded, code, cleanupPending: cleanup);
      }
    }
    return const RecordApplyOutcome(RecordApplyStatus.failed, 'invalid_result');
  }
}

/// Native Global Settings sees identities and safe outcomes, never a backend
/// channel, editable baseline, secret, or caller-selected service/method.
abstract interface class RecordApplication implements Listenable {
  bool supports(RecordApplyKey key);
  RecordApplyOutcome? outcome(RecordApplyKey key);
  RecordApplyKey? recentDeletion(RecordCollectionId collection);
  void saved(RecordApplyKey key, {bool deleted = false});
  void unconfirmed(RecordApplyKey key);
  void reconciled(RecordApplyKey key);
  void retry(RecordApplyKey key);
}

typedef _Handler = ({
  PreparedPluginInstallation installation,
  PreparedRecordApplyHandler declaration,
});

final class _ApplyEntry {
  int sequence = 0;
  bool running = false;
  InstalledBackendActivation? owner;
  RecordApplyOutcome? outcome;
}

const _applying = RecordApplyOutcome(RecordApplyStatus.applying, 'applying');
const _notApplied = RecordApplyOutcome(
  RecordApplyStatus.notApplied,
  'not_applied',
);
const _unavailable = RecordApplyOutcome(
  RecordApplyStatus.unavailable,
  'backend_unavailable',
);
const _restart = RecordApplyOutcome(
  RecordApplyStatus.restartRequired,
  'publication_outcome_unknown',
);

/// One in-memory owner per application/catalog. Acknowledgements enqueue at
/// most one runner per record; each runner captures the latest requested state,
/// not the historical bytes from a particular edit. No storage work is retried.
final class RecordApplyCoordinator extends ChangeNotifier
    implements RecordApplication {
  RecordApplyCoordinator(this._bootstrap, this._catalog) {
    if (!identical(_bootstrap.catalog, _catalog)) {
      throw ArgumentError('Record application requires the startup catalog.');
    }
    // Use the validated aggregate as well as exact installation declarations:
    // ambiguous record catalogs never acquire execution authority.
    final records = _catalog.records;
    for (final installation in _catalog.installations) {
      for (final declaration in installation.backendRecordApplyHandlers) {
        final type = records.definition(declaration.recordType);
        _handlers[(type.collection, type.id)] = (
          installation: installation,
          declaration: declaration,
        );
      }
    }
  }

  final ApplicationPluginBootstrap _bootstrap;
  final PreparedPluginCatalog _catalog;
  final _handlers = <(RecordCollectionId, RecordTypeId), _Handler>{};
  final _entries = <RecordApplyKey, _ApplyEntry>{};
  final _deletions = <RecordCollectionId, RecordApplyKey>{};
  final _retirement = <InstalledBackendActivation, VoidCallback>{};
  final _uncertain = <InstalledBackendActivation>{};
  static const _maxActive = 16;
  static const _maxEntries = 128;
  int _active = 0;
  bool _closed = false;

  @override
  bool supports(RecordApplyKey key) =>
      _handlers.containsKey((key.collection, key.type));

  @override
  RecordApplyOutcome? outcome(RecordApplyKey key) => _entries[key]?.outcome;

  @override
  RecordApplyKey? recentDeletion(RecordCollectionId collection) =>
      _deletions[collection];

  @override
  void saved(RecordApplyKey key, {bool deleted = false}) {
    if (_closed || !supports(key)) return;
    if (deleted) {
      _deletions[key.collection] = key;
    } else if (_deletions[key.collection] == key) {
      _deletions.remove(key.collection);
    }
    _request(key, apply: true);
  }

  @override
  void reconciled(RecordApplyKey key) => _request(key, apply: false);

  /// An ambiguous write is not an apply request. Don't attribute a previous
  /// outcome (even one still in flight) to the unconfirmed persisted state.
  @override
  void unconfirmed(RecordApplyKey key) {
    final entry = _entries[key];
    if (_closed || entry == null) return;
    entry.sequence++;
    entry.outcome = null;
    if (_deletions[key.collection] == key) _deletions.remove(key.collection);
    notifyListeners();
  }

  @override
  void retry(RecordApplyKey key) {
    switch (outcome(key)?.status) {
      case RecordApplyStatus.failed ||
          RecordApplyStatus.unavailable ||
          RecordApplyStatus.notApplied:
        _request(key, apply: true);
      default:
        break;
    }
  }

  void _request(RecordApplyKey key, {required bool apply}) {
    final handler = _handlers[(key.collection, key.type)];
    if (_closed || handler == null) return;
    final entry = _entries.remove(key) ?? _ApplyEntry();
    if (_entries.length == _maxEntries) {
      final oldest = _entries.entries
          .firstWhere((item) => !item.value.running)
          .key;
      _entries.remove(oldest);
      if (_deletions[oldest.collection] == oldest) {
        _deletions.remove(oldest.collection);
      }
    }
    _entries[key] = entry;
    entry.sequence++;
    final owner = entry.owner = _owner(handler);
    if (owner == null) {
      entry.outcome = _unavailable;
    } else if (_uncertain.contains(owner)) {
      entry.outcome = _restart;
    } else if (!apply) {
      entry.outcome = _notApplied;
    } else if (!entry.running && _active >= _maxActive) {
      entry.outcome = const RecordApplyOutcome(
        RecordApplyStatus.unavailable,
        'apply_capacity',
      );
    } else {
      entry.outcome = _applying;
      if (!entry.running) {
        entry.running = true;
        _active++;
        // The caller observes an acknowledged persistence Future. Never run a
        // backend call in a Settings mutation or credential admission callback.
        scheduleMicrotask(() => _run(key, handler, entry));
      }
    }
    notifyListeners();
  }

  InstalledBackendActivation? _owner(_Handler handler) {
    if (_closed || !identical(_bootstrap.catalog, _catalog)) return null;
    try {
      final owner = _bootstrap.backendForInstallation(handler.installation);
      if (owner != null) {
        owner.connection!.validateInfrastructureContext();
        _retirement.putIfAbsent(
          owner,
          () => owner.onRetire(() {
            _retirement.remove(owner);
            _uncertain.remove(owner);
            for (final entry in _entries.values.where(
              (e) => identical(e.owner, owner),
            )) {
              entry.owner = null;
              if (entry.outcome != null) entry.outcome = _unavailable;
              entry.sequence++;
            }
            if (!_closed) notifyListeners();
          }),
        );
      }
      return owner;
    } on Object {
      return null;
    }
  }

  Future<void> _run(
    RecordApplyKey key,
    _Handler handler,
    _ApplyEntry entry,
  ) async {
    try {
      while (!_closed && entry.outcome?.status == RecordApplyStatus.applying) {
        final sequence = entry.sequence;
        final owner = entry.owner;
        RecordApplyOutcome result;
        if (owner == null || !identical(_owner(handler), owner)) {
          result = _unavailable;
        } else if (_uncertain.contains(owner)) {
          result = _restart;
        } else {
          try {
            final response = await owner.connection!.requestRecordApply(
              handler.declaration,
              key.id,
            );
            result = RecordApplyOutcome._decode(response);
          } on Object {
            result = const RecordApplyOutcome(
              RecordApplyStatus.failed,
              'apply_failed',
            );
          }
          if (_closed || !identical(_owner(handler), owner)) {
            result = _unavailable;
          } else if (result.status == RecordApplyStatus.restartRequired) {
            // A lost publication acknowledgement fences this generation, even
            // if the triggering request has already been superseded.
            _uncertain.add(owner);
            for (final affected in _entries.values) {
              final status = affected.outcome?.status;
              if (identical(affected.owner, owner) &&
                  status != null &&
                  status != RecordApplyStatus.applied &&
                  status != RecordApplyStatus.noChange) {
                affected.outcome = _restart;
              }
            }
          } else if (_uncertain.contains(owner)) {
            result = _restart;
          }
        }
        if (!_closed && entry.sequence == sequence) entry.outcome = result;
      }
    } finally {
      entry.running = false;
      _active--;
      if (!_closed) notifyListeners();
    }
  }

  /// Fence immediately. Existing transport teardown settles admitted calls;
  /// they neither delay application exit nor publish after this point.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final cancel in _retirement.values) {
      cancel();
    }
    _retirement.clear();
    _uncertain.clear();
    for (final entry in _entries.values) {
      entry.owner = null;
      if (entry.outcome != null) entry.outcome = _unavailable;
    }
    notifyListeners();
    dispose();
  }
}
