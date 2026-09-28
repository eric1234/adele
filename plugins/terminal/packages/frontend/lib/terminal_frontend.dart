import 'package:adele_ui/environment_terminal_bridge.dart';
import 'package:adele_ui/terminal_surface_bridge.dart';
import 'package:flutter/widgets.dart';

/// The host renders this action in its shared console chrome. Its native adapter
/// retains the policy, not a callback into this short-lived operation runtime.
Future<List<dynamic>> newTerminal() => openEnvironmentTerminal(
  'Terminal',
  'This terminal may have running work. Close it and attempt to stop its shell?',
  true,
  true,
);

/// Each presentation receives fresh access to exactly one retained resource.
Widget buildTerminal() => buildTerminalSurface(requestTerminalSurface());
