import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/ui/commands/command_search.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  var availabilityReads = 0;
  setUp(() => availabilityReads = 0);
  tearDown(() => expect(availabilityReads, 0));

  List<ResolvedCommand> catalog(List<(String, String)> entries) {
    final registry = ExtensionRegistry();
    for (final (id, label) in entries) {
      registry.register(
        point: commandContributions,
        id: ExtensionId(id),
        value: CommandContribution(
          id: CommandId(id),
          label: label,
          availability: () {
            availabilityReads++;
            throw StateError('Search must not evaluate this');
          },
          invoke: () => throw StateError('Search must not invoke this'),
        ),
      );
    }
    return CommandResolver(registry).discover();
  }

  List<String> labels(List<ResolvedCommand> commands, String query) =>
      searchCommands(commands, query).map((c) => c.label).toList();

  test('exact label and unrelated exact ID outrank approximate labels', () {
    final commands = catalog([
      ('dev.test.open', 'Unrelated label'),
      ('test.exact-label', 'DEV.TEST.OPEN'),
      ('test.prefix', 'dev.test.open extra'),
      ('test.substring', 'A dev.test.open'),
    ]);
    expect(labels(commands, 'DEV.TEST.OPEN'), [
      'DEV.TEST.OPEN',
      'Unrelated label',
      'dev.test.open extra',
      'A dev.test.open',
    ]);
  });

  test('label tiers beat namespace-only matches', () {
    final commands = catalog([
      ('test.exact', 'Term'),
      ('test.prefix', 'Terminal'),
      ('test.word', 'New Terminal'),
      ('test.substring', 'Determine'),
      ('term.id', 'A namespace prefix'),
      ('test.term-id', 'B namespace segment'),
      ('test.fuzzy', 'Tree room'),
      ('test.determine', 'C namespace substring'),
    ]);
    expect(labels(commands, 'term'), [
      'Term',
      'Terminal',
      'New Terminal',
      'Determine',
      'A namespace prefix',
      'B namespace segment',
      'Tree room',
      'C namespace substring',
    ]);
  });

  test(
    'expected command names accept case, terms and ordered subsequences',
    () {
      final commands = catalog([
        ('dev.adele.terminal.new-terminal', 'New Terminal'),
        ('dev.adele.source-editor.open-source', 'Open Source...'),
        ('test.other', 'Other action'),
      ]);
      for (final query in [
        'new terminal',
        'nt',
        'ntrm',
        'NEW TERM',
        ' new   term ',
      ]) {
        expect(labels(commands, query), ['New Terminal'], reason: query);
      }
      for (final query in [
        'os',
        'open source',
        'open src',
        'source',
        'dev.adele.source-editor.open-source',
        'source ed',
        'source open',
      ]) {
        expect(labels(commands, query), ['Open Source...'], reason: query);
      }
      for (final query in [
        'zzq',
        'qnt',
        'terminal source',
        'new missing',
        '...missing',
      ]) {
        expect(labels(commands, query), isEmpty, reason: query);
      }
    },
  );

  test('word prefixes recognize punctuation, whitespace and ID segments', () {
    for (final separator in [' ', '-', '_', '.', ': ', '/', ' (']) {
      final commands = catalog([
        ('test.target', 'Open${separator}Remote${separator}Source'),
        ('test.weak', 'Operation request'),
      ]);
      expect(labels(commands, 'op sou'), [
        'Open${separator}Remote${separator}Source',
      ]);
    }
    final commands = catalog([
      ('dev.adele.source-editor.open-source', 'Unrelated label'),
    ]);
    for (final query in [
      'dev.ade',
      'source-ed',
      'source ed',
      'editor.op',
      'adele',
      'urce-ed',
    ]) {
      expect(labels(commands, query), ['Unrelated label'], reason: query);
    }
    expect(
      labels(commands, 'daso'),
      isEmpty,
      reason: 'No namespace fuzzy search',
    );
  });

  test('contiguous punctuation and whitespace substrings still match', () {
    final commands = catalog([('test.target', 'Open  Source...')]);
    for (final query in ['.', '...', 'n  s', 'EN  SOUR', 'SOURCE...']) {
      expect(labels(commands, query), ['Open  Source...'], reason: query);
    }
  });

  test(
    'fuzzy quality rewards boundaries, consecutive characters and fewer gaps',
    () {
      final commands = catalog([
        ('test.boundary', 'New Terminal'),
        ('test.internal', 'Neatime'),
        ('test.late', 'A New Terminal'),
        ('test.wide', 'New remote Terminal'),
      ]);
      expect(labels(commands, 'nt'), [
        'New Terminal',
        'A New Terminal',
        'Neatime',
        'New remote Terminal',
      ]);
      final runs = catalog([
        ('test.consecutive', 'Abc x'),
        ('test.gapped', 'Ab c x'),
      ]);
      expect(labels(runs, 'abcx'), ['Abc x', 'Ab c x']);
    },
  );

  test(
    'fuzzy alignment can skip an early weak occurrence for a better run',
    () {
      final commands = catalog([
        ('test.best', 'A distant Abc x'),
        ('test.weak', 'A distant b c x'),
      ]);
      expect(labels(commands, 'abcx'), ['A distant Abc x', 'A distant b c x']);
    },
  );

  test('single-character queries prefer labels over long namespaces', () {
    final commands = catalog([
      ('dev.adele.namespace', 'Alpha'),
      ('test.prefix', 'New Terminal'),
      ('test.word', 'Open New'),
      ('test.substring', 'Banana'),
    ]);
    expect(labels(commands, 'n'), [
      'New Terminal',
      'Open New',
      'Banana',
      'Alpha',
    ]);
  });

  test('empty queries and equal relevance retain the exact resolver order', () {
    final commands = catalog([
      ('test.z', 'alpha'),
      ('test.b', 'Alpha'),
      ('test.a', 'Zulu'),
    ]);
    for (final query in ['', ' ', '\t\n\u00a0']) {
      expect(searchCommands(commands, query), same(commands));
    }
    for (final query in ['alpha', 'al']) {
      final results = searchCommands(commands, query);
      expect(results.map((c) => c.id.value), ['test.b', 'test.z']);
      expect(results[0], same(commands[0]));
      expect(results[1], same(commands[1]));
    }
    expect(commands.map((c) => c.id.value), ['test.b', 'test.z', 'test.a']);
  });

  test('valid long labels and IDs do not expand fuzzy search work', () {
    // IDs have no public length cap; they use only non-fuzzy matching.
    final id = 'dev.${'namespace-' * 1000}operation';
    final label = '${'a' * 158} b';
    final commands = catalog([(id, label)]);
    for (final query in [label, 'ab', '${'a' * 100}b', id, 'operation']) {
      expect(searchCommands(commands, query).single, same(commands.single));
    }
    expect(searchCommands(commands, 'a' * 161), isEmpty);
    expect(searchCommands(commands, 'z' * 20000), isEmpty);
  });

  test(
    'non-ASCII labels retain case-insensitive matching and word boundaries',
    () {
      final commands = catalog([
        ('test.target', 'Ouvrir le projet \u00e9tendu'),
      ]);
      for (final query in ['OUVRIR', 'pro \u00c9T', 'op\u00e9']) {
        expect(searchCommands(commands, query).single, same(commands.single));
      }
    },
  );

  test('fuzzy search keeps supplementary characters atomic', () {
    final commands = catalog([
      ('test.absent', '\u{1f601} \u{10200}'),
      ('test.present', '\u{1f600} other \u{10200}'),
    ]);
    expect(labels(commands, '\u{1f600}'), ['\u{1f600} other \u{10200}']);
    expect(labels(commands, '\u{1f600}\u{10200}'), [
      '\u{1f600} other \u{10200}',
    ]);
    expect(labels(commands, '\u{10200}\u{1f600}'), isEmpty);
  });
}
