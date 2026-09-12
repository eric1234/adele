import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_desktop/ui/theme/adele_theme.dart';
import 'package:flutter/material.dart';

final class AdeleApplication extends StatefulWidget {
  const AdeleApplication({super.key, this.createRuntime = AdeleRuntime.new});

  /// Called once when mounted; this application owns and closes the result.
  final AdeleRuntime Function() createRuntime;

  @override
  State<AdeleApplication> createState() => _AdeleApplicationState();
}

final class _AdeleApplicationState extends State<AdeleApplication> {
  late final AdeleRuntime _runtime;
  late final AppLifecycleListener _lifecycleListener;
  Future<void>? _closing;

  @override
  void initState() {
    super.initState();
    _runtime = widget.createRuntime();
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await _closeRuntime();
        return AppExitResponse.exit;
      },
      onDetach: () => unawaited(_closeRuntime()),
    );
  }

  Future<void> _closeRuntime() => _closing ??= () async {
    try {
      await _runtime.close();
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'ADELE application',
          context: ErrorDescription('while closing the application runtime'),
        ),
      );
    }
  }();

  @override
  void dispose() {
    _lifecycleListener.dispose();
    // Flutter disposal cannot await; graceful desktop exit awaits above.
    unawaited(_closeRuntime());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const AdeleShell(),
      theme: buildAdeleTheme(),
      title: 'ADELE',
    );
  }
}
