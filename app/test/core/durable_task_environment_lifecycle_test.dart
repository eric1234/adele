import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart';

final _projectProviderId = ProviderId('dev.adele.test.project');
final _environmentProviderId = ProviderId('dev.adele.test.environment');
const _initialState = <String, Object?>{
  'version': 1,
  'location': 'worktrees/task',
  'opaque': <String, Object?>{
    'values': <Object?>[true, null, 3, 'retained'],
  },
};
const _refreshedState = <String, Object?>{
  'version': 2,
  'location': 'worktrees/restored',
  'opaque': <String, Object?>{'refreshed': true},
};

void main() {
  late Directory source;
  late AdeleRuntime runtime;
  late _EnvironmentChannel channel;
  late CapabilityRegistration environmentRegistration;

  setUp(() {
    source = Directory.systemTemp.createTempSync('adele-durable-task-');
    addTearDown(() => source.deleteSync(recursive: true));
    runtime = _newRuntime();
    channel = _EnvironmentChannel();
    environmentRegistration = _registerEnvironment(runtime.registry, channel);
  });

  Future<Project> open(ProductLifecycleCoordinator lifecycle) =>
      lifecycle.openProject(
        sourceLocation: source.uri,
        provider: lifecycle.resolveProjectProvider(_projectProviderId),
      );

  Future<TaskCreationResult> create(Project project, {String title = 'Task'}) =>
      runtime.lifecycle.createTask(
        projectId: project.id,
        title: title,
        providerId: _environmentProviderId,
      );

  Database inspect() {
    final database = sqlite3.open('${source.path}/.adele/data.db');
    addTearDown(database.close);
    return database;
  }

  test(
    'creation commits finalized Task and Environment, never provisional rows',
    () async {
      final project = await open(runtime.lifecycle);
      final database = inspect();
      final started = Completer<void>();
      final result = Completer<Map<String, Object?>>();
      channel.onEstablish = (_) {
        started.complete();
        return result.future;
      };

      final creating = create(project, title: 'Durable intent');
      await started.future;
      final context = channel.established.single;
      final taskId = TaskId(context['taskId']! as String);
      final environmentId = EnvironmentId(context['environmentId']! as String);
      expect(context['projectId'], project.id.value);
      expect(context['providerId'], _environmentProviderId.value);
      expect(context['providerStateInitialized'], isFalse);
      _expectUnpublished(runtime.lifecycle, project.id, taskId, environmentId);
      expect(database.select('SELECT * FROM adele_product_tasks'), isEmpty);
      expect(
        database.select('SELECT * FROM adele_product_environments'),
        isEmpty,
      );

      result.complete(_initialState);
      final created = await creating;

      expect(created.task.id, taskId);
      expect(created.environment.id, environmentId);
      expect(runtime.store.task(taskId), same(created.task));
      expect(
        runtime.store.primaryEnvironmentFor(taskId),
        same(created.environment),
      );
      expect(
        runtime.store.environment(environmentId),
        same(created.environment),
      );
      final materialization = runtime.lifecycle.environmentRuntime
          .currentMaterialization(environmentId)!;
      expect(materialization.environment, same(created.environment));
      materialization.validateBinding();
      expect(database.select('SELECT * FROM adele_product_tasks'), [
        {
          'id': taskId.value,
          'project_id': project.id.value,
          'title': 'Durable intent',
        },
      ]);
      final row = database
          .select('SELECT * FROM adele_product_environments')
          .single;
      expect(row['id'], environmentId.value);
      expect(row['task_id'], taskId.value);
      expect(row['role'], 'primary');
      expect(row['provider_id'], _environmentProviderId.value);
      expect(jsonDecode(row['provider_state_json']! as String), _initialState);
      expect(created.environment.providerState, _initialState);
      expect(channel.restored, isEmpty);
    },
  );

  test(
    'late establishment cannot fall back to volatile publication after close',
    () async {
      final project = await open(runtime.lifecycle);
      final database = inspect();
      final started = Completer<void>();
      final result = Completer<Map<String, Object?>>();
      channel.onEstablish = (_) {
        started.complete();
        return result.future;
      };
      final creating = create(project);
      await started.future;
      await runtime.close();
      final failure = expectLater(creating, throwsStateError);
      result.complete(_initialState);
      await failure;

      final context = channel.established.single;
      _expectUnpublished(
        runtime.lifecycle,
        project.id,
        TaskId(context['taskId']! as String),
        EnvironmentId(context['environmentId']! as String),
      );
      expect(database.select('SELECT * FROM adele_product_tasks'), isEmpty);
      expect(
        database.select('SELECT * FROM adele_product_environments'),
        isEmpty,
      );
    },
  );

  test(
    'provider failure leaves neither durable rows nor live publication',
    () async {
      final project = await open(runtime.lifecycle);
      final database = inspect();
      final before = _snapshot(database);
      channel.onEstablish = (_) => throw const EnvironmentFailure(
        code: 'fixture_failure',
        message: 'Establishment failed.',
        details: <String, Object?>{},
      );

      await expectLater(
        create(project),
        throwsA(
          isA<EnvironmentFailure>().having(
            (error) => error.code,
            'code',
            'fixture_failure',
          ),
        ),
      );

      final context = channel.established.single;
      _expectUnpublished(
        runtime.lifecycle,
        project.id,
        TaskId(context['taskId']! as String),
        EnvironmentId(context['environmentId']! as String),
      );
      expect(runtime.store.project(project.id), same(project));
      expect(_snapshot(database), before);
    },
  );

  test(
    'failed SQL commit rolls back both rows, not successful provider effects',
    () async {
      final project = await open(runtime.lifecycle);
      final database = inspect();
      // The deferred constraint fails at COMMIT, after both product inserts.
      database.execute('''
        CREATE TABLE fixture_parent (id TEXT PRIMARY KEY);
        CREATE TABLE fixture_child (
          id TEXT REFERENCES fixture_parent(id) DEFERRABLE INITIALLY DEFERRED
        );
        CREATE TRIGGER fail_commit AFTER INSERT ON adele_product_environments
        BEGIN INSERT INTO fixture_child VALUES (NEW.id); END;
      ''');
      final effect = File('${source.path}/provider-effect');
      channel.onEstablish = (_) {
        effect.writeAsStringSync('established');
        return _initialState;
      };

      await expectLater(
        create(project),
        throwsA(
          isA<SqliteException>().having(
            (error) => error.causingStatement,
            'causingStatement',
            'COMMIT',
          ),
        ),
      );

      final context = channel.established.single;
      _expectUnpublished(
        runtime.lifecycle,
        project.id,
        TaskId(context['taskId']! as String),
        EnvironmentId(context['environmentId']! as String),
      );
      expect(database.select('SELECT * FROM adele_product_tasks'), isEmpty);
      expect(
        database.select('SELECT * FROM adele_product_environments'),
        isEmpty,
      );
      expect(database.select('SELECT * FROM fixture_child'), isEmpty);
      expect(effect.readAsStringSync(), 'established');
      expect(runtime.store.project(project.id), same(project));

      database.execute('DROP TRIGGER fail_commit');
      final retried = await create(project);
      expect(runtime.store.task(retried.task.id), same(retried.task));
      expect(
        database.select('SELECT * FROM adele_product_tasks'),
        hasLength(1),
      );
      expect(
        database.select('SELECT * FROM adele_product_environments'),
        hasLength(1),
      );
    },
  );

  test(
    'fresh runtime loads the graph lazily without its Environment provider',
    () async {
      final project = await open(runtime.lifecycle);
      final created = await create(project, title: 'Retained intent');
      final database = inspect();
      final additionalId = EnvironmentId('additional-environment');
      database.execute(
        'INSERT INTO adele_product_environments '
        '(id, task_id, role, provider_id, provider_state_json) VALUES (?, ?, ?, ?, ?)',
        [
          additionalId.value,
          created.task.id.value,
          'additional',
          _environmentProviderId.value,
          jsonEncode(<String, Object?>{}),
        ],
      );
      final before = _snapshot(database);
      await runtime.close();

      final fresh = _newRuntime(restoring: true);
      final reopened = await open(fresh.lifecycle);
      expect(reopened.id, project.id);
      expect(reopened.sourceLocation, project.sourceLocation);
      final task = fresh.store.tasksFor(project.id).single;
      expect(task.id, created.task.id);
      expect(task.projectId, project.id);
      expect(task.title, 'Retained intent');
      final environment = fresh.store.primaryEnvironmentFor(task.id)!;
      expect(environment.id, created.environment.id);
      expect(environment.taskId, task.id);
      expect(environment.role, EnvironmentRole.primary);
      expect(environment.providerId, _environmentProviderId);
      expect(environment.providerState, _initialState);
      final additional = fresh.store.environment(additionalId)!;
      expect(additional.taskId, task.id);
      expect(additional.role, EnvironmentRole.additional);
      expect(additional.providerId, _environmentProviderId);
      expect(additional.providerState, isEmpty);

      final unrelated = _EnvironmentChannel();
      _registerEnvironment(
        fresh.registry,
        unrelated,
        providerId: ProviderId('dev.adele.test.other-environment'),
      );
      for (final value in [environment, additional]) {
        expect(
          fresh.lifecycle.environmentRuntime.currentMaterialization(value.id),
          isNull,
        );
        await expectLater(
          fresh.lifecycle.environmentRuntime.materialize(value.id),
          throwsA(isA<ProviderUnavailable>()),
        );
        expect(fresh.store.environment(value.id), same(value));
        expect(
          fresh.lifecycle.environmentRuntime.currentMaterialization(value.id),
          isNull,
        );
      }
      expect(fresh.store.task(task.id), same(task));
      expect(fresh.store.project(project.id), same(reopened));
      expect(unrelated.established, isEmpty);
      expect(unrelated.restored, isEmpty);
      expect(channel.restored, isEmpty);
      expect(_snapshot(database), before);
    },
  );

  test(
    'explicit restore persists refreshed opaque state for the next runtime',
    () async {
      final project = await open(runtime.lifecycle);
      final created = await create(project);
      await runtime.close();
      final fresh = _newRuntime(restoring: true);
      final restoring = _EnvironmentChannel();
      _registerEnvironment(fresh.registry, restoring);
      await open(fresh.lifecycle);
      expect(restoring.established, isEmpty);
      expect(restoring.restored, isEmpty);
      expect(
        fresh.lifecycle.environmentRuntime.currentMaterialization(
          created.environment.id,
        ),
        isNull,
      );

      final materialization = await fresh.lifecycle.environmentRuntime
          .materialize(created.environment.id);
      final context = restoring.restored.single;
      expect(context['projectId'], project.id.value);
      expect(context['taskId'], created.task.id.value);
      expect(context['environmentId'], created.environment.id.value);
      expect(context['providerId'], _environmentProviderId.value);
      expect(context['providerStateInitialized'], isTrue);
      expect(context['providerState'], _initialState);
      expect(materialization.environment.providerState, _refreshedState);
      expect(
        fresh.store.environment(created.environment.id),
        same(materialization.environment),
      );
      materialization.validateBinding();
      expect(
        await fresh.lifecycle.environmentRuntime.materialize(
          created.environment.id,
        ),
        same(materialization),
      );
      expect(restoring.restored, hasLength(1));
      expect(restoring.established, isEmpty);
      final database = inspect();
      expect(_storedState(database, created.environment.id), _refreshedState);

      await fresh.close();
      final next = _newRuntime(restoring: true);
      await open(next.lifecycle);
      final retained = next.store.environment(created.environment.id)!;
      expect(retained.taskId, created.task.id);
      expect(retained.role, created.environment.role);
      expect(retained.providerId, created.environment.providerId);
      expect(retained.providerState, _refreshedState);
      expect(
        next.lifecycle.environmentRuntime.currentMaterialization(retained.id),
        isNull,
      );
    },
  );

  test(
    'refreshed state survives stale final binding validation and restart',
    () async {
      final project = await open(runtime.lifecycle);
      final created = await create(project);
      await runtime.close();
      final registry = CapabilityRegistry();
      _registerProject(registry);
      final provider = _BlockingRestoreProvider();
      final registration = registry.register(
        provider: _environmentDescriptor(_environmentProviderId),
        endpoint: _ProviderEndpoint(provider),
      );
      addTearDown(registration.close);
      final coordinator = ProductLifecycleCoordinator(
        store: InMemoryProductStore(),
        registry: registry,
        extensions: ExtensionRegistry(),
        ids: _NoIds(),
        providerForBinding: (binding) =>
            binding.endpointAs<_ProviderEndpoint>().provider,
      );
      addTearDown(coordinator.close);
      await open(coordinator);
      final original = coordinator.store.environment(created.environment.id)!;
      final restoring = coordinator.environmentRuntime.materialize(original.id);
      await provider.started.future;
      expect(provider.environment!.providerState, _initialState);
      expect(coordinator.store.environment(original.id), same(original));
      expect(
        coordinator.environmentRuntime.currentMaterialization(original.id),
        isNull,
      );
      final database = inspect();
      expect(_storedState(database, original.id), _initialState);
      await registration.close();
      final failure = expectLater(restoring, throwsA(_staleProvider()));
      provider.result.complete(
        EnvironmentProviderResult(providerState: _refreshedState),
      );
      await failure;

      final retained = coordinator.store.environment(original.id)!;
      expect(retained, isNot(same(original)));
      expect(retained.providerState, _refreshedState);
      expect(_storedState(database, original.id), _refreshedState);
      final stale = coordinator.environmentRuntime.currentMaterialization(
        original.id,
      )!;
      expect(stale.environment, same(retained));
      expect(stale.validateBinding, throwsA(_staleProvider()));

      await coordinator.close();
      final next = _newRuntime(restoring: true);
      final nextChannel = _EnvironmentChannel();
      _registerEnvironment(next.registry, nextChannel);
      await open(next.lifecycle);
      expect(
        next.store.environment(original.id)!.providerState,
        _refreshedState,
      );
      expect(nextChannel.restored, isEmpty);
      final usable = await next.lifecycle.environmentRuntime.materialize(
        original.id,
      );
      expect(nextChannel.restored.single['providerState'], _refreshedState);
      usable.validateBinding();
      expect(stale.validateBinding, throwsA(_staleProvider()));
    },
  );

  test(
    'refresh SQL failure replaces neither semantic state nor materialization',
    () async {
      final project = await open(runtime.lifecycle);
      final created = await create(project);
      final original = runtime.lifecycle.environmentRuntime
          .currentMaterialization(created.environment.id)!;
      final database = inspect();
      final before = _snapshot(database);
      database.execute('''
        CREATE TRIGGER reject_refresh BEFORE UPDATE ON adele_product_environments
        BEGIN SELECT RAISE(ABORT, 'fixture refresh failure'); END;
      ''');
      await environmentRegistration.close();
      final replacement = _EnvironmentChannel();
      final replacementRegistration = _registerEnvironment(
        runtime.registry,
        replacement,
      );

      await expectLater(
        runtime.lifecycle.environmentRuntime.materialize(
          created.environment.id,
        ),
        throwsA(isA<SqliteException>()),
      );

      expect(replacement.restored.single['providerState'], _initialState);
      expect(replacement.established, isEmpty);
      expect(
        runtime.store.environment(created.environment.id),
        same(created.environment),
      );
      expect(
        runtime.lifecycle.environmentRuntime.currentMaterialization(
          created.environment.id,
        ),
        same(original),
      );
      expect(original.validateBinding, throwsA(_staleProvider()));
      expect(_snapshot(database), before);

      database.execute('DROP TRIGGER reject_refresh');
      // Restore may already have bound provider-owned live state before SQL fails.
      // Storage recovery alone does not promise an idempotent provider retry.
      await expectLater(
        runtime.lifecycle.environmentRuntime.materialize(
          created.environment.id,
        ),
        throwsA(
          isA<EnvironmentFailure>().having(
            (error) => error.code,
            'code',
            'environment_already_live',
          ),
        ),
      );
      expect(_snapshot(database), before);
      expect(
        runtime.store.environment(created.environment.id),
        same(created.environment),
      );
      await replacementRegistration.close();
      final freshProvider = _EnvironmentChannel();
      _registerEnvironment(runtime.registry, freshProvider);
      final restored = await runtime.lifecycle.environmentRuntime.materialize(
        created.environment.id,
      );
      expect(replacement.restored, hasLength(2));
      expect(freshProvider.restored.single['providerState'], _initialState);
      expect(restored, isNot(same(original)));
      expect(restored.environment.providerState, _refreshedState);
      expect(_storedState(database, created.environment.id), _refreshedState);
      restored.validateBinding();
    },
  );

  test(
    'createProject stays volatile even for an existing file directory URI',
    () async {
      final project = runtime.lifecycle.createProject(source.uri);
      final created = await create(project);
      await environmentRegistration.close();
      final replacement = _EnvironmentChannel();
      _registerEnvironment(runtime.registry, replacement);
      final restored = await runtime.lifecycle.environmentRuntime.materialize(
        created.environment.id,
      );
      expect(restored.environment.providerState, _refreshedState);
      expect(runtime.store.task(created.task.id), same(created.task));
      expect(
        runtime.store.environment(created.environment.id),
        same(restored.environment),
      );
      expect(source.listSync(), isEmpty);

      await runtime.close();
      final fresh = _newRuntime();
      final durable = await open(fresh.lifecycle);
      expect(fresh.store.tasksFor(durable.id), isEmpty);
      expect(fresh.store.environment(created.environment.id), isNull);
      final database = inspect();
      expect(database.select('SELECT * FROM adele_product_tasks'), isEmpty);
      expect(
        database.select('SELECT * FROM adele_product_environments'),
        isEmpty,
      );
    },
  );

  for (final corruption in [
    (
      name: 'missing primary',
      sql:
          "UPDATE adele_product_environments SET role = 'additional' WHERE id = ?",
      targetTask: false,
      error: isA<StateError>(),
    ),
    (
      name: 'invalid role',
      sql:
          "UPDATE adele_product_environments SET role = 'unknown' WHERE id = ?",
      targetTask: false,
      error: isA<ArgumentError>(),
    ),
    (
      name: 'invalid state JSON',
      sql:
          "UPDATE adele_product_environments SET provider_state_json = '{' WHERE id = ?",
      targetTask: false,
      error: isA<FormatException>(),
    ),
    (
      name: 'non-object state',
      sql:
          "UPDATE adele_product_environments SET provider_state_json = '[]' WHERE id = ?",
      targetTask: false,
      error: isA<FormatException>(),
    ),
    (
      name: 'orphan Environment',
      sql:
          "UPDATE adele_product_environments SET task_id = 'absent-task' WHERE id = ?",
      targetTask: false,
      error: isA<StateError>(),
    ),
    (
      name: 'cross-Project Task',
      sql:
          "UPDATE adele_product_tasks SET project_id = 'other-project' WHERE id = ?",
      targetTask: true,
      error: isA<StateError>(),
    ),
  ]) {
    test('loading ${corruption.name} publishes no partial graph', () async {
      final project = await open(runtime.lifecycle);
      final valid = await create(project, title: 'Valid first Task');
      final invalid = await create(project, title: 'Malformed second Task');
      await runtime.close();
      final database = inspect();
      // Corrupt relationships deliberately; ordinary writes enforce foreign keys.
      database.execute('PRAGMA foreign_keys = OFF');
      database.execute(corruption.sql, [
        corruption.targetTask
            ? invalid.task.id.value
            : invalid.environment.id.value,
      ]);
      final before = _snapshot(database);
      final fresh = _newRuntime(restoring: true);
      final unused = _EnvironmentChannel();
      _registerEnvironment(fresh.registry, unused);

      await expectLater(open(fresh.lifecycle), throwsA(corruption.error));

      expect(fresh.store.project(project.id), isNull);
      for (final created in [valid, invalid]) {
        _expectUnpublished(
          fresh.lifecycle,
          project.id,
          created.task.id,
          created.environment.id,
        );
      }
      expect(unused.established, isEmpty);
      expect(unused.restored, isEmpty);
      expect(_snapshot(database), before);
    });
  }

  test(
    'restored Environment ID conflict preserves the existing live graph',
    () async {
      final project = await open(runtime.lifecycle);
      final first = await create(project);
      final second = await create(project);
      await runtime.close();
      final database = inspect();
      final before = _snapshot(database);
      final fresh = _newRuntime(restoring: true);
      final existingProject = Project(
        id: ProjectId('existing-project'),
        sourceLocation: source.uri,
      );
      final existingTask = Task(
        id: TaskId('existing-task'),
        projectId: existingProject.id,
        title: 'Existing',
      );
      final existingEnvironment = Environment(
        id: second.environment.id,
        taskId: existingTask.id,
        role: EnvironmentRole.primary,
        providerId: _environmentProviderId,
        providerState: const <String, Object?>{},
      );
      fresh.store.publishProject(existingProject);
      fresh.store.publishTaskWithPrimaryEnvironment(
        existingTask,
        existingEnvironment,
      );

      await expectLater(open(fresh.lifecycle), throwsStateError);

      expect(fresh.store.project(project.id), isNull);
      expect(fresh.store.tasksFor(project.id), isEmpty);
      expect(fresh.store.task(first.task.id), isNull);
      expect(fresh.store.task(second.task.id), isNull);
      expect(fresh.store.environment(first.environment.id), isNull);
      expect(fresh.store.primaryEnvironmentFor(first.task.id), isNull);
      expect(fresh.store.primaryEnvironmentFor(second.task.id), isNull);
      expect(fresh.store.project(existingProject.id), same(existingProject));
      expect(fresh.store.task(existingTask.id), same(existingTask));
      expect(
        fresh.store.environment(existingEnvironment.id),
        same(existingEnvironment),
      );
      expect(
        fresh.store.primaryEnvironmentFor(existingTask.id),
        same(existingEnvironment),
      );
      expect(_snapshot(database), before);
    },
  );
}

