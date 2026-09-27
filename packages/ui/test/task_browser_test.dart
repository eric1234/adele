import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/task_browser_bridge.dart' as bridge;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native stubs grant no Task Browser access', () {
    expect(bridge.readTaskBrowser, throwsUnsupportedError);
    expect(() => bridge.selectTask(null), throwsUnsupportedError);
    expect(() => bridge.createTask('title'), throwsUnsupportedError);
    expect(() => bridge.createSession('opaque'), throwsUnsupportedError);
    expect(() => bridge.openSession('session'), throwsUnsupportedError);
    void listener() {}
    expect(() => bridge.subscribeTaskBrowser(listener), throwsUnsupportedError);
    expect(
      () => bridge.unsubscribeTaskBrowser(listener),
      throwsUnsupportedError,
    );
  });

  test(
    'zero is unavailable, one retains its binding, many are ambiguous',
    () async {
      final registry = ExtensionRegistry();
      final resolver = TaskBrowserResolver(registry);
      expect(resolver.resolve, throwsA(isA<TaskBrowserUnavailable>()));
      final id = ExtensionId('test.browser');
      final project = Project(
        id: ProjectId('project'),
        sourceLocation: Uri.parse('file:///project'),
      );
      Project? received;
      final contribution = TaskBrowserContribution(
        displayName: 'Browser',
        createPresentation: (project) {
          received = project;
          return const SizedBox.shrink();
        },
      );
      final first = registry.register(
        point: taskBrowserContributions,
        id: id,
        value: contribution,
      );
      final retained = resolver.resolve();
      expect(received, isNull);
      expect(retained.value, same(contribution));
      retained.value.createPresentation(project);
      expect(received, same(project));
      final other = registry.register(
        point: taskBrowserContributions,
        id: ExtensionId('test.another-browser'),
        value: contribution,
      );
      expect(
        resolver.resolve,
        throwsA(
          isA<AmbiguousTaskBrowser>().having(
            (error) => error.extensionIds,
            'sorted IDs',
            [ExtensionId('test.another-browser'), id],
          ),
        ),
      );
      final error = AmbiguousTaskBrowser([id]);
      expect(() => error.extensionIds.clear(), throwsUnsupportedError);
      await other.close();
      await first.close();
      registry.register(
        point: taskBrowserContributions,
        id: id,
        value: contribution,
      );
      expect(retained.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(retained.isSameRegistration(resolver.resolve()), isFalse);
      resolver.resolve().validate();
    },
  );
}
