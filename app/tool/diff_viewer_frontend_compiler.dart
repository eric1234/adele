import 'dart:io';

import 'package:adele_desktop/frontend/environment_capability_access_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/frontend/owning_backend_bridge.dart';
import 'package:adele_desktop/frontend/scroll_view_bridge.dart';
import 'package:adele_desktop/frontend/session_presentation_lifecycle_bridge.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:diff_viewer_contract/review_draft.dart' as draft_contract;
import 'package:flutter_eval/flutter_eval.dart';

const diffViewerFrontendLibrary = 'package:diff_viewer_frontend/main.dart';

String diffViewerDartSdk() {
  // Resolve from flutter_tester's matched toolchain, never an inherited SDK path.
  var directory = File(Platform.resolvedExecutable).parent;
  while (directory.parent.path != directory.path) {
    final candidate = Directory('${directory.path}/dart-sdk');
    if (File('${candidate.path}/lib/core/core.dart').existsSync()) {
      return candidate.path;
    }
    directory = directory.parent;
  }
  throw StateError('Cannot locate the running Flutter toolchain Dart SDK.');
}

Future<void> compileDiffViewerFrontend({
  required Directory repositoryRoot,
  required String sdkPath,
  required File artifact,
}) async {
  final root = repositoryRoot.path;
  final generated = await ContractGenerator(sdkPath: sdkPath).generateEvalClient(
    File(
      '$root/plugins/diff_viewer/packages/contract/lib/diff_viewer_contract.dart',
    ),
  );
  final draft = await ContractGenerator(sdkPath: sdkPath).generateEvalClient(
    File('$root/plugins/diff_viewer/packages/contract/lib/review_draft.dart'),
  );
  final compiler = Compiler()
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(const ScrollViewBridge())
    ..addPlugin(const MainContentDeclarations())
    ..addPlugin(const OwningBackendDeclarations())
    ..addPlugin(const EnvironmentCapabilityAccessDeclarations())
    ..addPlugin(const SessionPresentationLifecycleDeclarations())
    ..entrypoints.addAll([
      diffViewerFrontendLibrary,
      'package:diff_viewer_contract/diff_viewer_contract.dart',
      'package:diff_viewer_contract/review_draft.dart',
      'package:adele_contract/adele_contract.dart',
    ]);
  final program = compiler.compile({
    'diff_viewer_frontend': {
      'main.dart': await File(
        '$root/plugins/diff_viewer/packages/frontend/lib/main.dart',
      ).readAsString(),
    },
    'diff_viewer_contract': {
      'diff_viewer_contract.dart': "export 'review_draft.dart';\n$generated",
      // The generator projects annotated DTOs, enums and transport, not ordinary
      // constants. Project the authoritative UI bounds, never another DTO codec.
      'review_draft.dart':
          '''
$draft
class ReviewDraftLimits {
  static const maxComments = ${draft_contract.ReviewDraftLimits.maxComments};
  static const maxTextLength = ${draft_contract.ReviewDraftLimits.maxTextLength};
  static const maxExcerptLength = ${draft_contract.ReviewDraftLimits.maxExcerptLength};
  static const maxPathLength = ${draft_contract.ReviewDraftLimits.maxPathLength};
  static const maxIdentityLength = ${draft_contract.ReviewDraftLimits.maxIdentityLength};
  static const maxComparisonIdentityLength = ${draft_contract.ReviewDraftLimits.maxComparisonIdentityLength};
  static const maxLine = ${draft_contract.ReviewDraftLimits.maxLine};
  static const maxHunkIndex = ${draft_contract.ReviewDraftLimits.maxHunkIndex};
  static const maxLineIndex = ${draft_contract.ReviewDraftLimits.maxLineIndex};
}
''',
    },
    'adele_contract': {'adele_contract.dart': evalContractSupportSource},
    'adele_ui': {
      for (final name in [
        'environment_capability_bridge.dart',
        'main_content_bridge.dart',
        'owning_backend_bridge.dart',
        'session_presentation_lifecycle_bridge.dart',
      ])
        name: await File('$root/packages/ui/lib/$name').readAsString(),
    },
  });
  await artifact.writeAsBytes(program.write());
}
