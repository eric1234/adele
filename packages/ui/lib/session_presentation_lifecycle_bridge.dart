/// Registers the sole asynchronous deactivation hook for this prepared Session
/// presentation. Return true only after pending local state is acknowledged;
/// false keeps the presentation open for correction or retry. The host awaits
/// this hook before disposing the view, and prevents input while it settles.
/// A presentation without a hook has nothing to flush.
///
/// Keep this callback object and unregister it on disposal. Registration grants
/// no navigation authority and cannot outlive this exact presentation binding.
void registerSessionPrepareToDeactivate(Future<bool> Function() callback) =>
    throw UnsupportedError('Interpreted host only.');

/// Removes only the matching callback, never another presentation's hook.
void unregisterSessionPrepareToDeactivate(Future<bool> Function() callback) =>
    throw UnsupportedError('Interpreted host only.');
