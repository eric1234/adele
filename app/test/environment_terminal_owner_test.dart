import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/terminal/environment_terminal_owner.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:xterm2/xterm.dart';

final _providerId = ProviderId('dev.adele.test-terminal');
final _environmentId = EnvironmentId('terminal-environment');

EnvironmentTerminalDimensions _size(int columns, [int rows = 24]) =>
    EnvironmentTerminalDimensions(columns: columns, rows: rows);

EnvironmentTerminalRequest _request({
  EnvironmentTerminalDimensions? dimensions,
}) => EnvironmentTerminalRequest(
  program: '/fixture/shell',
  arguments: ['--interactive'],
  relativeWorkingDirectory: '',
  dimensions: dimensions ?? _size(80),
);

EnvironmentTerminalEvent _opened({
  String handle = 'opaque-handle',
  EnvironmentTerminalDimensions? dimensions,
}) => EnvironmentTerminalEvent(
  kind: EnvironmentTerminalEventKind.opened,
  opened: EnvironmentTerminalOpened(
    handle: handle,
    dimensions: dimensions ?? _size(80),
  ),
  output: null,
  completed: null,
);

EnvironmentTerminalEvent _output(String text) => EnvironmentTerminalEvent(
  kind: EnvironmentTerminalEventKind.output,
  opened: null,
  output: text,
  completed: null,
);

