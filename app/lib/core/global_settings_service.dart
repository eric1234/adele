import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer, RootIsolateToken;

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_backend_support/adele_backend_records.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_settings_host/adele_settings_host.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'credential_service.dart';
import 'prepared_records.dart';

export 'prepared_records.dart' show RecordDiagnosticView, StartupRecordsView;

part 'record_credential_service.dart';

/// An application owner's lease on the main isolate's shared settings worker.
///
/// Construct on the Flutter root isolate, never in independently spawned window
/// workers. All owners share one serial writer, including while a previous last
/// owner is closing. Stores, documents, and persistence baselines stay there.
base class GlobalSettingsService {
  GlobalSettingsService({
    required this.catalog,
    required PlatformStorageRoots roots,
    RecordCatalog? records,
  }) : records = records ?? RecordCatalog([]),
       _roots = roots,
       filePath = Directory(
         roots.configurationRoot,
       ).uri.resolve('settings.toml').toFilePath(),
       _worker = _SettingsWorker.acquire();

  final SettingsCatalog catalog;
  final RecordCatalog records;
  final String filePath;
  final PlatformStorageRoots _roots;
  final _SettingsWorker _worker;
  final Object _identity = Object();
  late final int _owner = _worker.nextOwner++;
  Future<void> _pending = Future<void>.value();
  Future<void>? _closing;

  /// A failed load invalidates this owner's previous edit baseline.
  Future<GlobalSettingsView> load() => _enqueueSettings(_Operation.load);

  Future<GlobalSettingsView> save(
    GlobalSettingsView expected,
    SettingId id,
    Object value,
  ) => _enqueueSettings(
    _Operation.save,
    expected: expected,
    id: id,
    value: value,
  );

  Future<GlobalSettingsView> reset(GlobalSettingsView expected, SettingId id) =>
      _enqueueSettings(_Operation.reset, expected: expected, id: id);

  /// Deliberately revokes this owner's older handles in the collection, even if
  /// enumeration fails. Other collections retain their independent baselines.
  Future<RecordCollectionView> loadRecords(RecordCollectionId collection) =>
      _enqueue<_RecordCollectionValues>(
        _Operation.loadRecords,
        collection: collection,
      ).then((loaded) => RecordCollectionView._(_identity, loaded));

  /// Read-only startup values for this exact installation's opted-in types.
  /// Unlike [loadRecords], this neither publishes nor invalidates edit handles.
  Future<StartupRecordsView> loadStartupRecords(
    PreparedPluginCatalog prepared,
    PreparedPluginInstallation installation,
  ) {
    if (_closing != null) {
      return Future.error(StateError('The settings service is closed.'));
    }
    try {
      if (!prepared.installations.any(
        (entry) => identical(entry, installation),
      )) {
        throw ArgumentError(
          'Records belong to another prepared catalog snapshot.',
        );
      }
      final definitions =
          installation.recordsSchema?.definitions ??
          const <RecordTypeDefinition>[];
      for (final id in installation.backendConsumedRecordTypes) {
        final definition = records.definition(id);
        if (definition.owner != installation.metadata.id ||
            !definitions.any((entry) => identical(entry, definition))) {
          throw ArgumentError(
            'Records belong to another prepared declaration snapshot.',
          );
        }
      }
      return _enqueue<_StartupRecordValues>(
        _Operation.loadStartupRecords,
        startupRecordTypes: installation.backendConsumedRecordTypes,
      ).then(
        (loaded) => StartupRecordsView.fromProjection(
          prepared,
          installation,
          records: loaded.records,
          diagnostics: loaded.diagnostics,
        ),
      );
    } on Object catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Future<RecordView> createRecord(
    RecordTypeId type,
    ConfigurationRecordId id,
    Map<String, Object?> values,
  ) => _enqueue<_RecordValues>(
    _Operation.createRecord,
    recordType: type,
    recordId: id,
    recordValues: Map.unmodifiable(values),
  ).then((saved) => RecordView._(_identity, saved));

  /// Replaces the complete known-field set using this owner's exact revision.
  /// A successful no-op also returns a fresh handle.
  Future<RecordView> updateRecord(
    RecordView expected,
    Map<String, Object?> values,
  ) => _enqueue<_RecordValues>(
    _Operation.updateRecord,
    expectedRecord: expected,
    recordValues: Map.unmodifiable(values),
  ).then((saved) => RecordView._(_identity, saved));

  /// Conditionally deletes the record and retires its edit handle.
  Future<void> deleteRecord(RecordView expected) =>
      _enqueue<void>(_Operation.deleteRecord, expectedRecord: expected);

  String collectionPath(RecordCollectionId collection) => Directory(
    _roots.configurationRoot,
  ).uri.resolve(collection.value).toFilePath();

  Future<GlobalSettingsView> _enqueueSettings(
    _Operation operation, {
    GlobalSettingsView? expected,
    SettingId? id,
    Object? value,
  }) => _enqueue<_Values>(
    operation,
    expected: expected,
    id: id,
    value: value,
  ).then((loaded) => GlobalSettingsView._(catalog, _identity, loaded));

  Future<T> _enqueue<T>(
    _Operation operation, {
    GlobalSettingsView? expected,
    RecordView? expectedRecord,
    SettingId? id,
    Object? value,
    RecordCollectionId? collection,
    RecordTypeId? recordType,
    ConfigurationRecordId? recordId,
    Map<String, Object?>? recordValues,
    List<RecordTypeId>? startupRecordTypes,
  }) {
    if (_closing != null) {
      return Future.error(StateError('The settings service is closed.'));
    }
    if ((expected != null && !identical(expected._owner, _identity)) ||
        (expectedRecord != null &&
            !identical(expectedRecord._owner, _identity))) {
      return Future.error(
        ArgumentError('The view belongs to another settings owner.'),
      );
    }
    final result = _pending.then((_) async {
      return await _worker.request(
            _Request(
              owner: _owner,
              operation: operation,
              catalog: catalog,
              records: records,
              roots: _roots,
              revision: expected?._revision ?? expectedRecord?._revision,
              setting: id,
              value: value,
              collection: collection ?? expectedRecord?.collection,
              recordType: recordType ?? expectedRecord?.type,
              recordId: recordId ?? expectedRecord?.id,
              recordValues: recordValues,
              startupRecordTypes: startupRecordTypes,
            ),
          )
          as T;
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Fences new work immediately and drains admitted work without cancellation.
  /// The final lease waits for the worker to exit, not merely a stop request.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    await _pending;
    await _worker.release(_owner);
  }
}

/// Immutable display values, not a TOML edit buffer or a transferable baseline.
final class GlobalSettingsView {
  GlobalSettingsView._(this.catalog, this._owner, _Values result)
    : _revision = result.revision,
      values = Map.unmodifiable(result.values),
      failures = Map.unmodifiable(result.failures);

  final SettingsCatalog catalog;
  final Map<SettingId, ResolvedSetting<Object>> values;
  final Map<SettingId, Object> failures;
  final Object _owner;
  final int _revision;
}

/// Immutable presentation data with no record document or edit baseline.
final class RecordCollectionView {
  RecordCollectionView._(Object owner, _RecordCollectionValues result)
    : records = List.unmodifiable(
        result.records.map((record) => RecordView._(owner, record)),
      ),
      diagnostics = List.unmodifiable(result.diagnostics);

  final List<RecordView> records;
  final List<RecordDiagnosticView> diagnostics;
}

/// Immutable display values and an owner-scoped handle, never a native snapshot.
final class RecordView {
  RecordView._(this._owner, _RecordValues record)
    : _revision = record.revision,
      collection = record.collection,
      id = record.id,
      type = record.type,
      values = Map.unmodifiable(record.values);

  final RecordCollectionId collection;
  final ConfigurationRecordId id;
  final RecordTypeId type;
  final Map<String, Object> values;
  final Object _owner;
  final int _revision;
}

final class _StartupRecordValues {
  _StartupRecordValues(
    Iterable<ConfigurationRecordSnapshot> snapshots,
    Iterable<RecordDiagnosticView> diagnostics,
  ) : records = adeleCopyBackendRecords([
        for (final record in snapshots)
          {
            'collection': record.collection.value,
            'type': record.type.id.value,
            'id': record.id.value,
            'values': record.values,
          },
      ]),
      diagnostics = List.unmodifiable(diagnostics);

  final List<Map<String, Object?>> records;
  final List<RecordDiagnosticView> diagnostics;
}

RecordDiagnosticView _recordDiagnostic(
  ConfigurationRecordDiagnostic diagnostic,
) => RecordDiagnosticView(
  collection: diagnostic.collection,
  fileName: diagnostic.fileName,
  recordId: diagnostic.recordId,
  message: diagnostic.error.toString(),
);

enum _Operation {
  load,
  save,
  reset,
  loadRecords,
  loadStartupRecords,
  createRecord,
  updateRecord,
  deleteRecord,
  inspectCredential,
  setCredentialReference,
  refreshRecord,
  release,
}

final class _Request {
  const _Request({
    required this.owner,
    required this.operation,
    this.catalog,
    this.records,
    this.roots,
    this.revision,
    this.setting,
    this.value,
    this.collection,
    this.recordType,
    this.recordId,
    this.recordValues,
    this.startupRecordTypes,
    this.credentialSlot,
    this.credentialReference,
  });

  final int owner;
  final _Operation operation;
  final SettingsCatalog? catalog;
  final RecordCatalog? records;
  final PlatformStorageRoots? roots;
  final int? revision;
  final SettingId? setting;
  final Object? value;
  final RecordCollectionId? collection;
  final RecordTypeId? recordType;
  final ConfigurationRecordId? recordId;
  final Map<String, Object?>? recordValues;
  final List<RecordTypeId>? startupRecordTypes;
  final RecordCredentialSlotId? credentialSlot;
  final CredentialReference? credentialReference;
}

final class _Values {
  const _Values(this.revision, this.values, this.failures);

  final int revision;
  final Map<SettingId, ResolvedSetting<Object>> values;
  final Map<SettingId, Object> failures;
}

final class _RecordValues {
  _RecordValues(this.revision, ConfigurationRecordSnapshot record)
    : collection = record.collection,
      id = record.id,
      type = record.type.id,
      values = Map.unmodifiable(record.values);

  final int revision;
  final RecordCollectionId collection;
  final ConfigurationRecordId id;
  final RecordTypeId type;
  final Map<String, Object> values;
}

final class _RecordCollectionValues {
  _RecordCollectionValues(this.records, this.diagnostics);

  final List<_RecordValues> records;
  final List<RecordDiagnosticView> diagnostics;
}

/// Only the trusted coordinator receives this projection, not generic views.
final class _CredentialValues {
  const _CredentialValues(this.owner, this.reference);

  final String owner;
  final CredentialReference? reference;
}

/// The lease registry is main-isolate-only: Dart's Unix locks do not serialize
/// writers in different isolates of the same process.
final class _SettingsWorker {
  _SettingsWorker(Future<void>? predecessor) {
    // Startup can fail before an owner calls load; retain that failure without
    // leaving an unobserved asynchronous error.
    unawaited(
      _ready.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    unawaited(_start(predecessor));
  }

  static _SettingsWorker? _shared;
  static const _ownerName = 'dev.adele.global-settings-owner';

  static _SettingsWorker acquire() {
    if (RootIsolateToken.instance == null) {
      throw StateError(
        'Settings owners must be created on the Flutter root isolate.',
      );
    }
    final previous = _shared;
    final worker = previous == null || previous._stopping
        ? _shared = _SettingsWorker(previous?._exited.future)
        : previous;
    worker._leases++;
    return worker;
  }

  final _ready = Completer<SendPort>();
  final _exited = Completer<void>();
  final _requests = <int, Completer<Object?>>{};
  ReceivePort? _events;
  Object? _failure;
  StackTrace? _failureStack;
  int _leases = 0;
  int nextOwner = 0;
  int _nextRequest = 0;
  bool _stopping = false;
  Future<void> _workflows = Future<void>.value();

  // A workflow reserves admission, not a native document or another writer.
  // Its individual TOML requests still execute on the existing worker. Keeping
  // this gate shared across owners prevents ordinary CRUD/reloads interleaving
  // while a credential operation is awaiting the separate keyring queue.
  Future<T> exclusive<T>(Future<T> Function() operation) {
    final result = _workflows.then((_) => operation());
    _workflows = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _start(Future<void>? predecessor) async {
    try {
      if (predecessor != null) await predecessor;
      final events = _events = ReceivePort();
      // Another Flutter engine has its own root-isolate statics. It must route
      // through the application owner, not spawn an independent process writer.
      if (!IsolateNameServer.registerPortWithName(
        events.sendPort,
        _ownerName,
      )) {
        throw StateError('Another root isolate already owns global settings.');
      }
      events.listen(_onEvent);
      await Isolate.spawn(
        _settingsWorkerMain,
        events.sendPort,
        debugName: 'adele-global-settings',
        onError: events.sendPort,
        onExit: events.sendPort,
      );
    } on Object catch (error, stack) {
      _fail(error, stack);
      _finish();
    }
  }

  void _onEvent(Object? event) {
    switch (event) {
      case SendPort():
        _ready.complete(event);
      case (
        final int id,
        final Object? value,
        final Object? error,
        final StackTrace? stack,
      ):
        final pending = _requests.remove(id);
        if (error != null) {
          pending?.completeError(error, stack);
        } else {
          pending?.complete(value);
        }
      case [final String error, final String stack]:
        _fail(RemoteError(error, stack), StackTrace.fromString(stack));
      case null:
        if (!_stopping || _requests.isNotEmpty || !_ready.isCompleted) {
          _fail(
            StateError('The settings worker exited unexpectedly.'),
            StackTrace.current,
          );
        }
        _finish();
    }
  }

  void _fail(Object error, StackTrace stack) {
    _failure ??= error;
    _failureStack ??= stack;
    if (!_ready.isCompleted) _ready.completeError(error, stack);
    for (final pending in _requests.values) {
      pending.completeError(error, stack);
    }
    _requests.clear();
  }

  void _finish() {
    if (IsolateNameServer.lookupPortByName(_ownerName) == _events?.sendPort) {
      IsolateNameServer.removePortNameMapping(_ownerName);
    }
    _events?.close();
    if (!_exited.isCompleted) _exited.complete();
  }

  Future<Object?> request(_Request request) =>
      exclusive(() => _request(request));

  Future<Object?> _request(_Request request) async {
    final port = await _ready.future;
    if (_failure case final failure?) {
      Error.throwWithStackTrace(failure, _failureStack!);
    }
    final id = _nextRequest++;
    final pending = Completer<Object?>();
    _requests[id] = pending;
    try {
      port.send((id, request));
    } on Object {
      _requests.remove(id);
      rethrow;
    }
    return pending.future;
  }

  Future<void> release(int owner) async {
    try {
      await request(_Request(owner: owner, operation: _Operation.release));
    } on Object {
      // Worker failure has already settled admitted operations. Still release
      // the lease and await its exit; close must not strand the shared owner.
    }
    if (--_leases != 0) return;
    _stopping = true;
    try {
      final port = await _ready.future;
      if (_failure == null) port.send(null);
    } on Object {
      // Startup failure also completes _exited.
    }
    await _exited.future;
  }
}

final class _SettingsOwner {
  _SettingsOwner(_Request request)
    : store = GlobalSettingsStore(
        store: ConfigurationStore(request.roots!),
        catalog: request.catalog!,
      ) {
    records = ConfigurationRecordStore(
      store: store.store,
      catalog: request.records!,
    );
  }

  final GlobalSettingsStore store;
  late final ConfigurationRecordStore records;
  GlobalSettingsSnapshot? baseline;
  int revision = 0;
  final recordBaselines =
      <
        (RecordCollectionId, ConfigurationRecordId),
        (int, ConfigurationRecordSnapshot)
      >{};
  int recordRevision = 0;

  Future<Object?> apply(_Request request) async {
    switch (request.operation) {
      case _Operation.loadStartupRecords:
        final types = {
          for (final id in request.startupRecordTypes!)
            id: records.catalog.definition(id),
        };
        final collections =
            types.values.map((type) => type.collection).toSet().toList()
              ..sort((a, b) => a.value.compareTo(b.value));
        final projected = <ConfigurationRecordSnapshot>[];
        final diagnostics = <RecordDiagnosticView>[];
        for (final collection in collections) {
          final loaded = await records.enumerate(collection);
          projected.addAll(
            loaded.records.where(
              (record) => identical(types[record.type.id], record.type),
            ),
          );
          diagnostics.addAll(loaded.diagnostics.map(_recordDiagnostic));
        }
        projected.sort((a, b) {
          final collection = a.collection.value.compareTo(b.collection.value);
          if (collection != 0) return collection;
          final type = a.type.id.value.compareTo(b.type.id.value);
          return type != 0 ? type : a.id.value.compareTo(b.id.value);
        });
        // Native snapshots are discarded here, never retained as UI baselines.
        return _StartupRecordValues(projected, diagnostics);
      case _Operation.loadRecords:
        recordBaselines.removeWhere((key, _) => key.$1 == request.collection);
        final loaded = await records.enumerate(request.collection!);
        return _RecordCollectionValues(
          loaded.records.map(_publishRecord).toList(),
          loaded.diagnostics.map(_recordDiagnostic).toList(),
        );
      case _Operation.createRecord:
        final type = records.catalog.definition(request.recordType!);
        _validateRecordValues(type, request.recordId!, request.recordValues!);
        try {
          return _publishRecord(
            await records.create(
              type.id,
              request.recordId!,
              request.recordValues!,
            ),
          );
        } on InvalidRecordValue {
          rethrow;
        } on Object {
          recordBaselines.remove((type.collection, request.recordId!));
          rethrow;
        }
      case _Operation.updateRecord:
      case _Operation.deleteRecord:
      case _Operation.inspectCredential:
      case _Operation.setCredentialReference:
      case _Operation.refreshRecord:
        final key = (request.collection!, request.recordId!);
        final current = recordBaselines[key];
        if (current == null ||
            current.$1 != request.revision ||
            current.$2.type.id != request.recordType) {
          // Reject an old request without retiring a newer successful revision.
          throw ConfigurationConflictException(
            store.store
                .recordFile(collectionId: key.$1.value, recordId: key.$2.value)
                .filePath,
          );
        }
        final expected = current.$2;
        if (request.credentialSlot case final slot?) {
          if (!expected.type.credentialSlots.any((entry) => entry.id == slot)) {
            throw const RecordCredentialFailure(
              RecordCredentialFailureKind.invalidSlot,
            );
          }
        }
        if (request.operation == _Operation.updateRecord) {
          _validateRecordValues(
            expected.type,
            expected.id,
            request.recordValues!,
          );
        }
        try {
          if (request.operation == _Operation.inspectCredential) {
            await records.validateCurrent(expected);
            return _CredentialValues(
              expected.type.owner.value,
              expected.credentials[request.credentialSlot!],
            );
          }
          if (request.operation == _Operation.setCredentialReference) {
            return _publishRecord(
              await records.setCredentialReference(
                expected,
                request.credentialSlot!,
                request.credentialReference,
              ),
            );
          }
          if (request.operation == _Operation.refreshRecord) {
            return _publishRecord(await records.validateCurrent(expected));
          }
          if (request.operation == _Operation.deleteRecord) {
            await records.delete(expected);
            recordBaselines.remove(key);
            return null;
          }
          return _publishRecord(
            await records.update(expected, request.recordValues!),
          );
        } on InvalidRecordValue {
          // R1 also validates edits, including document shape, before writing.
          rethrow;
        } on ConfigurationRecordCredentialsPresent {
          // A deletion guard is a known prewrite failure, not a lost baseline.
          rethrow;
        } on Object {
          // An unconfirmed transaction can have persisted. Only Reload may
          // establish a usable baseline after a conflict or uncertain failure.
          recordBaselines.remove(key);
          rethrow;
        }
      case _Operation.load:
      case _Operation.save:
      case _Operation.reset:
        return _applySettings(request);
      case _Operation.release:
        throw StateError('Release must remove the owner.');
    }
  }

  _RecordValues _publishRecord(ConfigurationRecordSnapshot record) {
    final revision = ++recordRevision;
    recordBaselines[(record.collection, record.id)] = (revision, record);
    return _RecordValues(revision, record);
  }

  void _validateRecordValues(
    RecordTypeDefinition type,
    ConfigurationRecordId id,
    Map<String, Object?> values,
  ) {
    final known = {for (final field in type.fields) field.id.value};
    for (final key in values.keys) {
      if (!known.contains(key)) {
        throw ConfigurationRecordFormatException(
          type.collection,
          id,
          'Cannot edit undeclared field "$key".',
        );
      }
    }
    type.validate(id, values);
  }

  _Values _applySettings(_Request request) {
    final GlobalSettingsSnapshot saved;
    if (request.operation == _Operation.load) {
      baseline = null;
      revision++;
      saved = store.load();
    } else {
      final expected = baseline;
      if (expected == null || request.revision != revision) {
        throw ConfigurationConflictException(store.store.filePath);
      }
      final edited = request.operation == _Operation.save
          ? expected.setOverride(request.setting!, request.value)
          : expected.resetOverride(request.setting!);
      saved = store.save(edited);
      revision++;
    }
    baseline = saved;
    final values = <SettingId, ResolvedSetting<Object>>{};
    final failures = <SettingId, Object>{};
    for (final definition in store.catalog.definitions) {
      try {
        values[definition.id] = saved.resolve<Object>(definition.id);
      } on Object catch (error) {
        failures[definition.id] = error;
      }
    }
    return _Values(revision, values, failures);
  }
}

Future<void> _settingsWorkerMain(SendPort reply) async {
  final requests = ReceivePort();
  final owners = <int, _SettingsOwner>{};
  reply.send(requests.sendPort);
  // Await the entire operation across all owners, including asynchronous scans.
  // An async listen callback would admit overlapping record and scalar work.
  await for (final message in requests) {
    if (message == null) {
      requests.close();
      return;
    }
    final (id, request) = message as (int, _Request);
    try {
      final Object? result;
      if (request.operation == _Operation.release) {
        owners.remove(request.owner);
        result = null;
      } else {
        result = await owners
            .putIfAbsent(request.owner, () => _SettingsOwner(request))
            .apply(request);
      }
      reply.send((id, result, null, null));
    } on Object catch (error, stack) {
      reply.send((id, null, error, stack));
    }
  }
}
