/// Internal declaration surface replaced by ADELE's eval runtime bridge.
final class WorkspaceDemoViewData {
  const WorkspaceDemoViewData({required this.names, required this.uris});

  final List<String> names;
  final List<String> uris;
}

final class WorkspaceDemoTextData {
  const WorkspaceDemoTextData(this.value);

  final String value;
}

Future<WorkspaceDemoViewData> loadWorkspaceDemoDirectory() {
  throw UnsupportedError('Available only inside the ADELE eval runtime.');
}

Future<WorkspaceDemoTextData> loadWorkspaceDemoText(String uri) {
  throw UnsupportedError('Available only inside the ADELE eval runtime.');
}