EnvironmentTerminalEvent _completed() => EnvironmentTerminalEvent(
  kind: EnvironmentTerminalEventKind.completed,
  opened: null,
  output: null,
  completed: EnvironmentTerminalCompleted(
    termination: EnvironmentTerminalTermination.exited,
    exitCode: 7,
  ),
);

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'creation is lazy and canonical, and each owner opens only once',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      expect(fixture.provider.restores, 0);
      expect(fixture.provider.opens, 0);
      expect(fixture.owner.state, EnvironmentTerminalState.idle);
      expect(fixture.coordinator.forEnvironment(_environmentId), [
        fixture.owner,
      ]);
      expect(
        () => fixture.coordinator.create(
          EnvironmentId('missing'),
          request: _request(),
        ),
        throwsStateError,
      );
      final opening = fixture.owner.open();
      expect(fixture.owner.open(), same(opening));
      await fixture.provider.listening.future;
      fixture.provider.events.add(_opened());
      await opening;
      expect(fixture.provider.restores, 1);
      expect(fixture.provider.opens, 1);
      expect(fixture.provider.openedEnvironment, _environmentId);
      expect(fixture.provider.request, same(fixture.owner.request));
      expect(fixture.store.sessionsForTask(TaskId('terminal-task')), isEmpty);
      await fixture.owner.open();
      expect(fixture.provider.opens, 1);
    },
  );

  test('selected provider without terminal facet fails explicitly', () async {
    final store = InMemoryProductStore();
    _publish(store);
    final registry = CapabilityRegistry();
    final provider = _EnvironmentProvider();
    registry.register(provider: _descriptor(), endpoint: provider);
    final coordinator = EnvironmentTerminalCoordinator(
      environmentRuntime: _runtime(store, registry),
    );
    addTearDown(coordinator.close);
    final owner = coordinator.create(_environmentId, request: _request());
    await owner.open();
    expect(owner.state, EnvironmentTerminalState.disconnected);
    expect(
      owner.error,
      isA<EnvironmentFailure>().having(
        (error) => error.code,
        'code',
        environmentTerminalUnavailableCode,
      ),
    );
    expect(owner.surface.isDisposed, isFalse);
  });

  test(
    'terminals in one Environment have independent resources and lifetimes',
    () async {
      final store = InMemoryProductStore();
      _publish(store);
      final registry = CapabilityRegistry();
      final provider = _MultiTerminalProvider();
      final registration = registry.register(
        provider: _descriptor(),
        endpoint: provider,
      );
      final coordinator = EnvironmentTerminalCoordinator(
        environmentRuntime: _runtime(store, registry),
      );
      addTearDown(coordinator.close);
      final first = coordinator.create(_environmentId, request: _request());
      final snapshot = coordinator.forEnvironment(_environmentId);
      final second = coordinator.create(_environmentId, request: _request());
      expect(first, isNot(same(second)));
      expect(first.surface, isNot(same(second.surface)));
      expect(snapshot, [first]);
      expect(() => snapshot.add(second), throwsUnsupportedError);
      expect(coordinator.forEnvironment(_environmentId), [first, second]);
      expect(coordinator.forEnvironment(EnvironmentId('missing')), isEmpty);
      await Future.wait([first.open(), second.open()]);
      expect(provider.restores, 1);
      expect(provider.events.keys, ['terminal-1', 'terminal-2']);

      provider.events['terminal-1']!.add(_output('one\x1b[6n'));
      provider.events['terminal-2']!.add(_output('second\x1b[6n'));
      await _turn();
      expect(provider.writes, [
        ('terminal-1', '\x1b[1;4R'),
        ('terminal-2', '\x1b[1;7R'),
      ]);
      provider.writes.clear();
      provider.writeGates['terminal-1'] = Completer<void>();
      first.write('in flight', isActive: () => true);
      first.write('queued', isActive: () => true);
      first.resize(_size(90), isActive: () => true);
      second.write('independent', isActive: () => true);
      second.resize(_size(110), isActive: () => true);
      await _turn();
      expect(provider.writes, [
        ('terminal-1', 'in flight'),
        ('terminal-2', 'independent'),
      ]);
      expect(provider.sizes, [('terminal-2', 110, 24)]);

      final removing = coordinator.remove(first);
      expect(first.state, EnvironmentTerminalState.disposed);
      expect(second.state, EnvironmentTerminalState.running);
      expect(second.surface.isDisposed, isFalse);
      expect(coordinator.forEnvironment(_environmentId), [second]);
      provider.events['terminal-2']!.add(_output('!\x1b[6n'));
      provider.writeGates['terminal-1']!.complete();
      await removing;
      await coordinator.remove(first);
      expect(provider.writes.last, ('terminal-2', '\x1b[1;8R'));
      expect(provider.writes.any((entry) => entry.$2 == 'queued'), isFalse);
      expect(provider.closes, ['terminal-1']);
      expect(provider.cancelled, ['terminal-1']);
      expect(provider.sizes, [('terminal-2', 110, 24)]);

      final third = coordinator.create(_environmentId, request: _request());
      await third.open();
      expect(provider.restores, 1);
      provider.events['terminal-2']!.add(_completed());
      expect(second.state, EnvironmentTerminalState.completed);
      expect(third.state, EnvironmentTerminalState.running);
      third.write('still live', isActive: () => true);
      await _turn();
      expect(provider.writes.last, ('terminal-3', 'still live'));
      expect(coordinator.forEnvironment(_environmentId), [second, third]);
      final retiring = registration.close();
      expect(second.state, EnvironmentTerminalState.completed);
      expect(third.state, EnvironmentTerminalState.disconnected);
      await retiring;
      await coordinator.close();
      expect(provider.closes, ['terminal-1', 'terminal-2', 'terminal-3']);
      expect(coordinator.forEnvironment(_environmentId), isEmpty);
    },
  );

  test(
    'hidden emulator uses provider opened dimensions before any view mounts',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      final owner = fixture.coordinator.create(
        _environmentId,
        request: _request(dimensions: _size(120, 40)),
      );
      final opening = owner.open();
      await fixture.provider.listening.future;
      fixture.provider.events.add(_opened(dimensions: _size(43, 17)));
      // The output immediately follows opened, without awaiting ready or mounting.
      fixture.provider.events.add(_output('\x1b[999;999H\x1b[6n'));
      await opening;
      await _turn();
      expect(fixture.provider.writes, ['\x1b[17;43R']);
      expect(fixture.provider.sizes, isEmpty);
      expect(owner.state, EnvironmentTerminalState.running);
    },
  );

  test(
    'close during materialization fences immediately and never opens late',
    () async {
      final provider = _Provider()..restoreGate = Completer<void>();
      final fixture = _Fixture(provider: provider);
      addTearDown(fixture.close);
      final opening = fixture.owner.open();
      final closing = fixture.owner.close();
      expect(fixture.owner.state, EnvironmentTerminalState.closed);
      expect(fixture.owner.write('late', isActive: () => true), isFalse);
      await opening;
      provider.restoreGate!.complete();
      await closing;
      expect(provider.opens, 0);
      expect(provider.closes, isEmpty);
      await fixture.owner.open();
      expect(provider.opens, 0);
    },
  );

  test(
    'close before opened cancels and joins late allocation cleanup',
    () async {
      final provider = _Provider()..cancelGate = Completer<void>();
      final fixture = _Fixture(provider: provider);
      addTearDown(fixture.close);
      final opening = fixture.owner.open();
      await provider.listening.future;
      final closing = fixture.owner.close();
      await _turn();
      expect(provider.cancellations, 1);
      // Cancellation owns backend allocation cleanup even if no handle arrived.
      provider.events.add(_opened());
      provider.events.add(_output('late'));
      expect(fixture.owner.state, EnvironmentTerminalState.closed);
      provider.cancelGate!.complete();
      await closing;
      await opening;
      expect(provider.writes, isEmpty);
      expect(provider.opens, 1);
      expect(fixture.owner.cleanupError, isNull);
    },
  );

  test(
    'retirement fences synchronously and never routes to replacement',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.open();
      fixture.provider.writeGate = Completer<void>();
      fixture.owner.write('in flight', isActive: () => true);
      fixture.owner.write('queued', isActive: () => true);
      final retiring = fixture.registration.close();
      expect(fixture.owner.state, EnvironmentTerminalState.disconnected);
      expect(fixture.owner.surface.readOnly, isTrue);
      final replacement = _Provider();
      fixture.registry.register(provider: _descriptor(), endpoint: replacement);
      fixture.provider.writeGate!.complete();
      await retiring;
      await fixture.owner.close();
      expect(fixture.provider.writes, ['in flight']);
      expect(fixture.provider.closes, ['opaque-handle']);
      expect(replacement.opens, 0);
      expect(replacement.writes, isEmpty);
      expect(replacement.closes, isEmpty);
      await fixture.owner.open();
      expect(fixture.provider.opens, 1);
      expect(fixture.coordinator.forEnvironment(_environmentId), [
        fixture.owner,
      ]);
      await fixture.coordinator.remove(fixture.owner);
      final fresh = fixture.coordinator.create(
        _environmentId,
        request: _request(),
      );
      final opening = fresh.open();
      await replacement.listening.future;
      replacement.events.add(_opened());
      await opening;
      expect(fresh, isNot(same(fixture.owner)));
      expect(replacement.restores, 1);
      expect(replacement.opens, 1);
    },
  );

  test(
    'endpoint loss is rechecked at dispatch without registration retirement',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.open();
      fixture.provider.writeGate = Completer<void>();
      fixture.owner.write('first', isActive: () => true);
      fixture.owner.write('second', isActive: () => true);
      fixture.provider.isAvailable = false;
      fixture.provider.writeGate!.complete();
      await _turn();
      expect(fixture.owner.state, EnvironmentTerminalState.disconnected);
      expect(fixture.owner.error, isA<ProviderEndpointUnavailable>());
      expect(fixture.provider.writes, ['first']);
    },
  );

  test(
    'input remains ordered, chunk bounded, and split Unicode stays valid',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.open();
      fixture.provider.writeGate = Completer<void>();
      final text = '${'a' * 8191}\u{1f642}${'b' * 9000}';
      expect(fixture.owner.write(text, isActive: () => true), isTrue);
      fixture.owner.write('last', isActive: () => true);
      expect(fixture.provider.writes, ['a' * 8191]);
      fixture.provider.writeGate!.complete();
      await _turn();
      expect(fixture.provider.writes.join(), '${text}last');
      expect(
        fixture.provider.writes.every((text) => text.length <= 8192),
        isTrue,
      );
      for (final chunk in fixture.provider.writes) {
        expect(() => validateEnvironmentTerminalText(chunk), returnsNormally);
      }
    },
  );

  test(
    'queued view input and resize recheck exact originating validator',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.open();
      fixture.provider.writeGate = Completer<void>();
      var active = true;
      fixture.owner.write('in flight', isActive: () => active);
      fixture.owner.write('revoked', isActive: () => active);
      fixture.owner.resize(_size(110), isActive: () => active);
      active = false;
      fixture.provider.writeGate!.complete();
      await _turn();
      expect(fixture.provider.writes, ['in flight']);
      expect(fixture.provider.sizes, isEmpty);
      expect(fixture.owner.state, EnvironmentTerminalState.running);
    },
  );

  test(
    'resize coalesces to latest geometry and serializes with input',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.open();
      fixture.provider.writeGate = Completer<void>();
      fixture.owner.write('first', isActive: () => true);
      fixture.owner.resize(_size(90), isActive: () => true);
      fixture.owner.resize(_size(100), isActive: () => true);
      fixture.owner.write('second', isActive: () => true);
      fixture.owner.resize(_size(120), isActive: () => true);
      expect(fixture.provider.sizes, isEmpty);
      fixture.provider.writeGate!.complete();
      await _turn();
      expect(fixture.provider.calls, [
        'write:first',
        'write:second',
        'resize:120',
      ]);
      fixture.owner.resize(_size(120), isActive: () => true);
      await _turn();
      expect(fixture.provider.sizes, [(120, 24)]);
    },
  );

  test(
    'dispatch cannot outlive synchronous revocation inside its validator',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.open();
      fixture.provider.writeGate = Completer<void>();
      fixture.owner.write('first', isActive: () => true);
      var validations = 0;
      fixture.owner.write(
        'revoked',
        isActive: () {
          if (++validations == 2) fixture.owner.close();
          return true;
        },
      );
      fixture.provider.writeGate!.complete();
      await _turn();
      await fixture.owner.close();
      expect(validations, 2);
      expect(fixture.provider.writes, ['first']);
      expect(fixture.owner.state, EnvironmentTerminalState.closed);
    },
  );

  for (final chunks in [false, true]) {
    test(
      'input queue rejects ${chunks ? 'chunk' : 'code-unit'} overflow without truncation',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.close);
        await fixture.open();
        fixture.provider.writeGate = Completer<void>();
        final text = chunks ? 'x' : 'x' * 8192;
        final count = chunks
            ? EnvironmentTerminalOwner.maxPendingInputChunks
            : 8;
        for (var i = 0; i < count; i++) {
          expect(fixture.owner.write(text, isActive: () => true), isTrue);
        }
        expect(fixture.owner.write('overflow', isActive: () => true), isFalse);
        expect(fixture.owner.state, EnvironmentTerminalState.disconnected);
        expect(fixture.owner.error.toString(), contains('queue limit'));
        fixture.provider.writeGate!.complete();
        await fixture.owner.close();
        expect(fixture.provider.writes, [text]);
      },
    );
  }

  test('close fences queued effects before async cleanup starts', () async {
    final fixture = _Fixture();
    addTearDown(fixture.close);
    await fixture.open();
    fixture.provider.writeGate = Completer<void>();
    fixture.owner.write('first', isActive: () => true);
    fixture.owner.write('queued', isActive: () => true);
    fixture.owner.resize(_size(110), isActive: () => true);
    final closing = fixture.owner.close();
    expect(fixture.owner.close(), same(closing));
    expect(fixture.owner.surface.isDisposed, isFalse);
    expect(fixture.owner.surface.readOnly, isTrue);
    fixture.provider.events.add(_output('ignored\x1b[6n'));
    fixture.provider.writeGate!.complete();
    await closing;
    expect(fixture.provider.writes, ['first']);
    expect(fixture.provider.sizes, isEmpty);
    expect(fixture.provider.closes, ['opaque-handle']);
    expect(fixture.provider.cancellations, 1);
  });

  test(
    'hidden protocol responses use owner authority, not view authority',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.open();
      fixture.provider.events.add(_output('abc\x1b[6n'));
      await _turn();
      expect(fixture.provider.writes, ['\x1b[1;4R']);
      fixture.provider.events.add(_completed());
      expect(fixture.owner.state, EnvironmentTerminalState.completed);
      fixture.owner.surface.write('\x1b[6n');
      await fixture.owner.close();
      expect(fixture.provider.writes, ['\x1b[1;4R']);
      expect(fixture.owner.completion!.exitCode, 7);
      expect(fixture.owner.error, isNull);
    },
  );

  for (final failure in ['eof', 'stream', 'write', 'resize', 'sequence']) {
    test(
      '$failure failure is captured, not a successful process exit',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.close);
        await fixture.open();
        switch (failure) {
          case 'eof':
            await fixture.provider.events.close();
          case 'stream':
            fixture.provider.events.addError(
              StateError('Transport disconnected.'),
            );
          case 'write':
            fixture.provider.failWrite = true;
            fixture.owner.write('input', isActive: () => true);
          case 'resize':
            fixture.provider.failResize = true;
            fixture.owner.resize(_size(110), isActive: () => true);
          case 'sequence':
            fixture.provider.events.add(_opened());
        }
        await _turn();
        expect(fixture.owner.state, EnvironmentTerminalState.disconnected);
        expect(fixture.owner.completion, isNull);
        expect(fixture.owner.error, isNotNull);
        expect(fixture.owner.surface.isDisposed, isFalse);
        expect(fixture.owner.surface.readOnly, isTrue);
      },
    );
  }

  test('cleanup failure still cancels and shutdown is bounded', () async {
    final provider = _Provider()..closeGate = Completer<void>();
    final fixture = _Fixture(
      provider: provider,
      cleanupTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(fixture.close);
    await fixture.open();
    final closing = fixture.coordinator.close();
    expect(fixture.owner.state, EnvironmentTerminalState.disposed);
    expect(fixture.owner.surface.isDisposed, isTrue);
    expect(
      () => fixture.coordinator.create(_environmentId, request: _request()),
      throwsStateError,
    );
    await closing;
    expect(provider.cancellations, 1);
    expect(fixture.owner.cleanupError, isA<TimeoutException>());
    provider.closeGate!.completeError(StateError('Late close error.'));
    await _turn();
  });

  test(
    'runtime closes terminals before backend teardown and always joins others',
    () async {
      final runtime = AdeleRuntime();
      addTearDown(runtime.close);
      _publish(runtime.store);
      final channel = _TerminalChannel();
      runtime.registry.register(
        provider: _descriptor(),
        endpoint: AdeleRequestChannelEndpoint(
          channel: channel,
          serviceId: environmentProviderServiceId,
          isAvailable: () => true,
        ),
      );
      final owner = runtime.terminals.create(
        _environmentId,
        request: _request(),
      );
      await owner.open();
      final closing = runtime.close();
      expect(runtime.close(), same(closing));
      expect(owner.state, EnvironmentTerminalState.disposed);
      expect(
        () => runtime.lifecycle.createProject(Uri.parse('file:///late')),
        throwsStateError,
      );
      await channel.closing.future;
      expect(runtime.plugins.state, ApplicationPluginState.unconfigured);
      channel.closeGate.completeError(StateError('Cleanup failed.'));
      await closing;
      expect(owner.cleanupError, isA<StateError>());
      expect(channel.cancelled, isTrue);
      expect(runtime.plugins.state, ApplicationPluginState.closed);
    },
  );

  testWidgets(
    'native mount validators survive queuing, hidden owner replies remain live',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      final opening = fixture.owner.open();
      await tester.pump();
      fixture.provider.events.add(_opened());
      await opening;
      await tester.pumpWidget(
        _host(fixture.owner.surface.buildView(isActive: () => true)),
      );
      await tester.pump();
      fixture.provider.writes.clear();
      fixture.provider.sizes.clear();
      fixture.provider.writeGate = Completer<void>();
      final terminal = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .terminal;
      terminal.textInput('first');
      terminal.textInput('revoked');
      terminal.resize(120, 30);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.provider.events.add(_output('abc\x1b[6n'));
      fixture.provider.writeGate!.complete();
      await tester.pump();
      expect(
        fixture.owner.state,
        EnvironmentTerminalState.running,
        reason: '${fixture.owner.error}\n${fixture.owner.errorStack}',
      );
      expect(fixture.provider.writes, ['first', '\x1b[1;4R']);
      expect(fixture.provider.sizes, isEmpty);
      await tester.pumpWidget(
        _host(fixture.owner.surface.buildView(isActive: () => true)),
      );
      expect(_screen(tester), contains('abc'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final complete in [true, false]) {
    testWidgets(
      '${complete ? 'exit' : 'disconnect'} preserves screen and local view but fences process input',
      (tester) async {
        final fixture = _Fixture();
        addTearDown(fixture.owner.surface.dispose);
        final opening = fixture.owner.open();
        await tester.pump();
        fixture.provider.events.add(_opened());
        await opening;
        fixture.provider.events.add(_output('retained screen\x1b[?1000h'));
        await tester.pumpWidget(
          _host(fixture.owner.surface.buildView(isActive: () => true)),
        );
        final terminal = tester
            .widget<TerminalView>(find.byType(TerminalView))
            .terminal;
        if (complete) {
          fixture.provider.events.add(_completed());
        } else {
          fixture.provider.events.addError(StateError('Disconnected.'));
        }
        terminal.textInput('blocked');
        terminal.paste('blocked paste');
        await tester.pump();
        expect(_screen(tester), contains('retained screen'));
        expect(
          tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
          isTrue,
        );
        expect(terminal.mouseMode, MouseMode.none);
        expect(fixture.provider.writes, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          _host(fixture.owner.surface.buildView(isActive: () => true)),
        );
        expect(_screen(tester), contains('retained screen'));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.coordinator.close);
        expect(fixture.owner.surface.isDisposed, isTrue);
      },
    );
  }
}

Widget _host(Widget view) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 480, height: 240, child: view)),
);

