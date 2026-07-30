/// Internal declaration surface replaced by ADELE's eval runtime bridge.
final class WorkspaceDemoViewData {
  const WorkspaceDemoViewData({
    required this.names,
    required this.uris,
    required this.cancelled,
  });

  final List<String> names;
  final List<String> uris;
  final bool cancelled;
}

final class WorkspaceDemoTextData {
  const WorkspaceDemoTextData(this.value, {this.cancelled = false});

  final String value;
  final bool cancelled;
}

Future<WorkspaceDemoViewData> loadWorkspaceDemoDirectory() {
  throw UnsupportedError('Available only inside the ADELE eval runtime.');
}

Future<WorkspaceDemoTextData> loadWorkspaceDemoText(String uri) {
  throw UnsupportedError('Available only inside the ADELE eval runtime.');
}
