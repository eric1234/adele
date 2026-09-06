import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:test/test.dart';

void main() {
  test('model definitions retain immutable structured schemas', () {
    final ModelToolDefinition definition = ModelToolDefinition(
      alias: 'inspect',
      description: 'Inspect a resource.',
      argumentsSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'uri': <String, Object?>{'type': 'string'},
        },
      },
    );

    expect(definition.alias, 'inspect');
    expect(
      () => definition.argumentsSchema['type'] = 'array',
      throwsUnsupportedError,
    );
  });

  test('tool outcomes keep model content separate from host data', () {
    final ToolOutcome outcome = ToolOutcome(
      disposition: ToolOutcomeDisposition.success,
      effectCertainty: EffectCertainty.knownOccurred,
      modelContent: 'Inspection complete.',
      hostData: const <String, Object?>{'privateDiagnostic': 'host-only'},
    );

    expect(outcome.modelContent, isNot(contains('host-only')));
    expect(outcome.hostData['privateDiagnostic'], 'host-only');
  });

  test('effect descriptions represent source mutation explicitly', () {
    final EffectDescription description = EffectDescription(
      effects: const <ToolEffect>[ToolEffect.sourceMutation],
      targets: <EffectTarget>[
        EffectTarget(
          uri: Uri.parse('adele-environment:/environment-1/source.dart'),
        ),
      ],
      summary: 'Patch Environment file source.dart.',
    );

    expect(description.effects, <ToolEffect>{ToolEffect.sourceMutation});
    expect(
      description.targets.single.uri.toString(),
      'adele-environment:/environment-1/source.dart',
    );
  });
}
