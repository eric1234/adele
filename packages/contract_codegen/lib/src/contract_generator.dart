import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:path/path.dart' as p;

final class ContractDiagnostic implements Exception {
  const ContractDiagnostic(this.message, this.path, this.line, this.column);

  final String message;
  final String path;
  final int line;
  final int column;

  @override
  String toString() => '$path:$line:$column: $message';
}

final class ContractGeneratedFile {
  const ContractGeneratedFile(this.path, this.contents);

  final String path;
  final String contents;
}

final class ContractModel {
  const ContractModel({
    required this.sourcePath,
    required this.partUri,
    required this.services,
    required this.values,
    required this.enums,
    required this.failures,
  });

  final String sourcePath;
  final String partUri;
  final List<ServiceModel> services;
  final List<ValueModel> values;
  final List<EnumModel> enums;
  final List<FailureModel> failures;
}

final class ServiceModel {
  const ServiceModel(this.name, this.id, this.methods);
  final String name;
  final String id;
  final List<MethodModel> methods;
}

final class MethodModel {
  const MethodModel(this.name, this.id, this.returnType, this.parameters);
  final String name;
  final String id;
  final TypeModel returnType;
  final List<FieldModel> parameters;
}

final class ValueModel {
  const ValueModel(this.name, this.id, this.fields);
  final String name;
  final String id;
  final List<FieldModel> fields;
}

final class FieldModel {
  const FieldModel(this.name, this.id, this.type, {required this.named});
  final String name;
  final String id;
  final TypeModel type;
  final bool named;
}

final class EnumModel {
  const EnumModel(this.name, this.values);
  final String name;
  final List<String> values;
}

final class FailureModel {
  const FailureModel(this.name, this.id);
  final String name;
  final String id;
}

enum TypeKind {
  string,
  boolean,
  integer,
  double_,
  list,
  enumeration,
  value,
  external,
}

final class TypeModel {
  const TypeModel(this.kind, this.dart, {this.argument, this.nullable = false});
  final TypeKind kind;
  final String dart;
  final TypeModel? argument;
  final bool nullable;
}

final class ContractGenerator {
  const ContractGenerator();

  Future<ContractGeneratedFile> generate(File source) async {
    final File absolute = source.absolute;
    final AnalysisContextCollection collection = AnalysisContextCollection(
      includedPaths: <String>[absolute.path],
    );
    final SomeResolvedUnitResult result = await collection
        .contextFor(absolute.path)
        .currentSession
        .getResolvedUnit(absolute.path);
    if (result is! ResolvedUnitResult) {
      throw ContractDiagnostic(
        'Could not resolve contract source.',
        absolute.path,
        1,
        1,
      );
    }
    final Diagnostic? error = result.diagnostics
        .where((Diagnostic value) => value.severity.name == 'ERROR')
        .firstOrNull;
    if (error != null) {
      final location = result.lineInfo.getLocation(error.offset);
      throw ContractDiagnostic(
        error.message,
        absolute.path,
        location.lineNumber,
        location.columnNumber,
      );
    }
    final ContractModel model = _Extractor(result).extract();
    final String unformatted = DartContractEmitter().emit(model);
    final String formatted = await _format(unformatted, source.parent);
    return ContractGeneratedFile(
      p.join(source.parent.path, model.partUri),
      formatted,
    );
  }

  Future<bool> apply(File source, {required bool check}) async {
    final ContractGeneratedFile output = await generate(source);
    final File destination = File(output.path);
    if (destination.existsSync() &&
        await destination.readAsString() == output.contents) {
      return true;
    }
    if (!check) await write(output);
    return false;
  }

  Future<void> write(ContractGeneratedFile output) async {
    final File destination = File(output.path);
    await destination.parent.create(recursive: true);
    final File temporary = File('${destination.path}.tmp.$pid');
    try {
      await temporary.writeAsString(output.contents, flush: true);
      await temporary.rename(destination.path);
    } finally {
      if (temporary.existsSync()) await temporary.delete();
    }
  }
}

