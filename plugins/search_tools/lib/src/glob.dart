part of '../search_tools_plugin.dart';

final ToolId globToolId = ToolId('dev.adele.plugin.search-tools.glob');

/// Path discovery using only the captured Environment directory-read authority.
final class GlobExecutable implements ToolExecutable {
  const GlobExecutable(AuthorizedEnvironmentFileReadFacet fileSystem)
    : _boundFileSystem = fileSystem;
  const GlobExecutable.unbound() : _boundFileSystem = null;

  final AuthorizedEnvironmentFileReadFacet? _boundFileSystem;
  AuthorizedEnvironmentFileReadFacet get _fileSystem =>
      _boundFileSystem ?? (throw StateError('Glob requires authorized reads.'));

  static Glob _glob(String pattern, {String current = '/'}) => Glob(
    pattern,
    context: p.Context(style: p.Style.posix, current: current),
    caseSensitive: true,
  );

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: globToolId,
      description: 'Discover Environment paths.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'glob',
      description:
          'Discover files, directories, and other entries using package:glob pathname syntax. '
          'Required pattern is Environment-relative, case-sensitive, with POSIX / separators. '
          '* lists root entries; xyz/* lists immediate children; ** recurses. '
          'Stock exclusions: .git, .dart_tool, build, node_modules (directory names, case-insensitive). '
          'At most 100 matches and 10000 visited entries. Check truncation and incompleteness; '
          'results do not include file contents.',
      argumentsSchema: const {
        'type': 'object',
        'required': ['pattern'],
        'properties': {
          'pattern': {'type': 'string', 'minLength': 1, 'maxLength': 512},
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
        proposedArguments['pattern'] is! String) {
      throw const ToolArgumentValidationException(
        'glob requires only string pattern.',
      );
    }
    final pattern = proposedArguments['pattern']! as String;
    if (pattern.isEmpty || pattern.length > 512) {
      throw const ToolArgumentValidationException(
        'pattern must contain 1 to 512 UTF-16 code units.',
      );
    }
    // Validate path safety/Unicode without rewriting syntax inside glob groups.
    _canonicalScopePath(pattern);
    if (RegExp(r'^[A-Za-z]:[/\\]').hasMatch(pattern) ||
        pattern.startsWith(r'\\')) {
      throw const ToolArgumentValidationException(
        'pattern must be Environment-relative.',
      );
    }
    try {
      // Initialize lazy matching, including relative-path checks that an
      // absolute match can short-circuit in the pinned matcher.
      _glob(pattern).matches('');
      _glob(pattern, current: '.').matches('');
    } on FormatException catch (error) {
      throw ToolArgumentValidationException('Invalid glob: ${error.message}');
    } on StateError catch (error) {
      throw ToolArgumentValidationException(
        'Glob matcher cannot evaluate pattern: ${error.message}',
      );
    }
    return CanonicalToolArguments({'pattern': pattern});
  }

