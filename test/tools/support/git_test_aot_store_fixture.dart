import 'dart:io';

import '../../../tools/git_test_aot_inputs.dart';
import '../../../tools/git_test_aot_store.dart';

/// Uses the real publisher, subprocess, receipt checks, and private copy. Only
/// inventory and compiler behavior are simulated, so faults can be scheduled
/// precisely without editing the checkout or its actual SDK.
class AotStoreFixture {
  AotStoreFixture(this.root);
  final Directory root;
  File get compiler => File('${root.path}/compiler');
  File get fault => File('${root.path}/fault');
  File get _calls => File('${root.path}/calls');
  int get compilations => _calls.readAsLinesSync().length;
  File get _input => File('${root.path}/input');
  String get identity => _input.readAsStringSync();
  set identity(String value) => _input.writeAsStringSync(value);
  bool provenanceValid = true;
  final observations = <String>[];

  Future<void> prepare() async {
    await _calls.create();
    identity = 'stable';
    await fault.writeAsString('none');
    await compiler.writeAsString(r'''#!/bin/sh
set -eu
printf '%s\n' "$3" >> calls
entry=$3; out=$5; dep=$7; config=$9
case "$out" in */snapshot) ;; *) exit 8 ;; esac
fault=$(cat fault)
printf 'producer bytes' > "$out"
case "$fault" in
  exit) printf 'compiler diagnostic\n' >&2; exit 19 ;;
  missing) rm "$out" ;;
  empty) : > "$out" ;;
  symlink) rm "$out"; ln -s "$PWD/fault" "$out" ;;
  hardlink) rm "$out"; ln "$PWD/fault" "$out" ;;
  edit-input) printf 'changed while compiling' > input ;;
esac
# Our controlled fixture roots have no spaces. The real parser also accepts
# the pinned compiler's Make-style escaping (covered in desktop tool tests).
case "$fault" in
  wrong-target) printf 'other: %s %s\n' "$entry" "$config" ;;
  no-entry) printf '%s: %s\n' "$out" "$config" ;;
  no-config) printf '%s: %s\n' "$out" "$entry" ;;
  uncovered) printf '%s: %s %s surprise.dart\n' "$out" "$entry" "$config" ;;
  *) printf '%s: %s %s\n' "$out" "$entry" "$config" ;;
esac > "$dep"
''');
    final chmod = await Process.run('/usr/bin/chmod', ['700', compiler.path]);
    if (chmod.exitCode != 0) throw StateError('${chmod.stderr}');
  }

  GitTestAotStore open(
    Directory scope, {
    Future<void> Function(GitTestAotPoint, File)? checkpoint,
    String? useCompiler,
  }) => GitTestAotStore.forTesting(
    scope: scope,
    capture: (recipe) async {
      observations.add(identity);
      return _Inputs(root, recipe, useCompiler ?? compiler.path, identity);
    },
    checkProvenance: (paths) async {
      if (!provenanceValid) throw StateError('Generation proof changed.');
    },
    checkpoint: checkpoint,
  );
}

class _Inputs implements GitTestAotInputs {
  _Inputs(this.root, this.recipe, this.dartExecutable, this.digest);
  @override
  final Directory root;
  @override
  final GitTestAot recipe;
  @override
  final String dartExecutable, digest;
  @override
  File get packageConfig => File('${root.path}/.dart_tool/package_config.json');
  @override
  Set<String> get filePaths => {
    '${root.path}/${recipe.entrypoint}',
    packageConfig.path,
  };
  @override
  String get runtimeExecutable =>
      File(dartExecutable).parent.uri.resolve('dartaotruntime').toFilePath();
  @override
  Map<String, String> get environment => const {
    'PATH': '/usr/bin:/bin',
    'DART_SUPPRESS_ANALYTICS': 'true',
  };
  @override
  List<String> arguments({required File output, required File depfile}) => [
    'compile',
    'aot-snapshot',
    recipe.entrypoint,
    '-o',
    output.path,
    '--depfile',
    depfile.path,
    '--packages',
    packageConfig.path,
  ];
}
