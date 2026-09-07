/// Stock foreground command tool for Session-authorized Environments.
library;

import 'dart:convert';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

final PluginId commandToolsPluginId = PluginId(
  'dev.adele.plugin.command-tools',
);

final class CommandToolsPlugin {
  const CommandToolsPlugin();

  ExtensionRegistration activate(ExtensionRegistry extensions) =>
      extensions.register(
        point: modelToolContributions,
        id: ExtensionId('dev.adele.plugin.command-tools.model-tools'),
        value: const _CommandModelTools(),
      );
}

final class _CommandModelTools implements ModelToolContribution {
  const _CommandModelTools();

  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async {
    final AuthorizedEnvironmentProcessFacet process = await context
        .requireHostService<AuthorizedEnvironmentProcessFacet>();
    if (process.sessionId != context.sessionId) {
      throw StateError('The process authority belongs to another Session.');
    }
    return <ToolRegistration>[_RunCommandExecutable(process).registration];
  }
}

final class _RunCommandExecutable implements ToolExecutable {
  const _RunCommandExecutable(this._process);

  static final ToolId _toolId = ToolId(
    'dev.adele.plugin.command-tools.run-command',
  );
  static const int _defaultTimeoutSeconds = 120;

  final AuthorizedEnvironmentProcessFacet _process;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: _toolId,
      description:
          'Run one foreground program in the current Session Environment.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'run_command',
      description:
          'Run one foreground program directly in the current Session '
          'Environment. program is one executable name or path and arguments '
          'are passed verbatim. This tool does not implicitly invoke a shell '
          'or interpret pipes, redirects, command chaining, variable '
          'expansion, or other shell syntax. workingDirectory is '
          'Environment-relative; omitted or empty means the Environment root.',
      argumentsSchema: const <String, Object?>{
        'type': 'object',
        'required': <Object?>['program'],
        'properties': <String, Object?>{
          'program': <String, Object?>{'type': 'string', 'minLength': 1},
          'arguments': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
          },
          'workingDirectory': <String, Object?>{'type': 'string'},
          'timeoutSeconds': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 600,
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
    const Set<String> fields = <String>{
      'program',
      'arguments',
      'workingDirectory',
      'timeoutSeconds',
    };
    if (proposedArguments.keys.any((String key) => !fields.contains(key)) ||
        proposedArguments['program'] is! String ||
        (proposedArguments['program']! as String).isEmpty) {
      throw const ToolArgumentValidationException(
        'run_command requires a non-empty string program and accepts only '
        'arguments, workingDirectory, and timeoutSeconds as optional fields.',
      );
    }
    final Object? proposedArgumentList = proposedArguments['arguments'];
    if (proposedArguments.containsKey('arguments') &&
        (proposedArgumentList is! List<Object?> ||
            proposedArgumentList.any((Object? value) => value is! String))) {
      throw const ToolArgumentValidationException(
        'run_command arguments must be an array of strings.',
      );
    }
    final Object? proposedWorkingDirectory =
        proposedArguments['workingDirectory'];
    if (proposedArguments.containsKey('workingDirectory') &&
        proposedWorkingDirectory is! String) {
      throw const ToolArgumentValidationException(
        'run_command workingDirectory must be a string.',
      );
    }
    final Object? proposedTimeout = proposedArguments['timeoutSeconds'];
    if (proposedArguments.containsKey('timeoutSeconds') &&
        proposedTimeout is! int) {
      throw const ToolArgumentValidationException(
        'run_command timeoutSeconds must be an integer.',
      );
    }

    final String program = proposedArguments['program']! as String;
    final List<String> arguments = proposedArgumentList == null
        ? <String>[]
        : List<String>.from(proposedArgumentList as List<Object?>);
    final String workingDirectory = _canonicalWorkingDirectory(
      proposedWorkingDirectory as String? ?? '',
    );
    final int timeoutSeconds =
        proposedTimeout as int? ?? _defaultTimeoutSeconds;
    try {
      final EnvironmentForegroundProcessRequest request =
          EnvironmentForegroundProcessRequest(
            program: program,
            arguments: arguments,
            relativeWorkingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds,
          );
      return CanonicalToolArguments(<String, Object?>{
        'program': request.program,
        'arguments': request.arguments,
        'workingDirectory': request.relativeWorkingDirectory,
        'timeoutSeconds': request.timeoutSeconds,
      });
    } on FormatException catch (error) {
      throw ToolArgumentValidationException(error.message);
    }
  }

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    _requireAuthorizedSession(context);
    final String program = arguments.snapshot['program']! as String;
    final List<Object?> programArguments =
        arguments.snapshot['arguments']! as List<Object?>;
    final String workingDirectory =
        arguments.snapshot['workingDirectory']! as String;
    final int timeoutSeconds = arguments.snapshot['timeoutSeconds']! as int;
    final String location = workingDirectory.isEmpty
        ? 'Environment root'
        : 'Environment directory ${jsonEncode(workingDirectory)}';
    return EffectDescription(
      effects: const <ToolEffect>[ToolEffect.processExecution],
      targets: <EffectTarget>[
        EffectTarget(
          uri: Uri(
            scheme: 'adele-environment',
            path: '/${_process.environmentId.value}/',
          ),
        ),
      ],
      summary:
          'Run program ${jsonEncode(program)} with arguments '
          '${jsonEncode(programArguments)} from $location with a '
          '$timeoutSeconds-second timeout.',
      uncertainty: EffectUncertainty.uncertain,
    );
  }

  @override
  void validateBinding() {
    try {
      _process.validateBinding();
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
    final EnvironmentForegroundProcessRequest request = _requestFromCanonical(
      arguments,
    );
    final _BoundedCommandOutput stdout = _BoundedCommandOutput();
    final _BoundedCommandOutput stderr = _BoundedCommandOutput();
    try {
      _requireAuthorizedSession(context);
      EnvironmentProcessCompleted? completed;
      await for (final EnvironmentProcessEvent event
          in _process.runForegroundProcess(request)) {
        if (completed != null) {
          throw const _ProcessStreamContractViolation(
            'The Environment process stream emitted an event after completion.',
          );
        }
        switch (event.kind) {
          case EnvironmentProcessEventKind.output:
            final EnvironmentProcessOutput output = event.output!;
            final ToolProgressKind kind;
            switch (output.stream) {
              case EnvironmentProcessOutputStream.stdout:
                stdout.add(output.text);
                kind = ToolProgressKind.stdout;
              case EnvironmentProcessOutputStream.stderr:
                stderr.add(output.text);
                kind = ToolProgressKind.stderr;
            }
            yield ToolExecutionProgress(
              ToolProgress(kind: kind, content: output.text),
            );
          case EnvironmentProcessEventKind.completed:
            completed = event.completed!;
        }
      }
      if (completed == null) {
        throw const _ProcessStreamContractViolation(
          'The Environment process stream ended without completion.',
        );
      }
      yield ToolExecutionTerminal(_success(request, completed, stdout, stderr));
    } on AuthorizedEnvironmentBindingStale catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          request,
          stdout,
          stderr,
          modelContent: 'The authorized Environment binding became stale.',
          kind: ToolFailureKind.staleBinding,
          cause: error,
        ),
      );
    } on AuthorizedEnvironmentBindingUnavailable catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          request,
          stdout,
          stderr,
          modelContent: 'The authorized Environment provider is unavailable.',
          kind: ToolFailureKind.infrastructure,
          cause: error,
        ),
      );
    } on EnvironmentFailure catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          request,
          stdout,
          stderr,
          modelContent: 'Environment command failed: ${error.message}',
          kind: ToolFailureKind.domain,
          cause: error,
          diagnostics: <String, Object?>{
            'code': error.code,
            'message': error.message,
            'details': error.details,
          },
        ),
      );
    } on _SessionAuthorityViolation catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          request,
          stdout,
          stderr,
          modelContent:
              'The Run Command tool is not authorized for this Session.',
          kind: ToolFailureKind.infrastructure,
          cause: error,
          certainty: EffectCertainty.knownNotOccurred,
        ),
      );
    } on Object catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          request,
          stdout,
          stderr,
          modelContent: 'Environment command execution failed.',
          kind: ToolFailureKind.infrastructure,
          cause: error,
        ),
      );
    }
  }

  EnvironmentForegroundProcessRequest _requestFromCanonical(
    CanonicalToolArguments arguments,
  ) => EnvironmentForegroundProcessRequest(
    program: arguments.snapshot['program']! as String,
    arguments: List<String>.from(
      arguments.snapshot['arguments']! as List<Object?>,
    ),
    relativeWorkingDirectory: arguments.snapshot['workingDirectory']! as String,
    timeoutSeconds: arguments.snapshot['timeoutSeconds']! as int,
  );

  ToolOutcome _success(
    EnvironmentForegroundProcessRequest request,
    EnvironmentProcessCompleted completed,
    _BoundedCommandOutput stdout,
    _BoundedCommandOutput stderr,
  ) {
    final bool stdoutTruncated = completed.stdoutTruncated || stdout.truncated;
    final bool stderrTruncated = completed.stderrTruncated || stderr.truncated;
    return ToolOutcome(
      disposition: ToolOutcomeDisposition.success,
      effectCertainty: EffectCertainty.knownOccurred,
      modelContent: _modelResult(
        request,
        termination: completed.termination.name,
        exitCode: completed.exitCode,
        stdout: stdout.value,
        stderr: stderr.value,
        stdoutTruncated: stdoutTruncated,
        stderrTruncated: stderrTruncated,
      ),
      hostData: <String, Object?>{
        ..._baseHostData(request, stdout, stderr),
        'termination': completed.termination.name,
        'exitCode': completed.exitCode,
        'stdoutTruncated': stdoutTruncated,
        'stderrTruncated': stderrTruncated,
      },
    );
  }

  ToolOutcome _failure(
    EnvironmentForegroundProcessRequest request,
    _BoundedCommandOutput stdout,
    _BoundedCommandOutput stderr, {
    required String modelContent,
    required ToolFailureKind kind,
    required Object cause,
    Map<String, Object?> diagnostics = const <String, Object?>{},
    EffectCertainty certainty = EffectCertainty.uncertain,
  }) => ToolOutcome(
    disposition: ToolOutcomeDisposition.failure,
    failureKind: kind,
    effectCertainty: certainty,
    modelContent:
        '$modelContent\n\n'
        'Retained partial STDOUT:\n${stdout.value}\n\n'
        'Retained partial STDERR:\n${stderr.value}',
    hostData: <String, Object?>{
      ..._baseHostData(request, stdout, stderr),
      'stdoutTruncated': stdout.truncated,
      'stderrTruncated': stderr.truncated,
      ...diagnostics,
    },
    hostDiagnostic: cause.toString(),
    cause: cause,
  );

  Map<String, Object?> _baseHostData(
    EnvironmentForegroundProcessRequest request,
    _BoundedCommandOutput stdout,
    _BoundedCommandOutput stderr,
  ) => <String, Object?>{
    'environmentId': _process.environmentId.value,
    'program': request.program,
    'arguments': request.arguments,
    'workingDirectory': request.relativeWorkingDirectory,
    'timeoutSeconds': request.timeoutSeconds,
    'stdout': stdout.value,
    'stderr': stderr.value,
  };

  void _requireAuthorizedSession(ToolExecutionContext context) {
    if (context.sessionId != _process.sessionId) {
      throw _SessionAuthorityViolation(context.sessionId.toString());
    }
  }
}

