import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';

void main() {
  group('PluginId', () {
    test('compares equal values equally', () {
      const PluginId first = PluginId('dev.adele.workspace-demo');
      const PluginId second = PluginId('dev.adele.workspace-demo');

      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });

    test('distinguishes different values', () {
      const PluginId first = PluginId('dev.adele.workspace-demo');
      const PluginId second = PluginId('dev.adele.other');

      expect(first, isNot(second));
    });

    test('converts to its value', () {
      const PluginId id = PluginId('dev.adele.workspace-demo');

      expect(id.toString(), 'dev.adele.workspace-demo');
    });
  });
}
