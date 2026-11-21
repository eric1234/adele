import 'dart:io';
import 'dart:typed_data';

import 'session_accessory_frontend_compiler.dart';

const agentConfigurationFrontendLibrary =
    'package:agent_configuration_frontend/agent_configuration_frontend.dart';

Future<Uint8List> compileAgentConfigurationFrontend({
  required Directory repositoryRoot,
}) => compileSessionAccessoryFrontend(
  repositoryRoot: repositoryRoot,
  plugin: 'agent_configuration',
);
