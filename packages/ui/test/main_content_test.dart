import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  MainContentPane pane({String id = 'editor.a', String title = 'Editor A'}) =>
      MainContentPane(
        id: id,
        title: title,
        createPresentation: () => const SizedBox.shrink(),
      );

  test('Main Content is additive rather than a single-provider resolver', () {
    final registry = ExtensionRegistry();
    for (final id in ['test.plugin.first', 'test.plugin.second']) {
      registry.register(
        point: mainContentContributions,
        id: ExtensionId(id),
        value: MainContentContribution(order: -10, attach: (_) {}),
      );
    }
    final bindings = registry.discover(mainContentContributions);
    expect(bindings, hasLength(2));
    expect(bindings.first.value.order, -10);
  });

  test('pane IDs are bounded local ASCII identifiers', () {
    for (final id in ['', 'two words', 'a\n', 'a/b', '\u00e9', 'x' * 129]) {
      expect(() => pane(id: id), throwsArgumentError);
    }
    expect(pane(id: 'Editor-1.local_2').id, 'Editor-1.local_2');
    expect(pane(id: 'x' * 128).id, hasLength(128));
  });

  test('titles reject blank, oversized, control and directional text', () {
    for (final title in ['', ' \t ', 'a\n', 'x' * 161, 'a\u001b', 'a\u202e']) {
      expect(() => pane(title: title), throwsArgumentError);
      expect(
        () => MainContentPaneInfo(id: 'a', title: title, canClose: false),
        throwsArgumentError,
      );
    }
    expect(pane(title: 'R\u00e9sum\u00e9.dart').title, 'R\u00e9sum\u00e9.dart');
    expect(pane(title: 'x' * 160).title, hasLength(160));
  });
}
