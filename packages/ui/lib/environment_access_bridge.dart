/// File access to the Environment captured by an admitted finite operation.
/// Views and operations without permission or context receive binding_unavailable.
/// Success: {ok: true, path, text, sizeBytes, revision}. Complete files only;
/// there is no preview/truncation. Failure: {ok: false, failure:
/// {code, message, details}}. Revisions are opaque provider values.
Future<Map<String, dynamic>> readEnvironmentTextFile(String path) =>
    throw UnsupportedError('Prepared only.');

/// Conditional replacement through the same captured Environment binding.
/// Success: {ok: true, revision}. Failure uses the same structured schema as read.
/// An unacknowledged operation is not proof that the file was unchanged; no
/// automatic retry or rollback is implied.
Future<Map<String, dynamic>> replaceEnvironmentTextFile(
  String path,
  String text,
  String expectedRevision,
) => throw UnsupportedError('Prepared only.');
