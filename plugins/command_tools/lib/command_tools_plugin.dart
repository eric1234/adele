/// Stock foreground command tool for Session-authorized Environments.
library;

import 'dart:async';
import 'dart:convert';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

import 'src/command_transcripts.dart';
import 'src/process_outcome.dart';

export 'src/command_transcripts.dart';

final PluginId commandToolsPluginId = PluginId(
  'dev.adele.plugin.command-tools',
);

final ToolId runCommandToolId = ToolId(
  'dev.adele.plugin.command-tools.run-command',
);

final ExtensionId commandToolsExtensionId = ExtensionId(
  'dev.adele.plugin.command-tools.model-tools',
);

/// Shared semantic registration for in-process and remote Command Tools.
ToolRegistration commandToolRegistration(
  AuthorizedEnvironmentProcessFacet process, {
  CommandTranscriptStore? transcripts,
}) => _RunCommandExecutable(process, transcripts).registration;

final class CommandToolsPlugin {
  const CommandToolsPlugin({this.transcripts});

  /// Required for execution; description/validation never allocate capture.
  final CommandTranscriptStore? transcripts;

  ExtensionRegistration activate(ExtensionRegistry extensions) =>
      extensions.register(
        point: modelToolContributions,
        id: commandToolsExtensionId,
        value: _CommandModelTools(transcripts),
      );
}

final class _CommandModelTools implements ModelToolContribution {
  const _CommandModelTools(this.transcripts);

  final CommandTranscriptStore? transcripts;

  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async {
    final AuthorizedEnvironmentProcessFacet process = await context
        .requireHostService<AuthorizedEnvironmentProcessFacet>();
    if (process.sessionId != context.sessionId) {
      throw StateError('The process authority belongs to another Session.');
    }
    return <ToolRegistration>[
      commandToolRegistration(process, transcripts: transcripts),
    ];
  }
}

final class _RunCommandExecutable implements ToolExecutable {
  const _RunCommandExecutable(this._process, this._transcripts);

  static const int _defaultTimeoutSeconds = 120;

