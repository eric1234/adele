import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart';

final _providerId = ProviderId('dev.adele.test.project');

void main() {
  late Directory source;
  late AdeleRuntime runtime;
  late _Ids ids;
  late _ProviderChannel channel;
  late CapabilityRegistration registration;

  setUp(() {
    source = Directory.systemTemp.createTempSync('adele-durable-lifecycle-');
    ids = _Ids();
    runtime = AdeleRuntime(ids: ids);
    channel = _ProviderChannel();
    registration = _register(runtime, channel);
    addTearDown(() async {
      await runtime.close();
      await registration.close();
      if (source.existsSync()) source.deleteSync(recursive: true);
    });
  });

  Future<Project> open({ProviderBinding? binding}) =>
      runtime.lifecycle.openProject(
        sourceLocation: source.uri,
        provider:
            binding ?? runtime.lifecycle.resolveProjectProvider(_providerId),
      );

  String getDatabasePath() => '${source.path}/.adele/data.db';

  test(
    'headless open commits one Project before exposing the live value',
    () async {
      channel.pending = Completer<Object?>();
      final opening = open();
      expect(
        runtime.extensions.discover(projectSelectorContributions),
        isEmpty,
      );
      expect(runtime.store.project(ProjectId('durable-1')), isNull);
      expect(ids.calls, 0);
      channel.pending!.complete(channel.backing(source.uri));
      final project = await opening;
      expect(ids.calls, 1);
      expect(runtime.store.project(project.id), same(project));
      final observer = sqlite3.open(getDatabasePath());
      try {
        final rows = observer.select(
          'SELECT id, source_location FROM adele_product_projects',
        );
        expect(rows, hasLength(1));
        expect(rows.single['id'], project.id.value);
        expect(rows.single['source_location'], source.uri.toString());
      } finally {
        observer.close();
      }
      expect(await open(), same(project));
      expect(ids.calls, 1);
    },
  );

  test(
    'fresh runtime reopens identity without consulting its ID source',
    () async {
      final project = await open();
      await runtime.close();
      final freshIds = _Ids()..fail = true;
      final fresh = AdeleRuntime(ids: freshIds);
      final provider = _register(fresh, _ProviderChannel());
      addTearDown(fresh.close);
      addTearDown(provider.close);
      final reopened = await fresh.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: fresh.lifecycle.resolveProjectProvider(_providerId),
      );
      expect(reopened.id, project.id);
      expect(reopened.sourceLocation, source.uri);
      expect(freshIds.calls, 0);
      expect(fresh.store.tasksFor(reopened.id), isEmpty);
    },
  );

  test(
    'concurrent opens of one backing publish one canonical identity',
    () async {
      channel.pending = Completer<Object?>();
      final first = open();
      final second = open();
      channel.pending!.complete(channel.backing(source.uri));
      final projects = await Future.wait([first, second]);
      expect(projects[0], same(projects[1]));
      expect(ids.calls, 1);
      expect(runtime.store.project(projects[0].id), same(projects[0]));
    },
  );

  test(
    'moving the complete backing retains identity and updates stored source',
    () async {
      final project = await open();
      final oldUri = source.uri;
      await runtime.close();
      source = source.renameSync('${source.path}-moved');
      final freshIds = _Ids()..fail = true;
      final fresh = AdeleRuntime(ids: freshIds);
      final provider = _register(fresh, _ProviderChannel());
      addTearDown(fresh.close);
      addTearDown(provider.close);
      final reopened = await fresh.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: fresh.lifecycle.resolveProjectProvider(_providerId),
      );
      expect(reopened.id, project.id);
      expect(reopened.sourceLocation, source.uri);
      expect(reopened.sourceLocation, isNot(oldUri));
      expect(freshIds.calls, 0);
      final db = sqlite3.open(getDatabasePath());
      try {
        expect(
          db
              .select('SELECT source_location FROM adele_product_projects')
              .single['source_location'],
          source.uri.toString(),
        );
      } finally {
        db.close();
      }
    },
  );

  test(
    'SQLite open failure publishes no Project and allocates no ID',
    () async {
      Directory('${source.path}/.adele').createSync();
      File(getDatabasePath()).writeAsStringSync('not a SQLite database');
      await expectLater(open(), throwsA(isA<SqliteException>()));
      expect(ids.calls, 0);
      expect(runtime.store.project(ProjectId('durable-1')), isNull);
    },
  );

  test('failed durable commit cannot publish a canonical Project', () async {
    // Initialize schema without retaining a Project row in the fresh runtime.
    await open();
    await runtime.close();
    final db = sqlite3.open(getDatabasePath());
    db.execute('DELETE FROM adele_product_projects');
    db.execute('CREATE TABLE parent (id TEXT PRIMARY KEY)');
    db.execute(
      'CREATE TABLE child (id TEXT REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)',
    );
    db.execute(
      'CREATE TRIGGER fail_commit AFTER INSERT ON adele_product_projects BEGIN INSERT INTO child VALUES (NEW.id); END',
    );
    db.close();
    final fresh = AdeleRuntime(ids: _Ids());
    final provider = _register(fresh, _ProviderChannel());
    addTearDown(fresh.close);
    addTearDown(provider.close);
    await expectLater(
      fresh.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: fresh.lifecycle.resolveProjectProvider(_providerId),
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(fresh.store.project(ProjectId('durable-1')), isNull);
    final observer = sqlite3.open(getDatabasePath());
    try {
      expect(observer.select('SELECT * FROM adele_product_projects'), isEmpty);
      expect(observer.select('SELECT * FROM child'), isEmpty);
    } finally {
      observer.close();
    }
  });

  for (final corruption in [
    "UPDATE adele_product_projects SET id = ''",
    "UPDATE adele_product_projects SET source_location = 'not a URI'",
    "INSERT INTO adele_product_projects VALUES ('second-project', 'file:///tmp/other/')",
    "UPDATE adele_schema_versions SET version = 999 WHERE owner_id = 'dev.adele.product'",
  ]) {
    test(
      'corruption/incompatibility fails non-destructively: $corruption',
      () async {
        await open();
        await runtime.close();
        final db = sqlite3.open(getDatabasePath());
        db.execute(corruption);
        final before = db
            .select('SELECT * FROM adele_product_projects')
            .map((row) => row.values.toList())
            .toList();
        db.close();
        final freshIds = _Ids()..fail = true;
        final fresh = AdeleRuntime(ids: freshIds);
        final provider = _register(fresh, _ProviderChannel());
        addTearDown(fresh.close);
        addTearDown(provider.close);
        await expectLater(
          fresh.lifecycle.openProject(
            sourceLocation: source.uri,
            provider: fresh.lifecycle.resolveProjectProvider(_providerId),
          ),
          throwsA(anything),
        );
        expect(fresh.store.project(ProjectId('durable-1')), isNull);
        expect(freshIds.calls, 0);
        final observer = sqlite3.open(getDatabasePath());
        try {
          expect(
            observer
                .select('SELECT * FROM adele_product_projects')
                .map((row) => row.values.toList())
                .toList(),
            before,
          );
        } finally {
          observer.close();
        }
      },
    );
  }

  test('retired captured provider never rebinds before invocation', () async {
    final binding = runtime.lifecycle.resolveProjectProvider(_providerId);
    await registration.close();
    registration = _register(runtime, channel);
    await expectLater(
      open(binding: binding),
      throwsA(isA<ProviderUnavailable>()),
    );
    expect(channel.calls, 0);
    expect(ids.calls, 0);
    expect(File(getDatabasePath()).existsSync(), isFalse);
  });

  test(
    'provider retirement during settlement rejects immutable late backing',
    () async {
      channel.pending = Completer<Object?>();
      final opening = open();
      await registration.close();
      final replacement = _ProviderChannel();
      registration = _register(runtime, replacement);
      final failure = expectLater(opening, throwsA(isA<ProviderUnavailable>()));
      channel.pending!.complete(channel.backing(source.uri));
      await failure;
      expect(replacement.calls, 0);
      expect(ids.calls, 0);
      expect(File(getDatabasePath()).existsSync(), isFalse);
    },
  );

  test('selection validation is repeated after provider settlement', () async {
    channel.pending = Completer<Object?>();
    bool live = true;
    final opening = runtime.lifecycle.openProject(
      sourceLocation: source.uri,
      provider: runtime.lifecycle.resolveProjectProvider(_providerId),
      validateSelection: () {
        if (!live) throw StateError('Retired selection');
      },
    );
    live = false;
    final failure = expectLater(opening, throwsStateError);
    channel.pending!.complete(channel.backing(source.uri));
    await failure;
    expect(ids.calls, 0);
    expect(File(getDatabasePath()).existsSync(), isFalse);
  });

  test('provider cannot substitute an unrelated source directory', () async {
    channel.resultSource = Directory.systemTemp.uri;
    await expectLater(open(), throwsStateError);
    expect(ids.calls, 0);
  });

  test(
    'same IDs from a foreign registry are not a selected provider',
    () async {
      final other = AdeleRuntime();
      final external = _register(other, channel);
      addTearDown(other.close);
      addTearDown(external.close);
      await expectLater(
        open(binding: other.lifecycle.resolveProjectProvider(_providerId)),
        throwsArgumentError,
      );
      expect(channel.calls, 0);
    },
  );

  test(
    'close stops admission, drains opens, and preserves concurrent completion',
    () async {
      channel.pending = Completer<Object?>();
      final opening = open();
      final closing = runtime.close();
      expect(runtime.close(), same(closing));
      bool closed = false;
      closing.then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(
        runtime.plugins.state,
        ApplicationPluginState.closed,
        reason:
            'An outstanding open must not prevent backend shutdown from starting.',
      );
      expect(
        () => runtime.lifecycle.createProject(source.uri),
        throwsStateError,
      );
      expect(
        () => runtime.lifecycle.resolveProjectProvider(_providerId),
        throwsStateError,
      );
      final failure = expectLater(opening, throwsStateError);
      channel.pending!.complete(channel.backing(source.uri));
      await failure;
      await closing;
      expect(ids.calls, 0);
      expect(File(getDatabasePath()).existsSync(), isFalse);
      expect(runtime.close(), same(closing));
    },
  );
}