final class _Extractor {
  _Extractor(this.result);
  final ResolvedUnitResult result;
  final Set<String> _ids = <String>{};
  final Set<String> _names = <String>{};

  ContractModel extract() {
    final List<PartDirective> parts = result.unit.directives
        .whereType<PartDirective>()
        .toList(growable: false);
    if (parts.isEmpty) {
      _fail(result.unit, 'Contract library must declare one generated part.');
    }
    if (parts.length != 1) {
      _fail(parts[1], 'Contract library must declare one generated part.');
    }
    final PartDirective part = parts.single;
    final String partUri = part.uri.stringValue ?? '';
    if (!partUri.endsWith('.g.dart') || p.isAbsolute(partUri)) {
      _fail(part, 'Generated part URI must be a relative .g.dart path.');
    }
    final List<ValueModel> values = <ValueModel>[];
    final List<EnumModel> enums = <EnumModel>[];
    final List<FailureModel> failures = <FailureModel>[];
    final List<ServiceModel> services = <ServiceModel>[];
    for (final CompilationUnitMember declaration in result.unit.declarations) {
      if (declaration case final EnumDeclaration value) {
        enums.add(
          EnumModel(
            value.name.lexeme,
            value.constants
                .map((EnumConstantDeclaration e) => e.name.lexeme)
                .toList(growable: false),
          ),
        );
      } else if (declaration case final ClassDeclaration value) {
        final InterfaceElement element = value.declaredFragment!.element;
        final String? valueId = _annotationId(element, 'AdeleValue');
        final String? failureId = _annotationId(element, 'AdeleFailure');
        final String? serviceId = _annotationId(element, 'AdeleService');
        if (valueId != null) values.add(_value(value, element, valueId));
        if (failureId != null) failures.add(_failure(value, failureId));
        if (serviceId != null) {
          services.add(_service(value, element, serviceId));
        }
      }
    }
    if (services.isEmpty) {
      _fail(result.unit, 'No @AdeleService service was found.');
    }
    if (failures.isEmpty) {
      _fail(result.unit, 'At least one @AdeleFailure type is required.');
    }
    return ContractModel(
      sourcePath: result.path,
      partUri: partUri,
      services: List.unmodifiable(services),
      values: List.unmodifiable(values),
      enums: List.unmodifiable(enums),
      failures: List.unmodifiable(failures),
    );
  }

  ValueModel _value(
    ClassDeclaration node,
    InterfaceElement element,
    String id,
  ) {
    _unique(node, node.name.lexeme, id);
    final ConstructorElement? constructor = element.unnamedConstructor;
    if (constructor == null || constructor.isFactory) {
      _fail(
        node,
        'Annotated value must have a generative unnamed constructor.',
      );
    }
    if (node.finalKeyword == null ||
        element.supertype?.element.name != 'Object') {
      _fail(
        node,
        'Annotated value must be a final class without a superclass.',
      );
    }
    final List<FieldModel> fields = <FieldModel>[];
    for (final FieldElement field in element.fields.where(
      (FieldElement field) => !field.isStatic,
    )) {
      final FormalParameterElement? parameter = constructor.formalParameters
          .where((FormalParameterElement p) => p.name == field.name)
          .firstOrNull;
      if (parameter == null || !parameter.isRequired) {
        _fail(
          node,
          'Field ${field.name} must have a matching required constructor parameter.',
        );
      }
      fields.add(
        FieldModel(
          field.name!,
          _annotationId(field, 'AdeleField') ?? field.name!,
          _type(field.type, node),
          named: parameter.isNamed,
        ),
      );
    }
    if (constructor.formalParameters.length != fields.length) {
      _fail(
        node,
        'Value constructor may only initialize declared instance fields.',
      );
    }
    _duplicates(node, fields.map((FieldModel value) => value.id), 'field ID');
    return ValueModel(node.name.lexeme, id, List.unmodifiable(fields));
  }