AdeleRuntime _newRuntime({bool restoring = false}) {
  final runtime = AdeleRuntime(
    ids: restoring ? _NoIds() : MonotonicProductIdSource(seed: 'durable-task'),
  );
  addTearDown(runtime.close);
  _registerProject(runtime.registry);
  return runtime;
}

void _registerProject(CapabilityRegistry registry) {
  final registration = registry.register(
    provider: ProviderDescriptor(
      id: _projectProviderId,
      capability: projectProviderCapability,
      pluginId: 'dev.adele.test.project-plugin',
      displayName: 'Fixture Project',
      serviceId: projectProviderServiceId,
    ),
    endpoint: AdeleRequestChannelEndpoint(
      channel: _ProjectChannel(),
      serviceId: projectProviderServiceId,
      isAvailable: () => true,
    ),
  );
  addTearDown(registration.close);
}

CapabilityRegistration _registerEnvironment(
  CapabilityRegistry registry,
  _EnvironmentChannel channel, {
  ProviderId? providerId,
}) {
  final registration = registry.register(
    provider: _environmentDescriptor(providerId ?? _environmentProviderId),
    endpoint: AdeleRequestChannelEndpoint(
      channel: channel,
      serviceId: environmentProviderServiceId,
      isAvailable: () => true,
    ),
  );
  addTearDown(registration.close);
  return registration;
}

