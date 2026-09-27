import 'package:flutter/widgets.dart';

/// Requests access to the single native surface selected by this presentation's
/// host. The opaque handle is valid only in this exact presentation.
///
/// This grants presentation, not construction, output feeding, configuration,
/// execution, or disposal. The host alone selects interactive/read-only behavior.
String requestTerminalSurface() => throw UnsupportedError(
  'Terminal surface access is available only to interpreted frontends.',
);

/// Builds the native view for an issued handle. Its access remains revocable
/// after construction, including while the widget is retained during exit.
/// Only one mounted view may attach to a surface at a time.
Widget buildTerminalSurface(String handle) => throw UnsupportedError(
  'Terminal surface access is available only to interpreted frontends.',
);
