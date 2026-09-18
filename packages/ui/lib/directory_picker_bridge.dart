/// Requests one native directory selection for this interpreted selector
/// operation. A selected platform path is returned unchanged; null means user
/// cancellation. Picker failures are errors, not cancellation.
///
/// This bridge is not available to presentation runtimes or native plugin code.
Future<String?> pickDirectory() {
  throw UnsupportedError('Interpreted frontend bridge only.');
}