const int maximumRetainedCommandOutputCharacters = 32 * 1024;
const int _retainedCommandOutputHeadCharacters =
    maximumRetainedCommandOutputCharacters ~/ 2;

final class _BoundedCommandOutput {
  final StringBuffer _head = StringBuffer();
  int _headRemaining = _retainedCommandOutputHeadCharacters;
  int _observed = 0;
  String _tail = '';

  bool get truncated => _observed > maximumRetainedCommandOutputCharacters;
  String get value => '${_head.toString()}$_tail';
  int get _tailCapacity =>
      maximumRetainedCommandOutputCharacters - _head.length;

  void add(String text) {
    _observed = _observed > maximumRetainedCommandOutputCharacters - text.length
        ? maximumRetainedCommandOutputCharacters + 1
        : _observed + text.length;
    int offset = 0;
    if (_headRemaining > 0) {
      final int requestedEnd = text.length < _headRemaining
          ? text.length
          : _headRemaining;
      int end = requestedEnd;
      if (end < text.length && _isHighSurrogate(text.codeUnitAt(end - 1))) {
        end--;
      }
      _head.write(text.substring(0, end));
      offset = end;
      _headRemaining = end < requestedEnd ? 0 : _headRemaining - end;
    }
    if (offset < text.length) _retainTail(text.substring(offset));
  }

