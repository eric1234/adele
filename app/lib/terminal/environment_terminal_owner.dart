import 'dart:async';
import 'dart:collection';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';

import '../core/product_lifecycle.dart';
import 'native_terminal_surface.dart';

enum EnvironmentTerminalState {
  idle,
  opening,
  running,
  completed,
  disconnected,
  closed,
  disposed,
}

/// App-native, runtime-lifetime resources, independent of Sessions and views.
/// Each creation has its own resource identity, even in the same Environment.
/// Presentations retain their owner across remounts; finished owners remain
/// discoverable until explicitly removed.
final class EnvironmentTerminalCoordinator {
  EnvironmentTerminalCoordinator({
    required this.environmentRuntime,
    this.cleanupTimeout = const Duration(seconds: 2),
  });

  final EnvironmentRuntime environmentRuntime;
  final Duration cleanupTimeout;
  final Set<EnvironmentTerminalOwner> _owners = Set.identity();
  final Map<EnvironmentTerminalOwner, Future<void>> _removals = Map.identity();
  final _changes = _TerminalChanges();
  Future<void>? _closing;

  /// Coalesced collection invalidations only, never owner output or lifecycle.
  /// Read [forEnvironment] after subscribing; the returned detach is idempotent.
  void Function() observe(void Function() observer) =>
      _changes.observe(observer);

  EnvironmentTerminalOwner create(
    EnvironmentId environmentId, {
    required EnvironmentTerminalRequest request,
  }) {
    if (_closing != null) throw StateError('Terminal coordinator is closed.');
    final environment = environmentRuntime.store.environment(environmentId);
    if (environment == null) {
      throw StateError('Environment $environmentId is not published.');
    }
    final owner = EnvironmentTerminalOwner._(
      environmentRuntime,
      environment,
      request,
      cleanupTimeout,
    );
    _owners.add(owner);
    _changes.notify();
    return owner;
  }

  /// Immutable snapshot, including finished owners whose screens are retained.
  List<EnvironmentTerminalOwner> forEnvironment(EnvironmentId id) =>
      List.unmodifiable(_owners.where((owner) => owner.environmentId == id));

  /// Synchronously removes and fences only this exact owner, not its siblings.
  /// Repeated removal joins the same pending cleanup, including during shutdown.
  Future<void> remove(EnvironmentTerminalOwner owner) {
    final pending = _removals[owner];
    if (pending != null) return pending;
    if (!_owners.remove(owner)) return Future<void>.value();
    final removing = owner.dispose().whenComplete(() {
      _removals.remove(owner);
    });
    _removals[owner] = removing;
    _changes.notify();
    return removing;
  }

  /// Fences all owners synchronously and joins their bounded cleanup.
  Future<void> close() {
    if (_closing != null) return _closing!;
    final closing = Completer<void>();
    _closing = closing.future;
    final owners = _owners.toList();
    _owners.clear();
    for (final owner in owners) {
      _removals[owner] = owner.dispose().whenComplete(() {
        _removals.remove(owner);
      });
    }
    _changes.close();
    closing.complete(Future.wait<void>(_removals.values).then((_) {}));
    return closing.future;
  }
}

/// One lazy terminal and emulator bound to one exact Environment materialization.
/// Async provider/cleanup failures are retained here, never emitted as unhandled
/// widget callback errors. The screen survives completion, disconnect, and close.
final class EnvironmentTerminalOwner {
  EnvironmentTerminalOwner._(
    this._runtime,
    this._environment,
    this.request,
    this._cleanupTimeout,
  ) {
    _validateGraph();
    surface = NativeTerminalSurface(
      onScopedInput: (text, active) => write(text, isActive: active),
      onResponse: (text) => write(text, isActive: () => _accepting),
      onScopedResize: (columns, rows, active) => resize(
        EnvironmentTerminalDimensions(columns: columns, rows: rows),
        isActive: active,
      ),
    );
    surface.resize(request.dimensions.columns, request.dimensions.rows);
    _detachTitle = surface.observeTitle(_changes.notify);
  }

  static const int maxPendingInputCodeUnits = 65536;
  static const int maxPendingInputChunks = 128;

