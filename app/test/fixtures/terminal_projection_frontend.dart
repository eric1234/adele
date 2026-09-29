import 'package:adele_ui/terminal_projection_bridge.dart';
import 'package:flutter/material.dart';

String requestRows(int rows) => requestTerminalProjection(rows);
Widget buildHandle(String handle) => buildTerminalProjection(handle);
int feedHandle(String handle, String text, int budget) =>
    feedTerminalProjection(handle, text, budget);
Map<String, dynamic> readHandle(String handle) =>
    readTerminalProjection(handle);
void resetHandle(String handle) => resetTerminalProjection(handle);
Future<bool> yieldHandle(String handle) => yieldTerminalProjection(handle);
void followHandle(String handle, bool following) =>
    setTerminalProjectionFollow(handle, following);
void scrollHandle(String handle, double offset) =>
    scrollTerminalProjection(handle, offset);

Widget buildProjection() => ProjectionProbe();

class ProjectionProbe extends StatefulWidget {
  @override
  State<ProjectionProbe> createState() => ProjectionProbeState();
}

class ProjectionProbeState extends State<ProjectionProbe> {
  late String handle;
  late Widget nativeView;
  late void Function() listener;
  int notifications = 0;

  @override
  void initState() {
    super.initState();
    handle = requestTerminalProjection(6);
    nativeView = buildTerminalProjection(handle);
    listener = () {
      setState(() {
        notifications++;
      });
    };
    subscribeTerminalProjection(handle, listener);
    feedTerminalProjection(handle, 'initial\noutput', 6);
  }

  @override
  void dispose() {
    unsubscribeTerminalProjection(handle, listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('Notifications: $notifications'),
      TextButton(
        onPressed: () => feedTerminalProjection(handle, '\nappended', 6),
        child: const Text('Append'),
      ),
      TextButton(
        onPressed: () => resetTerminalProjection(handle),
        child: const Text('Reset'),
      ),
      TextButton(
        onPressed: () => setTerminalProjectionFollow(handle, false),
        child: const Text('Freeze'),
      ),
      TextButton(
        onPressed: () => feedTerminalProjection(handle, 'x\x1b[999999999b', 6),
        child: const Text('Unsupported REP'),
      ),
      SizedBox(width: 480, height: 130, child: nativeView),
    ],
  );
}
