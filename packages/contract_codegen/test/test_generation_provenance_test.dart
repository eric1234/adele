import 'dart:convert';
import 'dart:isolate';

import 'package:contract_codegen/src/provenance_files.dart';
import 'package:contract_codegen/src/test_generation.dart';
import 'package:crypto/crypto.dart';

import 'support/contract_generator_support.dart';

void main() {
  group('Linux test generation provenance', () {
    test('fast edit/restore and negative create/delete are changes', () {
      final root = Directory.systemTemp.createTempSync('contract-ns.');
      addTearDown(() => root.deleteSync(recursive: true));
      final file = File('${root.path}/source')..writeAsStringSync('good');
      final files = ProvenanceFiles()..watch(file.path, read: true);
      files.verify();
      final mtime = file.lastModifiedSync();
      file
        ..writeAsStringSync('evil')
        ..writeAsStringSync('good')
        ..setLastModifiedSync(mtime);
      expect(files.verify, throwsStateError);
      final negative = ProvenanceFiles()..watch('${root.path}/nested/config');
      final nested = Directory('${root.path}/nested')..createSync();
      nested.deleteSync();
      expect(negative.verify, throwsStateError);
    });

    test(
      'proof binds authoritative output, analyzer resolution and transitives',
      () async {
        final fixture = await createFixture(
          "import 'support.dart' as support;\n${minimalContract(namedValue: true).replaceFirst("AdeleMethod('ping')", 'AdeleMethod(support.method)')}",
        );
        final support = File('${fixture.directory.path}/support.dart')
          ..writeAsStringSync("const method = 'ping';");
        final scratch = Directory.systemTemp.createTempSync('test-generation.');
        addTearDown(() => scratch.deleteSync(recursive: true));
        File(
          '${scratch.path}/libraries.json',
        ).writeAsStringSync(jsonEncode([fixture.directory.path]));
        final gen = TestGeneration(scratch);
        final output = await gen.generate(fixture.source);
        expect(
          output.contents,
          (await const ContractGenerator().generate(fixture.source)).contents,
        );
        await const ContractGenerator().write(output);
        await gen.finish([fixture.source], wroteOutputs: true);
        final proof =
            jsonDecode(File('${scratch.path}/proof.json').readAsStringSync())
                as Map;
        final hashes = proof['hashes'] as Map;
        expect(
          proof['packageConfig'],
          (await Isolate.packageConfig).toString(),
        );
        expect(proof['executable'], Platform.resolvedExecutable);
        expect(
          hashes[support.path],
          sha256.convert(support.readAsBytesSync()).toString(),
        );
        expect(
          hashes[output.path],
          sha256.convert(File(output.path).readAsBytesSync()).toString(),
        );
        final stamps = (proof['outputs'][output.path]['stamps'] as Map)
            .cast<String, String>();
        expect(
          stamps.keys,
          contains(endsWith('/.dart_tool/package_config.json')),
        );
        expect(stamps.keys, contains(contains('/dart-sdk/lib/')));
        expect(stamps.keys, contains(endsWith('/analysis_options.yaml')));
        final files = ProvenanceFiles()..merge(stamps);
        files.verify();
        support.writeAsStringSync("const method = 'pong';");
        expect(files.verify, throwsStateError);
        support.writeAsStringSync("const method = 'ping';");
        final report = File('${scratch.path}/proof.json')..deleteSync();
        await expectLater(
          gen.finish([fixture.source], wroteOutputs: false),
          throwsStateError,
        );
        expect(report.existsSync(), isFalse);
      },
    );
  }, skip: !Platform.isLinux);
}
