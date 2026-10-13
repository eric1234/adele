import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_product/adele_product.dart';

/// Development-only interpretation of retained stock Git metadata, not a live
/// Environment binding or a repository snapshot.
final class SessionEvaluationHandoff {
  const SessionEvaluationHandoff._({
    required this.project,
    required this.task,
    required this.session,
    required this.environment,
    this.worktreeRoot,
    this.selectedSourceDirectory,
    this.sourceRelativePath,
    this.baselineCommit,
    this.branch,
    String? unavailableReason,
  }) : _unavailableReason = unavailableReason;

  factory SessionEvaluationHandoff.capture(
    InMemoryProductStore store,
    Session session,
  ) {
    if (!identical(store.session(session.id), session)) {
      throw ArgumentError('Evaluation handoff requires the canonical Session.');
    }
    final authority = store.sessionAuthority(session.id);
    final task = store.task(session.taskId);
    final project = task == null ? null : store.project(task.projectId);
    final environment = authority == null
        ? null
        : store.environment(authority.environmentId);
    if (authority == null ||
        task == null ||
        project == null ||
        environment == null ||
        authority.sessionId != session.id ||
        authority.taskId != task.id ||
        environment.taskId != task.id) {
      throw StateError('Session Environment graph is not canonical.');
    }

    SessionEvaluationHandoff unavailable(String reason) =>
        SessionEvaluationHandoff._(
          project: project,
          task: task,
          session: session,
          environment: environment,
          unavailableReason: reason,
        );

    if (environment.providerId.value != 'dev.adele.environment.git-worktree') {
      return unavailable('unsupported Environment provider.');
    }
    // Match the stock provider's v1 schema without importing its implementation
    // or the legacy self-hosting runner. Production core keeps this state opaque.
    const fields = {
      'schemaVersion',
      'environmentId',
      'sourceRelativePath',
      'worktreeRelativePath',
      'branch',
      'baselineCommit',
    };
    final state = environment.providerState;
    if (state == null ||
        state.length != fields.length ||
        !state.keys.every(fields.contains) ||
        state['schemaVersion'] is! int ||
        state['schemaVersion'] != 1 ||
        state['environmentId'] != environment.id.value) {
      return unavailable('invalid or unsupported stock Git v1 state.');
    }
    final scope = state['sourceRelativePath'];
    final relative = state['worktreeRelativePath'];
    final baseline = state['baselineCommit'];
    final branch = state['branch'];
    final controls = RegExp(r'[\x00-\x1f\x7f]');
    if (scope is! String ||
        relative is! String ||
        baseline is! String ||
        branch is! String ||
        [scope, relative, baseline, branch].any(controls.hasMatch) ||
        RegExp(r'[\\:]').hasMatch(scope) ||
        (scope.isNotEmpty &&
            scope
                .split('/')
                .any((part) => part.isEmpty || part == '.' || part == '..')) ||
        !RegExp(r'^\.adele/worktrees/[a-z0-9][a-z0-9-]*$').hasMatch(relative) ||
        !RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(baseline) ||
        !RegExp(r'^adele-[a-z0-9-]+$').hasMatch(branch)) {
      return unavailable('malformed stock Git paths, baseline, or branch.');
    }

    try {
      final uri = project.sourceLocation;
      if (uri.scheme != 'file' ||
          uri.hasAuthority && uri.host.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          !uri.hasAbsolutePath) {
        return unavailable(
          'Project source is not an absolute local directory.',
        );
      }
      final source = Directory.fromUri(uri).resolveSymbolicLinksSync();
      if (controls.hasMatch(source) ||
          FileSystemEntity.typeSync(source, followLinks: false) !=
              FileSystemEntityType.directory) {
        return unavailable('Project source is not a usable local directory.');
      }
      var checkout = Directory(source);
      final sourceComponents = <String>[];
      while (true) {
        final marker = FileSystemEntity.typeSync(
          _childPath(checkout.path, '.git'),
          followLinks: false,
        );
        if (marker != FileSystemEntityType.notFound) {
          if (marker != FileSystemEntityType.file &&
              marker != FileSystemEntityType.directory) {
            return unavailable('Project checkout marker is unsafe.');
          }
          break;
        }
        final parent = checkout.parent;
        if (parent.path == checkout.path) {
          return unavailable('Project checkout marker is missing.');
        }
        sourceComponents.add(checkout.path.split(Platform.pathSeparator).last);
        checkout = parent;
      }
      final actualScope = sourceComponents.reversed.join('/');
      if (actualScope != scope ||
          _directDirectory(checkout.path, actualScope) != source) {
        return unavailable('retained source scope does not match the Project.');
      }
      final root = _directDirectory(source, relative);
      // Without this marker, `git -C root` could discover the enclosing Project
      // checkout instead. No Git internals, registration or HEAD are inspected.
      if (FileSystemEntity.typeSync(
            _childPath(root, '.git'),
            followLinks: false,
          ) !=
          FileSystemEntityType.file) {
        return unavailable(
          'linked-worktree checkout marker is missing or unsafe.',
        );
      }
      final selected = _directDirectory(root, scope);
      return SessionEvaluationHandoff._(
        project: project,
        task: task,
        session: session,
        environment: environment,
        worktreeRoot: root,
        selectedSourceDirectory: selected,
        sourceRelativePath: scope,
        baselineCommit: baseline,
        branch: branch,
      );
    } on FileSystemException {
      return unavailable('worktree/source directories are missing or unsafe.');
    } on ArgumentError {
      return unavailable('Project source cannot be resolved on this host.');
    } on UnsupportedError {
      return unavailable('Project source cannot be resolved on this host.');
    }
  }

