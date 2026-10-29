import 'dart:async';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';

import 'prepared_frontend.dart';
import 'session_feedback_source.dart';
import 'structured_bridge_data.dart';

const _library = 'package:adele_ui/session_feedback_bridge.dart';

class SessionFeedbackDeclarations implements EvalPlugin {
  const SessionFeedbackDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    for (final name in const [
      'readSessionFeedbackAvailability',
      'acceptSessionFeedback',
      'lookupSessionFeedback',
      'startSessionFeedbackRun',
      'lookupSessionFeedbackRun',
    ]) {
      final read = name == 'readSessionFeedbackAvailability';
      registry.defineBridgeTopLevelFunction(
        BridgeFunctionDeclaration(
          _library,
          name,
          BridgeFunctionDef(
            returns: read
                ? structuredBridgeMapType
                : const BridgeTypeAnnotation(
                    BridgeTypeRef(CoreTypes.future, [structuredBridgeMapType]),
                  ),
            params: [
              if (!read)
                const BridgeParameter('canonicalPayload', string, false),
              if (name.endsWith('Run'))
                const BridgeParameter('occurrenceId', string, false),
              if (name == 'startSessionFeedbackRun')
                const BridgeParameter(
                  'schedulingAttempt',
                  BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.int)),
                  false,
                ),
            ],
          ),
        ),
      );
    }
  }

  @override
  void configureForRuntime(Runtime runtime) =>
      throw UnsupportedError('Use a presentation-bound feedback bridge.');
}

/// The bridge exposes no channel, route, Session selector or general execution
/// controls. Invalidation fences publication, not an already admitted effect.
final class SessionFeedbackBridge extends SessionFeedbackDeclarations
    implements PreparedFrontendBridge {
  SessionFeedbackBridge({this.source});

  final SessionFeedbackPresentationSource? source;
  final Zone _zone = Zone.current;
  bool _active = true;

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(
      _library,
      'readSessionFeedbackAvailability',
      (_, _, _) => wrapStructuredBridgeData(
        _active && source != null
            ? source!.readAvailability()
            : const {
                'available': false,
                'canStart': false,
                'reason': 'Session feedback is unavailable for this pane.',
              },
      ),
    );
    for (final name in const [
      'acceptSessionFeedback',
      'lookupSessionFeedback',
      'startSessionFeedbackRun',
      'lookupSessionFeedbackRun',
    ]) {
      runtime.registerBridgeFunc(_library, name, (_, _, args) {
        final completion = Completer<$Value>();
        _zone.run(() async {
          Map<String, Object?> result;
          try {
            if (!_active || source == null) {
              throw StateError('Session feedback presentation is unavailable.');
            }
            final payload = args.first!.$value as String;
            result = switch (name) {
              'acceptSessionFeedback' => await source!.accept(payload),
              'lookupSessionFeedback' => await source!.lookup(payload),
              'startSessionFeedbackRun' => await source!.startRun(
                payload,
                args[1]!.$value as String,
                args[2]!.$value as int,
              ),
              _ => await source!.lookupRun(payload, args[1]!.$value as String),
            };
            if (!_active || !source!.isActive) {
              throw StateError('Session feedback presentation is retired.');
            }
          } on Object {
            result = const {
              'status': 'uncertain',
              'code': 'presentation_unavailable',
              'message': 'Reopen Diff and reconcile the retained review.',
            };
          }
          completion.complete(wrapStructuredBridgeData(result));
        });
        return $Future<$Value>.wrap(completion.future);
      });
    }
  }

  @override
  void invalidate() {
    _active = false;
    source?.invalidate();
  }
}
