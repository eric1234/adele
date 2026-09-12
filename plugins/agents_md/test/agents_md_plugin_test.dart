import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agents_md_plugin/agents_md_plugin.dart';
import 'package:test/test.dart';

void main() {
  test(
    'exact root text and revision are distinct from precedence guidance',
    () async {
      final fixture = _Fixture();
      fixture.files.text = ' \r\n# Anything\r\n  opaque Markdown \n';
      final snapshot = await fixture.compose();
      final result = snapshot.sourceResults.single;
      expect(result.failureMode, InferenceContextFailureMode.required);
      expect(result.status, InferenceContextSourceStatus.contributed);
      expect(result.sourceId.value, 'dev.adele.plugin.agents-md.instructions');
      expect(result.materials, hasLength(2));
      expect(
        result.materials.first.text,
        contains('user requests take precedence'),
      );
      expect(result.materials.first.revision, isNull);
      expect(result.materials.last.key, 'AGENTS.md');
      expect(result.materials.last.text, fixture.files.text);
      expect(result.materials.last.revision, 'revision-1');
      expect(
        renderInferenceInstructions(snapshot),
        endsWith(fixture.files.text!),
      );
      expect(fixture.files.paths, ['AGENTS.md']);
      expect(fixture.context.requested, [AuthorizedEnvironmentFileReadFacet]);
    },
  );

  test(
    'each new snapshot rereads; earlier snapshots remain unchanged',
    () async {
      final fixture = _Fixture();
      fixture.files.text = 'first';
      final first = await fixture.compose();
      fixture.files.text = 'second';
      fixture.files.revision = 'revision-2';
      final second = await fixture.compose();
      fixture.files.text = null;
      final third = await fixture.compose();
      expect(first.sourceResults.single.materials.last.text, 'first');
      expect(first.sourceResults.single.materials.last.revision, 'revision-1');
      expect(second.sourceResults.single.materials.last.text, 'second');
      expect(second.sourceResults.single.materials.last.revision, 'revision-2');
      expect(
        third.sourceResults.single.status,
        InferenceContextSourceStatus.empty,
      );
      expect(fixture.files.paths, ['AGENTS.md', 'AGENTS.md', 'AGENTS.md']);
    },
  );

  for (final text in <String?>[null, '', ' \n\t\r\n']) {
    test('missing or blank ($text) is successful empty output', () async {
      final fixture = _Fixture();
      fixture.files.text = text;
      final snapshot = await fixture.compose();
      expect(
        snapshot.sourceResults.single.status,
        InferenceContextSourceStatus.empty,
      );
      expect(snapshot.sourceResults.single.materials, isEmpty);
      expect(renderInferenceInstructions(snapshot), 'strategy');
      expect(fixture.files.paths, ['AGENTS.md']);
    });
  }

  for (final failure in <Object>[
    const EnvironmentFailure(
      code: 'permission_denied',
      message: 'denied',
      details: {},
    ),
    const EnvironmentFailure(
      code: 'not_a_file',
      message: 'directory',
      details: {},
    ),
    const AuthorizedEnvironmentBindingStale('retired'),
    StateError('unexpected'),
  ]) {
    test('non-absence failure propagates: $failure', () async {
      final fixture = _Fixture();
      fixture.files.failure = failure;
      await expectLater(
        fixture.compose(),
        throwsA(
          isA<InferenceContextSourceFailed>().having(
            (error) => error.cause,
            'cause',
            same(failure),
          ),
        ),
      );
    });
  }

  test('wrong Session and unavailable service fail closed', () async {
    final fixture = _Fixture();
    fixture.files.sessionId = SessionId('other');
    await expectLater(
      fixture.compose(),
      throwsA(isA<InferenceContextSourceFailed>()),
    );
    expect(fixture.files.paths, isEmpty);
    fixture.context.available = false;
    await expectLater(
      fixture.compose(),
      throwsA(isA<InferenceContextSourceFailed>()),
    );
    expect(fixture.files.paths, isEmpty);
  });

  test('closing activation removes source', () async {
    final fixture = _Fixture();
    await fixture.activation.close();
    expect((await fixture.compose()).sourceResults, isEmpty);
    expect(fixture.files.paths, isEmpty);
  });
}

final class _Fixture {
  final registry = ExtensionRegistry();
  final files = _Files();
  late final context = _Context(files);
  late final ExtensionRegistration activation = const AgentsMdPlugin().activate(
    registry,
  );

  Future<InferenceContextSnapshot> compose() {
    activation;
    return InferenceContextComposer(registry).compose(
      strategyMaterial: StrategyInferenceMaterial(
        instructions: 'strategy',
        input: const [],
      ),
      sourceContext: context,
    );
  }
}

final class _Context implements InferenceContextSourceContext {
  _Context(this.files);
  final _Files files;
  bool available = true;
  final requested = <Type>[];
  @override
  final session = Session(
    id: SessionId('session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('test.strategy'),
  );
  @override
  final runId = RunId('run');
  @override
  Future<T> requireHostService<T extends Object>() async {
    requested.add(T);
    if (available && T == AuthorizedEnvironmentFileReadFacet) return files as T;
    throw StateError('Unavailable service $T');
  }
}

final class _Files implements AuthorizedEnvironmentFileReadFacet {
  String? text;
  String revision = 'revision-1';
  Object? failure;
  final paths = <String>[];
  @override
  SessionId sessionId = SessionId('session');
  @override
  final environmentId = EnvironmentId('environment');
  @override
  void validateBinding() {}
  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    paths.add(relativePath);
    if (failure case final Object error) throw error;
    if (text == null) {
      throw const EnvironmentFailure(
        code: 'not_found',
        message: 'missing',
        details: {},
      );
    }
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: text!,
      sizeBytes: text!.length,
      revision: revision,
    );
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) =>
      throw StateError('AGENTS.md must not scan directories');
}