  FailureModel _failure(ClassDeclaration node, String id) {
    _unique(node, node.name.lexeme, id);
    final InterfaceElement element = node.declaredFragment!.element;
    if (node.finalKeyword == null ||
        !element.allSupertypes.any(
          (InterfaceType type) => type.element.name == 'Exception',
        )) {
      _fail(node, 'Annotated failure must be a final Exception class.');
    }
    final Set<String> fields = node.declaredFragment!.element.fields
        .map((FieldElement e) => e.name)
        .nonNulls
        .toSet();
    if (!fields.containsAll(<String>{'code', 'message', 'details'})) {
      _fail(node, 'Failure must declare code, message, and details fields.');
    }
    return FailureModel(node.name.lexeme, id);
  }

  ServiceModel _service(
    ClassDeclaration node,
    InterfaceElement element,
    String id,
  ) {
    _unique(node, node.name.lexeme, id);
    if (node.abstractKeyword == null ||
        node.interfaceKeyword == null ||
        element.supertype?.element.name != 'Object') {
      _fail(node, 'Annotated service must be an abstract interface class.');
    }
    final List<MethodModel> methods = <MethodModel>[];
    for (final MethodElement method in element.methods) {
      final String? methodId = _annotationId(method, 'AdeleMethod');
      if (methodId == null) {
        _failElement(method, 'Every service method must have @AdeleMethod.');
      }
      final DartType returnType = method.returnType;
      if (returnType is! InterfaceType ||
          returnType.element.name != 'Future' ||
          returnType.typeArguments.length != 1) {
        _failElement(method, 'Service methods must return Future<T>.');
      }
      final List<FieldModel> parameters = <FieldModel>[];
      for (final FormalParameterElement parameter in method.formalParameters) {
        if (parameter.isOptional || parameter.isNamed) {
          _failElement(
            parameter,
            'Service parameters must be required positional parameters.',
          );
        }
        parameters.add(
          FieldModel(
            parameter.name!,
            _annotationId(parameter, 'AdeleField') ?? parameter.name!,
            _type(parameter.type, node),
            named: false,
          ),
        );
      }
      _duplicates(
        node,
        parameters.map((FieldModel value) => value.id),
        'parameter ID',
      );
      methods.add(
        MethodModel(
          method.name!,
          methodId,
          _type(returnType.typeArguments.single, node),
          List.unmodifiable(parameters),
        ),
      );
    }
    _duplicates(
      node,
      methods.map((MethodModel value) => value.id),
      'method ID',
    );
    _duplicates(
      node,
      methods.map((MethodModel value) => value.name),
      'method name',
    );
    return ServiceModel(node.name.lexeme, id, List.unmodifiable(methods));
  }

  TypeModel _type(DartType type, AstNode node) {
    final bool nullable = type.getDisplayString().endsWith('?');
    if (type is InterfaceType) {
      final InterfaceType base = type;
      final String name = base.element.name ?? '';
      final TypeKind? scalar = <String, TypeKind>{
        'String': TypeKind.string,
        'bool': TypeKind.boolean,
        'int': TypeKind.integer,
        'double': TypeKind.double_,
      }[name];
      if (scalar != null) {
        return TypeModel(
          scalar,
          '$name${nullable ? '?' : ''}',
          nullable: nullable,
        );
      }
      if (name == 'List' && base.typeArguments.length == 1) {
        return TypeModel(
          TypeKind.list,
          type.getDisplayString(),
          argument: _type(base.typeArguments.single, node),
          nullable: nullable,
        );
      }
      if (base.element is EnumElement) {
        return TypeModel(
          TypeKind.enumeration,
          type.getDisplayString(),
          nullable: nullable,
        );
      }
      if (_annotationId(base.element, 'AdeleValue') != null) {
        return TypeModel(
          TypeKind.value,
          type.getDisplayString(),
          nullable: nullable,
        );
      }
      if (name == 'ResourceRef' &&
          base.element.library.uri.toString().startsWith(
                'package:adele_plugin_api/',
              ) ==
              true) {
        return TypeModel(
          TypeKind.external,
          type.getDisplayString(),
          nullable: nullable,
        );
      }
    }
    _fail(node, 'Unsupported contract type ${type.getDisplayString()}.');
  }