  void _retainTail(String text) {
    if (text.length >= _tailCapacity) {
      int start = text.length - _tailCapacity;
      if (_isLowSurrogate(text.codeUnitAt(start))) start++;
      _tail = text.substring(start);
      return;
    }
    final String combined = '$_tail$text';
    if (combined.length <= _tailCapacity) {
      _tail = combined;
      return;
    }
    int start = combined.length - _tailCapacity;
    if (_isLowSurrogate(combined.codeUnitAt(start))) start++;
    _tail = combined.substring(start);
  }
}

String _canonicalWorkingDirectory(String workingDirectory) {
  if (workingDirectory.startsWith('/')) {
    throw const ToolArgumentValidationException(
      'workingDirectory must be Environment-relative.',
    );
  }
  final List<String> segments = <String>[];
  for (final String segment in workingDirectory.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      throw const ToolArgumentValidationException(
        'workingDirectory must not contain parent traversal.',
      );
    }
    segments.add(segment);
  }
  return segments.join('/');
}

String _modelResult(
  EnvironmentForegroundProcessRequest request, {
  required String termination,
  required int? exitCode,
  required String stdout,
  required String stderr,
  required bool stdoutTruncated,
  required bool stderrTruncated,
}) =>
    'Program: ${jsonEncode(request.program)}\n'
    'Arguments: ${jsonEncode(request.arguments)}\n'
    'Working directory: ${jsonEncode(request.relativeWorkingDirectory)}\n'
    'Timeout seconds: ${request.timeoutSeconds}\n'
    'Termination: $termination\n'
    'Exit code: ${exitCode ?? '<not applicable>'}\n'
    'Stdout truncated: $stdoutTruncated\n'
    'Stderr truncated: $stderrTruncated\n\n'
    'STDOUT:\n$stdout\n\n'
    'STDERR:\n$stderr';

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;
bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xdc00 && codeUnit <= 0xdfff;

final class _SessionAuthorityViolation implements Exception {
  const _SessionAuthorityViolation(this.message);

  final String message;
}

final class _ProcessStreamContractViolation implements Exception {
  const _ProcessStreamContractViolation(this.message);

  final String message;

  @override
  String toString() => 'ProcessStreamContractViolation: $message';
}
