import 'package:adele_contract/adele_contract.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';
import 'package:test/test.dart';

void main() {
  test('snapshot owns an immutable copy of its definitions', () {
    final agents = [
      const AgentDefinition(
        id: 'author',
        name: 'Writer',
        description: null,
        whenToUse: '',
        instructions: '',
      ),
    ];
    final snapshot = AgentCatalogSnapshot(agents: agents, isComplete: true);
    agents.clear();
    expect(snapshot.agents.single.id, 'author');
    expect(snapshot.agents.clear, throwsUnsupportedError);
  });

  test(
    'generated read is selector-free and preserves nullable fields',
    () async {
      const markdown = '\r\n### Draft\n\n- preserve trailing spaces  \n';
      final client = AgentCatalogServiceClient(
        _Channel({
          'agents': [
            {
              'id': 'author',
              'name': 'Writer',
              'description': null,
              'whenToUse': '',
              'instructions': markdown,
            },
          ],
          'isComplete': false,
        }),
      );
      expect(agentCatalogServiceId, 'agentCatalog');
      final snapshot = await client.readAgents();
      final agent = snapshot.agents.single;
      expect(snapshot.isComplete, isFalse);
      expect(agent.id, 'author');
      expect(agent.name, 'Writer');
      expect(agent.description, isNull);
      expect(agent.whenToUse, '');
      expect(agent.instructions, markdown);
      expect(snapshot.agents.clear, throwsUnsupportedError);
    },
  );

  test('malformed service response cannot masquerade as a snapshot', () async {
    for (final response in [
      {'agents': <Object?>[]},
      {'agents': <Object?>[], 'isComplete': 'true'},
      {
        'agents': [
          {'id': 'work', 'name': 'Incomplete wire definition'},
        ],
        'isComplete': true,
      },
    ]) {
      final client = AgentCatalogServiceClient(_Channel(response));
      await expectLater(
        client.readAgents(),
        throwsA(isA<AdeleProtocolException>()),
      );
    }
  });
}

final class _Channel implements AdeleRequestChannel {
  const _Channel(this.response);
  final Map<String, Object?> response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(method, 'agentCatalog.readAgents');
    expect(payload, isEmpty);
    return response;
  }
}