  final EnvironmentRuntime _runtime;
  final Environment _environment;
  final EnvironmentTerminalRequest request;
  final Duration _cleanupTimeout;
  late final NativeTerminalSurface surface;
  EnvironmentId get environmentId => _environment.id;
  EnvironmentTerminalState get state => _state;
  EnvironmentTerminalState _state = EnvironmentTerminalState.idle;
  EnvironmentTerminalCompleted? get completion => _completion;
  EnvironmentTerminalCompleted? _completion;

  /// Actual shell exit evidence, distinct from provider close or disconnect.
  bool get shellCompleted =>
      _completion?.termination == EnvironmentTerminalTermination.exited;
  String? get title => surface.title;
  Object? get error => _error;
  Object? _error;
  StackTrace? get errorStack => _errorStack;
  StackTrace? _errorStack;
  Object? get cleanupError => _cleanupError;
  Object? _cleanupError;
  bool get cleanupPending => _cleanup != null && !_cleanupSettled;

  /// The bounded cleanup attempt settled, possibly with failure or timeout.
  /// This alone is not evidence that provider resources were released.
  bool get cleanupSettled => _cleanupSettled;
  bool _cleanupSettled = false;

  /// No observed cleanup failure. This is not proof a failed remote launch left
  /// no resource: the transport may contain subscription-cancellation errors.
  bool get cleanupSucceeded => cleanupSettled && cleanupError == null;

  /// Failed before issuing any terminal request, with cleanup settled normally.
  /// A pre-open stream failure/cancellation cannot prove remote resource release.
  bool get launchFailedWithoutResources =>
      _error != null && !_terminalRequested && cleanupSucceeded;

  final _changes = _TerminalChanges();
  late final void Function() _detachTitle;
  bool _terminalRequested = false;
  EnvironmentMaterialization? _materialization;
  EnvironmentTerminalProvider? _provider;
  StreamSubscription<EnvironmentTerminalEvent>? _subscription;
  void Function()? _detachRetirement;
  String? _handle;
  EnvironmentTerminalDimensions? _lastDimensions;
  final _ready = Completer<void>();
  Future<void>? _starting;
  Future<void>? _cleanup;
  Future<void>? _dispatch;
  bool _dispatching = false;
  final _input = Queue<({String text, bool Function() active})>();
  int _inputCodeUnits = 0;
  int _inputChunks = 0;
  ({EnvironmentTerminalDimensions dimensions, bool Function() active})?
  _pendingResize;

  bool get _accepting =>
      _state == EnvironmentTerminalState.opening ||
      _state == EnvironmentTerminalState.running;

  /// Coalesced lifecycle, cleanup and title invalidations; never output chunks.
  /// Read current getters after subscribing. Disposal sends a final cleanup
  /// settlement before detaching observers. The returned detach is idempotent.
  void Function() observe(void Function() observer) =>
      _changes.observe(observer);

  /// Starts at most once. Completion means opened or fenced/failed; inspect
  /// [state] and [error]. Calling this does not require a mounted presentation.
  Future<void> open() {
    if (_state == EnvironmentTerminalState.idle) {
      _state = EnvironmentTerminalState.opening;
      _changes.notify();
      _starting = _start();
    }
    return _ready.future;
  }

  void _validateGraph() {
    final store = _runtime.store;
    final current = store.environment(environmentId);
    final task = store.task(_environment.taskId);
    if (current == null ||
        current.taskId != _environment.taskId ||
        current.providerId != _environment.providerId ||
        current.role != _environment.role ||
        current.providerState == null ||
        task == null ||
        store.project(task.projectId) == null) {
      throw StateError('Terminal Environment graph is no longer canonical.');
    }
  }

  Future<void> _start() async {
    try {
      _validateGraph();
      final materialization = await _runtime.materialize(environmentId);
      if (!_accepting) return;
      _materialization = materialization;
      _validateGraph();
      materialization.validateBinding();
      final provider = materialization.provider;
      if (provider is! EnvironmentTerminalProvider) {
        throw const EnvironmentFailure(
          code: environmentTerminalUnavailableCode,
          message: 'The selected Environment provider has no terminal facet.',
          details: {},
        );
      }
      _provider = provider as EnvironmentTerminalProvider;
      _detachRetirement = materialization.binding.onRetire(
        () =>
            _disconnect(StateError('Terminal provider registration retired.')),
      );
      _terminalRequested = true;
      _subscription = _provider!
          .openTerminal(environmentId, request)
          .listen(
            _event,
            onError: (Object error, StackTrace stack) =>
                _disconnect(error, stack),
            onDone: () {
              if (_accepting) {
                _disconnect(
                  StateError('Terminal stream ended without completion.'),
                );
              }
            },
          );
    } catch (error, stack) {
      if (_accepting) _disconnect(error, stack);
    }
  }

