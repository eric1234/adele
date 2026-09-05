/// Stock literal search tool for Session-authorized Environments.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

final PluginId searchToolsPluginId = PluginId('dev.adele.plugin.search-tools');

final class SearchToolsPlugin {
  const SearchToolsPlugin();

  ExtensionRegistration activate(ExtensionRegistry extensions) =>
      extensions.register(
        point: modelToolContributions,
        id: ExtensionId('dev.adele.plugin.search-tools.model-tools'),
        value: _SearchModelTools(),
      );
}

final class _SearchModelTools implements ModelToolContribution {
  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async {
    final AuthorizedEnvironmentFileReadFacet fileSystem = await context
        .requireHostService<AuthorizedEnvironmentFileReadFacet>();
    if (fileSystem.sessionId != context.sessionId) {
      throw StateError('The filesystem authority belongs to another Session.');
    }
    return <ToolRegistration>[_SearchExecutable(fileSystem).registration];
  }
}

final class _SearchExecutable implements ToolExecutable {
  const _SearchExecutable(this._fileSystem);

  static final ToolId _toolId = ToolId('dev.adele.plugin.search-tools.search');
  static const int _maxMatches = 100;
  static const int _maxEntries = 10000;
  static const int _maxSearchedBytes = 16 * 1024 * 1024;
  static const int _maxFailedFileReads = 32;
  static const int _maxSnippetCodeUnits = 500;
  static const Set<String> _excludedDirectories = <String>{
    '.git',
    '.dart_tool',
    'build',
    'node_modules',
  };

