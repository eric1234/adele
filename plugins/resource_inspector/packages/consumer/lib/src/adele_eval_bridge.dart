final class CapabilityDemoData {
  const CapabilityDemoData({required this.lines});

  final List<String> lines;
}

Future<CapabilityDemoData> loadCapabilityDemo() {
  throw UnsupportedError('Available only inside the ADELE eval runtime.');
}
