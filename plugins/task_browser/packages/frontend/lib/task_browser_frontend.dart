import 'package:adele_ui/task_browser_bridge.dart';
import 'package:flutter/material.dart';

Widget createTaskBrowser() => TaskBrowserFrontend();

class TaskBrowserFrontend extends StatefulWidget {
  @override
  State<TaskBrowserFrontend> createState() => _TaskBrowserFrontendState();
}

class _TaskBrowserFrontendState extends State<TaskBrowserFrontend> {
  final TextEditingController searchController = TextEditingController();
  final TextEditingController titleController = TextEditingController();
  // Explicit null initialization is required by the pinned evaluator.
  // ignore: avoid_init_to_null
  Map<String, dynamic>? snapshot = null;
  void Function() listener = () {};
  String query = '';
  String failure = '';
  String readFailure = '';
  String busyLabel = '';
  int formGeneration = 0;
  bool showNewTask = false;
  bool showDetail = false;
  bool disposed = false;

  @override
  void initState() {
    super.initState();
    listener = () => refresh();
    subscribeTaskBrowser(listener);
    refresh();
  }

  void refresh() {
    if (disposed || !isTaskBrowserActive()) return;
    try {
      final bool firstSnapshot = snapshot == null;
      final next = readTaskBrowser();
      final bool hasSelectedTask = next['selectedTask'] != null;
      setState(() {
        if (firstSnapshot) showDetail = hasSelectedTask;
        snapshot = next;
        readFailure = '';
      });
    } catch (_) {
      setState(() {
        readFailure = 'Task Browser could not refresh. Retry to load tasks.';
      });
    }
  }

  bool canAct() =>
      !disposed &&
      busyLabel.isEmpty &&
      readFailure.isEmpty &&
      snapshot != null &&
      isTaskBrowserActive();

  Future<void> perform(String action, String? value) async {
    if (!canAct()) return;
    if (action == 'createTask') {
      if (!showNewTask || value!.trim().isEmpty) return;
    }
    setState(() {
      failure = '';
      busyLabel = 'Selecting Task...';
      if (action == 'createTask') busyLabel = 'Creating Task...';
      if (action == 'createSession') busyLabel = 'Creating Session...';
      if (action == 'openSession') busyLabel = 'Opening Session...';
    });
    List<dynamic> result = <dynamic>[];
    if (action == 'createTask') {
      result = await createTask(value!.trim());
    } else if (action == 'selectTask') {
      result = await selectTask(value);
    } else if (action == 'createSession') {
      result = await createSession(value!);
    } else {
      result = await openSession(value!);
    }
    if (disposed || !isTaskBrowserActive()) return;
    setState(() {
      busyLabel = '';
      if (result[0] == true) {
        if (action == 'createTask') {
          titleController.clear();
          showNewTask = false;
          formGeneration++;
        }
        if (action == 'selectTask' || action == 'createTask') {
          showDetail = value != null;
        }
      } else {
        failure = result[1] as String;
      }
    });
    refresh();
  }

  @override
  void dispose() {
    disposed = true;
    unsubscribeTaskBrowser(listener);
    searchController.dispose();
    titleController.dispose();
    super.dispose();
  }

