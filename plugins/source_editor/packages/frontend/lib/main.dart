import 'package:adele_ui/code_editor_bridge.dart';
import 'package:adele_ui/contribution_bridge.dart';
import 'package:adele_ui/environment_access_bridge.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:flutter/material.dart';

import 'source_documents.dart';

class ContributionSourcePort implements SourceDocumentPort {
  @override
  List<String> keys() => readContributionKeys();
  @override
  Map<String, dynamic> read(String id) {
    final data = readContributionData(id);
    final copy = <String, dynamic>{};
    for (final key in data.keys) {
      copy[key] = data[key];
    }
    return copy;
  }

  @override
  bool write(String id, Map<String, dynamic> data) =>
      writeContributionData(id, data);
  @override
  bool remove(String id) => removeContributionData(id);
  @override
  String allocateId() => allocateContributionId();
  @override
  Future<bool> createEditor(String id, String text, String language) =>
      createContributionCodeEditor(id, text, language);
  @override
  Map<String, dynamic> editorState(String id) =>
      readContributionCodeEditorState(id);
  @override
  Map<String, dynamic> snapshot(String id) =>
      snapshotContributionCodeEditor(id);
  @override
  bool releaseEditor(String id) => releaseContributionCodeEditor(id);
  @override
  Future<Map<String, dynamic>> readFile(String path) =>
      readEnvironmentTextFile(path);
  @override
  Future<Map<String, dynamic>> replaceFile(
    String path,
    String text,
    String expectedRevision,
  ) => replaceEnvironmentTextFile(path, text, expectedRevision);
  @override
  Future<bool> confirmDiscard(String message) =>
      confirmContribution(<String, dynamic>{
        'title': 'Discard unsaved changes?',
        'message': message,
        'acceptLabel': 'Discard',
        'cancelLabel': 'Cancel',
      });
}

SourceDocuments sourceDocuments() {
  final context = readMainContentContext();
  final environmentKey = context['environmentKey'];
  return SourceDocuments(
    ContributionSourcePort(),
    environmentKey is String ? environmentKey : '',
  );
}

String sourceArgument(String key) {
  final arguments = readContributionArguments();
  if (arguments == null) return '';
  final value = arguments[key];
  return value is String ? value : '';
}

Future<Map<String, dynamic>> displaySource() {
  final documents = sourceDocuments();
  final path = sourceArgument('path');
  return documents.display(path);
}

Future<Map<String, dynamic>> saveSource() {
  final documents = sourceDocuments();
  final id = sourceArgument('id');
  return documents.save(id);
}

Future<Map<String, dynamic>> closeSource() {
  final documents = sourceDocuments();
  final id = sourceArgument('id');
  return documents.close(id);
}

Future<Map<String, dynamic>> closeSources() => sourceDocuments().exit();

void initializeSource() {
  final documents = sourceDocuments();
  final records = documents.documents(false);
  final ids = <String>[];
  for (final data in records) {
    ids.add(data['id'] as String);
  }
  final current = readMainContentPanes();
  final existing = <String>[];
  for (final pane in current) {
    final id = pane['id'] as String;
    if (ids.contains(id)) {
      existing.add(id);
    } else {
      removeMainContentPane(id);
    }
  }
  for (final data in records) {
    final id = data['id'] as String;
    final title = sourceTitle(data);
    if (existing.contains(id)) {
      setMainContentPaneTitle(id, title);
    } else {
      openMainContentPane(id, title, true);
    }
  }
  setMainContentPaneOrder(ids);
}

Widget sourcePane() => SourcePane();
Widget openSourceInput() => OpenSourceInput();

Widget sourceButton(String label, bool enabled, void Function() callback) {
  if (enabled) return TextButton(onPressed: callback, child: Text(label));
  return Padding(
    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Text(label, style: TextStyle(color: Colors.grey)),
  );
}

class SourcePane extends StatefulWidget {
  @override
  State<SourcePane> createState() => SourcePaneState();
}

class SourcePaneState extends State<SourcePane> {
  final SourceDocuments documents = sourceDocuments();
  final String id = readMainContentPaneId();
  final String handle = requestCodeEditor();
  late Widget editor;
  void Function() editorListener = () {};
  void Function() dataListener = () {};
  Map<String, dynamic> data = <String, dynamic>{};
  String failure = '';
  bool pending = false;
  bool alive = true;

  bool active() {
    if (!alive) return false;
    final context = readMainContentContext();
    return readContributionArguments() != null &&
        context['environmentKey'] == documents.environmentKey &&
        readMainContentPaneId() == id;
  }

