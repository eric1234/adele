import 'dart:io';

import 'package:contract_codegen/contract_codegen.dart';
import 'package:test/test.dart';

void main() {
  test('generation is byte-for-byte deterministic', () async {
    final Directory repository = Directory.current.parent.parent;
    final WorkspaceDemoContractGenerator generator =
        const WorkspaceDemoContractGenerator();

    final List<ContractGeneratedFile> first = await generator.generate(
      repository,
    );
    final List<ContractGeneratedFile> second = await generator.generate(
      repository,
    );

    expect(
      first.map((ContractGeneratedFile value) => value.path),
      second.map((ContractGeneratedFile value) => value.path),
    );
    expect(
      first.map((ContractGeneratedFile value) => value.contents),
      second.map((ContractGeneratedFile value) => value.contents),
    );
    expect(await generator.apply(repository, check: true), isTrue);
  });
}
