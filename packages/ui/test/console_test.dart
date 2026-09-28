import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ConsoleCreationAction action(String id) =>
      ConsoleCreationAction(id: id, label: 'Create', create: (_) async {});

  test(
    'contributions compose, copying actions and rejecting duplicate IDs',
    () {
      final actions = [action('open')];
      final first = ConsoleContribution(actions: actions);
      actions.clear();
      expect(first.actions.single.id, 'open');
      expect(() => first.actions.clear(), throwsUnsupportedError);
      expect(
        () => ConsoleContribution(actions: [action('open'), action('open')]),
        throwsArgumentError,
      );
      final registry = ExtensionRegistry();
      registry.register(
        point: consoleContributions,
        id: ExtensionId('test.first'),
        value: first,
      );
      registry.register(
        point: consoleContributions,
        id: ExtensionId('test.second'),
        value: ConsoleContribution(actions: [action('open')]),
      );
      expect(registry.discover(consoleContributions), hasLength(2));
    },
  );

  test('action IDs are bounded, local ASCII identifiers', () {
    for (final id in ['', 'two words', 'a\n', 'x' * 129]) {
      expect(() => action(id), throwsArgumentError);
    }
    expect(action('read-only.log_1').id, 'read-only.log_1');
  });

  test('metadata and messages have bounded safe display text', () {
    final metadata = ConsoleMetadata(
      title: 'Name\n\u001b\u202e${'x' * 200}',
      description: 'Evidence\t${'y' * 400}',
      status: ConsoleStatus.completed,
    );
    expect(metadata.title, startsWith(r'Name\n\u001B\u202E'));
    expect(metadata.title.length, lessThanOrEqualTo(80));
    expect(metadata.description!.length, lessThanOrEqualTo(240));
    expect(metadata.status, ConsoleStatus.completed);
    expect(ConsoleMetadata(title: '   ').title, 'Console');
    expect(
      ConsoleCreationAction(
        id: 'open',
        label: 'z' * 500,
        create: (_) async {},
      ).label.length,
      lessThanOrEqualTo(80),
    );
    final warning = ConsoleCleanupResult(
      warning: '\u0000${'w' * 500}',
    ).warning!;
    expect(warning, startsWith(r'\u0000'));
    expect(warning.length, lessThanOrEqualTo(240));
    expect(ConsoleCleanupResult().warning, isNull);
  });

  test('close advice has only no-confirmation or a bounded confirmation', () {
    expect(const ConsoleCloseAdvice.noConfirmation().message, isNull);
    expect(ConsoleCloseAdvice.confirm('').message, 'Close this console?');
    expect(
      ConsoleCloseAdvice.confirm('m' * 500).message!.length,
      lessThanOrEqualTo(240),
    );
  });
}
