import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final kind = SessionContentKind('org.example.review-comments');
  final occurrenceId = SessionContentOccurrenceId('accepted:Review/1._-');
  final session = Session(
    id: SessionId('session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('org.example.strategy'),
  );

  test(
    'content kinds use bounded public identity grammar and value equality',
    () {
      for (final value in ['a.b', 'org.example.review-v2', 'a.${'b' * 126}']) {
        final first = SessionContentKind(value);
        final second = SessionContentKind(value);
        expect(first.value, value);
        expect(first.toString(), value);
        expect(first, second);
        expect(first.hashCode, second.hashCode);
        expect({first, second}, hasLength(1));
      }
      expect(SessionContentKind.maxLength, 128);
      expect(kind, isNot(SessionContentKind('${kind.value}.other')));
      expect(kind, isNot(SessionContentOccurrenceId(kind.value)));
    },
  );

  test('invalid kinds reject without retaining or echoing the payload', () {
    for (final value in [
      '',
      'review',
      'Org.example.review',
      'org.example.2review',
      'org..review',
      '.org.review',
      'org.review.',
      'org.review-',
      'org.-review',
      'org.re--view',
      'org.re_view',
      'org.re/view',
      'org.re:view',
      ' org.review',
      'org.review ',
      'org.review\n',
      'org.re\tview',
      'org.re\u0000view',
      'org.re\u007fview',
      'org.r\u00e9view',
      'a.${'b' * 127}',
      'private-payload' * 10000,
    ]) {
      expect(
        () => SessionContentKind(value),
        throwsA(
          isA<FormatException>()
              .having((error) => error.source, 'source', isNull)
              .having(
                (error) => error.toString(),
                'safe diagnostic',
                value.isEmpty ? isNotEmpty : isNot(contains(value)),
              ),
        ),
        reason: 'Invalid kind length ${value.length}',
      );
    }
  });

  test('occurrence references are opaque, bounded, and value-equal', () {
    for (final value in ['a', '0', occurrenceId.value, 'X' * 256]) {
      final first = SessionContentOccurrenceId(value);
      final second = SessionContentOccurrenceId(value);
      expect(first.value, value);
      expect(first.toString(), value);
      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect({first, second}, hasLength(1));
    }
    expect(SessionContentOccurrenceId.maxLength, 256);
    expect(occurrenceId, isNot(SessionContentOccurrenceId('other')));
    expect(
      SessionContentOccurrenceId('A'),
      isNot(SessionContentOccurrenceId('a')),
    );
  });

  test('occurrence references reject whitespace, controls, and unsafe ASCII', () {
    for (var code = 0; code < 128; code++) {
      final character = String.fromCharCode(code);
      final value = 'a${character}b';
      if (RegExp(r'[A-Za-z0-9._:/-]').hasMatch(character)) {
        expect(SessionContentOccurrenceId(value).value, value);
      } else {
        expect(() => SessionContentOccurrenceId(value), throwsFormatException);
      }
    }
    for (final value in [
      '',
      '.a',
      '_a',
      ':a',
      '/a',
      '-a',
      'a\n',
      'a\r',
      'a ',
      'a\u0080',
      'a\u00a0',
      'a\u202e',
      '\u00e9',
      'a' * 257,
      'private-payload' * 10000,
    ]) {
      expect(
        () => SessionContentOccurrenceId(value),
        throwsA(
          isA<FormatException>()
              .having((error) => error.source, 'source', isNull)
              .having(
                (error) => error.message,
                'safe diagnostic',
                value.isEmpty || value.length > 256
                    ? 'Session content occurrence ID must contain 1..256 ASCII characters.'
                    : 'Session content occurrence ID must be a safe ASCII identifier.',
              ),
        ),
        reason: 'Invalid occurrence length ${value.length}',
      );
    }
  });

  test('context captures immutable facts without execution or authority', () {
    final owner = _InspectionContext(
      session: session,
      kind: kind,
      occurrenceId: occurrenceId,
    );
    addTearDown(owner.dispose);
    final SessionContentInspectionContext context = owner;
    expect(context.session, same(session));
    expect(context.kind, same(kind));
    expect(context.occurrenceId, same(occurrenceId));
    expect(context.isActive, isTrue);
    final dynamic readOnly = context;
    expect(() => readOnly.session = session, throwsNoSuchMethodError);
    expect(() => readOnly.kind = kind, throwsNoSuchMethodError);
    expect(() => readOnly.occurrenceId = occurrenceId, throwsNoSuchMethodError);
    expect(() => readOnly.isActive = false, throwsNoSuchMethodError);
    expect(() => readOnly.runId, throwsNoSuchMethodError);
    expect(() => readOnly.startRun(), throwsNoSuchMethodError);
    expect(() => readOnly.backend, throwsNoSuchMethodError);
  });

  test(
    'host revocation is synchronously observable without changing facts',
    () {
      final owner = _InspectionContext(
        session: session,
        kind: kind,
        occurrenceId: occurrenceId,
      );
      addTearDown(owner.dispose);
      final SessionContentInspectionContext context = owner;
      final states = <bool>[];
      void onChanged() {
        states.add(context.isActive);
        expect(context.session, same(session));
        expect(context.kind, same(kind));
        expect(context.occurrenceId, same(occurrenceId));
      }

      context.addListener(onChanged);
      owner.retire();
      expect(states, [false]);
      expect(context.isActive, isFalse);
      owner.retire();
      expect(states, [false]);
      context.removeListener(onChanged);
    },
  );

  test(
    'presentation factories accept synchronous and asynchronous widgets',
    () async {
      final context = _InspectionContext(
        session: session,
        kind: kind,
        occurrenceId: occurrenceId,
      );
      addTearDown(context.dispose);
      const widget = SizedBox.shrink();
      final pending = Completer<Widget>();
      final synchronous = SessionContentInspectionContribution(
        kind: kind,
        createPresentation: (captured) {
          expect(captured, same(context));
          return widget;
        },
      );
      final asynchronous = SessionContentInspectionContribution(
        kind: kind,
        createPresentation: (captured) {
          expect(captured, same(context));
          return pending.future;
        },
      );
      expect(synchronous.createPresentation(context), same(widget));
      final result = asynchronous.createPresentation(context);
      expect(result, isA<Future<Widget>>());
      pending.complete(widget);
      expect(await result, same(widget));
    },
  );

  group('resolver', () {
    late ExtensionRegistry registry;
    late SessionContentInspectionResolver resolver;

    setUp(() {
      registry = ExtensionRegistry();
      resolver = SessionContentInspectionResolver(registry);
    });

    ExtensionRegistration register({
      String id = 'org.example.inspection',
      SessionContentKind? contentKind,
    }) => registry.register(
      point: sessionContentInspectionContributions,
      id: ExtensionId(id),
      value: SessionContentInspectionContribution(
        kind: contentKind ?? kind,
        createPresentation: (_) => throw StateError('Must not be invoked.'),
      ),
    );

    test('missing exact kinds are unavailable without unrelated fallback', () {
      expect(
        () => resolver.resolve(kind),
        throwsA(
          isA<SessionContentInspectionUnavailable>().having(
            (error) => error.kind,
            'kind',
            kind,
          ),
        ),
      );
      register(contentKind: SessionContentKind('${kind.value}.other'));
      expect(
        () => resolver.resolve(kind),
        throwsA(isA<SessionContentInspectionUnavailable>()),
      );
    });

    test('one exact kind resolves without invoking its factory', () {
      final registration = register();
      register(
        id: 'org.example.other',
        contentKind: SessionContentKind('${kind.value}.other'),
      );
      final binding = resolver.resolve(SessionContentKind(kind.value));
      expect(registration.owns(binding), isTrue);
      expect(binding.id, ExtensionId('org.example.inspection'));
      expect(binding.value.kind, kind);
      binding.validate();
    });

    test('multiple exact matches report sorted immutable registration IDs', () {
      register(id: 'org.example.b');
      register(
        id: 'org.example.a',
        contentKind: SessionContentKind(kind.value),
      );
      expect(
        () => resolver.resolve(kind),
        throwsA(
          isA<AmbiguousSessionContentInspection>()
              .having((error) => error.kind, 'kind', kind)
              .having((error) => error.extensionIds, 'extensionIds', [
                ExtensionId('org.example.a'),
                ExtensionId('org.example.b'),
              ]),
        ),
      );
      final ids = [ExtensionId('org.example.b'), ExtensionId('org.example.a')];
      final error = AmbiguousSessionContentInspection(kind, ids);
      ids.clear();
      expect(error.extensionIds, [
        ExtensionId('org.example.a'),
        ExtensionId('org.example.b'),
      ]);
      expect(error.extensionIds.clear, throwsUnsupportedError);
    });

    test('same-ID replacement never revives a captured registration', () async {
      final contribution = SessionContentInspectionContribution(
        kind: kind,
        createPresentation: (_) => const SizedBox.shrink(),
      );
      ExtensionRegistration activate() => registry.register(
        point: sessionContentInspectionContributions,
        id: ExtensionId('org.example.inspection'),
        value: contribution,
      );
      final first = activate();
      final retained = resolver.resolve(kind);
      await first.close();
      expect(
        () => resolver.resolve(kind),
        throwsA(isA<SessionContentInspectionUnavailable>()),
      );
      final replacement = activate();
      final fresh = resolver.resolve(kind);
      expect(retained.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(() => retained.value, throwsA(isA<StaleExtensionBinding>()));
      expect(retained.isSameRegistration(fresh), isFalse);
      expect(first.owns(retained), isTrue);
      expect(replacement.owns(retained), isFalse);
      expect(replacement.owns(fresh), isTrue);
      fresh.validate();
      expect(fresh.value, same(contribution));
    });
  });
}

final class _InspectionContext extends ChangeNotifier
    implements SessionContentInspectionContext {
  _InspectionContext({
    required this.session,
    required this.kind,
    required this.occurrenceId,
  });

  @override
  final Session session;
  @override
  final SessionContentKind kind;
  @override
  final SessionContentOccurrenceId occurrenceId;

  bool _active = true;

  @override
  bool get isActive => _active;

  void retire() {
    if (!_active) return;
    _active = false;
    notifyListeners();
  }
}
