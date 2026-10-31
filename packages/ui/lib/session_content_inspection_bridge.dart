/// Reads the captured context of this interpreted Session content Inspection.
/// The immutable map contains only string values: `sessionId`, `taskId`,
/// `strategyId`, `contentKind`, and `occurrenceId`. These are factual identities,
/// not a native Session, storage access, or execution/Environment authority.
/// Reads become unavailable when this exact presentation is retired.
///
/// Optional owning-backend retrieval is a separate, descriptor-allowlisted bridge.
/// Declared services must be retrieval-only: the service allowlist does not enforce
/// method semantics or provide a universal RPC sandbox.
Map<String, dynamic> readSessionContentInspectionContext() {
  throw UnsupportedError('Interpreted Session content Inspection bridge only.');
}
