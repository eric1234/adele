import 'dart:io';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_directory_project_selector_plugin/local_directory_project_selector_plugin.dart';

void main() {
  late _FileSelector picker;
  late ProjectSelectorContribution contribution;

  setUp(() {
    final original = FileSelectorPlatform.instance;
    picker = _FileSelector();
    FileSelectorPlatform.instance = picker;
    addTearDown(() => FileSelectorPlatform.instance = original);
    final registry = ExtensionRegistry();
    final activation = const LocalDirectoryProjectSelectorPlugin().activate(
      registry,
    );
    addTearDown(activation.close);
    contribution = registry.discover(projectSelectorContributions).single.value;
  });

  test(
    'default Flutter picker is lazy and delegates with default options',
    () async {
      final expected = Directory.current.uri.resolve('flutter%20project/');
      picker.path = expected.toFilePath();
      expect(picker.calls, isEmpty);

      expect(await contribution.selectProject(), expected);
      final options = picker.calls.single;
      expect(options.initialDirectory, isNull);
      expect(options.confirmButtonText, isNull);
      expect(options.canCreateDirectories, isNull);
    },
  );

  test('default Flutter picker preserves cancellation', () async {
    expect(await contribution.selectProject(), isNull);
    expect(picker.calls, hasLength(1));
  });

  test('default Flutter picker propagates the same failure', () async {
    final failure = StateError('directory selection unavailable');
    picker.failure = failure;
    await expectLater(contribution.selectProject(), throwsA(same(failure)));
    expect(picker.calls, hasLength(1));
  });
}

final class _FileSelector extends FileSelectorPlatform {
  String? path;
  Object? failure;
  final calls = <FileDialogOptions>[];

  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) async {
    calls.add(options);
    if (failure case final failure?) throw failure;
    return path;
  }
}
