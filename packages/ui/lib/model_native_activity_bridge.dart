/// Reads this interpreted view's static, presentation-only projection data.
/// Maps and nested maps/lists are recursively immutable primitive values. Native
/// envelopes, provider metadata and execution/approval authority are not exposed.
Map<String, dynamic> readModelNativeActivityData() {
  throw UnsupportedError('Interpreted Model native activity bridge only.');
}
