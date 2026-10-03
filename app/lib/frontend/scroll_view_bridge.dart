import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/painting.dart';
import 'package:flutter_eval/widgets.dart';

/// Supplies the vertical child/padding constructor missing from the pinned
/// evaluator. Layout remains frontend-chosen; this grants no product services.
final class ScrollViewBridge implements EvalPlugin {
  const ScrollViewBridge();

  static const _library = 'package:flutter/material.dart';
  static const _type = BridgeTypeRef(
    BridgeTypeSpec(_library, 'SingleChildScrollView'),
  );

  @override
  String get identifier => 'dev.adele.frontend.scroll-view';

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
                  'child',
                  BridgeTypeAnnotation($Widget.$type),
                  false,
                ),
                BridgeParameter(
                  'padding',
                  BridgeTypeAnnotation(
                    $EdgeInsetsGeometry.$type,
                    nullable: true,
                  ),
                  true,
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
    runtime.registerBridgeFunc(_library, 'SingleChildScrollView.', (
      _,
      _,
      args,
    ) {
      return $Widget.wrap(
        SingleChildScrollView(
          child: args[0]!.$value as Widget,
          padding: args[1]?.$value as EdgeInsetsGeometry?,
        ),
      );
    });
  }
}
