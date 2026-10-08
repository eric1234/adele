import 'package:adele_core_extensions/adele_core_extensions.dart';

/// Filters and ranks a resolver-ordered catalog without replacing its bindings.
/// Availability and composition remain the caller's and Command domain's policy.
List<ResolvedCommand> searchCommands(
  List<ResolvedCommand> commands,
  String query,
) {
  final search = _CommandSearch(query);
  if (search.query.isEmpty) return commands;
  final matches = <({ResolvedCommand command, int index, _Match match})>[];
  for (var index = 0; index < commands.length; index++) {
    final command = commands[index];
    final match = search.match(command.label, command.id.value);
    if (match != null) {
      matches.add((command: command, index: index, match: match));
    }
  }
  matches.sort((a, b) {
    final tier = b.match.tier.index.compareTo(a.match.tier.index);
    if (tier != 0) return tier;
    final quality = b.match.quality.compareTo(a.match.quality);
    return quality != 0 ? quality : a.index.compareTo(b.index);
  });
  return [for (final entry in matches) entry.command];
}

// Strong label matches beat namespace matches; an exact ID still ranks first.
enum _Tier {
  idSubstring,
  labelFuzzy,
  idWordPrefix,
  idPrefix,
  labelSubstring,
  labelWordPrefix,
  labelPrefix,
  exact,
}

typedef _Match = ({_Tier tier, int quality});

final class _CommandSearch {
  _CommandSearch(String input) : query = _normalize(input.trim());

  static final _whitespace = RegExp(r'\s+');
  static final _words = RegExp(r'[\p{L}\p{N}]+', unicode: true);
  static final _separators = RegExp(r'[\s\p{P}]+', unicode: true);

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(_whitespace, ' ');

  final String query;
  late final terms = query
      .split(_separators)
      .where((t) => t.isNotEmpty)
      .toList();
  late final fuzzyQuery = query.replaceAll(' ', '');
  late final fuzzyCharacters = fuzzyQuery.runes.toList();

  _Match? match(String label, String id) {
    label = _normalize(label);
    id = id.toLowerCase();
    if (label == query || id == query) {
      return (tier: _Tier.exact, quality: 0);
    }
    if (label.startsWith(query)) {
      return (tier: _Tier.labelPrefix, quality: 0);
    }
    final labelWords = _wordPrefixes(label);
    if (labelWords != null) {
      return (tier: _Tier.labelWordPrefix, quality: labelWords);
    }
    final labelIndex = label.indexOf(query);
    if (labelIndex >= 0) {
      return (tier: _Tier.labelSubstring, quality: -labelIndex);
    }
    if (id.startsWith(query)) {
      return (tier: _Tier.idPrefix, quality: 0);
    }
    final idWords = _wordPrefixes(id);
    if (idWords != null) {
      return (tier: _Tier.idWordPrefix, quality: idWords);
    }
    final fuzzy = _fuzzy(label);
    if (fuzzy != null) return (tier: _Tier.labelFuzzy, quality: fuzzy);
    final idIndex = id.indexOf(query);
    if (idIndex >= 0) return (tier: _Tier.idSubstring, quality: -idIndex);
    return null;
  }

  int? _wordPrefixes(String text) {
    if (terms.isEmpty || query.length > text.length) return null;
    var term = 0;
    var end = 0;
    var gaps = 0;
    for (final word in _words.allMatches(text)) {
      final prefix = terms[term];
      if (prefix.length > word.end - word.start ||
          !text.startsWith(prefix, word.start)) {
        continue;
      }
      gaps += word.start - end;
      end = word.start + prefix.length;
      if (++term == terms.length) return -gaps;
    }
    return null;
  }

  int? _fuzzy(String label) {
    if (fuzzyQuery.isEmpty || fuzzyQuery.length > label.length) return null;
    final characters = label.runes.toList();
    final starts = {for (final word in _words.allMatches(label)) word.start};
    final bonuses = <int>[];
    var offset = 0;
    for (final character in characters) {
      bonuses.add(starts.contains(offset) ? 8 : 0);
      offset += character > 0xffff ? 2 : 1;
    }
    var previous = List<int?>.filled(characters.length, null);
    // Best ordered alignment, with no backtracking: O(query * label) time and
    // O(label) space. Public labels are at most 160 UTF-16 units; IDs never use
    // this search. Align Unicode scalars, never separate surrogate halves.
    // Leading/gap penalties favor compact, early matches.
    for (var q = 0; q < fuzzyCharacters.length; q++) {
      final current = List<int?>.filled(characters.length, null);
      int? gapBest;
      for (var i = 0; i < characters.length; i++) {
        if (i >= 2 && previous[i - 2] != null) {
          final candidate = previous[i - 2]! + i - 2;
          if (gapBest == null || candidate > gapBest) gapBest = candidate;
        }
        if (characters[i] != fuzzyCharacters[q]) continue;
        final boundary = bonuses[i];
        if (q == 0) {
          current[i] = boundary - i;
          continue;
        }
        int? best = gapBest == null ? null : gapBest - i + 1;
        if (i > 0 && previous[i - 1] != null) {
          final consecutive = previous[i - 1]! + 12;
          if (best == null || consecutive > best) best = consecutive;
        }
        if (best != null) current[i] = best + boundary;
      }
      previous = current;
    }
    int? best;
    for (final score in previous) {
      if (score != null && (best == null || score > best)) best = score;
    }
    return best;
  }
}