ProviderDescriptor _environmentDescriptor(ProviderId id) => ProviderDescriptor(
  id: id,
  capability: environmentProviderCapability,
  pluginId: 'dev.adele.test.environment-plugin',
  displayName: 'Fixture Environment',
  serviceId: environmentProviderServiceId,
);

void _expectUnpublished(
  ProductLifecycleCoordinator lifecycle,
  ProjectId projectId,
  TaskId taskId,
  EnvironmentId environmentId,
) {
  expect(lifecycle.store.tasksFor(projectId), isEmpty);
  expect(lifecycle.store.task(taskId), isNull);
  expect(lifecycle.store.environment(environmentId), isNull);
  expect(lifecycle.store.primaryEnvironmentFor(taskId), isNull);
  expect(
    lifecycle.environmentRuntime.currentMaterialization(environmentId),
    isNull,
  );
}

Map<String, List<List<Object?>>> _snapshot(Database database) => {
  for (final table in [
    'adele_product_projects',
    'adele_product_tasks',
    'adele_product_environments',
  ])
    table: database
        .select('SELECT * FROM $table ORDER BY id')
        .map((row) => row.values.toList())
        .toList(),
};

Object? _storedState(Database database, EnvironmentId id) => jsonDecode(
  database.select(
        'SELECT provider_state_json FROM adele_product_environments WHERE id = ?',
        [id.value],
      ).single['provider_state_json']!
      as String,
);