  @override
  void validateBinding() => SearchExecutable(_fileSystem).validateBinding();

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    _requireSession(context);
    return EffectDescription(
      effects: const [ToolEffect.sourceRead],
      targets: [
        EffectTarget(
          uri: Uri(
            scheme: 'adele-environment',
            pathSegments: ['', _fileSystem.environmentId.value],
          ),
        ),
      ],
      summary:
          'Discover authorized Environment paths matching ${jsonEncode(arguments.snapshot['pattern'])}.',
    );
  }

  void _requireSession(ToolExecutionContext context) {
    if (context.sessionId != _fileSystem.sessionId) {
      throw const _SessionAuthorityViolation(
        'Glob authority belongs to another Session.',
      );
    }
  }

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    final pattern = arguments.snapshot['pattern']! as String;
    final state = _GlobState(pattern);
    try {
      _requireSession(context);
      _fileSystem.validateBinding();
      final plan = _GlobTraversal(pattern);
      if (!plan.root.split('/').any(SearchExecutable._isExcludedDirectory)) {
        final listing = await _fileSystem.readDirectory('');
        await _walk(listing, state, plan);
      }
      state.matches.sort((a, b) => a.relativePath.compareTo(b.relativePath));
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.success,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent: [
            'Glob results (stock directory exclusions: .git, .dart_tool, build, node_modules):',
            if (state.matches.isEmpty) 'No matches.',
            for (final match in state.matches)
              jsonEncode({
                'relativePath': match.relativePath,
                'kind': match.kind.name,
              }),
            if (state.stopReason != null)
              'Glob truncated: ${state.stopReason} limit (${state.stopLimit}); retained ${state.matches.length}, visited ${state.entriesVisited}.',
            if (state.failedDirectoryReads > 0)
              'Glob incomplete: some paths could not be inspected (${state.failedDirectoryReads} failed directory reads).',
          ].join('\n'),
          hostData: _data(state),
        ),
      );
    } on Object catch (error) {
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: error is AuthorizedEnvironmentBindingStale
              ? ToolFailureKind.staleBinding
              : error is EnvironmentFailure
              ? ToolFailureKind.domain
              : ToolFailureKind.infrastructure,
          effectCertainty: EffectCertainty.uncertain,
          modelContent:
              'Environment glob failed: ${error is EnvironmentFailure
                  ? error.message
                  : error is AuthorizedEnvironmentBindingStale
                  ? 'stale binding'
                  : error is AuthorizedEnvironmentBindingUnavailable
                  ? 'unavailable binding'
                  : 'discovery unavailable'}.',
          hostData: {
            ..._data(state),
            if (error is EnvironmentFailure) 'code': error.code,
          },
          hostDiagnostic: error.toString(),
          cause: error,
        ),
      );
    }
  }

  Map<String, Object?> _data(_GlobState state) => {
    'pattern': state.pattern,
    'matches': [
      for (final match in state.matches)
        {'relativePath': match.relativePath, 'kind': match.kind.name},
    ],
    'truncated': state.stopReason != null,
    'incomplete': state.failedDirectoryReads > 0,
    'entriesVisited': state.entriesVisited,
    'retainedMatchCount': state.matches.length,
    'failedDirectoryReads': state.failedDirectoryReads,
    'stopReason': state.stopReason,
    'stopLimit': state.stopLimit,
    'environmentId': _fileSystem.environmentId.value,
  };

  Future<void> _walk(
    EnvironmentDirectoryListing listing,
    _GlobState state,
    _GlobTraversal plan,
  ) async {
    final entries = listing.entries.toList()
      ..sort((a, b) => a.relativePath.compareTo(b.relativePath));
    for (final entry in entries) {
      if (state.stopReason != null) return;
      if (state.entriesVisited == 10000) {
        state.stop('max_entries', 10000);
        return;
      }
      state.entriesVisited++;
      if (entry.kind == EnvironmentDirectoryEntryKind.directory &&
          SearchExecutable._isExcludedDirectory(entry.name)) {
        continue;
      }
      if (state.glob.matches(entry.relativePath)) {
        if (state.matches.length == 100) {
          state.stop('max_matches', 100);
          return;
        }
        state.matches.add(entry);
      }
      if (entry.kind == EnvironmentDirectoryEntryKind.directory &&
          (plan.recursive ||
              entry.relativePath.split('/').length < plan.maxDepth)) {
        // A literal prefix narrows traversal, but never bypasses entry kinds.
        final requiredPrefix =
            plan.root == entry.relativePath ||
            plan.root.startsWith('${entry.relativePath}/');
        if (!requiredPrefix &&
            plan.root.isNotEmpty &&
            !entry.relativePath.startsWith('${plan.root}/')) {
          continue;
        }
        try {
          await _walk(
            await _fileSystem.readDirectory(entry.relativePath),
            state,
            plan,
          );
        } on EnvironmentFailure {
          if (requiredPrefix) rethrow;
          state.failedDirectoryReads++;
        }
      }
    }
  }
}

/// Conservative structural bounds, not a matching grammar. Any syntax-bearing
/// component ends the literal prefix. Counting every slash overestimates depth
/// for alternatives/classes/escapes; any ** permits recursion. Glob alone matches.
final class _GlobTraversal {
  _GlobTraversal(String pattern) {
    final segments = pattern.split('/');
    final prefix = <String>[];
    for (final segment in segments.take(segments.length - 1)) {
      if (segment.isEmpty || segment == '.' || Glob.quote(segment) != segment) {
        break;
      }
      prefix.add(segment);
    }
    root = prefix.join('/');
    maxDepth = segments.length;
    recursive = pattern.contains('**');
  }
  late final String root;
  late final int maxDepth;
  late final bool recursive;
}

final class _GlobState {
  _GlobState(this.pattern) : glob = GlobExecutable._glob(pattern);
  final String pattern;
  final Glob glob;
  final matches = <EnvironmentDirectoryEntry>[];
  int entriesVisited = 0;
  int failedDirectoryReads = 0;
  String? stopReason;
  int? stopLimit;
  void stop(String reason, int limit) {
    stopReason = reason;
    stopLimit = limit;
  }
}
