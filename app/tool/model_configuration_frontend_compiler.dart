import 'dart:io';
import 'dart:typed_data';

import 'session_accessory_frontend_compiler.dart';

const modelConfigurationFrontendLibrary =
    'package:model_configuration_frontend/model_configuration_frontend.dart';

Future<Uint8List> compileModelConfigurationFrontend({
  required Directory repositoryRoot,
}) => compileSessionAccessoryFrontend(
  repositoryRoot: repositoryRoot,
  plugin: 'model_configuration',
);
