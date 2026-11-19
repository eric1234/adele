/// Reads the Session ID captured for this interpreted accessory, not the
/// window's current selection. No native Session or execution authority is
/// exposed. During accepted exit only this frozen display value is retained.
String readSessionAccessorySessionId() {
  throw UnsupportedError('Interpreted Session accessory bridge only.');
}