  Widget heading(String text) =>
      Text(text, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold));

  Widget actionButton(
    String label,
    bool enabled,
    void Function() onPressed, {
    bool prominent = false,
  }) {
    // The pin does not accept nullable TextButton.onPressed callbacks.
    if (enabled) {
      if (prominent) {
        return ElevatedButton(onPressed: onPressed, child: Text(label));
      }
      return TextButton(onPressed: onPressed, child: Text(label));
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(label, style: TextStyle(color: Colors.grey)),
    );
  }

  bool canEditForm(int generation) =>
      generation == formGeneration && showNewTask && canAct();

  Widget newTaskForm(int generation) => Card(
    child: Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Task title'),
          TextField(
            controller: titleController,
            enabled: canAct(),
            onChanged: (String value) {
              if (!canEditForm(generation)) return;
              setState(() {});
            },
            onSubmitted: (String value) {
              if (!canEditForm(generation)) return;
              perform('createTask', value);
            },
          ),
          SizedBox(height: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              actionButton(
                'Create Task',
                canAct() && titleController.text.trim().isNotEmpty,
                () {
                  if (!canEditForm(generation)) return;
                  perform('createTask', titleController.text);
                },
              ),
              actionButton('Cancel', canAct(), () {
                if (!canEditForm(generation)) return;
                setState(() {
                  titleController.clear();
                  showNewTask = false;
                  formGeneration++;
                  failure = '';
                });
              }),
            ],
          ),
        ],
      ),
    ),
  );

  // Keep each callback in its own call frame: eval loop closures otherwise
  // capture reused loop slots and can dispatch another row's identity.
  void Function() actionCallback(String action, String identity) =>
      () => perform(action, identity);

  // Keep nested bridge data dynamic across helper call boundaries.
  Widget taskRow(dynamic task, bool selected) {
    final String id = task['id'] as String;
    final String title = task['title'] as String;
    final int count = task['sessionCount'] as int;
    final counts = task['executionCounts'];
    final int preparing = counts['preparing'] as int;
    final int running = counts['running'] as int;
    final int waiting = counts['waiting'] as int;
    final int terminal = counts['terminal'] as int;
    final int failed = counts['failed'] as int;
    final String sessions = count == 1 ? '1 Session' : '$count Sessions';
    return ListTile(
      title: Text(title),
      subtitle: Text(
        '$sessions\n$preparing preparing | $running running | '
        '$waiting waiting | $terminal terminal ($failed failed)',
      ),
      isThreeLine: true,
      selected: selected,
      enabled: canAct(),
      onTap: actionCallback('selectTask', id),
    );
  }

  Widget taskList(dynamic current) {
    final tasks = current['tasks'] as List<dynamic>;
    final selectedId = current['selectedTaskId'];
    final children = <Widget>[
      heading('Tasks'),
      SizedBox(height: 16),
      Text('Search tasks'),
      TextField(
        controller: searchController,
        onChanged: (String value) {
          if (disposed || !isTaskBrowserActive()) return;
          setState(() {
            query = value.toLowerCase();
          });
        },
      ),
      SizedBox(height: 8),
      actionButton('New Task', canAct(), () {
        if (!canAct() || showNewTask) return;
        setState(() {
          formGeneration++;
          showNewTask = true;
          failure = '';
        });
      }, prominent: true),
    ];
    if (showNewTask) children.add(newTaskForm(formGeneration));
    int matches = 0;
    for (final task in tasks) {
      final title = task['title'] as String;
      if (title.toLowerCase().contains(query)) {
        // The pin can unbox an already-pushed map while evaluating a later
        // argument that indexes the same map. Finish that work before the call.
        final bool selected = task['id'] == selectedId;
        children.add(taskRow(task, selected));
        matches++;
      }
    }
    if (tasks.isEmpty) {
      children.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('No Tasks yet. Create a Task to get started.'),
        ),
      );
    } else if (matches == 0) {
      children.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('No Tasks match your search.'),
        ),
      );
    }
    return ListView(padding: EdgeInsets.all(16), children: children);
  }

  Widget sessionRow(dynamic session) {
    final String id = session['id'] as String;
    final String strategy = session['strategyId'] as String;
    final String name = session['displayName'] as String;
    final bool canOpen = session['canOpen'] == true;
    final bool executionAvailable = session['executionAvailable'] == true;
    final labels = <String, String>{
      'idle': 'Idle',
      'preparing': 'Preparing',
      'running': 'Running',
      'waitingForApproval': 'Waiting for approval',
      'completed': 'Completed',
      'cancelled': 'Cancelled',
      'failed': 'Failed',
    };
    final String status = labels[session['executionStatus']] as String;
    final String availability = executionAvailable
        ? ''
        : '\nExecution unavailable';
    return ListTile(
      title: Text(name),
      subtitle: Text(
        'Session: $id\nStrategy: $strategy\nStatus: $status$availability',
      ),
      isThreeLine: true,
      trailing: Text(canOpen ? 'Open' : 'Unavailable'),
      enabled: canOpen && canAct(),
      onTap: actionCallback('openSession', id),
    );
  }

  Widget sessionChoice(dynamic option, bool direct) {
    final String handle = option['opaqueHandle'] as String;
    final String label = option['displayName'] as String;
    if (direct) {
      return actionButton(
        'New $label Session',
        canAct(),
        actionCallback('createSession', handle),
      );
    }
    return ListTile(
      title: Text(label),
      enabled: canAct(),
      onTap: actionCallback('createSession', handle),
    );
  }

  Widget taskDetail(dynamic current, bool wide) {
    final selected = current['selectedTask'];
    if (selected == null) {
      return Padding(
        padding: EdgeInsets.all(24),
        child: Text('Select a Task to view its Environment and Sessions.'),
      );
    }
    final task = selected;
    final environment = task['primaryEnvironment'];
    final sessions = task['sessions'] as List<dynamic>;
    final options = task['sessionCreationOptions'] as List<dynamic>;
    final children = <Widget>[];
    if (!wide) {
      children.add(
        actionButton('Back to Tasks', canAct(), () {
          if (!canAct()) return;
          setState(() {
            showDetail = false;
          });
        }),
      );
    }
    children.add(heading(task['title'] as String));
    children.add(Text('Task: ${task['id']}'));
    children.add(SizedBox(height: 16));
    children.add(
      Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Primary Environment',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              if (environment == null)
                Text('No primary Environment is available.'),
              if (environment != null)
                Text('Environment: ${environment['id']}'),
              if (environment != null)
                Text('Provider: ${environment['providerId']}'),
            ],
          ),
        ),
      ),
    );
    children.add(SizedBox(height: 24));
    children.add(heading('Sessions'));
    if (sessions.isEmpty) {
      children.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('No Sessions in this Task.'),
        ),
      );
    }
    for (final session in sessions) {
      children.add(sessionRow(session));
    }
    children.add(SizedBox(height: 16));
    if (options.isEmpty) {
      children.add(actionButton('New Session', false, () {}));
      children.add(Text('No Session creation strategy is available.'));
    } else {
      if (options.length > 1) {
        children.add(Text('New Session: choose a strategy'));
      }
      final bool direct = options.length == 1;
      for (final option in options) {
        children.add(sessionChoice(option, direct));
      }
    }
    return ListView(padding: EdgeInsets.all(16), children: children);
  }

  Widget content(bool wide) {
    final current = snapshot;
    if (current == null) {
      return Center(
        child: Text(
          readFailure.isEmpty
              ? 'Loading Task Browser...'
              : 'Task Browser is unavailable.',
        ),
      );
    }
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(width: 320, child: Card(child: taskList(current))),
          Expanded(flex: 1, child: taskDetail(current, true)),
        ],
      );
    }
    if (showDetail && current['selectedTask'] != null) {
      // A distinct subtree prevents inheriting the Task list's scroll offset.
      return Padding(
        padding: EdgeInsets.all(0),
        child: taskDetail(current, false),
      );
    }
    return taskList(current);
  }

  @override
  Widget build(BuildContext context) {
    final current = snapshot;
    final children = <Widget>[
      Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            heading('Task Browser'),
            if (current != null)
              Text('Project: ${current['project']['displayName']}'),
          ],
        ),
      ),
    ];
    if (busyLabel.isNotEmpty) children.add(Text(busyLabel));
    if (failure.isNotEmpty) {
      children.add(Padding(padding: EdgeInsets.all(16), child: Text(failure)));
    }
    if (readFailure.isNotEmpty) {
      children.add(Text(readFailure));
      children.add(
        TextButton(onPressed: () => refresh(), child: Text('Retry')),
      );
    }
    children.add(
      Expanded(
        flex: 1,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) =>
              content(constraints.maxWidth >= 760),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