  @override
  void initState() {
    super.initState();
    editor = buildCodeEditor(handle);
    editorListener = () => refresh();
    dataListener = () => refresh();
    subscribeCodeEditor(handle, editorListener);
    subscribeContribution(dataListener);
    final state = readCodeEditorState(handle);
    if (state['ready'] == true) {
      final snapshot = snapshotCodeEditor(handle);
      documents.observeSnapshot(id, snapshot);
    }
    refresh();
  }

  void refresh() {
    if (!active()) return;
    final state = readCodeEditorState(handle);
    documents.invalidate(id, state);
    final current = documents.document(id);
    setState(() {
      data = current;
    });
    if (current.isNotEmpty) setMainContentPaneTitle(id, sourceTitle(current));
  }

  bool canAct() =>
      active() &&
      !pending &&
      data.isNotEmpty &&
      data['saving'] != true &&
      data['closing'] != true;

  Future<void> perform(String operation) async {
    if (!canAct()) return;
    setState(() {
      pending = true;
      failure = '';
    });
    final result = await invokeContributionOperation(
      operation,
      <String, dynamic>{'id': id},
    );
    if (!active()) return;
    // Keep bridged maps out of a captured setState closure on the evaluator pin.
    var nextFailure = '';
    if (result['ok'] != true) nextFailure = sourceFailureText(result);
    setState(() {
      pending = false;
      failure = nextFailure;
    });
    refresh();
  }

  void reorder(int direction) {
    if (!canAct()) return;
    if (documents.move(id, direction)) initializeSource();
  }

  @override
  void dispose() {
    alive = false;
    unsubscribeCodeEditor(handle, editorListener);
    unsubscribeContribution(dataListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final path = data['path'];
    var status = 'Saved';
    if (data['dirty'] == true) status = 'Possibly modified';
    if (data['saving'] == true) status = 'Saving...';
    if (data['closing'] == true) status = 'Confirming Close...';
    if (data['conflict'] == true) status = 'Save conflict';
    final providerFailure = data['failure'];
    var message = failure;
    if (providerFailure != null && providerFailure.isNotEmpty == true) {
      if (data['saving'] != true &&
          data['closing'] != true &&
          data['conflict'] != true) {
        status = 'Save unconfirmed';
      }
      final result = <String, dynamic>{'failure': providerFailure};
      message = sourceFailureText(result);
      message =
          '$message\nText is retained. Copy any local changes you need before '
          'discarding. To reconcile: Close, choose Discard '
          'if prompted, then reopen the path. No automatic retry.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('$path'),
              Text(status),
              Row(
                children: <Widget>[
                  sourceButton('Save', canAct(), () => perform('save')),
                  sourceButton('Close', canAct(), () => perform('close')),
                ],
              ),
              Row(
                children: <Widget>[
                  sourceButton('Move left', canAct(), () => reorder(-1)),
                  sourceButton('Move right', canAct(), () => reorder(1)),
                ],
              ),
              if (message.isNotEmpty) Text(message),
            ],
          ),
        ),
        Expanded(flex: 1, child: editor),
      ],
    );
  }
}

class OpenSourceInput extends StatefulWidget {
  @override
  State<OpenSourceInput> createState() => OpenSourceInputState();
}

class OpenSourceInputState extends State<OpenSourceInput> {
  final SourceDocuments documents = sourceDocuments();
  String path = '';
  String status = '';
  bool pending = false;
  bool alive = true;

  bool active() {
    if (!alive || documents.environmentKey.isEmpty) return false;
    final context = readMainContentContext();
    return readContributionArguments() != null &&
        context['environmentKey'] == documents.environmentKey;
  }

  Future<void> open() async {
    if (!active() || pending || path.isEmpty) return;
    final requestedPath = path;
    setState(() {
      pending = true;
      status = 'Opening...';
    });
    // This is the exact operation used by the public DisplaySourceFile provider.
    final result = await invokeContributionOperation(
      'display',
      <String, dynamic>{'path': requestedPath},
    );
    if (!active()) return;
    var nextStatus = 'Source Document opened.';
    if (result['ok'] != true) nextStatus = sourceFailureText(result);
    setState(() {
      pending = false;
      status = nextStatus;
    });
  }

  @override
  void dispose() {
    alive = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(16),
    children: <Widget>[
      Text('Open Source File'),
      Text('Existing path relative to the Session Environment'),
      TextField(
        enabled: active() && !pending,
        onChanged: (String value) {
          if (!active() || pending) return;
          setState(() {
            path = value;
          });
        },
        onSubmitted: (String value) {
          if (!active() || pending) return;
          path = value;
          open();
        },
      ),
      sourceButton('Open', active() && !pending && path.isNotEmpty, open),
      if (status.isNotEmpty) Text(status),
    ],
  );
}
