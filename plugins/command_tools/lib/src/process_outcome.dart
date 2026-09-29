/// Internal validation shared by capture writes and persisted-header reads.
/// A null result rejects the whole optional pair rather than inventing facts.
({String? termination, int? exitCode})? parseCommandProcessOutcome(
  Object? termination,
  Object? exitCode,
) => switch ((termination, exitCode)) {
  (null, null) => (termination: null, exitCode: null),
  ('exited', final int code) => (termination: 'exited', exitCode: code),
  ('timedOut', null) => (termination: 'timedOut', exitCode: null),
  _ => null,
};