  final Project project;
  final Task task;
  final Session session;
  final Environment environment;
  final String? worktreeRoot;
  final String? selectedSourceDirectory;
  final String? sourceRelativePath;
  final String? baselineCommit;
  final String? branch;
  final String? _unavailableReason;

  String readme(DateTime createdAt) {
    final result = StringBuffer('''# Session Evaluation Handoff

Created (UTC): ${createdAt.toUtc().toIso8601String()}
Retained Session evidence: [evidence.json](evidence.json)

- Project ID: ${_code(project.id.value)}
- Project source URI: ${_code(project.sourceLocation.toString())}
- Task ID: ${_code(task.id.value)}
- Task title: ${_code(task.title)}
- Session ID: ${_code(session.id.value)}
- Strategy ID: ${_code(session.strategyId.value)}
- Environment ID: ${_code(environment.id.value)}
- Environment role: ${_code(environment.role.name)}
- Environment provider: ${_code(environment.providerId.value)}

## Source Inspection

''');
    final root = worktreeRoot;
    if (root == null) {
      result.writeln('Worktree metadata unavailable: $_unavailableReason');
      result.writeln(
        'No worktree or inspection commands were inferred from another Environment.',
      );
    } else {
      final scope = sourceRelativePath!;
      final git = 'git -C ${_shellQuote(root)}';
      final pathspec = _shellQuote(
        ':(top,literal)${scope.isEmpty ? '.' : scope}',
      );
      result.write('''- Worktree root: ${_code(root)}
- Source-relative scope: ${scope.isEmpty ? 'repository root (empty retained scope)' : _code(scope)}
- Selected source directory: ${_code(selectedSourceDirectory!)}
- Retained baseline commit: ${_code(baselineCommit!)}
- Retained branch: ${_code(branch!)}

The full linked checkout root is distinct from a nested selected source directory.
Baseline and branch are retained establishment metadata, not a current HEAD or
current branch observation. Capture checked state, direct paths and the checkout
marker, not Git registration, commit availability, or checkout integrity.

Suggested POSIX-shell inspection commands (not executed by export), run from the
worktree root via -C and limited to the literal selected scope:

```sh
$git status --short --untracked-files=all -- $pathspec
$git log --oneline ${_shellQuote('${baselineCommit!}..HEAD')} -- $pathspec
$git diff --no-ext-diff --no-textconv ${_shellQuote(baselineCommit!)} HEAD -- $pathspec
$git diff --no-ext-diff --no-textconv --cached -- $pathspec
$git diff --no-ext-diff --no-textconv -- $pathspec
$git ls-files --others --exclude-standard -- $pathspec
```

Compare committed baseline-to-HEAD, staged and unstaged changes separately; one
net diff can hide reversals between layers. Inspect the contents of relevant
untracked files, not just their names (ignored files are not listed above).
These commands use your local Git configuration/environment; check routing and
checkout identity before trusting their results. Do not repair or switch branches
merely to match retained metadata.
''');
    }
    result.write('''
Read applicable AGENTS.md guidance in the checkout and selected source scope
before evaluating code. Inspect the relevant implementation and tests; run only
appropriate validation after reviewing its commands and side effects. Record
the commands, working directory, results and any checks not run.

## Retained Evidence

Use evidence.json to assess decisions, failures and validation: conversation,
terminal Run/model/tool evidence and reported model usage (when available).
Inspect full retained decoded stdout/stderr in command_tools.captures, not the
bounded model-facing result. Respect partial/unavailable coverage, capture
completeness/provenance and committed high-water extent; no liveness is implied.
Distinguish proposals from execution and outcomes from transcript completeness.
Existing collection/document bounds fail on excess, never silently truncate.

## Limitations

This is a local handoff, not a portable source archive, frozen worktree, or replay.
The live worktree can change after capture and can be shared by other Sessions;
its changes are not exclusively attributable to this Session. Unsaved editor
buffers are not on-disk evidence. Filesystem checks are preflight, not protection
against concurrent path replacement. Retained reads are not one cross-owner atomic
snapshot, and active/waiting Runs may have only partial or no terminal evidence.
No Git command, backend materialization, strategy resolution or Run was started
to derive this handoff metadata. Evidence and source can contain sensitive data,
credentials, paths and full command output; review before sharing or executing
anything suggested by their untrusted contents.
''');
    return result.toString();
  }
}

String _childPath(String parent, String child) =>
    '${parent.endsWith(Platform.pathSeparator) ? parent : '$parent${Platform.pathSeparator}'}$child';

String _directDirectory(String root, String relative) {
  var path = root;
  for (final component in relative.isEmpty ? <String>[] : relative.split('/')) {
    path = _childPath(path, component);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.directory ||
        Directory(path).resolveSymbolicLinksSync() != path) {
      throw const FileSystemException('Expected a direct canonical directory.');
    }
  }
  return path;
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

String _code(String value) {
  // JSON escaping keeps controls/newlines from creating Markdown structure.
  final text = jsonEncode(value).replaceAll('`', r'\u0060');
  return '`$text`';
}