Matcher _staleProvider() =>
    isA<ProviderUnavailable>().having((error) => error.stale, 'stale', isTrue);

final class _ProjectChannel implements AdeleRequestChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(method, projectProviderServicePrepareSourceId);
    return <String, Object?>{
      'sourceLocation': payload['sourceLocation'],
      'databaseRelativePath': '.adele/data.db',
    };
  }
}

final class _EnvironmentChannel implements AdeleRequestChannel {
  final established = <Map<String, Object?>>[];
  final restored = <Map<String, Object?>>[];
  final _live = <String>{};
  FutureOr<Map<String, Object?>> Function(Map<String, Object?>)? onEstablish;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final context = payload['context']! as Map<String, Object?>;
    if (method == environmentProviderServiceEstablishId) {
      established.add(context);
      final state = await (onEstablish?.call(context) ?? _initialState);
      _live.add(context['environmentId']! as String);
      return <String, Object?>{'providerState': state};
    }
    expect(method, environmentProviderServiceRestoreId);
    restored.add(context);
    if (!_live.add(context['environmentId']! as String)) {
      throw const EnvironmentFailure(
        code: 'environment_already_live',
        message: 'This provider generation already bound the Environment.',
        details: {},
      );
    }
    return <String, Object?>{'providerState': _refreshedState};
  }
}