String _screen(WidgetTester tester) {
  final terminal = tester
      .widget<TerminalView>(find.byType(TerminalView))
      .terminal;
  return [
    for (var i = 0; i < terminal.buffer.lines.length; i++)
      terminal.buffer.lines[i].getText(),
  ].join('\n');
}

ProviderDescriptor _descriptor() => ProviderDescriptor(
  id: _providerId,
  capability: environmentProviderCapability,
  pluginId: 'dev.adele.test-terminal',
  displayName: 'Terminal fixture',
  serviceId: environmentProviderServiceId,
);

void _publish(InMemoryProductStore store) {
  final project = Project(
    id: ProjectId('terminal-project'),
    sourceLocation: Uri.parse('file:///fixture'),
  );
  final task = Task(
    id: TaskId('terminal-task'),
    projectId: project.id,
    title: 'Terminal',
  );
  store.publishProject(project);
  store.publishTaskWithPrimaryEnvironment(
    task,
    Environment(
      id: _environmentId,
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: _providerId,
      providerState: const {},
    ),
  );
}

EnvironmentRuntime _runtime(
  InMemoryProductStore store,
  CapabilityRegistry registry,
) => EnvironmentRuntime(
  store: store,
  registry: registry,
  providerForBinding: (binding) => binding.endpointAs<_EnvironmentProvider>(),
  retainEnvironment: store.replaceEnvironment,
);

