import 'package:adele_ui/inspection_display.dart';
import 'package:adele_ui/tool_activity_inspection_bridge.dart';
import 'package:flutter/material.dart';

Widget buildCreateFileInspection() => CreateFileInspection();
Widget buildCreateFileCompact() => CreateFileInspection(compact: true);

class CreateFileInspection extends StatefulWidget {
  CreateFileInspection({this.compact = false});

  final bool compact;

  @override
  State<CreateFileInspection> createState() =>
      _CreateFileInspectionState(compact);
}

class _CreateFileInspectionState extends State<CreateFileInspection> {
  // The eval pin cannot reliably resolve this field through State.widget.
  _CreateFileInspectionState(this.compact);

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
    final dynamic target = arguments['relativePath'];
    if (compact) {
      if (target is! String) {
        throw FormatException('Create File compact data is unavailable.');
      }
      final String path = compactDisplayText(
        target,
        maximumCharacters: 120,
        quoted: true,
      );
      return Text('Create File: $path');
    }
    final String lifecycle = snapshot.lifecycle;
    final String? disposition = snapshot.disposition;
    String status = lifecycle;
    if (lifecycle == 'prepared') status = 'Prepared';
    if (lifecycle == 'approvalRequested') status = 'Waiting for approval';
    if (lifecycle == 'executionStarted') status = 'Running';
    if (lifecycle == 'completed') status = 'Completed';
    if (disposition == 'success') status = 'Succeeded';
    if (disposition == 'failure') status = 'Failed';
    if (disposition == 'userRejected') status = 'User rejected';
    if (disposition == 'policyDenied') status = 'Policy denied';
    if (disposition == 'cancelled') status = 'Cancelled';
    if (disposition == 'indeterminate') status = 'Indeterminate';
    final String path = compactDisplayText(
      target is String ? target : 'Unavailable',
      maximumCharacters: 2000,
      quoted: true,
    );
    final List<Widget> children = <Widget>[
      Text('Create File', style: TextStyle(fontWeight: FontWeight.bold)),
      SizedBox(height: 8),
      Text('Relative path: $path'),
      Text('Status: ${compactDisplayText(status)}'),
      Text('Lifecycle: ${compactDisplayText(lifecycle)}'),
      Text('Tool delivery: ${compactDisplayText(disposition ?? 'Pending')}'),
      Text(
        'Requested content preview (up to 2,000 displayed characters; ... indicates truncation; not a file read or proof of written content):',
      ),
    ];
    final dynamic content = arguments['content'];
    if (content is String) {
      children.add(
        Text(
          content.isEmpty
              ? 'Empty requested content ("").'
              : compactDisplayText(
                  content,
                  maximumCharacters: 2000,
                  quoted: true,
                ),
        ),
      );
    } else {
      children.add(Text('Requested content unavailable.'));
    }
    final Map<String, dynamic> data = snapshot.hostData;
    final dynamic revision = data['revision'];
    if (lifecycle == 'completed' && disposition == 'success') {
      children.add(Text('Creation succeeded.'));
      if (revision is String) {
        children.add(
          Text(
            'New revision: ${compactDisplayText(revision, maximumCharacters: 2000)}',
          ),
        );
      }
    }
    if (snapshot.failureKind != null) {
      children.add(
        Text('Failure kind: ${compactDisplayText(snapshot.failureKind!)}'),
      );
    }
    final dynamic code = data['code'];
    if (code is String) {
      children.add(
        Text(
          'Failure code: ${compactDisplayText(code, maximumCharacters: 256)}',
        ),
      );
    }
    if (disposition != null &&
        disposition != 'success' &&
        snapshot.modelContent.isNotEmpty) {
      children.add(
        Text(
          'Outcome: ${compactDisplayText(snapshot.modelContent, maximumCharacters: 2000)}',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

Widget buildReadFileInspection() => ReadFileInspection();
Widget buildReadFileCompact() => ReadFileInspection(compact: true);

class ReadFileInspection extends StatefulWidget {
  ReadFileInspection({this.compact = false});

  final bool compact;

  @override
  State<ReadFileInspection> createState() => _ReadFileInspectionState(compact);
}

class _ReadFileInspectionState extends State<ReadFileInspection> {
  // The eval pin cannot reliably resolve this field through State.widget.
  _ReadFileInspectionState(this.compact);

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
    final dynamic target = arguments['relativePath'];
    final dynamic start = arguments['startLine'];
    final dynamic count = arguments['lineCount'];
    final bool ranged = start != null || count != null;
    String scope = 'whole file';
    if (ranged) {
      final String first = inspectionDisplayText("${start ?? 1}");
      String limit = 'through EOF';
      if (count != null) {
        final String requestedCount = inspectionDisplayText('$count');
        limit = 'count $requestedCount';
      }
      scope = 'start $first, $limit';
    }
    if (compact) {
      if (target is! String) {
        throw FormatException('Read File compact data is unavailable.');
      }
      final String path = compactDisplayText(
        target,
        maximumCharacters: 120,
        quoted: true,
      );
      final String range = ranged
          ? ' / ${compactDisplayText(scope, maximumCharacters: 64)}'
          : '';
      return Text('Read File: $path$range');
    }
    final String lifecycle = snapshot.lifecycle;
    String status = lifecycle;
    if (lifecycle == 'prepared') status = 'Prepared';
    if (lifecycle == 'approvalRequested') status = 'Waiting for approval';
    if (lifecycle == 'executionStarted') status = 'Running';
    if (lifecycle == 'completed') status = 'Completed';
    final String? disposition = snapshot.disposition;
    if (disposition == 'success') status = 'Succeeded';
    if (disposition == 'failure') status = 'Failed';
    if (disposition == 'userRejected') status = 'User rejected';
    if (disposition == 'policyDenied') status = 'Policy denied';
    if (disposition == 'cancelled') status = 'Cancelled';
    if (disposition == 'indeterminate') status = 'Indeterminate';
    final String path = inspectionDisplayText(
      "${target ?? 'Unavailable'}",
    ).replaceAll('"', r'\"');
    final List<Widget> children = <Widget>[
      Text('Read File', style: TextStyle(fontWeight: FontWeight.bold)),
      SizedBox(height: 8),
      Text('Relative path: "$path"'),
      Text('Requested scope: $scope'),
      Text('Status: ${inspectionDisplayText(status)}'),
      Text('Lifecycle: ${inspectionDisplayText(lifecycle)}'),
      Text('Tool delivery: ${inspectionDisplayText(disposition ?? 'Pending')}'),
    ];
    final Map<String, dynamic> data = snapshot.hostData;
    if (lifecycle == 'completed' && disposition == 'success') {
      if (data['sizeBytes'] != null) {
        children.add(
          Text(
            'File size (bytes): ${inspectionDisplayText("${data['sizeBytes']}")}',
          ),
        );
      }
      if (data['revision'] != null) {
        children.add(
          Text('Revision: ${inspectionDisplayText("${data['revision']}")}'),
        );
      }
      if (data['returnedLineCount'] != null) {
        children.add(
          Text(
            'Returned lines: ${inspectionDisplayText("${data['returnedLineCount']}")}',
          ),
        );
      }
      if (data['totalLines'] != null) {
        children.add(
          Text(
            'Total lines: ${inspectionDisplayText("${data['totalLines']}")}',
          ),
        );
      }
      if (data['nextStartLine'] != null) {
        children.add(
          Text(
            'Continuation line: ${inspectionDisplayText("${data['nextStartLine']}")}',
          ),
        );
      }
      final dynamic text = data['text'];
      if (text is String) {
        children.add(
          Text(
            'Text preview (up to 2,000 displayed characters; ... indicates truncation):',
          ),
        );
        children.add(Text(compactDisplayText(text, maximumCharacters: 2000)));
      }
    }
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
    if (disposition != null &&
        disposition != 'success' &&
        snapshot.modelContent.isNotEmpty) {
      children.add(
        Text(
          'Outcome: ${compactDisplayText(snapshot.modelContent, maximumCharacters: 2000)}',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

Widget buildApplyPatchInspection() => ApplyPatchInspection();
Widget buildApplyPatchCompact() => ApplyPatchInspection(compact: true);

class ApplyPatchInspection extends StatefulWidget {
  ApplyPatchInspection({this.compact = false});

  final bool compact;

  @override
  State<ApplyPatchInspection> createState() =>
      _ApplyPatchInspectionState(compact);
}

class _ApplyPatchInspectionState extends State<ApplyPatchInspection> {
  // The eval pin cannot reliably resolve this field through State.widget.
  _ApplyPatchInspectionState(this.compact);

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
    final dynamic edits = arguments['edits'];
    if (compact) {
      final dynamic target = arguments['relativePath'];
      if (target is! String || edits is! List<dynamic>) {
        throw FormatException('Apply Patch compact data is unavailable.');
      }
      final String path = compactDisplayText(
        target,
        maximumCharacters: 120,
        quoted: true,
      );
      // This is the canonical requested count, not applied edits or diff lines.
      final int count = edits.length;
      return Text(
        'Apply Patch: $path / $count ${count == 1 ? 'edit' : 'edits'}',
      );
    }
    final String lifecycle = snapshot.lifecycle;
    String status = lifecycle;
    if (lifecycle == 'prepared') status = 'Prepared';
    if (lifecycle == 'approvalRequested') status = 'Waiting for approval';
    if (lifecycle == 'executionStarted') status = 'Running';
    if (lifecycle == 'completed') status = 'Completed';
    final String? disposition = snapshot.disposition;
    if (disposition == 'success') status = 'Succeeded';
    if (disposition == 'failure') status = 'Failed';
    if (disposition == 'userRejected') status = 'User rejected';
    if (disposition == 'policyDenied') status = 'Policy denied';
    if (disposition == 'cancelled') status = 'Cancelled';
    if (disposition == 'indeterminate') status = 'Indeterminate';
    final Map<String, dynamic> data = snapshot.hostData;
    final String path = inspectionDisplayText(
      "${arguments['relativePath'] ?? 'Unavailable'}",
    ).replaceAll('"', r'\"');
    final List<Widget> children = <Widget>[
      Text('Apply Patch', style: TextStyle(fontWeight: FontWeight.bold)),
      SizedBox(height: 8),
      Text('Relative path: "$path"'),
      Text(
        'Edit count: ${edits is List<dynamic> ? edits.length : 'Unavailable'}',
      ),
      Text('Status: ${inspectionDisplayText(status)}'),
      Text('Lifecycle: ${inspectionDisplayText(lifecycle)}'),
      Text(
        'Tool delivery: ${inspectionDisplayText(snapshot.disposition ?? 'Pending')}',
      ),
    ];
    if (data['newRevision'] != null) {
      children.add(
        Text(
          'New revision: ${inspectionDisplayText("${data['newRevision']}")}',
        ),
      );
    }
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
    if (data['failedEditIndex'] != null) {
      children.add(
        Text(
          'Failed edit index (zero-based): ${inspectionDisplayText("${data['failedEditIndex']}")}',
        ),
      );
    }
    if (snapshot.modelContent.isNotEmpty) {
      final String content = snapshot.modelContent;
      children.add(
        Text(
          'Outcome: ${inspectionDisplayText(content.length > 4096 ? content.substring(0, 4096) : content)}',
        ),
      );
      if (content.length > 4096) {
        children.add(Text('Outcome preview truncated.'));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}
