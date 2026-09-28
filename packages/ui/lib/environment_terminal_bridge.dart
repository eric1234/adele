/// Creates terminal content in the Environment captured by the admitted console
/// action. No Environment/resource lookup or process authority is returned.
///
/// The native adapter validates and retains these contribution-owned policies,
/// independently of the operation runtime and subsequent content presentations.
/// The result is [true, null] or [false, safeErrorString], never a rejected native
/// Future or a diagnostic exception. Default-shell selection belongs to the
/// Environment provider, not this frontend.
Future<List<dynamic>> openEnvironmentTerminal(
  String label,
  String liveCloseMessage,
  bool followTitle,
  bool removeAfterExit,
) => throw UnsupportedError(
  'Environment terminal creation is available only to interpreted console actions.',
);