class _Fixture {
  _Fixture({
    _Provider? provider,
    Duration cleanupTimeout = const Duration(seconds: 2),
  }) : provider = provider ?? _Provider() {
    _publish(store);
    registration = registry.register(
      provider: _descriptor(),
      endpoint: this.provider,
    );
    coordinator = EnvironmentTerminalCoordinator(
      environmentRuntime: _runtime(store, registry),
      cleanupTimeout: cleanupTimeout,
    );
    owner = coordinator.create(_environmentId, request: _request());
  }

  final InMemoryProductStore store = InMemoryProductStore();
  final CapabilityRegistry registry = CapabilityRegistry();
  final _Provider provider;
  late final CapabilityRegistration registration;
  late final EnvironmentTerminalCoordinator coordinator;
  late final EnvironmentTerminalOwner owner;

  Future<void> open() async {
    final opening = owner.open();
    await provider.listening.future;
    provider.events.add(_opened());
    await opening;
  }

  Future<void> close() => coordinator.close();
}

class _EnvironmentProvider implements EnvironmentProvider, CapabilityEndpoint {
  int restores = 0;
  Completer<void>? restoreGate;
  @override
  final ProviderId providerId = _providerId;
  @override
  String get serviceId => environmentProviderServiceId;
  @override
  bool isAvailable = true;
  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async {
    restores++;
    await restoreGate?.future;
    return EnvironmentProviderResult(providerState: {});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Provider extends _EnvironmentProvider
    implements EnvironmentTerminalProvider {
  _Provider() {
    events = StreamController<EnvironmentTerminalEvent>(
      sync: true,
      onListen: listening.complete,
      onCancel: () {
        cancellations++;
        return cancelGate?.future;
      },
    );
  }

  late final StreamController<EnvironmentTerminalEvent> events;
  final listening = Completer<void>();
  final writes = <String>[];
  final sizes = <(int, int)>[];
  final closes = <String>[];
  final calls = <String>[];
  int opens = 0;
  int cancellations = 0;
  EnvironmentId? openedEnvironment;
  EnvironmentTerminalRequest? request;
  Completer<void>? writeGate;
  Completer<void>? closeGate;
  Completer<void>? cancelGate;
  bool failWrite = false;
  bool failResize = false;

  @override
  Stream<EnvironmentTerminalEvent> openTerminal(
    EnvironmentId id,
    EnvironmentTerminalRequest request,
  ) {
    opens++;
    openedEnvironment = id;
    this.request = request;
    return events.stream;
  }

  @override
  Future<void> writeTerminal(
    EnvironmentId id,
    String handle,
    String text,
  ) async {
    expectSync(id, _environmentId);
    expectSync(handle, 'opaque-handle');
    writes.add(text);
    calls.add('write:$text');
    if (failWrite) throw StateError('Write failed.');
    await writeGate?.future;
  }

  @override
  Future<void> resizeTerminal(
    EnvironmentId id,
    String handle,
    EnvironmentTerminalDimensions dimensions,
  ) async {
    expectSync(id, _environmentId);
    expectSync(handle, 'opaque-handle');
    sizes.add((dimensions.columns, dimensions.rows));
    calls.add('resize:${dimensions.columns}');
    if (failResize) throw StateError('Resize failed.');
  }

  @override
  Future<void> closeTerminal(EnvironmentId id, String handle) async {
    expectSync(id, _environmentId);
    closes.add(handle);
    await closeGate?.future;
  }
}

class _MultiTerminalProvider extends _EnvironmentProvider
    implements EnvironmentTerminalProvider {
  final events = <String, StreamController<EnvironmentTerminalEvent>>{};
  final writes = <(String, String)>[];
  final sizes = <(String, int, int)>[];
  final closes = <String>[];
  final cancelled = <String>[];
  final writeGates = <String, Completer<void>>{};

  @override
  Stream<EnvironmentTerminalEvent> openTerminal(
    EnvironmentId id,
    EnvironmentTerminalRequest request,
  ) {
    expectSync(id, _environmentId);
    final handle = 'terminal-${events.length + 1}';
    late final StreamController<EnvironmentTerminalEvent> stream;
    stream = StreamController<EnvironmentTerminalEvent>(
      sync: true,
      onListen: () =>
          stream.add(_opened(handle: handle, dimensions: request.dimensions)),
      onCancel: () => cancelled.add(handle),
    );
    events[handle] = stream;
    return stream.stream;
  }

  @override
  Future<void> writeTerminal(
    EnvironmentId id,
    String handle,
    String text,
  ) async {
    expectSync(id, _environmentId);
    writes.add((handle, text));
    await writeGates[handle]?.future;
  }

  @override
  Future<void> resizeTerminal(
    EnvironmentId id,
    String handle,
    EnvironmentTerminalDimensions dimensions,
  ) async {
    expectSync(id, _environmentId);
    sizes.add((handle, dimensions.columns, dimensions.rows));
  }

  @override
  Future<void> closeTerminal(EnvironmentId id, String handle) async {
    expectSync(id, _environmentId);
    closes.add(handle);
  }
}

class _TerminalChannel implements AdeleStreamChannel {
  final closing = Completer<void>();
  final closeGate = Completer<void>();
  bool cancelled = false;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method == environmentProviderServiceCloseTerminalId) {
      closing.complete();
      await closeGate.future;
      return null;
    }
    return {'providerState': <String, Object?>{}};
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    late StreamController<Object?> events;
    events = StreamController<Object?>(
      onListen: () => events.add({
        'kind': 'opened',
        'opened': {
          'handle': 'runtime-handle',
          'dimensions': {'columns': 80, 'rows': 24},
        },
        'output': null,
        'completed': null,
      }),
      onCancel: () => cancelled = true,
    );
    return events.stream;
  }
}
