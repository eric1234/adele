import 'dart:async';

import 'package:adele_desktop/core/resource_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('empty cleanup succeeds', () async {
    await closeResources(<Future<void> Function()>[]);
  });

  test('actions run in order and each completion is awaited', () async {
    final List<String> events = <String>[];
    final Completer<void> started = Completer<void>();
    final Completer<void> release = Completer<void>();
    bool completed = false;
    final Future<void> closing = closeResources(<Future<void> Function()>[
      () async {
        events.add('first');
      },
      () async {
        events.add('blocked');
        started.complete();
        await release.future;
        events.add('released');
      },
      () async {
        events.add('last');
      },
    ]).then((_) => completed = true);

    await started.future;
    expect(events, <String>['first', 'blocked']);
    expect(completed, isFalse);
    release.complete();
    await closing;
    expect(events, <String>['first', 'blocked', 'released', 'last']);
    expect(completed, isTrue);
  });

  for (final bool firstIsAsync in <bool>[false, true]) {
    test(
      'attempts all actions and preserves first ${firstIsAsync ? 'async' : 'sync'} error and stack',
      () async {
        final List<String> events = <String>[];
        final StateError firstError = StateError('first failure');
        final StateError laterError = StateError('later failure');
        final StackTrace firstStack = StackTrace.fromString(
          'first close stack',
        );
        final StackTrace laterStack = StackTrace.fromString(
          'later close stack',
        );
        final Future<void> closing = closeResources(<Future<void> Function()>[
          () {
            events.add('first failure');
            if (firstIsAsync) {
              return Future<void>.error(firstError, firstStack);
            }
            Error.throwWithStackTrace(firstError, firstStack);
          },
          () async {
            events.add('success between failures');
          },
          () {
            events.add('later failure');
            if (!firstIsAsync) {
              return Future<void>.error(laterError, laterStack);
            }
            Error.throwWithStackTrace(laterError, laterStack);
          },
          () async {
            events.add('last success');
          },
        ]);

        try {
          await closing;
          fail('Cleanup must rethrow its first failure.');
        } catch (error, stackTrace) {
          expect(error, same(firstError));
          expect(stackTrace.toString(), firstStack.toString());
        }
        expect(events, <String>[
          'first failure',
          'success between failures',
          'later failure',
          'last success',
        ]);
      },
    );
  }
}
