import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';

void main() {
  test('PluginMetadata preserves supplied metadata', () {
    const PluginMetadata metadata = PluginMetadata(
      id: PluginId('dev.adele.workspace-demo'),
      version: '0.1.0',
      displayName: 'Workspace Demo',
      description: 'Phase 1 walking skeleton.',
    );

    expect(metadata.id, const PluginId('dev.adele.workspace-demo'));
    expect(metadata.version, '0.1.0');
    expect(metadata.displayName, 'Workspace Demo');
    expect(metadata.description, 'Phase 1 walking skeleton.');
  });
}
