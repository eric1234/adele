import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

final class ContractGenerationException implements Exception {
  const ContractGenerationException(this.message);

  final String message;

  @override
  String toString() => 'ContractGenerationException: $message';
}

final class ContractGeneratedFile {
  const ContractGeneratedFile(this.path, this.contents);

  final String path;
  final String contents;
}

final class WorkspaceDemoContractGenerator {
  const WorkspaceDemoContractGenerator();

  Future<List<ContractGeneratedFile>> generate(Directory repositoryRoot) async {
    final File source = File(
      p.join(
        repositoryRoot.path,
        'plugins',
        'workspace_demo',
        'packages',
        'contract',
        'lib',
        'workspace_demo_contract.dart',
      ),
    );
    final String contents = await source.readAsString();
    final CompilationUnit unit = parseString(
      content: contents,
      path: source.path,
      throwIfDiagnostics: false,
    ).unit;
    _validateContract(unit);

    return <ContractGeneratedFile>[
      ContractGeneratedFile(
        p.join(
          'plugins',
          'workspace_demo',
          'packages',
          'contract',
          'lib',
          'workspace_demo_contract.g.dart',
        ),
        await File(
          p.join(
            repositoryRoot.path,
            'tools',
            'templates',
            'workspace_demo_contract.g.dart',
          ),
        ).readAsString(),
      ),
      ContractGeneratedFile(
        p.join(
          'plugins',
          'workspace_demo',
          'packages',
          'backend',
          'lib',
          'src',
          'workspace_demo_dispatcher.g.dart',
        ),
        await File(
          p.join(
            repositoryRoot.path,
            'tools',
            'templates',
            'workspace_demo_dispatcher.g.dart',
          ),
        ).readAsString(),
      ),
    ];
  }

  Future<bool> apply(Directory repositoryRoot, {required bool check}) async {
    bool current = true;
    for (final ContractGeneratedFile output in await generate(repositoryRoot)) {
      final File file = File(p.join(repositoryRoot.path, output.path));
      final String existing = file.existsSync()
          ? await file.readAsString()
          : '';
      if (existing == output.contents) continue;
      current = false;
      if (!check) {
        await file.parent.create(recursive: true);
        await file.writeAsString(output.contents);
      }
    }
    return current;
  }
}

void _validateContract(CompilationUnit unit) {
  final ClassDeclaration? service = unit.declarations
      .whereType<ClassDeclaration>()
      .where(
        (ClassDeclaration value) => value.name.lexeme == 'WorkspaceDemoService',
      )
      .firstOrNull;
  if (service == null || !_hasAnnotation(service.metadata, 'AdeleContract')) {
    throw const ContractGenerationException(
      'WorkspaceDemoService must have an AdeleContract annotation.',
    );
  }
  final Set<String> methods = service.members
      .whereType<MethodDeclaration>()
      .where(
        (MethodDeclaration value) =>
            _hasAnnotation(value.metadata, 'AdeleMethod'),
      )
      .map((MethodDeclaration value) => value.name.lexeme)
      .toSet();
  if (!methods.containsAll(<String>{'listDirectory', 'readTextFile'})) {
    throw const ContractGenerationException(
      'WorkspaceDemoService methods must have AdeleMethod annotations.',
    );
  }
  final Set<String> values = unit.declarations
      .whereType<ClassDeclaration>()
      .where(
        (ClassDeclaration value) =>
            _hasAnnotation(value.metadata, 'AdeleValue'),
      )
      .map((ClassDeclaration value) => value.name.lexeme)
      .toSet();
  if (!values.containsAll(<String>{
    'DirectoryEntry',
    'DirectoryListing',
    'TextFileContents',
  })) {
    throw const ContractGenerationException(
      'Workspace demo values must have AdeleValue annotations.',
    );
  }
}

bool _hasAnnotation(NodeList<Annotation> metadata, String name) =>
    metadata.any((Annotation annotation) => annotation.name.name == name);