  ElementAnnotation? _annotation(Element element, String name) => element
      .metadata
      .annotations
      .where(
        (ElementAnnotation annotation) =>
            annotation.element?.enclosingElement?.name == name &&
            annotation.element?.library?.uri.toString() ==
                'package:adele_contract/adele_contract.dart',
      )
      .firstOrNull;
  String? _annotationId(Element element, String name) =>
      _annotation(
        element,
        name,
      )?.computeConstantValue()?.getField('id')?.toStringValue() ??
      _annotation(
        element,
        name,
      )?.computeConstantValue()?.getField('name')?.toStringValue();
  void _unique(AstNode node, String name, String id) {
    if (!_names.add(name)) _fail(node, 'Duplicate declaration name $name.');
    if (id.isEmpty || !_ids.add(id)) {
      _fail(node, 'Duplicate or empty stable ID $id.');
    }
  }

  void _duplicates(AstNode node, Iterable<String> values, String label) {
    final Set<String> seen = <String>{};
    for (final String value in values) {
      if (value.isEmpty || !seen.add(value)) {
        _fail(node, 'Duplicate or empty $label $value.');
      }
    }
  }

  Never _fail(AstNode node, String message) {
    final location = result.lineInfo.getLocation(node.offset);
    throw ContractDiagnostic(
      message,
      result.path,
      location.lineNumber,
      location.columnNumber,
    );
  }

  Never _failElement(Element element, String message) {
    final location = result.lineInfo.getLocation(element.firstFragment.offset);
    throw ContractDiagnostic(
      message,
      result.path,
      location.lineNumber,
      location.columnNumber,
    );
  }
}

final class DartContractEmitter {
  String emit(ContractModel model) {
    final StringBuffer out = StringBuffer(
      '// GENERATED CODE - DO NOT MODIFY BY HAND.\n'
      '// ignore_for_file: curly_braces_in_flow_control_structures, unnecessary_nullable_for_final_variable_declarations, unused_catch_clause, unused_element, use_null_aware_elements\n\n'
      'part of \'${p.basename(model.sourcePath)}\';\n\n',
    );
    for (final ServiceModel service in model.services) {
      out.writeln("const String ${_lower(service.name)}Id = '${service.id}';");
      for (final MethodModel method in service.methods) {
        out.writeln(
          "const String ${_lower(service.name)}${_cap(method.name)}Id = '${service.id}.${method.id}';",
        );
      }
      _client(out, service, model.failures);
      _dispatcher(out, service, model.failures);
    }
    for (final ValueModel value in model.values) {
      out.writeln("const String ${_lower(value.name)}TypeId = '${value.id}';");
      out.writeln(
        'Map<String, Object?> _encode${value.name}(${value.name} value) => <String, Object?>{${value.fields.map((FieldModel f) => "'${f.id}': ${_encode(f.type, 'value.${f.name}')} ").join(',')}};',
      );
      out.writeln(
        '${value.name} _decode${value.name}(Object? value) { final map = _contractMap(value, \'${value.name}\'); _contractFields(map, const {${value.fields.map((FieldModel f) => "'${f.id}'").join(',')}}, \'${value.name}\'); return ${value.name}(${value.fields.map((FieldModel f) => "${f.named ? '${f.name}: ' : ''}${_decode(f.type, "map['${f.id}']", f.name)}").join(',')}); }',
      );
    }
    for (final EnumModel value in model.enums) {
      out.writeln(
        '${value.name} _decode${value.name}(Object? value) { if (value is! String) throw AdeleProtocolException(\'Expected ${value.name}.\'); return switch(value) { ${value.values.map((String e) => "'$e' => ${value.name}.$e").join(',')}, _ => throw AdeleProtocolException(\'Unknown ${value.name}: \$value.\') }; }',
      );
    }
    out.writeln(
      "Map<Object?, Object?> _contractMap(Object? value, String label) { if (value is! Map<Object?, Object?>) throw AdeleProtocolException('Expected map for \$label.'); for (final key in value.keys) { if (key is! String) throw AdeleProtocolException('Expected string keys for \$label.'); } return value; }",
    );
    out.writeln(
      "void _contractFields(Map<Object?, Object?> value, Set<String> expected, String label) { for (final key in value.keys) { if (key is! String || !expected.contains(key)) throw AdeleProtocolException('Unknown field in \$label: \$key.'); } for (final key in expected) { if (!value.containsKey(key)) throw AdeleProtocolException('Missing field in \$label: \$key.'); } }",
    );
    out.writeln(
      "List<Object?> _contractList(Object? value, String label) { if (value is! List) throw AdeleProtocolException('Expected list for \$label.'); return List<Object?>.of(value); }",
    );
    out.writeln(
      "String _contractString(Object? value, String label) { if (value is! String) throw AdeleProtocolException('Expected String for \$label.'); return value; }",
    );
    out.writeln(
      "bool _contractBool(Object? value, String label) { if (value is! bool) throw AdeleProtocolException('Expected bool for \$label.'); return value; }",
    );
    out.writeln(
      "int _contractInt(Object? value, String label) { if (value is! int) throw AdeleProtocolException('Expected int for \$label.'); return value; }",
    );
    out.writeln(
      "double _contractDouble(Object? value, String label) { if (value is! double) throw AdeleProtocolException('Expected double for \$label.'); return value; }",
    );
    out.writeln(
      "Map<String, Object?> _contractResourceRef(ResourceRef value) => {'uri': value.uri.toString(), 'mediaType': value.mediaType}; ResourceRef _decodeResourceRef(Object? value) { final map = _contractMap(value, 'ResourceRef'); _contractFields(map, const {'uri', 'mediaType'}, 'ResourceRef'); final uri = map['uri']; final mediaType = map['mediaType']; if (uri is! String || mediaType != null && mediaType is! String) throw const AdeleProtocolException('Malformed ResourceRef.'); return ResourceRef(uri: Uri.parse(uri), mediaType: mediaType as String?); }",
    );
    return out.toString();
  }