  void _event(EnvironmentTerminalEvent event) {
    try {
      if (!_accepting) {
        // A synchronous stream may deliver opened while listen is still being
        // assigned. Cleanup waits for _start before inspecting this handle.
        if (_handle == null && event.opened != null) {
          _handle = event.opened!.handle;
        }
        return;
      }
      _validateGraph();
      _materialization!.validateBinding();
      switch (event.kind) {
        case EnvironmentTerminalEventKind.opened:
          if (_handle != null) throw StateError('Duplicate terminal opened.');
          _handle = event.opened!.handle;
          _lastDimensions = event.opened!.dimensions;
          // A console may mount while launch is pending. Do not overwrite its
          // already-admitted geometry with the provider's initial request size.
          final pendingResize = _pendingResize;
          final dimensions =
              pendingResize != null && _active(pendingResize.active)
              ? pendingResize.dimensions
              : _lastDimensions!;
          if (!_accepting) return;
          surface.resize(dimensions.columns, dimensions.rows);
          _state = EnvironmentTerminalState.running;
          _changes.notify();
          if (!_ready.isCompleted) _ready.complete();
          _pump();
        case EnvironmentTerminalEventKind.output:
          if (_handle == null) {
            throw StateError('Terminal output before opened.');
          }
          surface.write(event.output!);
        case EnvironmentTerminalEventKind.completed:
          if (_handle == null) {
            throw StateError('Terminal completion before opened.');
          }
          _completion = event.completed!;
          _fence(EnvironmentTerminalState.completed);
          _beginCleanup();
      }
    } catch (error, stack) {
      _disconnect(error, stack);
    }
  }

  /// Queues an entire input action or disconnects on overflow, never truncates a
  /// paste. The exact originating mount validator travels with every chunk and
  /// is checked again immediately before dispatch, after all earlier awaits.
  bool write(String text, {required bool Function() isActive}) {
    if (!_accepting || text.isEmpty) return false;
    // A validator can itself synchronously revoke the owner.
    if (!_active(isActive) || !_accepting) return false;
    try {
      if (_inputCodeUnits + text.length > maxPendingInputCodeUnits) {
        throw StateError('Terminal input queue limit exceeded.');
      }
      final chunks = <String>[];
      for (var start = 0; start < text.length;) {
        var end = (start + environmentTerminalTextLimit).clamp(0, text.length);
        if (end < text.length &&
            text.codeUnitAt(end - 1) >= 0xd800 &&
            text.codeUnitAt(end - 1) <= 0xdbff) {
          end--;
        }
        final chunk = text.substring(start, end);
        validateEnvironmentTerminalText(chunk);
        chunks.add(chunk);
        start = end;
      }
      if (_inputChunks + chunks.length > maxPendingInputChunks) {
        throw StateError('Terminal input queue limit exceeded.');
      }
      _inputCodeUnits += text.length;
      _inputChunks += chunks.length;
      for (final chunk in chunks) {
        _input.add((text: chunk, active: isActive));
      }
      _pump();
      return true;
    } catch (error, stack) {
      _disconnect(error, stack);
      return false;
    }
  }

  /// Geometry is coalesced independently of ordered input. Like input, a layout
  /// change cannot borrow the authority of a later replacement mount.
  void resize(
    EnvironmentTerminalDimensions dimensions, {
    required bool Function() isActive,
  }) {
    if (!_accepting) return;
    if (!_active(isActive) || !_accepting) return;
    _pendingResize = (dimensions: dimensions, active: isActive);
    _pump();
  }

  bool _active(bool Function() validate) {
    try {
      return validate();
    } on Object {
      return false;
    }
  }

  void _pump() {
    if (_dispatching || _state != EnvironmentTerminalState.running) return;
    _dispatching = true;
    _dispatch = _drain();
  }

