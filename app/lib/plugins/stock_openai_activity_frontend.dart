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
    activation._registrations.add(activation._registration);
    activation._compactRegistration = extensions.register(
      point: modelNativeActivityCompactPresentationContributions,
      id: ExtensionId('dev.adele.plugin.openai.activity-compact'),
      value: ModelNativeActivityCompactPresentationContribution(
        presentationKind: openAiReasoningSummaryPresentationKind,
        createPresentation: (presentation) {
          if (!activation._compactActive) {
            throw StateError('The OpenAI compact frontend is retired.');
          }
          return generation.createPresentation(
            library: 'package:openai_frontend/openai_frontend.dart',
            entrypoint: 'buildOpenAiReasoningCompact',
            key: ObjectKey(presentation),
            createBridge: () => ModelNativeActivityBridge(
              presentation: presentation,
              isActive: () => activation._compactActive,
            ),
          );
        },
      ),
    );
    activation._registrations.add(activation._compactRegistration);
    return activation;
  } on Object {
    activation._closed = true;
    generation.invalidate();
    await activation._registrations.close();
    rethrow;
  }
}

/// Owns one EVC generation and its independent exact presentation registrations.
final class StockOpenAiActivityFrontendActivation {
  StockOpenAiActivityFrontendActivation._(this._generation);

  final PreparedFrontend _generation;
  late final ExtensionRegistration _registration;
  late final ExtensionRegistration _compactRegistration;
  final ExtensionRegistrationGroup _registrations =
      ExtensionRegistrationGroup();
  bool _closed = false;
  Future<void>? _closing;

  bool get _active => !_closed && !_registration.isClosed;
  bool get _compactActive => !_closed && !_compactRegistration.isClosed;

  /// Retires one role; the exact-binding host disposes only that role's views.
  Future<void> retireCompact() => _compactRegistration.close();
  Future<void> retireInspection() => _registration.close();

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    final Future<void> retiring = _registrations.close();
    _generation.invalidate();
    return _closing = retiring;
  }
}
