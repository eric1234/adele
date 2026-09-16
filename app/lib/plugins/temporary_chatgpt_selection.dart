import 'dart:io' show Platform;

import 'package:adele_capabilities/adele_capabilities.dart';

// Temporary product selection until provider/model selection has a UI. Backend
// availability and configuration belong to the installed plugin, not this state.
const String stockChatGptDefaultModel = 'gpt-6-astra';
const String stockChatGptProviderIdValue =
    'dev.adele.openai.chatgpt-experimental';
final ProviderId stockChatGptProviderId = ProviderId(
  stockChatGptProviderIdValue,
);

final class StockChatGptConfiguration {
  const StockChatGptConfiguration({this.model = stockChatGptDefaultModel});

  final String model;

  static StockChatGptConfiguration fromEnvironment([
    Map<String, String>? environment,
  ]) {
    final Map<String, String> source = environment ?? Platform.environment;
    final String? model = source['ADELE_OPENAI_CHATGPT_MODEL'];
    return StockChatGptConfiguration(
      model: model == null || model.trim().isEmpty
          ? stockChatGptDefaultModel
          : model,
    );
  }
}
