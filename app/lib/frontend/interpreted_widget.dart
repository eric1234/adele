import 'dart:async';
import 'dart:typed_data';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/flutter_eval.dart';

typedef InterpretedWidget = ({Runtime runtime, Widget widget});

/// Retains the runtime alongside its widget, preserving synchronous entrypoints.
FutureOr<InterpretedWidget> loadInterpretedWidget({
  required Uint8List bytes,
  required EvalPlugin bridge,
  required String library,
  required String entrypoint,
}) {
  final Runtime runtime = Runtime(ByteData.sublistView(bytes))
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(bridge);

  InterpretedWidget reify(Object? result) {
    final Object? widget = result is $Value ? result.$reified : result;
    if (widget is! Widget) {
      throw StateError('The interpreted entrypoint did not return a Widget.');
    }
    return (runtime: runtime, widget: widget);
  }

  final Object? pending = runtime.executeLib(library, entrypoint);
  return pending is Future<Object?> ? pending.then(reify) : reify(pending);
}