  void _client(
    StringBuffer out,
    ServiceModel service,
    List<FailureModel> failures,
  ) {
    out.writeln(
      'final class ${service.name}Client implements ${service.name} { const ${service.name}Client(this._channel); final AdeleRequestChannel _channel;',
    );
    for (final MethodModel method in service.methods) {
      out.writeln(
        '@override Future<${method.returnType.dart}> ${method.name}(${method.parameters.map((FieldModel p) => '${p.type.dart} ${p.name}').join(',')}) async { try { return ${_decode(method.returnType, "await _channel.request('${service.id}.${method.id}', <String, Object?>{${method.parameters.map((FieldModel p) => "'${p.id}': ${_encode(p.type, p.name)}").join(',')}})", method.name)}; } on AdeleRemoteFailure catch(error) { ${_failureSwitch(failures)} } }',
      );
    }
    out.writeln('}');
  }

  void _dispatcher(
    StringBuffer out,
    ServiceModel service,
    List<FailureModel> failures,
  ) {
    out.writeln(
      'abstract interface class ${service.name}RequestDispatcher { Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request); } final class ${service.name}Dispatcher implements ${service.name}RequestDispatcher { const ${service.name}Dispatcher(this._service); final ${service.name} _service; @override Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async { final requestId = request[\'requestId\']; try { _contractFields(request, const {\'kind\', \'requestId\', \'method\', \'payload\'}, \'request envelope\'); if (requestId is! int || request[\'kind\'] != \'request\' || request[\'method\'] is! String) throw const AdeleProtocolException(\'Malformed request envelope.\'); final payload = _contractMap(request[\'payload\'], \'request payload\'); final Object? result = await switch(request[\'method\']) {',
    );
    for (final MethodModel method in service.methods) {
      out.writeln(
        "'${service.id}.${method.id}' => ${_dispatchMethod(method)},",
      );
    }
    out.writeln(
      "_ => throw const AdeleProtocolException('Unknown method.'), }; return {'kind': 'response', 'requestId': requestId, 'ok': true, 'payload': result};",
    );
    for (final FailureModel failure in failures) {
      out.writeln(
        "} on ${failure.name} catch(error) { return _contractFailure(requestId, '${failure.id}', error.code, error.message, error.details);",
      );
    }
    out.writeln(
      "} on AdeleProtocolException catch(error) { final unknown = error.message == 'Unknown method.'; return _contractFailure(requestId, null, unknown ? 'unknown_method' : 'invalid_request', error.message, const {}); } on Object catch(error) { return _contractFailure(requestId, null, 'internal_error', 'The backend request failed unexpectedly.', const {}); } } }",
    );
    out.writeln(
      "Map<String, Object?> _contractFailure(Object? requestId, String? declaredFailureType, String code, String message, Map<String, Object?> details) => {'kind': 'response', if(requestId is int) 'requestId': requestId, 'ok': false, 'error': {if(declaredFailureType != null) 'declaredFailureType': declaredFailureType, 'code': code, 'message': message, 'details': details}};",
    );
  }

