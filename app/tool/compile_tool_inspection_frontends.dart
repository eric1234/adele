import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'tool_inspection_frontend_compiler.dart';

void main() {
  test('compile the prepared stock tool Inspection frontend', () async {
    final String? root = Platform.environment['ADELE_REPOSITORY_ROOT'];
    final String? output =
        Platform.environment['ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT'];
    final String? kind = Platform.environment['ADELE_TOOL_INSPECTION_FRONTEND'];
    if (root == null ||
        root.isEmpty ||
        output == null ||
        output.isEmpty ||
        (kind != 'filesystem' && kind != 'command')) {
      throw StateError(
        'ADELE_REPOSITORY_ROOT, ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT and '
        'ADELE_TOOL_INSPECTION_FRONTEND (filesystem or command) are required.',
      );
    }
    await compileToolInspectionFrontend(
      repositoryRoot: Directory(root),
      artifact: File(output),
      frontend: kind == 'filesystem'
          ? ToolInspectionFrontend.filesystem
          : ToolInspectionFrontend.command,
    );
  });
}
