import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/widgets.dart';
// The pinned evaluator does not publicly export its BoxConstraints wrapper.
// ignore: implementation_imports
import 'package:flutter_eval/src/rendering/box.dart';
import 'package:flutter_eval/widgets.dart';

import 'prepared_frontend.dart';

/// Adds Flutter's LayoutBuilder to the pinned evaluator's Material surface.
/// This bridge owns no subscriptions or product authority.
final class LayoutBuilderBridge implements PreparedFrontendBridge {
  const LayoutBuilderBridge();

  static const _library = 'package:flutter/material.dart';
  static const _type = BridgeTypeRef(BridgeTypeSpec(_library, 'LayoutBuilder'));

  @override
  String get identifier => 'dev.adele.frontend.layout-builder';

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeClass(
      const BridgeClassDef(
        BridgeClassType(_type, $extends: $Widget.$type),
        constructors: {
          '': BridgeConstructorDef(
            BridgeFunctionDef(
              returns: BridgeTypeAnnotation(_type),
              namedParams: [
                BridgeParameter(
                  'builder',
                  BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.function)),
                  false,
                ),
              ],
            ),
          ),
        },
        wrap: true,
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(_library, 'LayoutBuilder.', (_, _, args) {
      final builder = args.single! as EvalCallable;
      return $Widget.wrap(
        LayoutBuilder(
          builder: (context, constraints) =>
              builder.call(runtime, null, [
                    $BuildContext.wrap(context),
                    $BoxConstraints.wrap(constraints),
                  ])!.$value
                  as Widget,
        ),
      );
    });
  }

  @override
  void invalidate() {}
}
