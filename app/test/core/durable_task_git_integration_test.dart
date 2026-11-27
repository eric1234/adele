@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../support/prepared_durable_git.dart';

void main() {
  final suite = PreparedDurableGit(Directory.current.parent);
  setUpAll(suite.prepare);

  for (final failCommit in [false, true]) {
    test(
      'actual Git establishment survives externally but SQL ${failCommit ? 'COMMIT' : 'insert'} failure publishes nothing',
      () async {
        final source = await createGitRepository('adele-git-atomic-failure-');
        final fixture = _HeldEstablishmentFixture(suite);
        addTearDown(fixture.close);
        await fixture.start();
        final project = await fixture.open(source);
        final prior = await fixture.create(project);
        final backing = fixture.lifecycle.existingDatabaseForProject(project)!;
        final originalAnchor = gitAnchor(backing, prior.environment.id);
        final inspection = sqlite3.open(backing.path);
        addTearDown(inspection.close);
        if (failCommit) {
          inspection.execute('''
            CREATE TABLE fixture_deferred (
              environment_id TEXT REFERENCES adele_product_environments(id)
              DEFERRABLE INITIALLY DEFERRED
            );
            CREATE TRIGGER reject_anchor AFTER INSERT ON adele_git_task_anchors
            BEGIN
              INSERT INTO fixture_deferred (environment_id) VALUES ('absent');
            END;
          ''');
        } else {
          inspection.execute('''
            CREATE TRIGGER reject_anchor BEFORE INSERT ON adele_git_task_anchors
            BEGIN SELECT RAISE(ABORT, 'injected anchor insert failure'); END;
          ''');
        }
        final gate = fixture.holdNext();
        final creating = fixture.create(project);
        final rejected = expectLater(
          creating,
          throwsA(
            isA<SqliteException>().having(
              (error) => error.causingStatement,
              'causingStatement',
              failCommit
                  ? equals('COMMIT')
                  : contains('INSERT INTO adele_git_task_anchors'),
            ),
          ),
        );
        await gate.arrived.future;
        final plan = gate.result!['initialState']! as Map;
        expect(plan['inserts'], hasLength(1));
        expect(((plan['inserts']! as List).single as Map)['expectedRows'], 1);
        gate.release.complete();
        await rejected;
        _expectRejected(fixture, project, gate, prior: prior);
        expect(gitAnchor(backing, prior.environment.id), originalAnchor);
        expect(inspection.select('SELECT * FROM adele_git_task_anchors'), [
          originalAnchor,
        ]);
        expect(inspection.select('SELECT id FROM adele_product_tasks'), [
          {'id': prior.task.id.value},
        ]);
        expect(inspection.select('SELECT id FROM adele_product_environments'), [
          {'id': prior.environment.id.value},
        ]);
        expect(
          inspection.select('SELECT * FROM adele_product_sessions'),
          isEmpty,
        );
        if (failCommit) {
          expect(inspection.select('SELECT * FROM fixture_deferred'), isEmpty);
        }
        expect(backing.autocommit, isTrue);
        await _expectExternalWorktree(source, gate);
        inspection.execute('DROP TRIGGER reject_anchor');
        final retried = await fixture.create(project);
        expect(retried.task.id.value, isNot(gate.context!['taskId']));
        expect(fixture.lifecycle.store.tasksFor(project.id), hasLength(2));
        expect(
          inspection.select('SELECT * FROM adele_git_task_anchors'),
          hasLength(2),
        );
      },
    );
  }

  for (final replace in [false, true]) {
    test(
      'retired actual Git plan cannot enter SQL${replace ? ' through a same-ID replacement' : ''}',
      () async {
        final source = await createGitRepository('adele-git-retired-plan-');
        final fixture = _HeldEstablishmentFixture(suite);
        addTearDown(fixture.close);
        await fixture.start();
        final project = await fixture.open(source);
        final oldBinding = fixture.registry.resolve(
          environmentProviderCapability,
        );
        final gate = fixture.holdNext();
        final creating = fixture.create(project);
        final rejected = expectLater(
          creating,
          throwsA(
            isA<ProviderUnavailable>().having(
              (error) => error.stale,
              'stale',
              isTrue,
            ),
          ),
        );
        await gate.arrived.future;
        expect(gate.result!['initialState'], isA<Map<String, Object?>>());
        final backing = fixture.lifecycle.existingDatabaseForProject(project)!;
        expect(backing.loadProductGraph().tasks, isEmpty);
        await fixture.backends.close();
        if (replace) {
          await fixture.start();
          final freshBinding = fixture.registry.resolve(
            environmentProviderCapability,
          );
          expect(freshBinding.provider.id, oldBinding.provider.id);
          expect(freshBinding.isSameRegistration(oldBinding), isFalse);
        }
        gate.release.complete();
        await rejected;
        _expectRejected(fixture, project, gate);
        expect(backing.loadProductGraph().tasks, isEmpty);
        expect(backing.loadProductGraph().environments, isEmpty);
        expect(
          backing.queryPluginRows(
            "SELECT name FROM sqlite_master WHERE name='adele_git_task_anchors'",
            {},
          ),
          isEmpty,
        );
        expect(
          fixture.establishments,
          1,
          reason: 'Never retry on the replacement.',
        );
        await _expectExternalWorktree(source, gate);
        if (replace) {
          final fresh = await fixture.create(project);
          expect(fixture.establishments, 2);
          expect(fixture.lifecycle.store.tasksFor(project.id), [fresh.task]);
          expect(
            gitAnchor(backing, fresh.environment.id)['baseline_commit'],
            gate.baseline,
          );
        }
      },
    );
  }
}

