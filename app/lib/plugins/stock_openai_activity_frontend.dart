import 'dart:io';

import 'package:adele_desktop/frontend/model_native_activity_bridge.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:openai_contract/openai_contract.dart'
    show openAiReasoningSummaryPresentationKind;

/// Activates only the prepared OpenAI presentation, independently of its backend.
Future<StockOpenAiActivityFrontendActivation>
activateStockOpenAiActivityFrontend({
  required ExtensionRegistry extensions,
  required String artifactPath,
}) async {
  if (artifactPath.isEmpty) {
    throw StateError(
      'No prepared OpenAI activity frontend artifact configured.',
    );
  }
  final PreparedFrontend generation = await PreparedFrontend.load(
    File(artifactPath),
  );
  if (generation.failure != null) {
    generation.invalidate();
    throw StateError('Could not load the prepared OpenAI activity frontend.');
  }
  final activation = StockOpenAiActivityFrontendActivation._(generation);
  try {
    activation._registration = extensions.register(
      point: modelNativeActivityPresentationContributions,
      id: ExtensionId('dev.adele.plugin.openai.activity-presentation'),
      value: ModelNativeActivityPresentationContribution(
        presentationKind: openAiReasoningSummaryPresentationKind,
        createInspection: (presentation) {
          if (!activation._active) {
            throw StateError('The OpenAI activity frontend is retired.');
          }
          return generation.createPresentation(
            library: 'package:openai_frontend/openai_frontend.dart',
            entrypoint: 'buildOpenAiReasoningInspection',
            key: ObjectKey(presentation),
            createBridge: () => ModelNativeActivityBridge(
              presentation: presentation,
              isActive: () => activation._active,
            ),
          );
        },
      ),
    );
    return activation;
  } on Object {
    generation.invalidate();
    rethrow;
  }
}

/// Owns one EVC generation and its exact presentation registration.
final class StockOpenAiActivityFrontendActivation {
  StockOpenAiActivityFrontendActivation._(this._generation);

  final PreparedFrontend _generation;
  late final ExtensionRegistration _registration;
  bool _closed = false;
  Future<void>? _closing;

  bool get _active => !_closed && !_registration.isClosed;

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    final Future<void> retiring = _registration.close();
    _generation.invalidate();
    return _closing = retiring;
  }
}
