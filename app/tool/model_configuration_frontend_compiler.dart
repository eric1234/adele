import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/capability_access_bridge.dart';
import 'package:adele_desktop/frontend/presentation_dialog_bridge.dart';
import 'package:adele_desktop/frontend/settings_field_editor_bridge.dart';
import 'package:adele_model_provider/adele_model_catalog.dart' as catalog;

import 'session_accessory_frontend_compiler.dart';

const modelConfigurationFrontendLibrary =
    'package:model_configuration_frontend/model_configuration_frontend.dart';

Future<Uint8List> compileModelConfigurationFrontend({
  required Directory repositoryRoot,
}) => compileSessionAccessoryFrontend(
  repositoryRoot: repositoryRoot,
  plugin: 'model_configuration',
  additionalLibraries: [
    'model_reference_editor.dart',
    'model_browser.dart',
    'preset_form.dart',
  ],
  additionalUiSources: [
    'settings_field_editor_bridge.dart',
    'capability_bridge.dart',
    'presentation_dialog.dart',
  ],
  additionalDeclarations: const [
    SettingsFieldEditorDeclarations(),
    CapabilityAccessDeclarations(),
    PresentationDialogDeclarations(),
  ],
  generateAdditionalContracts: (generator) async {
    final client = await generator.generateEvalClient(
      File.fromUri(
        repositoryRoot.uri.resolve(
          'packages/model_provider/lib/adele_model_catalog.dart',
        ),
      ),
    );
    // Eval generation projects annotated transport, not ordinary constants.
    // Project the same bounds and inference vocabulary used by native validation.
    return {
      'adele_model_provider': {
        'adele_model_catalog.dart':
            '''
$client
const int modelCatalogMaxModels = ${catalog.modelCatalogMaxModels};
const int modelCatalogMaxModelIdLength = ${catalog.modelCatalogMaxModelIdLength};
const int modelCatalogMaxDisplayNameLength = ${catalog.modelCatalogMaxDisplayNameLength};
const int modelCatalogMaxDescriptionLength = ${catalog.modelCatalogMaxDescriptionLength};
const int modelCatalogMaxTextLength = ${catalog.modelCatalogMaxTextLength};
const List<String> modelCatalogReasoningEffortNames = ${jsonEncode(catalog.modelCatalogReasoningEffortNames)};
''',
      },
    };
  },
);
