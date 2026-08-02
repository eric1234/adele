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
  void_,
  string,
  boolean,
  integer,
  double_,
  list,
  map,
  uri,
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

  TypeModel get nonNullable => TypeModel(
    kind,
    dart.endsWith('?') ? dart.substring(0, dart.length - 1) : dart,
    argument: argument,
  );
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
        final String? valueId = _declaredAnnotationId(element, 'AdeleValue');
        final String? failureId = _declaredAnnotationId(
          element,
          'AdeleFailure',
        );
        final String? serviceId = _declaredAnnotationId(
          element,
          'AdeleService',
        );
        if (valueId != null) values.add(_value(value, element, valueId));
        if (failureId != null) failures.add(_failure(value, failureId));
        if (serviceId != null) {
          services.add(_service(value, element, serviceId));
        }
      }
    }
    values.sort((ValueModel a, ValueModel b) => a.id.compareTo(b.id));
    enums.sort((EnumModel a, EnumModel b) => a.name.compareTo(b.name));
    failures.sort((FailureModel a, FailureModel b) => a.id.compareTo(b.id));
    services.sort((ServiceModel a, ServiceModel b) => a.id.compareTo(b.id));
    if (services.isEmpty) {
      _fail(result.unit, 'No @AdeleService service was found.');
    }
    if (services.length != 1) {
      _fail(
        result.unit,
        'Phase II contract libraries must declare exactly one @AdeleService service.',
      );
    }
    if (failures.isEmpty) {
      _fail(result.unit, 'At least one @AdeleFailure type is required.');
    }
    _rejectValueCycles(values);
    _rejectGeneratedSymbolCollisions(services, values, failures);
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
    if (element.constructors.length != 1 ||
        element.unnamedConstructor == null) {
      _fail(
        node,
        'Annotated value must declare exactly one unnamed constructor.',
      );
    }
    final ConstructorElement constructor = element.unnamedConstructor!;
    if (constructor.isFactory) {
      _fail(
        node,
        'Annotated value must have a generative unnamed constructor.',
      );
    }
    if (node.finalKeyword == null ||
        element.supertype?.element.name != 'Object' ||
        element.mixins.isNotEmpty ||
        element.interfaces.isNotEmpty) {
      _fail(
        node,
        'Annotated value must be a final class without a superclass.',
      );
    }
    final List<FieldModel> fields = <FieldModel>[];
    for (final FieldElement field in element.fields.where(
      (FieldElement field) => !field.isStatic,
    )) {
      if (!field.isFinal) {
        _failElement(field, 'Value fields must be final.');
      }
      final FormalParameterElement? parameter = constructor.formalParameters
          .where((FormalParameterElement p) => p.name == field.name)
          .firstOrNull;
      if (parameter == null) {
        _fail(
          node,
          'Field ${field.name} must have a matching constructor parameter.',
        );
      }
      if (!parameter.isRequired || !parameter.isNamed) {
        _fail(node, 'Value constructor parameters must be required and named.');
      }
      if (parameter.type != field.type) {
        _fail(
          node,
          'Field ${field.name} and its required named constructor parameter must have exactly the same type.',
        );
      }
      if (parameter is! FieldFormalParameterElement ||
          parameter.field?.name != field.name) {
        _fail(
          node,
          'Value constructor parameters must be required named field-formal parameters.',
        );
      }
      fields.add(
        FieldModel(
          field.name!,
          _annotationId(field, 'AdeleField') ?? field.name!,
          _type(field.type, field),
          named: true,
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
    fields.sort((FieldModel a, FieldModel b) => a.id.compareTo(b.id));
    return ValueModel(node.name.lexeme, id, List.unmodifiable(fields));
  }

  FailureModel _failure(ClassDeclaration node, String id) {
    _unique(node, node.name.lexeme, id);
    final InterfaceElement element = node.declaredFragment!.element;
    if (node.finalKeyword == null ||
        element.supertype?.element.name != 'Object' ||
        element.mixins.isNotEmpty ||
        element.interfaces.length != 1 ||
        element.interfaces.single.element.name != 'Exception') {
      _fail(node, 'Annotated failure must be a final Exception class.');
    }
    final List<FieldElement> instanceFields = element.fields
        .where((FieldElement field) => !field.isStatic)
        .toList(growable: false);
    for (final FieldElement field in instanceFields) {
      if (!field.isFinal) _failElement(field, 'Failure fields must be final.');
    }
    if (element.constructors.length != 1 ||
        element.unnamedConstructor == null) {
      _fail(
        node,
        'Annotated failure must declare exactly one unnamed constructor.',
      );
    }
    final Set<String> fields = instanceFields
        .map((FieldElement e) => e.name)
        .nonNulls
        .toSet();
    if (fields.length != 3 ||
        !fields.containsAll(<String>{'code', 'message', 'details'})) {
      _fail(
        node,
        'Failure must declare only code, message, and details fields.',
      );
    }
    final Map<String, FieldElement> byName = {
      for (final FieldElement field in instanceFields) field.name!: field,
    };
    if (byName['code']?.type.getDisplayString() != 'String' ||
        byName['message']?.type.getDisplayString() != 'String' ||
        byName['details']?.type.getDisplayString() != 'Map<String, Object?>') {
      _fail(
        node,
        'Failure fields must be String, String, and Map<String, Object?>.',
      );
    }
    final ConstructorElement constructor = element.unnamedConstructor!;
    if (constructor.isFactory) {
      _fail(
        node,
        'Annotated failure must have a generative unnamed constructor.',
      );
    }
    if (constructor.formalParameters.length != instanceFields.length) {
      _fail(
        node,
        'Failure constructor may only initialize declared instance fields.',
      );
    }
    final Map<String, FormalParameterElement> parameters = {
      for (final FormalParameterElement parameter
          in constructor.formalParameters)
        if (parameter.name != null) parameter.name!: parameter,
    };
    for (final String name in const ['code', 'message', 'details']) {
      final FormalParameterElement? parameter = parameters[name];
      final FieldElement field = byName[name]!;
      if (parameter == null ||
          !parameter.isNamed ||
          (name != 'details' && !parameter.isRequired) ||
          parameter.type != field.type ||
          parameter is! FieldFormalParameterElement ||
          parameter.field?.name != field.name) {
        _fail(
          node,
          'Failure constructor must reconstruct required named code and message plus named details field-formal parameters.',
        );
      }
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
        element.supertype?.element.name != 'Object' ||
        element.mixins.isNotEmpty ||
        element.interfaces.isNotEmpty) {
      _fail(node, 'Annotated service must be an abstract interface class.');
    }
    final List<MethodModel> methods = <MethodModel>[];
    for (final FieldElement field in element.fields.where(
      (FieldElement field) => !field.isSynthetic,
    )) {
      _failElement(
        field,
        'Service declarations may only contain abstract instance methods annotated with @AdeleMethod.',
      );
    }
    for (final ConstructorElement constructor in element.constructors) {
      if (!constructor.isSynthetic) {
        _failElement(
          constructor,
          'Service declarations may not declare constructors.',
        );
      }
    }
    for (final PropertyAccessorElement accessor in <PropertyAccessorElement>[
      ...element.getters,
      ...element.setters,
    ]) {
      if (!accessor.isSynthetic) {
        _failElement(
          accessor,
          'Service declarations may not declare getters or setters.',
        );
      }
    }
    for (final MethodElement method in element.methods) {
      if (method.isStatic || !method.isAbstract || method.isOperator) {
        _failElement(
          method,
          'Service declarations may only contain abstract instance methods annotated with @AdeleMethod.',
        );
      }
      if (method.typeParameters.isNotEmpty) {
        _failElement(method, 'Generic service methods are not supported.');
      }
      final String? methodId = _declaredAnnotationId(method, 'AdeleMethod');
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
            _type(parameter.type, parameter),
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
          _type(returnType.typeArguments.single, method),
          List.unmodifiable(parameters),
        ),
      );
    }
    _duplicates(
      node,
      methods.map((MethodModel value) => value.id),
      'method ID',
    );
    methods.sort((MethodModel a, MethodModel b) => a.id.compareTo(b.id));
    if (methods.isEmpty) {
      _fail(node, 'Annotated service must declare at least one method.');
    }
    _duplicates(
      node,
      methods.map((MethodModel value) => value.name),
      'method name',
    );
    return ServiceModel(node.name.lexeme, id, List.unmodifiable(methods));
  }

  void _rejectValueCycles(List<ValueModel> values) {
    final Map<String, ValueModel> byName = {
      for (final ValueModel value in values) value.name: value,
    };
    final Set<String> active = <String>{};
    final Set<String> complete = <String>{};

    void visit(ValueModel value) {
      if (complete.contains(value.name)) return;
      if (!active.add(value.name)) {
        _fail(
          result.unit,
          'Recursive annotated value schema cycles are not supported: ${value.name}.',
        );
      }
      for (final FieldModel field in value.fields) {
        for (final String dependency in _valueDependencies(field.type)) {
          final ValueModel? target = byName[dependency];
          if (target != null) visit(target);
        }
      }
      active.remove(value.name);
      complete.add(value.name);
    }

    for (final ValueModel value in values) {
      visit(value);
    }
  }

  Iterable<String> _valueDependencies(TypeModel type) sync* {
    if (type.kind == TypeKind.value) yield type.dart.replaceAll('?', '');
    if (type.argument != null) yield* _valueDependencies(type.argument!);
  }

  void _rejectGeneratedSymbolCollisions(
    List<ServiceModel> services,
    List<ValueModel> values,
    List<FailureModel> failures,
  ) {
    final Map<String, String> symbols = <String, String>{};
    final Set<String> declaredNames = <String>{
      ...services.map((ServiceModel value) => value.name),
      ...values.map((ValueModel value) => value.name),
      ...failures.map((FailureModel value) => value.name),
      ...result.unit.declarations.whereType<ClassDeclaration>().map(
        (ClassDeclaration value) => value.name.lexeme,
      ),
    };
    void add(String symbol, String source) {
      if (declaredNames.contains(symbol)) {
        _fail(
          result.unit,
          'Generated symbol collision for $symbol between a contract declaration and $source.',
        );
      }
      final String? previous = symbols[symbol];
      if (previous != null) {
        _fail(
          result.unit,
          'Generated symbol collision for $symbol between $previous and $source.',
        );
      }
      symbols[symbol] = source;
    }

    for (final ServiceModel service in services) {
      add('${_lowerName(service.name)}Id', 'service ${service.name}');
      add('${service.name}Client', 'service ${service.name}');
      add('${service.name}Dispatcher', 'service ${service.name}');
      add('${service.name}RequestDispatcher', 'service ${service.name}');
      for (final MethodModel method in service.methods) {
        add(
          '${_lowerName(service.name)}${_capitalize(method.name)}Id',
          'method ${service.name}.${method.name}',
        );
      }
    }
    for (final ValueModel value in values) {
      add('${_lowerName(value.name)}TypeId', 'value ${value.name}');
      add('_encode${value.name}', 'value ${value.name}');
      add('_decode${value.name}', 'value ${value.name}');
    }
    for (final FailureModel failure in failures) {
      add('${_lowerName(failure.name)}TypeId', 'failure ${failure.name}');
    }
  }

  TypeModel _type(DartType type, Object node) {
    if (type is DynamicType || type is TypeParameterType) {
      _failSource(
        node,
        'Dynamic or unconstrained contract types are not supported.',
      );
    }
    final bool nullable = type.getDisplayString().endsWith('?');
    if (type is VoidType) return const TypeModel(TypeKind.void_, 'void');
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
      if (name == 'Map' && base.element.library.uri.toString() == 'dart:core') {
        if (base.typeArguments.length != 2 ||
            base.typeArguments.first.getDisplayString() != 'String' ||
            base.typeArguments.last.getDisplayString() != 'Object?') {
          _failSource(
            node,
            'Only Map<String, Object?> is supported; map keys must be String.',
          );
        }
        return TypeModel(
          TypeKind.map,
          type.getDisplayString(),
          nullable: nullable,
        );
      }
      if (name == 'Stream') {
        _failSource(node, 'Stream contract types are not supported.');
      }
      if (name == 'Uri' && base.element.library.uri.toString() == 'dart:core') {
        return TypeModel(
          TypeKind.uri,
          type.getDisplayString(),
          nullable: nullable,
        );
      }
      if (base.element is EnumElement) {
        _requireLocalType(base.element, node);
        return TypeModel(
          TypeKind.enumeration,
          type.getDisplayString(),
          nullable: nullable,
        );
      }
      if (_annotation(base.element, 'AdeleValue') != null) {
        if (!_isLocalType(base.element)) {
          _failSource(
            node,
            'Contract schema declarations must be declared in the source library, not imported.',
          );
        }
        _declaredAnnotationId(base.element, 'AdeleValue');
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
      if (base.element.library.uri.toString() != 'dart:core' &&
          base.element.library.uri.toString() != 'dart:async' &&
          !_isLocalType(base.element)) {
        _failSource(node, 'Imported contract schema types are not supported.');
      }
    }
    _failSource(node, 'Unsupported contract type ${type.getDisplayString()}.');
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
  String? _declaredAnnotationId(Element element, String name) {
    if (_annotation(element, name) == null) return null;
    final String? id = _annotationId(element, name);
    if (id == null || !_validId(id)) {
      _failElement(
        element,
        '@$name must declare a stable ID using ASCII letters or digits separated by single dots, hyphens, or underscores.',
      );
    }
    return id;
  }

  void _unique(AstNode node, String name, String id) {
    if (!_names.add(name)) _fail(node, 'Duplicate declaration name $name.');
    if (!_validId(id)) {
      _fail(node, 'Invalid stable ID $id.');
    }
    if (!_ids.add(id)) {
      _fail(node, 'Duplicate stable ID $id.');
    }
  }

  void _duplicates(AstNode node, Iterable<String> values, String label) {
    final Set<String> seen = <String>{};
    for (final String value in values) {
      if (!_validId(value)) {
        _fail(node, 'Invalid $label $value.');
      }
      if (!seen.add(value)) {
        _fail(node, 'Duplicate $label $value.');
      }
    }
  }

  bool _validId(String value) =>
      RegExp(r'^[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*$').hasMatch(value);

  void _requireLocalType(Element element, Object node) {
    if (!_isLocalType(element)) {
      _failSource(
        node,
        'Contract enums and values must be declared in the source library.',
      );
    }
  }

  bool _isLocalType(Element element) =>
      element.library?.firstFragment.source.fullName == result.path;

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

  Never _failSource(Object source, String message) => switch (source) {
    final AstNode node => _fail(node, message),
    final Element element => _failElement(element, message),
    _ => throw StateError('Unsupported diagnostic source.'),
  };
}

