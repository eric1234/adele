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
          'Optional path selects an Environment-relative directory; omitted or '
          'empty means root. Use read_file for a known file. '
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
          'path': <String, Object?>{'type': 'string'},
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
    if (proposedArguments.keys.any(
          (String key) => key != 'query' && key != 'path',
        ) ||
        proposedArguments['query'] is! String ||
        (proposedArguments.containsKey('path') &&
            proposedArguments['path'] is! String)) {
      throw const ToolArgumentValidationException(
        'search requires string query and accepts only optional string path.',
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
    return CanonicalToolArguments(<String, Object?>{
      'query': query,
      'path': _canonicalDirectoryPath(
        proposedArguments['path'] as String? ?? '',
      ),
    });
  }

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    _requireAuthorizedSession(context);
    final String path = arguments.snapshot['path']! as String;
    return EffectDescription(
      effects: const <ToolEffect>[ToolEffect.sourceRead],
      targets: <EffectTarget>[
        EffectTarget(
          uri: Uri(
            scheme: 'adele-environment',
            pathSegments: <String>[
              '',
              _fileSystem.environmentId.value,
              ...path.split('/'),
            ],
          ),
        ),
      ],
      summary: path.isEmpty
          ? 'Search the authorized Environment root.'
          : 'Search the authorized Environment directory ${jsonEncode(path)}.',
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
    final _SearchState state = _SearchState(
      query,
      arguments.snapshot['path']! as String,
    );
    try {
      _requireAuthorizedSession(context);
      _fileSystem.validateBinding();
      if (state.path.split('/').any(_excludedDirectories.contains)) {
        yield ToolExecutionTerminal(
          _failure(
            state,
            _fileSystem.environmentId.value,
            'Search scope ${jsonEncode(state.path)} is excluded by stock Search defaults.',
            ToolFailureKind.domain,
            'excluded_scope',
            certainty: EffectCertainty.knownNotOccurred,
          ),
        );
        return;
      }
      final EnvironmentDirectoryListing root = await _fileSystem.readDirectory(
        state.path,
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
      if (state.path.isNotEmpty) 'Scope: ${jsonEncode(state.path)}',
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
    'path': state.path,
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

String _canonicalDirectoryPath(String path) {
  // Reject before normalization or URI encoding can change the path identity.
  for (int index = 0; index < path.length; index++) {
    final int codeUnit = path.codeUnitAt(index);
    if (_isHighSurrogate(codeUnit)) {
      if (++index < path.length && _isLowSurrogate(path.codeUnitAt(index))) {
        continue;
      }
      throw const ToolArgumentValidationException(
        'path must contain well-formed Unicode text.',
      );
    }
    if (_isLowSurrogate(codeUnit)) {
      throw const ToolArgumentValidationException(
        'path must contain well-formed Unicode text.',
      );
    }
  }
  if (path.startsWith('/') || path.contains('\u0000')) {
    throw const ToolArgumentValidationException(
      'path must be a NUL-free Environment-relative directory path.',
    );
  }
  final List<String> segments = <String>[];
  for (final String segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      throw const ToolArgumentValidationException(
        'path must not contain parent traversal.',
      );
    }
    segments.add(segment);
  }
  return segments.join('/');
}

final class _SearchState {
  _SearchState(this.query, this.path);

  final String query;
  final String path;
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
    'path': state.path,
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
