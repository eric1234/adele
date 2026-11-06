import 'package:adele_ui/inspection_display.dart';
import 'package:adele_ui/tool_activity_inspection_bridge.dart';
import 'package:flutter/material.dart';

import 'command_output_view.dart';

export 'command_output_view.dart' show buildRunCommandOutput;

Widget buildRunCommandInspection() => RunCommandInspection();
Widget buildRunCommandCompact() => RunCommandInspection(compact: true);

// Display delimiters preserve value boundaries; this is not shell quoting.
String _quoted(String value) =>
    '"${inspectionDisplayText(value).replaceAll('"', r'\"')}"';

class RunCommandInspection extends StatefulWidget {
  RunCommandInspection({this.compact = false});

  final bool compact;

  @override
  State<RunCommandInspection> createState() =>
      _RunCommandInspectionState(compact);
}

class _RunCommandInspectionState extends State<RunCommandInspection> {
  // The eval pin cannot reliably resolve this field through State.widget.
  _RunCommandInspectionState(this.compact);

  final bool compact;
  bool disposed = false;

  @override
  void initState() {
    super.initState();
    subscribeToolActivityChanges(() {
      if (!disposed) setState(() {});
    });
  }

  @override
  void dispose() {
    disposed = true;
    unsubscribeToolActivityChanges();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ToolActivityInspectionSnapshot snapshot = readToolActivitySnapshot();
    final Map<String, dynamic> arguments = snapshot.canonicalArguments;
    final dynamic shellCommand = arguments['shellCommand'];
    if (compact) {
      if (shellCommand is String) {
        return Text(
          'Run Command (shell): ${compactDisplayText(shellCommand, maximumCharacters: 240, quoted: true)}',
        );
      }
      final dynamic program = arguments['program'];
      final dynamic argv = arguments['arguments'];
      if (program is! String || argv is! List<dynamic>) {
        throw FormatException('Run Command compact data is unavailable.');
      }
      final List<String> tokens = <String>[];
      for (int index = 0; index < argv.length && index < 4; index++) {
        final dynamic argument = argv[index];
        if (argument is! String) {
          throw FormatException('Run Command argument is unavailable.');
        }
        tokens.add(
          compactDisplayText(argument, maximumCharacters: 48, quoted: true),
        );
      }
      String argumentsText = argv.isEmpty ? '[]' : '[${tokens.join(', ')}]';
      if (argv.length > tokens.length) {
        argumentsText =
            '$argumentsText (${argv.length - tokens.length} more arguments)';
      }
      return Text(
        'Run Command: ${compactDisplayText(program, maximumCharacters: 80, quoted: true)} $argumentsText',
      );
    }
    final Map<String, dynamic> data = snapshot.hostData;
    final String lifecycle = snapshot.lifecycle;
    String status = lifecycle;
    if (lifecycle == 'prepared') status = 'Prepared';
    if (lifecycle == 'approvalRequested') status = 'Waiting for approval';
    if (lifecycle == 'executionStarted') status = 'Running';
    if (lifecycle == 'completed') status = 'Completed';
    final String? disposition = snapshot.disposition;
    if (disposition == 'failure') status = 'Failed';
    if (disposition == 'userRejected') status = 'User rejected';
    if (disposition == 'policyDenied') status = 'Policy denied';
    if (disposition == 'cancelled') status = 'Cancelled';
    if (disposition == 'indeterminate') status = 'Indeterminate';
    final List<Widget> children = <Widget>[
      Text('Run Command', style: TextStyle(fontWeight: FontWeight.bold)),
      SizedBox(height: 8),
    ];
    if (shellCommand is String) {
      children.add(Text('Shell command (display escapes):'));
      final List<String> lines = <String>[];
      for (final String line in shellCommand.split('\n')) {
        lines.add(inspectionDisplayText(line));
      }
      children.add(Text(lines.join('\n')));
      final dynamic profile = data['shellProfile'];
      if (profile is Map<String, dynamic>) {
        if (profile['profileId'] is String) {
          children.add(
            Text('Shell profile: ${_quoted(profile['profileId'] as String)}'),
          );
        }
        if (profile['interpreter'] is String) {
          children.add(
            Text('Interpreter: ${_quoted(profile['interpreter'] as String)}'),
          );
        }
        if (profile['dialect'] is String) {
          children.add(
            Text('Dialect: ${_quoted(profile['dialect'] as String)}'),
          );
        }
      }
    } else {
      children.add(
        Text('Program: ${_quoted("${arguments['program'] ?? 'Unavailable'}")}'),
      );
      children.add(Text('Arguments (direct argv):'));
      final dynamic argv = arguments['arguments'];
      if (argv is List<dynamic>) {
        if (argv.isEmpty) children.add(Text('No arguments.'));
        for (int index = 0; index < argv.length; index++) {
          children.add(Text('[$index]: ${_quoted("${argv[index]}")}'));
        }
      } else {
        children.add(Text('Arguments unavailable.'));
      }
    }
    final dynamic cwd = arguments['workingDirectory'];
    String location = _quoted("${cwd ?? 'Unavailable'}");
    if (cwd == '') location = '$location (Environment root)';
    children.add(Text('Working directory: $location'));
    children.add(
      Text(
        'Timeout seconds: ${inspectionDisplayText("${arguments['timeoutSeconds'] ?? 'Unavailable'}")}',
      ),
    );
    children.add(Text('Status: ${inspectionDisplayText(status)}'));
    children.add(Text('Lifecycle: ${inspectionDisplayText(lifecycle)}'));
    // Delivery success means a process result was delivered, not exit code zero.
    children.add(
      Text(
        'Tool delivery: ${inspectionDisplayText(snapshot.disposition ?? 'Pending')}',
      ),
    );
    children.add(
      Text(
        'Process termination: ${inspectionDisplayText("${data['termination'] ?? 'Not reported'}")}',
      ),
    );
    children.add(
      Text(
        'Exit code: ${inspectionDisplayText("${data['exitCode'] ?? 'Not reported'}")}',
      ),
    );
    if (snapshot.failureKind != null) {
      children.add(
        Text('Failure kind: ${inspectionDisplayText(snapshot.failureKind!)}'),
      );
    }
    if (data['code'] != null) {
      children.add(
        Text('Failure code: ${inspectionDisplayText("${data['code']}")}'),
      );
    }
    if (snapshot.failureKind != null && snapshot.modelContent.isNotEmpty) {
      final String content = snapshot.modelContent;
      children.add(
        Text(
          'Failure detail: ${inspectionDisplayText(content.length > 4096 ? content.substring(0, 4096) : content)}',
        ),
      );
      if (content.length > 4096) {
        children.add(Text('Failure detail preview truncated.'));
      }
    }
    children.add(
      CommandOutputView(
        sessionId: snapshot.sessionId,
        runId: snapshot.runId,
        invocationId: snapshot.toolInvocationId,
        title: shellCommand is String
            ? 'Shell: ${compactDisplayText(shellCommand, maximumCharacters: 64)}'
            : 'Command: ${compactDisplayText("${arguments['program'] ?? 'Unavailable'}", maximumCharacters: 64)}',
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}