String _lowerName(String value) =>
    '${value[0].toLowerCase()}${value.substring(1)}';
String _capitalize(String value) =>
    '${value[0].toUpperCase()}${value.substring(1)}';

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
    for (final FailureModel failure in model.failures) {
      out.writeln(
        "const String ${_lower(failure.name)}TypeId = '${failure.id}';",
      );
    }
    for (final ValueModel value in model.values) {
      out.writeln("const String ${_lower(value.name)}TypeId = '${value.id}';");
      out.writeln(
        'Map<String, Object?> _encode${value.name}(${value.name} value) => <String, Object?>{${value.fields.map((FieldModel f) => "'${f.id}': ${_encode(f.type, 'value.${f.name}')} ").join(',')}};',
      );
      out.writeln(
        '${value.name} _decode${value.name}(Object? value) { final map = _contractMap(value, \'${value.name}\'); _contractFields(map, const {${value.fields.map((FieldModel f) => "'${f.id}'").join(',')}}, \'${value.name}\'); ${value.fields.map((FieldModel f) => 'final ${f.name} = ${_decode(f.type, "map['${f.id}']", f.name)};').join(' ')} return _contractConstruct(\'${value.name}\', () => ${value.name}(${value.fields.map((FieldModel f) => "${f.name}: ${f.name}").join(',')})); }',
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
      "const int _contractJsonMaxDepth = 64; Map<String, Object?> _contractJsonMap(Object? value, String label) { final map = _contractMap(value, label); final active = Set<Object>.identity(); Object? validate(Object? item, int depth) { if (item == null || item is String || item is bool || item is int) return item; if (item is double) { _contractFiniteDouble(item, label); return item; } if (depth >= _contractJsonMaxDepth) throw AdeleProtocolException('JSON value for \$label exceeds maximum depth \$_contractJsonMaxDepth.'); if (item is List) { if (!active.add(item)) throw AdeleProtocolException('Cyclic JSON value for \$label.'); try { return item.map((element) => validate(element, depth + 1)).toList(growable: false); } finally { active.remove(item); } } if (item is Map) { if (!active.add(item)) throw AdeleProtocolException('Cyclic JSON value for \$label.'); try { final result = <String, Object?>{}; for (final entry in item.entries) { if (entry.key is! String) throw AdeleProtocolException('Expected string keys for \$label.'); result[entry.key as String] = validate(entry.value, depth + 1); } return result; } finally { active.remove(item); } } throw AdeleProtocolException('Expected recursively JSON-compatible values for \$label.'); } return validate(map, 0) as Map<String, Object?>; }",
    );
    out.writeln(
      "void _contractVoid(Object? value, String label) { if (value != null) throw AdeleProtocolException('Expected null for \$label.'); }",
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
      "double _contractDouble(Object? value, String label) { if (value is! double) throw AdeleProtocolException('Expected double for \$label.'); return _contractFiniteDouble(value, label); } double _contractFiniteDouble(double value, String label) { if (!value.isFinite) throw AdeleProtocolException('Expected finite double for \$label.'); return value; }",
    );
    out.writeln(
      "Uri _contractUri(Object? value, String label) { final text = _contractString(value, label); final Uri uri; try { uri = Uri.parse(text); } on FormatException { throw AdeleProtocolException('Malformed Uri for \$label.'); } if (!uri.hasScheme) throw AdeleProtocolException('Malformed Uri for \$label.'); return uri; }",
    );
    out.writeln(
      "String _contractUriString(Uri value, String label) => _contractUri(value.toString(), label).toString();",
    );
    out.writeln(
      "T _contractConstruct<T>(String label, T Function() construct) { try { return construct(); } on Object { throw AdeleProtocolException('Invalid value for \$label.'); } }",
    );
    if (_usesExternal(model)) {
      out.writeln(
        "Map<String, Object?> _contractResourceRef(ResourceRef value) => {'uri': _contractUriString(value.uri, 'ResourceRef uri'), 'mediaType': value.mediaType}; ResourceRef _decodeResourceRef(Object? value) { final map = _contractMap(value, 'ResourceRef'); _contractFields(map, const {'uri', 'mediaType'}, 'ResourceRef'); final uri = _contractUri(map['uri'], 'ResourceRef uri'); final mediaType = map['mediaType']; if (mediaType != null && mediaType is! String) throw const AdeleProtocolException('Malformed ResourceRef.'); return _contractConstruct('ResourceRef', () => ResourceRef(uri: uri, mediaType: mediaType as String?)); }",
      );
    }
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
        '@override Future<${method.returnType.dart}> ${method.name}(${method.parameters.map((FieldModel p) => '${p.type.dart} ${p.name}').join(',')}) async { try { ${_clientResult(service, method)} } on AdeleRemoteFailure catch(error) { ${_failureSwitch(failures)} } }',
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
      'abstract interface class ${service.name}RequestDispatcher { Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request); } final class ${service.name}Dispatcher implements ${service.name}RequestDispatcher { const ${service.name}Dispatcher(this._service); final ${service.name} _service; @override Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async { final requestId = request[\'requestId\']; late final String method; try { method = _decodeContractEnvelope(request); } on AdeleProtocolException catch(error) { return _contractFailure(requestId, null, \'invalid_request\', error.message, const {}); } if (!const {${service.methods.map((MethodModel method) => '${_lower(service.name)}${_cap(method.name)}Id').join(',')}}.contains(method)) return _contractFailure(requestId, null, \'unknown_method\', \'Unknown method.\', const {}); late final Map<Object?, Object?> payload; try { payload = _contractMap(request[\'payload\'], \'request payload\'); } on AdeleProtocolException catch(error) { return _contractFailure(requestId, null, \'invalid_request\', error.message, const {}); } late final Object? arguments; try { arguments = switch(method) {',
    );
    for (final MethodModel method in service.methods) {
      out.writeln(
        '${_lower(service.name)}${_cap(method.name)}Id => ${_decodeArguments(method)},',
      );
    }
    out.writeln(
      "_ => throw const _ContractUnknownMethod(), }; } on _ContractUnknownMethod { return _contractFailure(requestId, null, 'unknown_method', 'Unknown method.', const {}); } on AdeleProtocolException catch(error) { return _contractFailure(requestId, null, 'invalid_request', error.message, const {}); } late final Object? result; try { result = await switch(method) {",
    );
    for (final MethodModel method in service.methods) {
      out.writeln(
        '${_lower(service.name)}${_cap(method.name)}Id => ${_invokeMethod(method)},',
      );
    }
    out.writeln("_ => throw const _ContractUnknownMethod(), };");
    for (final FailureModel failure in failures) {
      out.writeln(
        "} on ${failure.name} catch(error) { try { return _contractFailure(requestId, ${_lower(failure.name)}TypeId, error.code, error.message, _contractJsonMap(error.details, 'failure details')); } on Object { return _contractFailure(requestId, null, 'backend_contract_violation', 'The backend violated its generated contract.', const {}); }",
      );
    }
    out.writeln(
      "} on _ContractUnknownMethod { return _contractFailure(requestId, null, 'unknown_method', 'Unknown method.', const {}); } on Object catch(error) { return _contractFailure(requestId, null, 'internal_error', 'The backend request failed unexpectedly.', const {}); } try { final encoded = switch(method) {",
    );
    for (final MethodModel method in service.methods) {
      out.writeln(
        '${_lower(service.name)}${_cap(method.name)}Id => ${_encode(method.returnType, '(result as ${method.returnType.dart})')},',
      );
    }
    out.writeln(
      "_ => throw const _ContractUnknownMethod(), }; return {'kind': 'response', 'requestId': requestId, 'ok': true, 'payload': encoded}; } on Object { return _contractFailure(requestId, null, 'backend_contract_violation', 'The backend violated its generated contract.', const {}); } } } String _decodeContractEnvelope(Map<Object?, Object?> request) { _contractFields(request, const {'kind', 'requestId', 'method', 'payload'}, 'request envelope'); if (request['requestId'] is! int || request['kind'] != 'request' || request['method'] is! String) throw const AdeleProtocolException('Malformed request envelope.'); return request['method'] as String; } final class _ContractUnknownMethod implements Exception { const _ContractUnknownMethod(); }",
    );
    out.writeln(
      "Map<String, Object?> _contractFailure(Object? requestId, String? declaredFailureType, String code, String message, Map<String, Object?> details) => {'kind': 'response', if(requestId is int) 'requestId': requestId, 'ok': false, 'error': {if(declaredFailureType != null) 'declaredFailureType': declaredFailureType, 'code': code, 'message': message, 'details': details}};",
    );
  }

  String _failureSwitch(List<FailureModel> failures) =>
      "switch(error.declaredFailureType) { ${failures.map((FailureModel f) => "case ${_lower(f.name)}TypeId: final details = _contractJsonMap(error.details, 'failure details'); throw _contractConstruct('${f.name}', () => ${f.name}(code: error.code, message: error.message, details: details));").join()} default: rethrow; }";
  String _decodeArguments(MethodModel method) {
    final String fields = method.parameters
        .map((FieldModel parameter) => "'${parameter.id}'")
        .join(',');
    final String values = method.parameters
        .map(
          (FieldModel parameter) => _decode(
            parameter.type,
            "payload['${parameter.id}']",
            parameter.name,
          ),
        )
        .join(',');
    return "(() { _contractFields(payload, const {$fields}, '${method.name} payload'); return <Object?>[$values]; })()";
  }

  String _invokeMethod(MethodModel method) {
    final String values = <String>[
      for (int index = 0; index < method.parameters.length; index++)
        'values[$index] as ${method.parameters[index].type.dart}',
    ].join(',');
    final String invocation = 'await _service.${method.name}($values)';
    return "(() async { final values = arguments as List<Object?>; ${method.returnType.kind == TypeKind.void_ ? '$invocation; return null;' : 'return $invocation;'} })()";
  }

  String _encode(TypeModel type, String value) {
    final String encoded = switch (type.kind) {
      TypeKind.void_ => 'null',
      TypeKind.string || TypeKind.boolean || TypeKind.integer => value,
      TypeKind.double_ => '_contractFiniteDouble($value, \'double\')',
      TypeKind.list =>
        '$value.map((element) => ${_encode(type.argument!, 'element')}).toList(growable: false)',
      TypeKind.map => '_contractJsonMap($value, \'map\')',
      TypeKind.uri => "_contractUriString($value, 'Uri')",
      TypeKind.enumeration => '$value.name',
      TypeKind.value => '_encode${_base(type.dart)}($value)',
      TypeKind.external => '_contractResourceRef($value)',
    };
    return type.nullable
        ? 'switch ($value) { final nonNullValue? => ${_encode(type.nonNullable, 'nonNullValue')}, null => null }'
        : encoded;
  }

  String _decode(TypeModel type, String value, String label) {
    final String decoded = switch (type.kind) {
      TypeKind.void_ => '_contractVoid($value, \'$label\')',
      TypeKind.string => '_contractString($value, \'$label\')',
      TypeKind.boolean => '_contractBool($value, \'$label\')',
      TypeKind.integer => '_contractInt($value, \'$label\')',
      TypeKind.double_ => '_contractDouble($value, \'$label\')',
      TypeKind.list =>
        "List<${type.argument!.dart}>.unmodifiable(_contractList($value, '$label').map((element) => ${_decode(type.argument!, 'element', '$label element')}))",
      TypeKind.map => '_contractJsonMap($value, \'$label\')',
      TypeKind.uri => '_contractUri($value, \'$label\')',
      TypeKind.enumeration => '_decode${_base(type.dart)}($value)',
      TypeKind.value => '_decode${_base(type.dart)}($value)',
      TypeKind.external => '_decodeResourceRef($value)',
    };
    return type.nullable
        ? 'switch ($value) { final nonNullValue? => ${_decode(type.nonNullable, 'nonNullValue', label)}, null => null }'
        : decoded;
  }

  String _clientResult(ServiceModel service, MethodModel method) {
    final String response =
        "await _channel.request(${_lower(service.name)}${_cap(method.name)}Id, <String, Object?>{${method.parameters.map((FieldModel p) => "'${p.id}': ${_encode(p.type, p.name)}").join(',')}})";
    if (method.returnType.kind == TypeKind.void_) {
      return "final response = $response; _contractVoid(response, '${method.name}'); return;";
    }
    return 'return ${_decode(method.returnType, response, method.name)};';
  }

  String _base(String value) => value.replaceAll('?', '');
  bool _usesExternal(ContractModel model) =>
      model.values.any(
        (ValueModel value) => value.fields.any(
          (FieldModel field) => _typeUsesExternal(field.type),
        ),
      ) ||
      model.services.any(
        (ServiceModel service) => service.methods.any(
          (MethodModel method) =>
              _typeUsesExternal(method.returnType) ||
              method.parameters.any(
                (FieldModel parameter) => _typeUsesExternal(parameter.type),
              ),
        ),
      );
  bool _typeUsesExternal(TypeModel type) =>
      type.kind == TypeKind.external ||
      type.argument != null && _typeUsesExternal(type.argument!);
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