CapabilityRegistration _register(
  AdeleRuntime runtime,
  _ProviderChannel channel,
) => runtime.registry.register(
  provider: ProviderDescriptor(
    id: _providerId,
    capability: projectProviderCapability,
    pluginId: 'dev.adele.test.project-plugin',
    displayName: 'Fixture Project',
    serviceId: projectProviderServiceId,
  ),
  endpoint: AdeleRequestChannelEndpoint(
    channel: channel,
    serviceId: projectProviderServiceId,
    isAvailable: () => true,
  ),
);

final class _ProviderChannel implements AdeleRequestChannel {
  int calls = 0;
  Completer<Object?>? pending;
  Uri? resultSource;

  Map<String, Object?> backing(Uri source) => {
    'sourceLocation': (resultSource ?? source).toString(),
    'databaseRelativePath': '.adele/data.db',
  };

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    calls++;
    expect(method, projectProviderServicePrepareSourceId);
    return pending?.future ??
        backing(Uri.parse(payload['sourceLocation']! as String));
  }
}

final class _Ids implements ProductIdSource {
  int calls = 0;
  bool fail = false;

  @override
  ProjectId nextProjectId() {
    calls++;
    if (fail) throw StateError('ID source must not be called');
    return ProjectId('durable-$calls');
  }

  @override
  TaskId nextTaskId() => throw StateError('No Task persistence');
  @override
  EnvironmentId nextEnvironmentId() =>
      throw StateError('No Environment persistence');
  @override
  SessionId nextSessionId() => throw StateError('No Session persistence');
}