  final AuthorizedEnvironmentFileReadFacet _fileSystem;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: _toolId,
      description: 'Search text files in the current Session Environment.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'search',
      description:
          'Recursively search Environment text files for one literal query. '
          'Current stock search defaults exclude common generated, dependency, '
          'and metadata directories: .git, .dart_tool, build, and node_modules.',
      argumentsSchema: const <String, Object?>{
        'type': 'object',
        'required': <Object?>['query'],
        'properties': <String, Object?>{
          'query': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 256,
          },
        },
        'additionalProperties': false,
      },
    ),
    executable: this,
  );

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) {
    if (proposedArguments.length != 1 ||
        proposedArguments['query'] is! String) {
      throw const ToolArgumentValidationException(
        'search requires exactly one string argument named query.',
      );
    }
    final String query = proposedArguments['query']! as String;
    if (query.isEmpty ||
        query.length > 256 ||
        query.contains('\u0000') ||
        query.contains('\n') ||
        query.contains('\r') ||
        query.contains('\u2028') ||
        query.contains('\u2029')) {
      throw const ToolArgumentValidationException(
        'query must be non-empty, single-line, NUL-free, and at most 256 UTF-16 code units.',
      );
    }
    return CanonicalToolArguments(<String, Object?>{'query': query});
  }

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    _requireAuthorizedSession(context);
    return EffectDescription(
      effects: const <ToolEffect>[ToolEffect.sourceRead],
      targets: <EffectTarget>[
        EffectTarget(
          uri: Uri(
            scheme: 'adele-environment',
            path: '/${_fileSystem.environmentId.value}/',
          ),
        ),
      ],
      summary: 'Search the authorized Environment root.',
    );
  }

  @override
  void validateBinding() {
    try {
      _fileSystem.validateBinding();
    } on AuthorizedEnvironmentBindingStale catch (error) {
      throw StaleToolBindingException(
        error.message,
        cause: error.cause ?? error,
      );
    } on AuthorizedEnvironmentBindingUnavailable catch (error) {
      throw ToolBindingUnavailableException(
        error.message,
        cause: error.cause ?? error,
      );
    }
  }

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    final String query = arguments.snapshot['query']! as String;
    final _SearchState state = _SearchState(query);
    try {
      _requireAuthorizedSession(context);
      _fileSystem.validateBinding();
      final EnvironmentDirectoryListing root = await _fileSystem.readDirectory(
        '',
      );
      state.readOccurred = true;
      await _searchListing(root, state);
      yield ToolExecutionTerminal(_success(state));
    } on AuthorizedEnvironmentBindingStale catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          state,
          _fileSystem.environmentId.value,
          'The authorized Environment binding is stale.',
          ToolFailureKind.staleBinding,
          error,
          certainty: state.readOccurred
              ? EffectCertainty.knownOccurred
              : EffectCertainty.knownNotOccurred,
        ),
      );
    } on AuthorizedEnvironmentBindingUnavailable catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          state,
          _fileSystem.environmentId.value,
          'The authorized Environment provider is unavailable.',
          ToolFailureKind.infrastructure,
          error,
          certainty: state.readOccurred
              ? EffectCertainty.knownOccurred
              : EffectCertainty.knownNotOccurred,
        ),
      );
    } on EnvironmentFailure catch (error) {
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.domain,
          effectCertainty: EffectCertainty.uncertain,
          modelContent: 'Environment search failed: ${error.message}',
          hostData: <String, Object?>{
            ..._hostData(state),
            'code': error.code,
            'details': error.details,
          },
          hostDiagnostic: error.message,
          cause: error,
        ),
      );
    } on _SessionAuthorityViolation catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          state,
          _fileSystem.environmentId.value,
          'The Search tool is not authorized for this Session.',
          ToolFailureKind.infrastructure,
          error,
          certainty: EffectCertainty.knownNotOccurred,
        ),
      );
    } on Object catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          state,
          _fileSystem.environmentId.value,
          'Environment search failed.',
          ToolFailureKind.infrastructure,
          error,
        ),
      );
    }
  }

  Future<void> _searchListing(
    EnvironmentDirectoryListing listing,
    _SearchState state,
  ) async {
    final List<EnvironmentDirectoryEntry> entries = listing.entries.toList()
      ..sort(
        (EnvironmentDirectoryEntry left, EnvironmentDirectoryEntry right) =>
            left.relativePath.compareTo(right.relativePath),
      );
    for (final EnvironmentDirectoryEntry entry in entries) {
      if (state.stopped) return;
      if (state.entries == _maxEntries) {
        state.truncated = true;
        return;
      }
      state.entries++;
      switch (entry.kind) {
        case EnvironmentDirectoryEntryKind.file:
          await _searchFile(entry.relativePath, state);
        case EnvironmentDirectoryEntryKind.directory:
          if (_excludedDirectories.contains(entry.name)) continue;
          try {
            final EnvironmentDirectoryListing nested = await _fileSystem
                .readDirectory(entry.relativePath);
            state.readOccurred = true;
            await _searchListing(nested, state);
          } on EnvironmentFailure {
            state.incomplete = true;
            continue;
          }
        case EnvironmentDirectoryEntryKind.other:
          continue;
      }
    }
  }

  Future<void> _searchFile(String relativePath, _SearchState state) async {
    if (state.failedFileReads >= _maxFailedFileReads) {
      state.truncated = true;
      return;
    }
    EnvironmentTextFile file;
    try {
      file = await _fileSystem.readFile(relativePath);
      state.readOccurred = true;
    } on EnvironmentFailure {
      state.failedFileReads++;
      state.incomplete = true;
      return;
    }
    if (file.sizeBytes > _maxSearchedBytes - state.searchedBytes) {
      state.truncated = true;
      return;
    }
    state.searchedBytes += file.sizeBytes;
    int lineNumber = 0;
    for (final String line in const LineSplitter().convert(file.text)) {
      lineNumber++;
      if (!line.contains(state.query)) continue;
      if (state.matches.length == _maxMatches) {
        state.truncated = true;
        return;
      }
      state.matches.add(
        _SearchMatch(
          relativePath: file.relativePath,
          lineNumber: lineNumber,
          snippet: _boundedSnippet(
            line,
            matchStart: line.indexOf(state.query),
            matchLength: state.query.length,
          ),
        ),
      );
    }
  }

  ToolOutcome _success(_SearchState state) {
    final String modelContent = <String>[
      'Search results:',
      if (state.matches.isEmpty)
        'No matches.'
      else ...<String>[
        for (final _SearchMatch match in state.matches)
          _encodeModelMatch(match),
      ],
      if (state.matches.isEmpty)
        'Scope note: current stock search defaults exclude common generated, dependency, and metadata directories.',
      if (state.truncated)
        'Search truncated: a configured search limit was reached.',
      if (state.incomplete)
        'Search incomplete: one or more files or directories could not be inspected.',
    ].join('\n');
    return ToolOutcome(
      disposition: ToolOutcomeDisposition.success,
      effectCertainty: EffectCertainty.knownOccurred,
      modelContent: modelContent,
      hostData: _hostData(state),
    );
  }

  Map<String, Object?> _hostData(_SearchState state) => <String, Object?>{
    'query': state.query,
    'matches': <Object?>[
      for (final _SearchMatch match in state.matches)
        <String, Object?>{
          'relativePath': match.relativePath,
          'lineNumber': match.lineNumber,
          'snippet': match.snippet,
        },
    ],
    'truncated': state.truncated,
    'incomplete': state.incomplete,
    'environmentId': _fileSystem.environmentId.value,
  };

  void _requireAuthorizedSession(ToolExecutionContext context) {
    if (context.sessionId != _fileSystem.sessionId) {
      throw _SessionAuthorityViolation(context.sessionId.toString());
    }
  }
}

