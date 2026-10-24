import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'contract_generator.dart';
import 'contract_inputs.dart';

const _version = 1;
final _activeRoots = <String>{};

/// Internal, checkout-local native generation. The launcher also holds its
/// preparation lease; this lock serializes direct incremental CLI invocations.
Future<({int current, int regenerated})> generateIncrementally({
  required Directory root,
  required List<File> sources,
  required String configuration,
  required String generatorIdentity,
  void Function()? validateIdentity,
  Future<ContractGeneratedFile> Function(File, {ContractInputs? inputs})?
  generate,
}) async {
  final rootPath = root.resolveSymbolicLinksSync();
  if (!_activeRoots.add(rootPath)) {
    throw FileSystemException(
      'Contract generation is already active.',
      rootPath,
    );
  }
  RandomAccessFile? lock;
  try {
    final directory = Directory(p.join(rootPath, '.dart_tool/adele/contracts'));
    await directory.create(recursive: true);
    lock = await File(
      p.join(directory.path, 'generation.lock'),
    ).open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    return await _generate(
      root: Directory(rootPath),
      sources: sources,
      configuration: configuration,
      generatorIdentity: generatorIdentity,
      recordFile: File(p.join(directory.path, 'freshness.json')),
      generate: generate ?? const ContractGenerator().generate,
      validateIdentity: validateIdentity,
    );
  } finally {
    await lock?.close();
    _activeRoots.remove(rootPath);
  }
}

Future<({int current, int regenerated})> _generate({
  required Directory root,
  required List<File> sources,
  required String configuration,
  required String generatorIdentity,
  required File recordFile,
  required void Function()? validateIdentity,
  required Future<ContractGeneratedFile> Function(
    File, {
    ContractInputs? inputs,
  })
  generate,
}) async {
  final metadata = ContractInputs(excludedOutput: '');
  for (final relative in [
    'pubspec.yaml',
    'pubspec_overrides.yaml',
    'pubspec.lock',
    '.dart_tool/package_config.json',
    '.dart_tool/package_graph.json',
  ]) {
    final file = metadata.resources.getFile(p.join(root.path, relative));
    if (file.exists) file.readAsBytesSync();
  }
  // Inventory changes must not invalidate unrelated contracts. It is checked
  // for races, but is deliberately outside the common generation identity.
  final identity = _digest(
    utf8.encode(jsonEncode([generatorIdentity, metadata.observations])),
  );
  final config = metadata.resources.getFile(
    p.join(root.path, 'contract_codegen.yaml'),
  );
  if (config.readAsStringSync() != configuration) {
    throw FileSystemException(
      'Contract configuration changed; retry.',
      config.path,
    );
  }
  final previous = _readRecords(recordFile, identity);
  final states = <String, _ContractState>{};
  final observations = <String, String>{};
  final stamps = <String, String>{};
  final seen = <String>{};
  var dirty = <String>[];
  for (final file in sources) {
    final source = p.normalize(file.absolute.path);
    if (!p.isWithin(root.path, source) ||
        p.extension(source) != '.dart' ||
        !seen.add(source)) {
      throw FormatException(
        'Expected a unique in-repository Dart source: $source',
      );
    }
    final outputPath = p.setExtension(source, '.g.dart');
    final record = _readRecord(previous[source], source, identity);
    var reusable = record != null;
    if (record != null) {
      for (final entry in record.inputs.entries) {
        final value = observations.putIfAbsent(entry.key, () {
          final captured = ContractInputs.capture(entry.key);
          stamps[entry.key] = captured.stamp;
          return captured.value;
        });
        if (value != entry.value) reusable = false;
      }
      if (_outputDigest(outputPath) != record.output) reusable = false;
    }
    if (reusable) {
      states[source] = _ContractState(record!.inputs, record.output);
    } else {
      dirty.add(source);
    }
  }
  final regenerated = <String>{};
  final written = <String, String>{};
  void validateInputs() {
    validateIdentity?.call();
    metadata.validate();
    final checked = <String>{};
    for (final entry in states.entries) {
      final state = entry.value;
      if (state.tracker case final tracker?) {
        tracker.validate(writtenOutputs: written.keys.toSet());
      } else {
        for (final input in state.inputs.entries) {
          if (!checked.add(input.key)) continue;
          final path = (jsonDecode(input.key) as List<dynamic>)[1] as String;
          if (written.containsKey(path)) continue;
          final captured = ContractInputs.capture(input.key);
          if (captured.value != input.value ||
              captured.stamp != stamps[input.key]) {
            throw FileSystemException(
              'Contract input changed during generation; retry.',
              path,
            );
          }
        }
      }
    }
    for (final entry in written.entries) {
      if (_outputDigest(entry.key) != entry.value) {
        throw FileSystemException(
          'Contract output changed during generation; retry.',
          entry.key,
        );
      }
    }
  }

  for (var pass = 0; ; pass++) {
    if (dirty.isEmpty) break;
    if (pass > sources.length) {
      throw FileSystemException(
        'Generated contract dependencies did not settle; retry.',
        root.path,
      );
    }
    if (pass > 0) validateInputs();
    final outputs = <ContractGeneratedFile>[];
    for (final source in dirty) {
      final path = p.setExtension(source, '.g.dart');
      final inputs = ContractInputs(excludedOutput: path);
      final output = await generate(File(source), inputs: inputs);
      if (output.path != path) {
        throw FileSystemException('Unexpected contract output.', output.path);
      }
      states[source] = _ContractState(
        inputs.observations,
        _digest(utf8.encode(output.contents)),
        tracker: inputs,
      );
      regenerated.add(source);
      outputs.add(output);
    }
    validateInputs();
    for (final output in outputs) {
      final digest = _digest(utf8.encode(output.contents));
      if (_outputDigest(output.path) != digest) {
        await const ContractGenerator().write(output);
        written[output.path] = digest;
      }
    }
    // Other libraries' generated parts remain real analyzer inputs. If this
    // invocation changed one, regenerate its dependents before certifying them.
    // This also settles a completely missing set of generated siblings.
    final after = <String, String>{};
    dirty = [
      for (final entry in states.entries)
        if (entry.value.inputs.entries.any(
          (input) =>
              after.putIfAbsent(
                input.key,
                () => ContractInputs.observe(input.key),
              ) !=
              input.value,
        ))
          entry.key,
    ];
    if (dirty.isEmpty) break;
  }

  final records = <String, Object>{};
  for (final source in seen) {
    final state = states[source]!;
    if (_outputDigest(p.setExtension(source, '.g.dart')) != state.output) {
      throw FileSystemException(
        'Contract output changed during generation; retry.',
        source,
      );
    }
    if (state.tracker?.cacheable ?? true) {
      records[source] = _record(source, identity, state.inputs, state.output);
    }
  }
  final contents = jsonEncode({
    'version': _version,
    'generator': identity,
    'contracts': records,
  });
  final temporary = File('${recordFile.path}.tmp.$pid');
  try {
    temporary.writeAsStringSync(contents, flush: true);
    validateInputs();
    for (final source in seen) {
      if (_outputDigest(p.setExtension(source, '.g.dart')) !=
          states[source]!.output) {
        throw FileSystemException(
          'Contract output changed before publication; retry.',
          source,
        );
      }
    }
    temporary.renameSync(recordFile.path);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
  return (
    current: sources.length - regenerated.length,
    regenerated: regenerated.length,
  );
}

final class _ContractState {
  _ContractState(this.inputs, this.output, {this.tracker});
  final Map<String, String> inputs;
  final String output;
  final ContractInputs? tracker;
}

Map<String, dynamic> _readRecords(File file, String identity) {
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic> &&
        decoded['version'] == _version &&
        decoded['generator'] == identity &&
        decoded['contracts'] is Map<String, dynamic>) {
      return decoded['contracts'] as Map<String, dynamic>;
    }
  } on FormatException {
    // Incomplete or damaged records are misses, never generation authority.
  } on FileSystemException {
    // Missing records are the ordinary cold path.
  }
  return {};
}

