import 'dart:io';

import 'package:test/test.dart';

import '../tool/generate_notices.dart' as notices;

void main() {
  final package = File('native/Cargo.lock').existsSync()
      ? Directory.current
      : Directory('packages/credential_store');
  final licenseFile = File('${package.path}/LICENSE');
  final license = licenseFile.readAsStringSync();
  final sections = license.split(notices.noticeSeparator);

  test('reviewed notices match every generation input and the full text', () {
    expect(license, contains(notices.inputFingerprints(package)));
    expect(
      notices.sha256File(File('${package.path}/native/Cargo.lock')),
      notices.reviewedLockSha256,
    );
    // Deliberate text changes require reviewing/regenerating the inventory and
    // updating this digest. CI needs no Cargo cache, network, or rust-src here.
    expect(
      notices.sha256File(licenseFile),
      '4c03228046311f4712b9e8a3ea7786b74e3e84c178242e805b6f71c6944472ec',
    );
  });

  test(
    'all 116 locked crates carry exact identity and full selected terms',
    () {
      final locked = notices.lockChecksums(
        File('${package.path}/native/Cargo.lock').readAsStringSync(),
      );
      final native = sections.where(
        (s) => s.split('\n').first.endsWith('(Cargo.lock)'),
      );
      expect(locked, hasLength(116));
      expect(native, hasLength(locked.length));
      for (final entry in locked.entries) {
        final section = native.singleWhere(
          (s) => s.startsWith('${entry.key} (Cargo.lock)\n'),
        );
        expect(
          section,
          contains('Checksum (crates.io SHA256): ${entry.value}'),
        );
        expect(section, contains('Declared license: '));
        expect(section, contains('Selected option: MIT'));
        expect(
          section.replaceAll(RegExp(r'\s+'), ' '),
          contains('Permission is hereby granted, free of charge'),
        );
        expect(section, contains('THE SOFTWARE IS PROVIDED'));
      }
      final unicode = native.singleWhere((s) => s.startsWith('unicode-ident '));
      expect(unicode, contains('Selected option: MIT AND Unicode-3.0'));
      expect(unicode, contains('UNICODE LICENSE V3'));
      expect(license, contains('Copyright (c) 2014 Mathijs van de Nes'));
      expect(license, contains('Copyright (c) 2017 The Tokio Authors'));
    },
  );

  test(
    'pinned Linux runtime closure has its own versions and full notices',
    () {
      final runtime = sections.where(
        (s) => s.split('\n').first.endsWith('(Rust 1.93.0 runtime)'),
      );
      expect(runtime.map((s) => s.split(' (Rust').first), [
        'addr2line 0.25.1',
        'adler2 2.0.1',
        'cfg-if 1.0.4',
        'foldhash 0.2.0',
        'gimli 0.32.3',
        'hashbrown 0.16.1',
        'libc 0.2.177',
        'memchr 2.7.6',
        'miniz_oxide 0.8.9',
        'object 0.37.3',
        'rustc-demangle 0.1.26',
      ]);
      expect(license, contains('Selected option: 0BSD'));
      expect(license, contains('Selected option: Zlib'));
      expect(license, contains('LLVM Exceptions to the Apache 2.0 License'));
      expect(
        license,
        contains('Redistribution and use in source and binary forms'),
      );
      expect(license, contains('Rust 1.93.0 in-tree runtime\n\n'));
    },
  );

  test('Flutter component format preserves scope without licensing ADELE', () {
    expect(sections, hasLength(129));
    for (final section in sections) {
      final split = section.indexOf('\n\n');
      expect(split, greaterThan(0));
      expect(section.substring(0, split).split('\n'), hasLength(1));
      expect(section.substring(split + 2).trim(), isNotEmpty);
    }
    expect(license, contains('does NOT license ADELE source'));
    expect(license, isNot(contains('<year>')));
    expect(license, isNot(contains('<copyright holders>')));
    expect(license, isNot(contains('OFL-1.1')));
    expect(license, isNot(contains('FiraSans')));
  });

  test(
    'unsupported expressions fail instead of choosing an invalid option',
    () {
      expect(notices.selectedLicense('MIT OR Apache-2.0'), 'MIT');
      expect(
        notices.selectedLicense('(MIT OR Apache-2.0) AND Unicode-3.0'),
        'MIT AND Unicode-3.0',
      );
      for (final expression in [
        '',
        'GPL-3.0',
        'MIT AND GPL-3.0',
        'LicenseRef-custom',
      ]) {
        expect(() => notices.selectedLicense(expression), throwsStateError);
      }
      expect(
        () => notices.lockChecksums('''
[[package]]
name = "missing-checksum"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
'''),
        throwsStateError,
      );
    },
  );

  group('missing or unreviewed source licenses fail closed', () {
    late Directory fixture;
    late String mit;
    setUp(() {
      fixture = Directory.systemTemp.createTempSync('credential-notices-');
      Directory('${fixture.path}/src').createSync();
      final aes = sections.singleWhere((s) => s.startsWith('aes 0.9.3 '));
      mit = aes.split('--- LICENSE-MIT ---\n\n').last;
    });
    tearDown(() => fixture.deleteSync(recursive: true));

    test('an unreviewed lock fails before any Cargo or runtime discovery', () {
      Directory('${fixture.path}/native').createSync();
      File(
        '${fixture.path}/native/Cargo.lock',
      ).writeAsStringSync('version = 4\n');
      expect(() => notices.generateNotices(fixture), throwsStateError);
      expect(File('${fixture.path}/LICENSE').existsSync(), isFalse);
    });

    test('missing, empty and SPDX-only texts are rejected', () {
      expect(
        () => notices.crateNotices(fixture, 'MIT', name: 'fixture'),
        throwsStateError,
      );
      for (final incomplete in ['', 'MIT', 'Copyright (c) 2026 Fixture']) {
        File('${fixture.path}/LICENSE-MIT').writeAsStringSync(incomplete);
        expect(
          () => notices.crateNotices(fixture, 'MIT', name: 'fixture'),
          throwsStateError,
        );
      }
    });

    test('copyright templates are rejected', () {
      File(
        '${fixture.path}/LICENSE-MIT',
      ).writeAsStringSync('$mit\nCopyright <year> <owner>');
      expect(
        () => notices.crateNotices(fixture, 'MIT', name: 'fixture'),
        throwsStateError,
      );
    });

    test('required Unicode and supplemental notices cannot disappear', () {
      File('${fixture.path}/LICENSE-MIT').writeAsStringSync(mit);
      expect(
        () => notices.crateNotices(
          fixture,
          'MIT AND Unicode-3.0',
          name: 'unicode-ident',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => notices.crateNotices(fixture, 'MIT', name: 'atomic-waker'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('unknown nested notices require review', () {
      File('${fixture.path}/LICENSE-MIT').writeAsStringSync(mit);
      File('${fixture.path}/src/NOTICE').writeAsStringSync('Additional terms');
      expect(
        () => notices.crateNotices(fixture, 'MIT', name: 'fixture'),
        throwsStateError,
      );
    });

    test('embedded notices preserve copyright text and Unicode', () {
      File('${fixture.path}/LICENSE-MIT').writeAsStringSync(mit);
      const comment =
          '// Copyright \u00a9 2026 Example\n// Permission notice.\n';
      File(
        '${fixture.path}/src/lib.rs',
      ).writeAsStringSync('$comment\nfn main() {}\n');
      final result = notices.crateNotices(fixture, 'MIT', name: 'fixture');
      expect(
        result['src/lib.rs (embedded source notices)'],
        comment.trimRight(),
      );
    });
  });
}
