import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// One application-owned binding, scoped to the shell route rather than dialogs.
final class CommandPaletteShortcut extends StatelessWidget {
  const CommandPaletteShortcut({
    super.key,
    required this.canInvoke,
    required this.onInvoke,
    required this.child,
  });

  final bool Function() canInvoke;
  final VoidCallback onInvoke;
  final Widget child;

  SingleActivator get _activator => SingleActivator(
    LogicalKeyboardKey.keyP,
    control: defaultTargetPlatform != TargetPlatform.macOS,
    meta: defaultTargetPlatform == TargetPlatform.macOS,
    shift: true,
    includeRepeats: false,
  );

  bool _isEnabled(BuildContext context) =>
      ModalRoute.isCurrentOf(context) == true && canInvoke();

  /// Native input encoders yield only an applicable chord in this scope.
  /// Yielding is not admission: the action and Command revalidate afterward.
  static SingleActivator? maybeOf(BuildContext context) {
    final scope = context
        .findAncestorWidgetOfExactType<CommandPaletteShortcut>();
    return scope != null && scope._isEnabled(context) ? scope._activator : null;
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: {_activator: const _ShowCommandPaletteIntent()},
    child: Actions(
      actions: {
        _ShowCommandPaletteIntent: _ShowCommandPaletteAction(
          () => _isEnabled(context),
          onInvoke,
        ),
      },
      // Give the empty pre-Project shell a focus target, without a Tab stop.
      child: Focus(autofocus: true, skipTraversal: true, child: child),
    ),
  );
}

final class _ShowCommandPaletteIntent extends Intent {
  const _ShowCommandPaletteIntent();
}

final class _ShowCommandPaletteAction
    extends Action<_ShowCommandPaletteIntent> {
  _ShowCommandPaletteAction(this.canInvoke, this.onInvoke);

  final bool Function() canInvoke;
  final VoidCallback onInvoke;

  @override
  bool isEnabled(_ShowCommandPaletteIntent intent) => canInvoke();

  @override
  void invoke(_ShowCommandPaletteIntent intent) => onInvoke();
}
