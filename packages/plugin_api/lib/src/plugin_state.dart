/// A provisional summary of plugin lifecycle state.
///
/// This is not the final lifecycle model and does not represent profile
/// activation, configuration, or a runtime instance.
enum PluginState {
  discovered,
  installed,
  building,
  ready,
  running,
  failed,
  disabled,
}
