import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_eval/widgets.dart';

import 'prepared_frontend.dart';

const _library = 'package:adele_ui/presentation_dialog.dart';
const _material = 'package:flutter/material.dart';
const _choiceChip = BridgeTypeRef(BridgeTypeSpec(_material, 'ChoiceChip'));

class PresentationDialogDeclarations implements EvalPlugin {
  const PresentationDialogDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const context = BridgeParameter(
      'context',
      BridgeTypeAnnotation($BuildContext.$type),
      false,
    );
    const widget = BridgeTypeAnnotation($Widget.$type);
    const boolean = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool));
    const nothing = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType));
    for (final (name, returns, params) in [
      (
        'showPresentationDialog',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future, [nothing])),
        const [context, BridgeParameter('child', widget, false)],
      ),
      ('isPresentationDialogCurrent', boolean, const [context]),
      ('dismissPresentationDialog', nothing, const [context]),
    ]) {
      registry.defineBridgeTopLevelFunction(
        BridgeFunctionDeclaration(
          _library,
          name,
          BridgeFunctionDef(returns: returns, params: params),
        ),
      );
    }
    // flutter_eval's Material library does not expose ChoiceChip at the pin.
    registry.defineBridgeClass(
      const BridgeClassDef(
        BridgeClassType(_choiceChip, $extends: $Widget.$type),
        constructors: {
          '': BridgeConstructorDef(
            BridgeFunctionDef(
              returns: BridgeTypeAnnotation(_choiceChip),
              namedParams: [
                BridgeParameter('label', widget, false),
                BridgeParameter('selected', boolean, false),
                BridgeParameter(
                  'onSelected',
                  BridgeTypeAnnotation(
                    BridgeTypeRef(CoreTypes.function),
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
  void configureForRuntime(Runtime runtime) => throw UnsupportedError(
    'Use a presentation-scoped PresentationDialogBridge.',
  );
}

/// Retains only the route opened by this presentation. Dismissal never pops a
/// replacement dialog or another route above the one being retired.
final class PresentationDialogBridge extends PresentationDialogDeclarations
    implements PreparedFrontendBridge {
  DialogRoute<void>? _route;
  bool _active = true;

  Future<void> _show(BuildContext context, Widget child) async {
    if (!_active || _route != null || !context.mounted) return;
    final navigator = Navigator.of(context);
    late final DialogRoute<void> route;
    route = DialogRoute<void>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (_) => _DialogScope(
        route: route,
        child: Dialog(child: child),
      ),
    );
    _route = route;
    try {
      await navigator.push(route);
    } finally {
      if (identical(_route, route)) _route = null;
    }
  }

  bool _current(BuildContext context) {
    final route = _route;
    return _active &&
        route != null &&
        route.isCurrent &&
        context.mounted &&
        identical(
          context.getInheritedWidgetOfExactType<_DialogScope>()?.route,
          route,
        );
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime
      ..registerBridgeFunc(_library, 'showPresentationDialog', (_, _, args) {
        return $Future.wrap(
          _show(
            args[0]!.$value as BuildContext,
            args[1]!.$value as Widget,
          ).then((_) => const $null()),
        );
      })
      ..registerBridgeFunc(_library, 'isPresentationDialogCurrent', (
        _,
        _,
        args,
      ) {
        return $bool(_current(args.single!.$value as BuildContext));
      })
      ..registerBridgeFunc(_library, 'dismissPresentationDialog', (_, _, args) {
        if (_current(args.single!.$value as BuildContext)) {
          _route!.navigator!.pop();
        }
        return null;
      })
      ..registerBridgeFunc(_material, 'ChoiceChip.', (_, _, args) {
        return $Widget.wrap(
          ChoiceChip(
            label: args[0]!.$value as Widget,
            selected: args[1]!.$value as bool,
            onSelected: switch (args[2]) {
              final EvalCallable callback => (selected) => callback.call(
                runtime,
                null,
                [$bool(selected)],
              ),
              _ => null,
            },
          ),
        );
      });
  }

  @override
  void invalidate() {
    _active = false;
    final route = _route;
    _route = null;
    if (route == null) return;
    void remove() {
      final navigator = route.navigator;
      if (navigator != null && navigator.mounted && route.isActive) {
        navigator.removeRoute(route);
      }
    }

    // A parent may retire its interpreted child during build or disposal.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => remove());
    } else {
      remove();
    }
  }
}

final class _DialogScope extends InheritedWidget {
  const _DialogScope({required this.route, required super.child});
  final DialogRoute<void> route;

  @override
  bool updateShouldNotify(_DialogScope oldWidget) => oldWidget.route != route;
}
