import 'package:agent_configuration_backend/agent_configuration_backend.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';
import 'package:test/test.dart';

void main() {
  late _Selection selection;
  late _Catalog catalog;
  late AgentInferenceContextBackend source;
  setUp(() {
    selection = _Selection();
    catalog = _Catalog();
    source = AgentInferenceContextBackend(selection, catalog);
  });

  test('a Run that captured no Agent never needs a definition', () async {
    catalog.unavailable = true;
    final binding = await source.captureRun('session', 'run');
    expect(binding, isNull);
    selection.id = 'later';
    expect(await source.snapshot('session', 'run', binding), isEmpty);
    expect(selection.reads, ['session']);
    expect(catalog.reads, 0);
  });

  test('capture reads selection, not configuration or revision', () async {
    selection.id = 'stable-id';
    catalog.unavailable = true;
    expect(await source.captureRun('session', 'run'), 'stable-id');
    expect(selection.reads, ['session']);
    expect(catalog.reads, 0);
  });

  test('failed selection read is not an empty or cached binding', () async {
    selection.id = 'stable-id';
    await source.captureRun('one', 'first');
    selection.unavailable = true;
    await expectLater(
      source.captureRun('two', 'second'),
      _failsSafely('Agent selection could not be read.'),
    );
    expect(selection.reads, ['one', 'two']);
    expect(catalog.reads, 0);
  });

  test('snapshots follow the bound ID but use its current Markdown', () async {
    const markdown = '  # Review\r\n\r\n```dart\ncheck();\n```  \n';
    selection.id = 'work';
    final binding = await source.captureRun('session', 'run');
    final other = _agent('other', 'Other instructions', name: 'Original');
    catalog.agents = [other, _agent('work', markdown, name: 'Original')];
    final first = (await source.snapshot('session', 'run', binding)).single;
    expect(
      (first.key, first.text, first.revision),
      ('instructions', markdown, null),
    );

    selection.id = other.id;
    catalog.agents = [
      _agent('work', 'New instructions', name: 'Renamed'),
      other,
    ];
    catalog.complete = false;
    final next = (await source.snapshot('session', 'run', binding)).single;
    expect(
      (next.key, next.text, next.revision),
      ('instructions', 'New instructions', null),
    );
    expect(first.text, markdown);
    expect(selection.reads, ['session']);
    expect(catalog.reads, 2);
  });

  test('blank instructions are a successful empty contribution', () async {
    for (final blank in ['', ' \r\n\t ']) {
      catalog.agents = [_agent('work', blank)];
      expect(await source.snapshot('session', 'run', 'work'), isEmpty);
    }
  });

  test(
    'missing and unobserved IDs fail; re-created IDs resolve anew',
    () async {
      selection.id = 'work';
      final binding = await source.captureRun('session', 'run');
      catalog.agents = [_agent('other', 'private Markdown', name: 'work')];
      await expectLater(
        source.snapshot('session', 'run', binding),
        _failsSafely('The captured Agent does not exist.'),
      );
      catalog.complete = false;
      await expectLater(
        source.snapshot('session', 'run', binding),
        _failsSafely(
          'The captured Agent was not observed in the incomplete catalog.',
        ),
      );
      catalog.agents = [_agent('work', 'Replacement instructions')];
      expect(
        (await source.snapshot('session', 'run', binding)).single.text,
        'Replacement instructions',
      );
      expect(selection.reads, ['session']);
    },
  );

  test('catalog failure does not reuse text or disclose the cause', () async {
    catalog.agents = [_agent('work', 'private Markdown')];
    await source.snapshot('session', 'run', 'work');
    catalog.unavailable = true;
    await expectLater(
      source.snapshot('session', 'run', 'work'),
      _failsSafely('Agent configuration could not be read.'),
    );
    expect(catalog.reads, 2);
  });
}

Matcher _failsSafely(String message) => throwsA(
  isA<StateError>().having((e) => e.message, 'public message', message),
);

AgentDefinition _agent(
  String id,
  String text, {
  String name = 'Display name',
}) => AgentDefinition(
  id: id,
  name: name,
  instructions: text,
  description: 'Not instructions',
  whenToUse: 'Not instructions either',
);

final class _Selection implements AgentSelectionService {
  String? id;
  bool unavailable = false;
  final reads = <String>[];

  @override
  Future<AgentSelectionSnapshot> readSessionSelection(String sessionId) async {
    reads.add(sessionId);
    if (unavailable) throw StateError('/private/db: private SQL diagnostic');
    return AgentSelectionSnapshot(
      sessionId: sessionId,
      selectedAgentId: id,
      revision: id == null ? 0 : 17,
    );
  }

  @override
  Future<AgentSelectionSnapshot> updateSessionSelection(
    String sessionId,
    String? selectedAgentId,
    int expectedRevision,
  ) => throw UnsupportedError('Inference cannot change selection.');
}

final class _Catalog implements AgentCatalogService {
  List<AgentDefinition> agents = [];
  bool complete = true;
  bool unavailable = false;
  int reads = 0;

  @override
  Future<AgentCatalogSnapshot> readAgents() async {
    reads++;
    if (unavailable) throw StateError('/private/record.toml: private Markdown');
    return AgentCatalogSnapshot(agents: agents, isComplete: complete);
  }
}
