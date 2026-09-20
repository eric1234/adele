import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';

final PluginId chatStrategyPluginId = PluginId(
  'dev.adele.plugin.chat-strategy',
);
final OrchestrationStrategyId chatStrategyId = OrchestrationStrategyId(
  'dev.adele.strategy.chat',
);
final ExtensionId chatStrategyExtensionId = ExtensionId(
  'dev.adele.plugin.chat-strategy.orchestration',
);
const String chatStrategyRouteId = 'chat';

/// Opaque occurrence identity, stable across snapshots within one Session.
/// The generated DTO transports [value] as a String for interpreted clients.
final class ChatEntryId {
  ChatEntryId(this.value) {
    if (value.trim().isEmpty) {
      throw const FormatException('Chat entry identity must not be empty.');
    }
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is ChatEntryId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
