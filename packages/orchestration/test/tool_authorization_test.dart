import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'public point supports independent synchronous and async policies',
    () async {
      final registry = ExtensionRegistry();
      expect(
        toolAuthorizationPolicies.value,
        'dev.adele.extension.tool-authorization-policies',
      );
      expect(registry.discover(toolAuthorizationPolicies), isEmpty);
      for (final decision in ToolAuthorizationDecision.values) {
        registry.register(
          point: toolAuthorizationPolicies,
          id: ExtensionId('dev.test.policy.${decision.name}'),
          value: ToolAuthorizationPolicyContribution(evaluate: (_) => decision),
        );
      }
      registry.register(
        point: toolAuthorizationPolicies,
        id: ExtensionId('dev.test.policy.async'),
        value: ToolAuthorizationPolicyContribution(
          evaluate: (_) async => ToolAuthorizationDecision.abstain,
        ),
      );
      final request = _request({});
      final decisions = [
        for (final binding in registry.discover(toolAuthorizationPolicies))
          await binding.value.evaluate(request),
      ];
      expect(decisions, [
        ...ToolAuthorizationDecision.values,
        ToolAuthorizationDecision.abstain,
      ]);
    },
  );

  test(
    'request retains semantic identities and deeply snapshots arguments',
    () {
      final nested = <String, Object?>{'path': 'normalized.dart'};
      final items = <Object?>[nested];
      final arguments = <String, Object?>{'items': items};
      final request = _request(arguments);
      arguments.clear();
      items.clear();
      nested['path'] = 'changed.dart';

      expect(request.toolId, ToolId('dev.test.tool.read'));
      expect(request.runId, RunId('run'));
      expect(request.sessionId, SessionId('session'));
      expect(request.projectId, ProjectId('project'));
      expect(request.toolInvocationId, ToolInvocationId('invocation'));
      expect(request.effects, same(_effects));
      expect(request.canonicalArguments, {
        'items': [
          {'path': 'normalized.dart'},
        ],
      });
      expect(() => request.canonicalArguments.clear(), throwsUnsupportedError);
      final retained = request.canonicalArguments['items']! as List<Object?>;
      expect(() => retained.clear(), throwsUnsupportedError);
      expect(
        () => (retained.single! as Map<String, Object?>).clear(),
        throwsUnsupportedError,
      );
    },
  );

  test('request rejects executable objects and cyclic argument data', () {
    expect(() => _request({'callback': () {}}), throwsFormatException);
    expect(() => _request({'value': double.nan}), throwsFormatException);
    final cycle = <String, Object?>{};
    cycle['self'] = cycle;
    expect(() => _request(cycle), throwsFormatException);
  });
}

final _effects = EffectDescription(
  effects: [ToolEffect.sourceRead],
  targets: [EffectTarget(uri: Uri.parse('file:///normalized.dart'))],
  summary: 'Read normalized source.',
);

ToolAuthorizationRequest _request(Map<String, Object?> arguments) =>
    ToolAuthorizationRequest(
      toolId: ToolId('dev.test.tool.read'),
      canonicalArguments: arguments,
      effects: _effects,
      runId: RunId('run'),
      sessionId: SessionId('session'),
      projectId: ProjectId('project'),
      toolInvocationId: ToolInvocationId('invocation'),
    );