  String _failureSwitch(List<FailureModel> failures) =>
      "switch(error.declaredFailureType) { ${failures.map((FailureModel f) => "case '${f.id}': throw ${f.name}(code: error.code, message: error.message, details: error.details);").join()} default: rethrow; }";
  String _dispatchMethod(MethodModel method) {
    final String invocation = _encode(
      method.returnType,
      'await _service.${method.name}(${method.parameters.map((FieldModel p) => _decode(p.type, "payload['${p.id}']", p.name)).join(',')})',
    );
    final String fields = method.parameters
        .map((FieldModel parameter) => "'${parameter.id}'")
        .join(',');
    return "(() async { _contractFields(payload, const {$fields}, '${method.name} payload'); return $invocation; })()";
  }

  String _encode(TypeModel type, String value) {
    final String encoded = switch (type.kind) {
      TypeKind.string ||
      TypeKind.boolean ||
      TypeKind.integer ||
      TypeKind.double_ => value,
      TypeKind.list =>
        '$value.map((element) => ${_encode(type.argument!, 'element')}).toList(growable: false)',
      TypeKind.enumeration => '$value.name',
      TypeKind.value => '_encode${_base(type.dart)}($value)',
      TypeKind.external => '_contractResourceRef($value)',
    };
    return type.nullable
        ? '$value == null ? null : ${_parenthesize(encoded)}'
        : encoded;
  }

  String _decode(TypeModel type, String value, String label) {
    final String decoded = switch (type.kind) {
      TypeKind.string => '_contractString($value, \'$label\')',
      TypeKind.boolean => '_contractBool($value, \'$label\')',
      TypeKind.integer => '_contractInt($value, \'$label\')',
      TypeKind.double_ => '_contractDouble($value, \'$label\')',
      TypeKind.list =>
        "List.unmodifiable(_contractList($value, '$label').map((element) => ${_decode(type.argument!, 'element', '$label element')}))",
      TypeKind.enumeration => '_decode${_base(type.dart)}($value)',
      TypeKind.value => '_decode${_base(type.dart)}($value)',
      TypeKind.external => '_decodeResourceRef($value)',
    };
    return type.nullable ? '$value == null ? null : $decoded' : decoded;
  }

  String _base(String value) => value.replaceAll('?', '');
  String _parenthesize(String value) => '($value)';
  String _lower(String value) =>
      '${value[0].toLowerCase()}${value.substring(1)}';
  String _cap(String value) => '${value[0].toUpperCase()}${value.substring(1)}';
}

Future<String> _format(String source, Directory workingDirectory) async {
  final Directory temporaryDirectory = await Directory.systemTemp.createTemp(
    'contract_codegen.',
  );
  try {
    final File input = File(p.join(temporaryDirectory.path, 'contract.g.dart'));
    await input.writeAsString(source);
    final ProcessResult result = await Process.run(
      Platform.resolvedExecutable,
      <String>['format', input.path],
      workingDirectory: workingDirectory.path,
    );
    if (result.exitCode != 0) {
      throw StateError('dart format failed: ${result.stderr}');
    }
    return input.readAsString();
  } finally {
    await temporaryDirectory.delete(recursive: true);
  }
}
