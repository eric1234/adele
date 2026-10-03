import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/editor/native_code_editor.dart';
import 'package:adele_desktop/frontend/code_editor_bridge.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const mainContentFixturePluginId = 'dev.adele.fixture.main-content';
const mainContentFixtureLibrary = 'package:main_content_fixture/main.dart';
final mainContentFixtureDescriptor = PreparedMainContentPresentation(
  extensionId: ExtensionId('$mainContentFixturePluginId.editors'),
  order: 300,
  library: mainContentFixtureLibrary,
  initialize: 'initialize',
  entrypoint: 'buildPane',
);
const mainContentFixtureTextA = 'const editorA = "synthetic-a";\n';
const mainContentFixtureTextB = 'const editorB = "synthetic-b";\n';

/// Adds only a development installation, never an entry in stock inventory.
Future<void> installMainContentFixture({
  required Directory installationRoot,
  required File artifact,
}) async {
  final installed = await Directory(
    '${installationRoot.path}/$mainContentFixturePluginId',
  ).create();
  await artifact.copy('${installed.path}/frontend.evc');
  final descriptor = mainContentFixtureDescriptor;
  await File('${installed.path}/adele_plugin.installation.json').writeAsString(
    jsonEncode({
      'manifestVersion': 1,
      'metadata': {
        'id': mainContentFixturePluginId,
        'version': '1.0.0',
        'displayName': 'Synthetic Main Content editors',
      },
      'components': {
        'frontend': {
          'artifact': 'frontend.evc',
          'presentations': [
            {
              'role': 'mainContent',
              'extensionId': descriptor.extensionId.value,
              'order': descriptor.order,
              'library': descriptor.library,
              'initialize': descriptor.initialize,
              'entrypoint': descriptor.entrypoint,
            },
          ],
        },
      },
    }),
  );
}

/// Native resource policy shared by tests and the manual development route.
/// Collection operations belong exclusively to the interpreted frontend.
final class MainContentFixtureResources {
  final Map<(SessionId, String), NativeCodeEditor> _editors = {};
  bool _disposed = false;

  late final PreparedMainContentHost host = PreparedMainContentHost(
    createBinding:
        ({
          required installation,
          required descriptor,
          required session,
          required paneId,
        }) {
          if (installation.metadata.id.value != mainContentFixturePluginId ||
              descriptor.extensionId !=
                  mainContentFixtureDescriptor.extensionId) {
            return null;
          }
          if (_disposed) throw StateError('Fixture resources are closed.');
          final text = switch (paneId) {
            'editor-a' => mainContentFixtureTextA,
            'editor-b' => mainContentFixtureTextB,
            _ => throw ArgumentError.value(paneId, 'paneId'),
          };
          final key = (session.id, paneId);
          if (_editors.containsKey(key)) {
            throw StateError('An editor is already bound to this pane.');
          }
          final editor = NativeCodeEditor(text: text);
          _editors[key] = editor;
          return PreparedMainContentPaneBinding(
            ready: editor.initialize(),
            createBridge: (isActive) =>
                CodeEditorBridge(editor: editor, isActive: isActive),
            requestFocus: () => editor.requestFocus(),
            release: () {
              if (identical(_editors[key], editor)) _editors.remove(key);
              editor.dispose();
            },
          );
        },
  );

  NativeCodeEditor? editor(SessionId session, String paneId) =>
      _editors[(session, paneId)];

  List<NativeCodeEditor> get editors => List.unmodifiable(_editors.values);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final editor in _editors.values) {
      editor.dispose();
    }
    _editors.clear();
  }
}
