import '../core/adele_runtime.dart';
import 'environment_terminal_owner.dart';

/// Desktop host graph with native terminal resources, separate from SDK callers.
final class NativeAdeleRuntime extends AdeleRuntime {
  NativeAdeleRuntime({super.ids, super.runIds}) {
    terminals = EnvironmentTerminalCoordinator(
      environmentRuntime: lifecycle.environmentRuntime,
    );
  }

  late final EnvironmentTerminalCoordinator terminals;
  Future<void>? _nativeClosing;

  @override
  Future<void> close() => _nativeClosing ??= _closeNative();

  Future<void> _closeNative() {
    final terminalClosing = Future<void>.sync(terminals.close);
    // Fence product admission now, but let backend teardown settle pending opens
    // after bounded terminal cleanup. The base close joins this same future.
    final productClosing = Future<void>.sync(lifecycle.close);
    return Future.wait<void>([
      productClosing,
      terminalClosing.whenComplete(super.close),
    ]).then((_) {});
  }
}
