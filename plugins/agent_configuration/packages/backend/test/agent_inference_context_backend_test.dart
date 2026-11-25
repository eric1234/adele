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
  tearDown(() => expect(selection.writes, 0));

  test('no selection succeeds without reading the catalog', () async {
    catalog.unavailable = true;
    expect(await source.captureRun('session', 'run'), isEmpty);
    expect(selection.reads, ['session']);
    expect(catalog.reads, 0);
  });

  test('failed selection read is not empty or cached success', () async {
    selection.id = 'work';
    catalog.agents = [_agent('work', 'Previous instructions')];
    await source.captureRun('session', 'first');
    selection.unavailable = true;
    await expectLater(
      source.captureRun('session', 'second'),
      _failsSafely('Agent selection could not be read.'),
    );
    expect(selection.reads, ['session', 'session']);
    expect(catalog.reads, 1);
  });

  test(
    'capture resolves the stable ID once, returning only its exact Markdown',
    () async {
      const markdown = '  # Review\r\n\r\n```dart\ncheck();\n```  \n';
      selection.id = 'work';
      final other = _agent('other', 'Other instructions', name: 'work');
      catalog.agents = [other, _agent('work', markdown)];
      catalog.complete = false;
      final first = (await source.captureRun('session', 'run')).single;
      expect(
        (first.key, first.text, first.revision),
        ('instructions', markdown, null),
      );

      expect(selection.reads, ['session']);
      expect(catalog.reads, 1);
    },
  );

  test('blank instructions are a successful empty contribution', () async {
    selection.id = 'work';
    for (final blank in ['', ' \r\n\t ']) {
      catalog.agents = [_agent('work', blank)];
      expect(await source.captureRun('session', 'run'), isEmpty);
    }
    expect(catalog.reads, 2);
  });

  test('missing and unobserved IDs fail; recreated IDs resolve anew', () async {
    selection.id = 'work';
    catalog.agents = [_agent('other', 'private Markdown', name: 'work')];
    await expectLater(
      source.captureRun('session', 'one'),
      _failsSafely('The selected Agent does not exist.'),
    );
    catalog.complete = false;
    await expectLater(
      source.captureRun('session', 'two'),
      _failsSafely(
        'The selected Agent was not observed in the incomplete catalog.',
      ),
    );
    catalog.agents = [_agent('work', 'Replacement instructions')];
    expect(
      (await source.captureRun('session', 'three')).single.text,
      'Replacement instructions',
    );
    expect(selection.reads, ['session', 'session', 'session']);
    expect(catalog.reads, 3);
  });

  test('catalog failure does not reuse text or disclose the cause', () async {
    selection.id = 'work';
    catalog.agents = [_agent('work', 'private Markdown')];
    await source.captureRun('session', 'run');
    catalog.unavailable = true;
    await expectLater(
      source.captureRun('session', 'run'),
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
  int writes = 0;

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
  ) async {
    writes++;
    throw UnsupportedError('Inference cannot change selection.');
  }
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
