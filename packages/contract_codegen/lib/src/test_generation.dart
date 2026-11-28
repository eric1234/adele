import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'contract_generator.dart';
import 'contract_inputs.dart';
import 'provenance_files.dart';

/// Evidence for *this* full generation only. There is no previous record to
/// load, no skip path, and the analyzer/extractor/emitter are unchanged.
final class TestGeneration {
  TestGeneration(this.directory)
    : libraries =
          (jsonDecode(
                    File(
                      p.join(directory.path, 'libraries.json'),
                    ).readAsStringSync(),
                  )
                  as List)
              .cast<String>();

  final Directory directory;
  final List<String> libraries;
  final _hashes = <String, (String, String)>{};
  final _inputs = <String, ProvenanceFiles>{};
  final _outputs = <String, String>{};
  final _directives = <String, (String, List<String?>?)>{};
  var _supported = true;

  Future<ContractGeneratedFile> generate(File source) async {
    if (!_supported || !libraries.any((dir) => p.isWithin(dir, source.path))) {
      return const ContractGenerator().generate(source);
    }
    final files = ProvenanceFiles();
    final inputs = ContractInputs(
      excludedOutput: p.setExtension(source.path, '.g.dart'),
      directiveCache: _directives,
      testRead: (kind, path) {
        // First read is hashed before the semantic operation; duplicate
        // analyzer/SDK reads reuse *only* an invocation-local observed digest.
        files.watch(path, read: kind == 'read', listing: kind == 'directory');
        if (kind == 'read' && files.reads.contains(path)) {
          final stamp = files.stamps[path]!;
          final prior = _hashes[path];
          if (prior == null || prior.$1 != stamp) {
            _hashes[path] = (
              stamp,
              sha256.convert(File(path).readAsBytesSync()).toString(),
            );
          }
        }
      },
    );
    final output = await const ContractGenerator().generate(
      source,
      inputs: inputs,
    );
    if (!inputs.cacheable) {
      _supported = false;
    } else {
      files.verify();
      _inputs[output.path] = files;
      _outputs[output.path] = sha256
          .convert(utf8.encode(output.contents))
          .toString();
    }
    return output;
  }

  Future<void> finish(List<File> sources, {required bool wroteOutputs}) async {
    if (!_supported) return;
    if (wroteOutputs) {
      // A first bootstrap can create a previously negative generated sibling
      // or change a directory inventory. Re-establish the selected proofs
      // from the settled filesystem, including fresh semantic emission.
      final selected = _inputs.keys.toSet();
      for (final source in sources) {
        if (selected.contains(p.setExtension(source.path, '.g.dart'))) {
          await generate(source);
        }
      }
      if (!_supported) return;
    }
    for (final entry in _inputs.entries) {
      entry.value.watch(entry.key, read: true);
      entry.value.verify();
    }
    File(p.join(directory.path, 'proof.json')).writeAsStringSync(
      jsonEncode({
        'executable': Platform.resolvedExecutable,
        'packageConfig': (await Isolate.packageConfig)?.toString(),
        'hashes': {
          for (final entry in _hashes.entries) entry.key: entry.value.$2,
          ..._outputs,
        },
        'outputs': {
          for (final entry in _inputs.entries)
            entry.key: {
              'stamps': entry.value.stamps,
              'reads': entry.value.reads.toList(),
            },
        },
      }),
    );
  }
}
