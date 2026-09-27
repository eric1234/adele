import 'package:adele_ui/terminal_surface_bridge.dart';
import 'package:flutter/material.dart';

Widget buildView() => TerminalFixture();

Widget buildFabricatedView() => buildTerminalSurface('fabricated');

String requestHandle() => requestTerminalSurface();

Widget buildHandle(String handle) => buildTerminalSurface(handle);

class TerminalFixture extends StatefulWidget {
  @override
  State<TerminalFixture> createState() => TerminalFixtureState();
}

class TerminalFixtureState extends State<TerminalFixture> {
  // Deliberately cache the widget: native revocation must survive this cache.
  final Widget terminal = buildTerminalSurface(requestTerminalSurface());
  bool visible = true;
  bool wide = false;
  bool failed = false;
  int rebuilds = 0;

  @override
  Widget build(BuildContext context) {
    if (failed) throw StateError('deterministic terminal fixture failure');
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            TextButton(
              onPressed: () {
                setState(() {
                  rebuilds++;
                });
              },
              child: Text('Rebuild'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  visible = !visible;
                });
              },
              child: Text('Toggle'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  wide = !wide;
                });
              },
              child: Text('Resize'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  failed = true;
                });
              },
              child: Text('Fail'),
            ),
          ],
        ),
        Text('Rebuilds: $rebuilds'),
        if (visible)
          SizedBox(width: wide ? 560.0 : 400.0, height: 240, child: terminal),
      ],
    );
  }
}
