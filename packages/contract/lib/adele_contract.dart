/// Experimental declarations and transport-neutral runtime types for typed
/// ADELE plugin contracts.
library;

final class AdeleService {
  const AdeleService(this.id);

  final String id;
}

final class AdeleValue {
  const AdeleValue(this.id);

  final String id;
}

final class AdeleMethod {
  const AdeleMethod(this.name);

  final String name;
}

final class AdeleField {
  const AdeleField(this.name);

  final String name;
}

final class AdeleFailure {
  const AdeleFailure(this.id);

  final String id;
}

abstract interface class AdeleRequestChannel {
  Future<Object?> request(String method, Map<String, Object?> payload);
}

abstract interface class AdeleRemoteFailure implements Exception {
  String? get declaredFailureType;
  String get code;
  String get message;
  Map<String, Object?> get details;
}

final class AdeleProtocolException implements FormatException {
  const AdeleProtocolException(this.message, [this.source, this.offset]);

  @override
  final String message;

  @override
  final Object? source;

  @override
  final int? offset;

  @override
  String toString() => 'AdeleProtocolException: $message';
}