final class _NoIds implements ProductIdSource {
  @override
  ProjectId nextProjectId() => fail('Unexpected Project allocation');

  @override
  TaskId nextTaskId() => fail('Unexpected Task allocation');

  @override
  EnvironmentId nextEnvironmentId() =>
      fail('Unexpected Environment allocation');

  @override
  SessionId nextSessionId() => fail('Unexpected Session allocation');
}

final class _ProviderEndpoint implements CapabilityEndpoint {
  const _ProviderEndpoint(this.provider);

  final EnvironmentProvider provider;

  @override
  bool get isAvailable => true;

  @override
  String get serviceId => environmentProviderServiceId;
}

final class _BlockingRestoreProvider implements EnvironmentProvider {
  final started = Completer<void>();
  final result = Completer<EnvironmentProviderResult>();
  LocalEnvironment? environment;

  @override
  ProviderId get providerId => _environmentProviderId;

  @override
  Future<EnvironmentProviderResult> restore(LocalEnvironment environment) {
    this.environment = environment;
    started.complete();
    return result.future;
  }

  @override
  Future<EnvironmentProviderResult> establish(LocalEnvironment environment) =>
      throw UnimplementedError();

  @override
  Future<EnvironmentTextFile> readFile(
    EnvironmentId environmentId,
    String relativePath,
  ) => throw UnimplementedError();

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    EnvironmentId environmentId,
    String relativePath,
  ) => throw UnimplementedError();

  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String text,
  ) => throw UnimplementedError();

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) => throw UnimplementedError();

  @override
  Future<void> deleteExistingTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String expectedRevision,
  ) => throw UnimplementedError();

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentId environmentId,
    EnvironmentForegroundProcessRequest request,
  ) => throw UnimplementedError();
}