  Future<void> _drain() async {
    try {
      while (_state == EnvironmentTerminalState.running) {
        if (_input.isNotEmpty) {
          final input = _input.removeFirst();
          try {
            if (!_active(input.active) ||
                _state != EnvironmentTerminalState.running) {
              continue;
            }
            _validateGraph();
            _materialization!.validateBinding();
            await _provider!.writeTerminal(environmentId, _handle!, input.text);
          } finally {
            _inputCodeUnits -= input.text.length;
            _inputChunks--;
          }
        } else {
          final resize = _pendingResize;
          _pendingResize = null;
          if (resize == null) break;
          if (!_active(resize.active) ||
              _state != EnvironmentTerminalState.running) {
            continue;
          }
          final size = resize.dimensions;
          if (_lastDimensions?.columns == size.columns &&
              _lastDimensions?.rows == size.rows) {
            continue;
          }
          _validateGraph();
          _materialization!.validateBinding();
          await _provider!.resizeTerminal(environmentId, _handle!, size);
          _lastDimensions = size;
        }
      }
    } catch (error, stack) {
      if (_accepting) _disconnect(error, stack);
    } finally {
      _dispatching = false;
    }
  }

  void _disconnect(Object error, [StackTrace? stack]) {
    if (!_accepting) return;
    _error = error;
    _errorStack = stack;
    _fence(EnvironmentTerminalState.disconnected);
    _beginCleanup();
  }

  void _fence(EnvironmentTerminalState state) {
    if (_state == state) return;
    _state = state;
    for (final input in _input) {
      _inputCodeUnits -= input.text.length;
      _inputChunks--;
    }
    _input.clear();
    _pendingResize = null;
    _detachRetirement?.call();
    _detachRetirement = null;
    surface.stopInput();
    if (!_ready.isCompleted) _ready.complete();
    _changes.notify();
  }

  /// Fences synchronously, preserves the emulator, and joins bounded cleanup.
  /// The future settles even on failure; inspect [cleanupSucceeded]/[cleanupError].
  Future<void> close() {
    if (_state != EnvironmentTerminalState.disposed &&
        _state != EnvironmentTerminalState.completed &&
        _state != EnvironmentTerminalState.disconnected) {
      _fence(EnvironmentTerminalState.closed);
    }
    return _beginCleanup();
  }

  /// Explicit owner disposal, not presentation detachment.
  Future<void> dispose() {
    if (_state == EnvironmentTerminalState.disposed) return _cleanup!;
    final closing = close();
    _state = EnvironmentTerminalState.disposed;
    _detachTitle();
    surface.dispose();
    if (cleanupSettled) {
      _changes.close();
    } else {
      _changes.notify();
    }
    return closing;
  }

  Future<void> _beginCleanup() {
    if (_cleanup != null) return _cleanup!;
    _cleanup = _cleanUp()
        .timeout(_cleanupTimeout)
        .catchError((Object error, StackTrace stack) {
          _cleanupError ??= error;
        })
        .whenComplete(() {
          _cleanupSettled = true;
          if (_state == EnvironmentTerminalState.disposed) {
            _changes.close();
          } else {
            _changes.notify();
          }
        });
    _changes.notify();
    return _cleanup!;
  }

  Future<void> _cleanUp() async {
    await _starting;
    // Close and stream cancellation must both be attempted, even if either
    // throws or stalls. Neither cleanup operation may resolve a replacement.
    await Future.wait<void>([
      if (_handle != null && _provider != null)
        Future<void>.sync(
          () => _provider!.closeTerminal(environmentId, _handle!),
        ),
      if (_subscription != null) Future<void>.sync(_subscription!.cancel),
      ?_dispatch,
    ]);
  }
}

/// Native invalidations are deferred so observers cannot reenter stream startup
/// or teardown. Each registration has its own immediate, idempotent detach.
final class _TerminalChanges {
  final _observers = <void Function()>{};
  bool _pending = false;
  bool _closed = false;

  void Function() observe(void Function() observer) {
    if (_closed) throw StateError('Terminal observation is closed.');
    void listener() => observer();
    _observers.add(listener);
    return () => _observers.remove(listener);
  }

  void notify() {
    if (_pending) return;
    _pending = true;
    scheduleMicrotask(() {
      _pending = false;
      final finalDelivery = _closed;
      for (final observer in _observers.toList()) {
        if (!_observers.contains(observer)) continue;
        try {
          observer();
        } on Object {
          // A presentation observer cannot break cleanup or other observers.
        }
      }
      if (finalDelivery) _observers.clear();
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    notify();
  }
}