  final AuthorizedEnvironmentProcessFacet _process;
  final CommandTranscriptStore? _transcripts;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: runCommandToolId,
      description:
          'Run one foreground program in the current Session Environment.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'run_command',
      description:
          'Use for builds, tests, Git, and other operations requiring program '
          'execution. Prefer an available dedicated file-reading, content-search, '
          'or file-editing tool when it adequately supports the operation, rather '
          'than recreating it with shell commands or scripts. Commands remain '
          'available when those tools are absent or unsuitable, including path '
          'or file discovery unsupported by available tools, as well as '
          'generators, formatters, and other transformations. Runs one foreground '
          'executable directly in the current Session Environment: program is '
          'one executable name or path and arguments '
          'are passed verbatim. This tool does not implicitly invoke a shell '
          'or interpret pipes, redirects, command chaining, or variable expansion; '
          'shell syntax requires explicitly invoking an available shell. '
          'workingDirectory is Environment-relative; omitted or empty means the '
          'Environment root. Inspect returned termination, exit code, output, and '
          'truncation indicators: tool completion alone does not prove program '
          'or validation success.',
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
  ) {
    StreamIterator<EnvironmentProcessEvent>? producer;
    bool cancelled = false;
    Future<void>? work;
    Future<void>? cancellation;
    Future<void> stopProducer() =>
        cancellation ??= producer?.cancel() ?? Future<void>.value();
    late final StreamController<ToolExecutionEvent> controller;
    Future<ToolOutcome> run() async {
      final EnvironmentForegroundProcessRequest request = _requestFromCanonical(
        arguments,
      );
      final _BoundedCommandOutput stdout = _BoundedCommandOutput();
      final _BoundedCommandOutput stderr = _BoundedCommandOutput();
      CommandCaptureWriter? capture;
      EnvironmentProcessCompleted? completed;
      bool executionAdmitted = false;
      try {
        _requireAuthorizedSession(context);
        final transcripts = _transcripts;
        if (transcripts == null) {
          throw StateError(
            'Command execution requires a transcript storage service.',
          );
        }
        capture = await transcripts.begin(
          context: context,
          environmentId: _process.environmentId.value,
          request: request,
        );
        if (cancelled) throw StateError('Command execution was cancelled.');
        // Storage and the unique header commit precede listening to the lazy
        // process stream. Invocation identity does not grant process authority.
        executionAdmitted = true;
        producer = StreamIterator(_process.runForegroundProcess(request));
        capture.cancelProducer = stopProducer;
        while (!cancelled && await producer!.moveNext()) {
          final event = producer!.current;
          if (completed != null) {
            throw const _ProcessStreamContractViolation(
              'The Environment process stream emitted an event after completion.',
            );
          }
          switch (event.kind) {
            case EnvironmentProcessEventKind.output:
              final EnvironmentProcessOutput output = event.output!;
              switch (output.stream) {
                case EnvironmentProcessOutputStream.stdout:
                  stdout.add(output.text);
                case EnvironmentProcessOutputStream.stderr:
                  stderr.add(output.text);
              }
              await capture.append(output);
            case EnvironmentProcessEventKind.completed:
              completed = event.completed!;
          }
        }
        if (completed == null) {
          throw const _ProcessStreamContractViolation(
            'The Environment process stream ended without completion.',
          );
        }
        await stopProducer();
        await capture.seal(completed);
        if (completed.stdoutTruncated || completed.stderrTruncated) {
          throw StateError('The Environment did not deliver complete output.');
        }
        return _success(request, completed, stdout, stderr);
      } on Object catch (error) {
        Object? cleanupFailure;
        try {
          await stopProducer();
        } on Object catch (cleanupError) {
          cleanupFailure = cleanupError;
        }
        final details = error is EnvironmentFailure
            ? error.details
            : const <String, Object?>{};
        // Typed completion is one coherent fact, including a null timeout exit
        // code. Optional diagnostics may supply only a valid complete pair.
        final processOutcome = completed == null
            ? parseCommandProcessOutcome(
                details['termination'],
                details['exitCode'],
              )
            : (
                termination: completed.termination.name,
                exitCode: completed.exitCode,
              );
        final termination = processOutcome?.termination;
        final exitCode = processOutcome?.exitCode;
        await capture?.fail(
          'Command execution or capture failed; effects may have occurred.',
          termination: termination,
          exitCode: exitCode,
        );
        return _failure(
          request,
          stdout,
          stderr,
          modelContent: error is _SessionAuthorityViolation
              ? 'The Run Command tool is not authorized for this Session.'
              : error is EnvironmentFailure
              ? 'Environment command failed: ${error.message}'
              : 'Command execution or transcript capture failed.',
          kind: error is AuthorizedEnvironmentBindingStale
              ? ToolFailureKind.staleBinding
              : error is EnvironmentFailure &&
                    details['outputIncomplete'] != true
              ? ToolFailureKind.domain
              : ToolFailureKind.infrastructure,
          cause: error,
          certainty: executionAdmitted
              ? EffectCertainty.uncertain
              : EffectCertainty.knownNotOccurred,
          diagnostics: {
            'captureState': 'failed',
            'stdoutTruncated':
                stdout.truncated ||
                completed?.stdoutTruncated == true ||
                details['stdoutTruncated'] == true,
            'stderrTruncated':
                stderr.truncated ||
                completed?.stderrTruncated == true ||
                details['stderrTruncated'] == true,
            if (cleanupFailure != null) 'cleanupFailed': true,
            'termination': ?termination,
            'exitCode': ?exitCode,
            if (error is EnvironmentFailure) ...{
              'code': error.code,
              'message': error.message,
              // Outcome facts are exposed only in the validated fields above;
              // malformed optional values must not break structured diagnostics.
              'details': {
                for (final entry in error.details.entries)
                  if (entry.key != 'termination' && entry.key != 'exitCode')
                    entry.key: entry.value,
              },
            },
          },
        );
      } finally {
        try {
          await stopProducer();
        } on Object {
          // The primary outcome already carries the failure. Cleanup cannot
          // replace it or prevent capture from becoming honestly non-complete.
        } finally {
          await capture?.fail(
            'Capture interrupted before acknowledged completion.',
            termination: completed?.termination.name,
            exitCode: completed?.exitCode,
          );
        }
      }
    }

    controller = StreamController<ToolExecutionEvent>(
      onListen: () {
        work = run()
            .then<void>(
              (outcome) {
                if (!cancelled) controller.add(ToolExecutionTerminal(outcome));
              },
              onError: (Object error, StackTrace stack) {
                if (!cancelled) controller.addError(error, stack);
              },
            )
            .whenComplete(() => unawaited(controller.close()));
      },
      onCancel: () async {
        cancelled = true;
        // Unlike an async generator suspended on moveNext, this directly
        // interrupts a silent producer without waiting for another event.
        try {
          await stopProducer();
        } on Object {
          // run() reports cleanup failure without letting it strand its writer.
        }
        await work;
      },
    );
    return controller.stream;
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
        'captureState': 'complete',
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
        '${certainty == EffectCertainty.knownNotOccurred ? 'The process was not launched.' : 'External effects may have occurred; capture completeness is unconfirmed.'}\n'
        '${diagnostics['termination'] == null ? '' : 'Known termination: ${diagnostics['termination']}\n'}'
        '${diagnostics['exitCode'] == null ? '' : 'Known exit code: ${diagnostics['exitCode']}\n'}'
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
