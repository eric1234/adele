import 'package:adele_contract/adele_contract.dart';
import 'package:scripted_model_contract/scripted_model_contract.dart';
import 'package:test/test.dart';

void main() {
  test('fixture contract invokes its generated unary service', () async {
    final _FixtureChannel channel = _FixtureChannel();
    final ScriptedModelResponse response =
        await ScriptedModelFixtureServiceClient(channel).invoke(
          const ScriptedModelRequest(
            messages: <ScriptedModelMessage>[
              ScriptedModelMessage(
                role: ScriptedModelMessageRole.user,
                content: 'inspect',
                toolCallId: null,
                toolOutcome: null,
                toolProposal: null,
              ),
            ],
            tools: <ScriptedToolDefinition>[],
          ),
        );

    expect(channel.method, scriptedModelFixtureServiceInvokeId);
    expect(response.content, 'fixture complete');
    expect(response.toolCall, isNull);
    expect(scriptedModelFixtureCapability.id.value, contains('fixture'));
  });
}

final class _FixtureChannel implements AdeleRequestChannel {
  String? method;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    return <String, Object?>{'content': 'fixture complete', 'toolCall': null};
  }
}
