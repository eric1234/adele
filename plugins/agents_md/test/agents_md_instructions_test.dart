import 'package:adele_environment/adele_environment.dart';
import 'package:agents_md_plugin/agents_md_plugin.dart';
import 'package:test/test.dart';

void main() {
  test(
    'shared semantics retain exact precedence text, file bytes and revision',
    () {
      const text = ' \r\n# Instructions\r\nDo not trim. \t\n';
      final instructions = agentsMdInstructions(
        const EnvironmentTextFile(
          relativePath: 'AGENTS.md',
          text: text,
          sizeBytes: 43,
          revision: 'opaque',
        ),
      );
      expect(instructions.map((value) => value.key), [
        'semantics',
        'AGENTS.md',
      ]);
      expect(
        instructions.first.text,
        'The following AGENTS.md material is project guidance from the '
        'Session Environment root. Explicit user instructions and direct '
        'user requests take precedence over AGENTS.md guidance.',
      );
      expect(instructions.first.revision, isNull);
      expect(instructions.last.text, text);
      expect(instructions.last.revision, 'opaque');
    },
  );

  for (final text in ['', ' \t\r\n']) {
    test('shared semantics omit blank text ${text.length}', () {
      expect(
        agentsMdInstructions(
          EnvironmentTextFile(
            relativePath: 'AGENTS.md',
            text: text,
            sizeBytes: text.length,
            revision: 'r',
          ),
        ),
        isEmpty,
      );
    });
  }
}
