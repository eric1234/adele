import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';

void main() {
  group('PluginId', () {
    test('compares equal values equally', () {
      final PluginId first = PluginId('dev.adele.workspace-demo');
      final PluginId second = PluginId('dev.adele.workspace-demo');

      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });

    test('distinguishes different values', () {
      final PluginId first = PluginId('dev.adele.workspace-demo');
      final PluginId second = PluginId('dev.adele.other');

      expect(first, isNot(second));
    });

    test('converts to its value', () {
      final PluginId id = PluginId('dev.adele.workspace-demo');

      expect(id.toString(), 'dev.adele.workspace-demo');
    });

    test('enforces the shared public identifier grammar', () {
      expect(PluginId('dev.adele.workspace-demo').value, isNotEmpty);
      for (final String value in <String>[
        '',
        'single',
        'dev..adele',
        'dev.adele_bad',
        'dev.adele.-bad',
        'dev.adele.bad-',
        'Dev.adele.bad',
        'dev.adèle.bad',
      ]) {
        expect(() => PluginId(value), throwsFormatException, reason: value);
      }
    });
  });
}
