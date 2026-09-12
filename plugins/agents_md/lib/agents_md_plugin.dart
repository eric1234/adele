/// Stock root-level AGENTS.md inference instructions.
library;

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

final PluginId agentsMdPluginId = PluginId('dev.adele.plugin.agents-md');

final class AgentsMdPlugin {
  const AgentsMdPlugin();

  ExtensionRegistration activate(ExtensionRegistry extensions) =>
      extensions.register(
        point: inferenceContextSources,
        id: ExtensionId('dev.adele.plugin.agents-md.instructions'),
        value: InferenceContextSourceContribution(
          failureMode: InferenceContextFailureMode.required,
          snapshot: _snapshot,
        ),
      );

  static Future<Iterable<InferenceContextMaterial>> _snapshot(
    InferenceContextSourceContext context,
  ) async {
    final AuthorizedEnvironmentFileReadFacet files = await context
        .requireHostService<AuthorizedEnvironmentFileReadFacet>();
    if (files.sessionId != context.session.id) {
      throw StateError('The filesystem authority belongs to another Session.');
    }
    files.validateBinding();
    final EnvironmentTextFile file;
    try {
      file = await files.readFile('AGENTS.md');
    } on EnvironmentFailure catch (failure) {
      if (failure.code != 'not_found') rethrow;
      files.validateBinding();
      return const <InferenceContextMaterial>[];
    }
    files.validateBinding();
    if (file.text.trim().isEmpty) return const <InferenceContextMaterial>[];
    return <InferenceContextMaterial>[
      InferenceInstructionMaterial(
        key: 'semantics',
        text:
            'The following AGENTS.md material is project guidance from the '
            'Session Environment root. Explicit user instructions and direct '
            'user requests take precedence over AGENTS.md guidance.',
      ),
      InferenceInstructionMaterial(
        key: 'AGENTS.md',
        text: file.text,
        revision: file.revision,
      ),
    ];
  }
}