final class _SearchState {
  _SearchState(this.query);

  final String query;
  final List<_SearchMatch> matches = <_SearchMatch>[];
  int entries = 0;
  int searchedBytes = 0;
  int failedFileReads = 0;
  bool truncated = false;
  bool incomplete = false;
  bool readOccurred = false;

  bool get stopped => truncated;
}

final class _SearchMatch {
  const _SearchMatch({
    required this.relativePath,
    required this.lineNumber,
    required this.snippet,
  });

  final String relativePath;
  final int lineNumber;
  final String snippet;
}

String _encodeModelMatch(_SearchMatch match) => jsonEncode(<String, Object?>{
  'relativePath': match.relativePath,
  'lineNumber': match.lineNumber,
  'snippet': match.snippet,
}).replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029');

final class _SessionAuthorityViolation implements Exception {
  const _SessionAuthorityViolation(this.message);

  final String message;
}

String _boundedSnippet(
  String line, {
  required int matchStart,
  required int matchLength,
}) {
  if (line.length <= _SearchExecutable._maxSnippetCodeUnits) return line;
  final int context =
      (_SearchExecutable._maxSnippetCodeUnits - matchLength) ~/ 2;
  int start = math.max(0, matchStart - context);
  int end = math.min(
    line.length,
    start + _SearchExecutable._maxSnippetCodeUnits,
  );
  start = math.max(0, end - _SearchExecutable._maxSnippetCodeUnits);
  if (start > 0 && _isLowSurrogate(line.codeUnitAt(start))) start++;
  if (end < line.length && _isHighSurrogate(line.codeUnitAt(end - 1))) end--;
  return line.substring(start, end);
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xdc00 && codeUnit <= 0xdfff;

ToolOutcome _failure(
  _SearchState state,
  String environmentId,
  String modelContent,
  ToolFailureKind kind,
  Object cause, {
  EffectCertainty certainty = EffectCertainty.uncertain,
}) => ToolOutcome(
  disposition: ToolOutcomeDisposition.failure,
  failureKind: kind,
  effectCertainty: certainty,
  modelContent: modelContent,
  hostData: <String, Object?>{
    'query': state.query,
    'matches': <Object?>[
      for (final _SearchMatch match in state.matches)
        <String, Object?>{
          'relativePath': match.relativePath,
          'lineNumber': match.lineNumber,
          'snippet': match.snippet,
        },
    ],
    'truncated': state.truncated,
    'incomplete': state.incomplete,
    'environmentId': environmentId,
  },
  hostDiagnostic: cause.toString(),
  cause: cause,
);
