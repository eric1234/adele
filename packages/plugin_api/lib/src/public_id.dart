/// Validates ADELE's stable public identity grammar.
///
/// IDs contain at least two dot-separated lowercase ASCII segments. Segments
/// start with a letter and may contain digits or internal hyphens.
void validateAdelePublicId(String value, {required String label}) {
  if (!RegExp(
    r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*(\.[a-z][a-z0-9]*(?:-[a-z0-9]+)*)+$',
  ).hasMatch(value)) {
    throw FormatException(
      '$label must be a lowercase reverse-domain ASCII identifier: $value',
      value,
    );
  }
}
