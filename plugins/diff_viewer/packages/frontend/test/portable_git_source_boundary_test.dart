@TestOn('linux')
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'stock Diff frontend preserves portable Git client boundaries',
    () async {
      final stock = await File('lib/main.dart').readAsString();
      expect(stock, contains('ReviewApprovalHandlerServiceClient('));
      expect(stock, contains('ReviewHunkSelection('));
      expect(stock, contains('file.reviewRevision'));
      expect(stock, contains('ReviewFileSelection('));
      expect(stock, contains('file.fileReviewRevision'));
      expect(
        stock,
        contains('resolveEnvironmentBufferedProcessCapabilityProvider('),
      );
      expect(stock, contains('ChangeSetSourceServiceClient('));
      for (final forbidden in [
        "import 'dart:io'",
        'package:adele_environment',
        'package:adele_project_storage',
        'package:git_backend',
        'EnvironmentBufferedProcessRequest',
        'runBufferedProcess',
        'capturedIdentity',
        'baselineCommit',
      ]) {
        expect(stock, isNot(contains(forbidden)));
      }
    },
  );
}