({Map<String, String> inputs, String output})? _readRecord(
  Object? value,
  String source,
  String identity,
) {
  if (value is! Map<String, dynamic> ||
      value['inputs'] is! Map<String, dynamic> ||
      value['output'] is! String ||
      value['seal'] is! String) {
    return null;
  }
  final inputs = <String, String>{};
  for (final entry in (value['inputs'] as Map<String, dynamic>).entries) {
    if (entry.value is! String) return null;
    try {
      ContractInputs.validateKey(entry.key);
    } on FormatException {
      return null;
    }
    inputs[entry.key] = entry.value as String;
  }
  if (!RegExp(
    r'^[a-f0-9]{64}$',
  ).hasMatch(inputs[jsonEncode(['read', source])] ?? '')) {
    return null;
  }
  final output = value['output'] as String;
  if (_record(source, identity, inputs, output)['seal'] != value['seal']) {
    return null;
  }
  return (inputs: inputs, output: output);
}

Map<String, Object> _record(
  String source,
  String identity,
  Map<String, String> inputs,
  String output,
) {
  final ordered = {
    for (final key in inputs.keys.toList()..sort()) key: inputs[key]!,
  };
  return {
    'inputs': ordered,
    'output': output,
    'seal': _digest(
      utf8.encode(jsonEncode([_version, source, identity, ordered, output])),
    ),
  };
}

String? _outputDigest(String path) {
  final file = File(path);
  if (!file.existsSync() || file.lengthSync() == 0) return null;
  return _digest(file.readAsBytesSync());
}

String _digest(List<int> bytes) => sha256.convert(bytes).toString();
