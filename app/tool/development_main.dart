import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:flutter/material.dart';

import 'session_evidence_exporter.dart';

void main() {
  final navigator = GlobalKey<NavigatorState>();
  late NativeAdeleRuntime runtime;
  runApp(
    AdeleApplication(
      navigatorKey: navigator,
      createRuntime: () => runtime = NativeAdeleRuntime(),
      attachSessionContext: (context) => SessionEvidenceExporter(
        runtime: runtime,
        context: context,
        navigatorKey: navigator,
      ).close,
    ),
  );
}