void _expectRejected(
  _HeldEstablishmentFixture fixture,
  Project project,
  _EstablishmentGate gate, {
  TaskCreationResult? prior,
}) {
  final task = TaskId(gate.context!['taskId']! as String);
  final environment = EnvironmentId(gate.context!['environmentId']! as String);
  final store = fixture.lifecycle.store;
  expect(
    store.tasksFor(project.id),
    prior == null ? isEmpty : equals([prior.task]),
  );
  expect(store.task(task), isNull);
  expect(store.environment(environment), isNull);
  expect(store.primaryEnvironmentFor(task), isNull);
  expect(store.sessionsForTask(task), isEmpty);
  expect(
    fixture.lifecycle.environmentRuntime.currentMaterialization(environment),
    isNull,
  );
}

Future<void> _expectExternalWorktree(
  Directory source,
  _EstablishmentGate gate,
) async {
  final state = gate.result!['providerState']! as Map;
  final worktree = Directory.fromUri(
    source.uri.resolve(state['worktreeRelativePath']! as String),
  );
  expect(await worktree.exists(), isTrue);
  expect((await git(worktree, ['rev-parse', 'HEAD'])).trim(), gate.baseline);
  expect(
    (await git(worktree, ['symbolic-ref', 'HEAD'])).trim(),
    'refs/heads/${state['branch']}',
  );
  expect(
    await git(source, ['worktree', 'list', '--porcelain']),
    contains('worktree ${worktree.path}\n'),
  );
}

final class _HeldEstablishmentFixture {
  _HeldEstablishmentFixture(this.suite) {
    lifecycle = ProductLifecycleCoordinator(
      store: InMemoryProductStore(),
      registry: registry,
      extensions: extensions,
      ids: MonotonicProductIdSource(seed: 'held-git'),
      providerForBinding: (binding) => GeneratedEnvironmentProvider(
        providerId: binding.provider.id,
        service: EnvironmentProviderServiceClient(
          _EstablishmentChannel(binding.requestChannel, this),
        ),
      ),
      captureEstablishmentOwner: (binding) {
        final owner = backends.backendForProvider(binding)!;
        return EnvironmentEstablishmentOwner(
          pluginId: PluginId(owner.connection!.pluginId),
          validate: () => owner.validateProviderOwnership(binding),
        );
      },
    );
  }

  final PreparedDurableGit suite;
  final registry = CapabilityRegistry();
  final extensions = ExtensionRegistry();
  late final ProductLifecycleCoordinator lifecycle;
  late ApplicationPluginBootstrap backends;
  _EstablishmentGate? nextGate;
  final gates = <_EstablishmentGate>[];
  int establishments = 0;

  Future<void> start() async {
    backends = ApplicationPluginBootstrap(
      registry,
      extensions,
      createInfrastructureServices: (connection) =>
          projectStorageServices(lifecycle, connection),
    );
    await suite.startBackends(backends);
  }

  Future<Project> open(Directory source) => lifecycle.openProject(
    sourceLocation: source.uri,
    provider: lifecycle.resolveProjectProvider(localDirectoryProviderId),
  );

  Future<TaskCreationResult> create(Project project) => lifecycle.createTask(
    projectId: project.id,
    title: 'Actual Git establishment',
  );

  _EstablishmentGate holdNext() {
    final gate = _EstablishmentGate();
    gates.add(gate);
    return nextGate = gate;
  }

  Future<void> close() async {
    for (final gate in gates) {
      if (!gate.release.isCompleted) gate.release.complete();
    }
    await backends.close();
    await lifecycle.close();
  }
}

final class _EstablishmentGate {
  final arrived = Completer<void>();
  final release = Completer<void>();
  Map<String, Object?>? context;
  Map<String, Object?>? result;

  String get baseline =>
      (((result!['initialState']! as Map)['inserts']! as List).single
              as Map)['parameters'][':baseline']
          as String;
}

/// Observe and delay only the already-completed real AOT result, never synthesize
/// provider state, an initial plan, or any comparison implementation.
final class _EstablishmentChannel implements AdeleRequestChannel {
  _EstablishmentChannel(this.delegate, this.fixture);

  final AdeleRequestChannel delegate;
  final _HeldEstablishmentFixture fixture;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method != environmentProviderServiceEstablishId) {
      return delegate.request(method, payload);
    }
    fixture.establishments++;
    final gate = fixture.nextGate;
    fixture.nextGate = null;
    final result = await delegate.request(method, payload);
    if (gate != null) {
      gate.context = Map<String, Object?>.from(payload['context']! as Map);
      gate.result = Map<String, Object?>.from(result! as Map);
      gate.arrived.complete();
      await gate.release.future;
    }
    return result;
  }
}
