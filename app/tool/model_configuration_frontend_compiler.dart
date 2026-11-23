import 'dart:io';
import 'dart:typed_data';

import 'package:adele_desktop/frontend/settings_field_editor_bridge.dart';

import 'session_accessory_frontend_compiler.dart';

const modelConfigurationFrontendLibrary =
    'package:model_configuration_frontend/model_configuration_frontend.dart';

Future<Uint8List> compileModelConfigurationFrontend({
  required Directory repositoryRoot,
}) => compileSessionAccessoryFrontend(
  repositoryRoot: repositoryRoot,
  plugin: 'model_configuration',
  additionalLibraries: ['model_reference_editor.dart'],
  additionalUiSources: ['settings_field_editor_bridge.dart'],
  additionalDeclarations: [const SettingsFieldEditorDeclarations()],
);
