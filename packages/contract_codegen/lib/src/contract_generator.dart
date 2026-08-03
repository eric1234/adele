import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
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
    final String sourceDirectory = p.normalize(absolute.parent.path);
    final String destination = p.normalize(
      p.join(sourceDirectory, model.partUri),
    );
    if (p.dirname(destination) != sourceDirectory) {
      throw ContractDiagnostic(
        'Generated output must remain in the contract source directory.',
        absolute.path,
        1,
        1,
      );
    }
    return ContractGeneratedFile(destination, formatted);
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
    final String expectedPartUri =
        '${p.basenameWithoutExtension(result.path)}.g.dart';
    Uri? parsedPartUri;
    try {
      parsedPartUri = Uri.parse(partUri);
    } on FormatException {
      // The exact textual check below emits the contract-specific diagnostic.
    }
    if (partUri != expectedPartUri ||
        parsedPartUri == null ||
        parsedPartUri.hasScheme ||
        parsedPartUri.hasAuthority ||
        parsedPartUri.hasQuery ||
        parsedPartUri.hasFragment ||
        parsedPartUri.pathSegments.length != 1 ||
        partUri.contains('/') ||
        partUri.contains(r'\')) {
      _fail(
        part,
        'Generated part URI must be exactly $expectedPartUri in the contract source directory.',
      );
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
        final Map<String, String> roles = _roleAnnotationIds(element);
        final String? valueId = roles['AdeleValue'];
        final String? failureId = roles['AdeleFailure'];
        final String? serviceId = roles['AdeleService'];
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
    _rejectGeneratedSymbolCollisions(services, values, enums, failures);
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
    _rejectGenericDeclaration(node, element, 'value');
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
      if (!field.isFinal || field.isLate) {
        _failElement(field, 'Value fields must be non-late and final.');
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
    final InterfaceElement element = node.declaredFragment!.element;
    _rejectGenericDeclaration(node, element, 'failure');
    _unique(node, node.name.lexeme, id);
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
      if (!field.isFinal || field.isLate) {
        _failElement(field, 'Failure fields must be non-late and final.');
      }
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
    _rejectGenericDeclaration(node, element, 'service');
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
      if (method.name?.startsWith('_') ?? false) {
        _failElement(
          method,
          'Private service methods cannot be implemented across package boundaries.',
        );
      }
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
    final Set<String> methodNames = <String>{};
    for (final MethodModel method in methods) {
      if (!methodNames.add(method.name)) {
        _fail(node, 'Duplicate method name ${method.name}.');
      }
    }
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
    List<EnumModel> enums,
    List<FailureModel> failures,
  ) {
    final Map<String, String> symbols = <String, String>{};
    final Set<String> declaredNames = _topLevelNames();
    void add(String symbol, String source) {
      _validateGeneratedIdentifier(symbol, source);
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

    for (final String helper in _fixedGeneratedSymbols) {
      add(helper, 'fixed generated helper');
    }
    if (_usesExternalTypes(services, values)) {
      add('_contractResourceRef', 'ResourceRef encoder');
      add('_decodeResourceRef', 'ResourceRef decoder');
    }

    for (final ServiceModel service in services) {
      _validateGeneratedIdentifier(service.name, 'service ${service.name}');
      add('${_lowerName(service.name)}Id', 'service ${service.name}');
      add('${service.name}Client', 'service ${service.name}');
      add('${service.name}Dispatcher', 'service ${service.name}');
      add('${service.name}RequestDispatcher', 'service ${service.name}');
      for (final MethodModel method in service.methods) {
        _validateGeneratedIdentifier(
          method.name,
          'method ${service.name}.${method.name}',
        );
        for (final FieldModel parameter in method.parameters) {
          _validateGeneratedIdentifier(
            parameter.name,
            'parameter ${service.name}.${method.name}.${parameter.name}',
          );
        }
        if (method.name == 'dispatch') {
          _fail(
            result.unit,
            'Service method dispatch conflicts with the generated dispatcher API.',
          );
        }
        add(
          '${_lowerName(service.name)}${_capitalize(method.name)}Id',
          'method ${service.name}.${method.name}',
        );
      }
    }
    for (final ValueModel value in values) {
      _validateGeneratedIdentifier(value.name, 'value ${value.name}');
      for (final FieldModel field in value.fields) {
        _validateGeneratedIdentifier(
          field.name,
          'field ${value.name}.${field.name}',
        );
      }
      add('${_lowerName(value.name)}TypeId', 'value ${value.name}');
      add('_encode${value.name}', 'value ${value.name}');
      add('_decode${value.name}', 'value ${value.name}');
    }
    for (final FailureModel failure in failures) {
      _validateGeneratedIdentifier(failure.name, 'failure ${failure.name}');
      add('${_lowerName(failure.name)}TypeId', 'failure ${failure.name}');
    }
    for (final EnumModel value in enums) {
      _validateGeneratedIdentifier(value.name, 'enum ${value.name}');
      for (final String enumValue in value.values) {
        _validateGeneratedIdentifier(
          enumValue,
          'enum value ${value.name}.$enumValue',
        );
      }
      add('_decode${value.name}', 'enum ${value.name}');
    }
  }

  Set<String> _topLevelNames() {
    final Set<String> names = <String>{};
    for (final CompilationUnitMember declaration in result.unit.declarations) {
      switch (declaration) {
        case ClassDeclaration(:final name) ||
            EnumDeclaration(:final name) ||
            MixinDeclaration(:final name) ||
            ExtensionTypeDeclaration(:final name) ||
            TypeAlias(:final name):
          names.add(name.lexeme);
        case ExtensionDeclaration(:final name?):
          names.add(name.lexeme);
        case FunctionDeclaration(:final name):
          names.add(name.lexeme);
        case TopLevelVariableDeclaration(:final variables):
          names.addAll(
            variables.variables.map(
              (VariableDeclaration variable) => variable.name.lexeme,
            ),
          );
        default:
          break;
      }
    }
    return names;
  }

  void _rejectGenericDeclaration(
    ClassDeclaration node,
    InterfaceElement element,
    String kind,
  ) {
    if (element.typeParameters.isNotEmpty) {
      _fail(
        node.typeParameters ?? node,
        'Generic annotated $kind declarations are not supported.',
      );
    }
  }

  void _validateGeneratedIdentifier(String value, String source) {
    if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(value) ||
        Keyword.keywords.containsKey(value)) {
      _fail(
        result.unit,
        'Generated identifier $value for $source is not a valid Dart identifier.',
      );
    }
  }

  bool _usesExternalTypes(
    List<ServiceModel> services,
    List<ValueModel> values,
  ) =>
      values.any(
        (ValueModel value) => value.fields.any(
          (FieldModel field) => _typeUsesExternal(field.type),
        ),
      ) ||
      services.any(
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
      if (_annotations(base.element, 'AdeleValue').isNotEmpty) {
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

  List<ElementAnnotation> _annotations(Element element, String name) => element
      .metadata
      .annotations
      .where(
        (ElementAnnotation annotation) =>
            annotation.element?.enclosingElement?.name == name &&
            annotation.element?.library?.uri.toString() ==
                'package:adele_contract/adele_contract.dart',
      )
      .toList(growable: false);
  String? _annotationId(Element element, String name) {
    final List<ElementAnnotation> annotations = _annotations(element, name);
    if (annotations.length > 1) {
      _failElement(element, 'Repeated @$name annotations are not allowed.');
    }
    final ElementAnnotation? annotation = annotations.firstOrNull;
    return annotation
            ?.computeConstantValue()
            ?.getField('id')
            ?.toStringValue() ??
        annotation?.computeConstantValue()?.getField('name')?.toStringValue();
  }

  String? _declaredAnnotationId(Element element, String name) {
    if (_annotations(element, name).isEmpty) return null;
    final String? id = _annotationId(element, name);
    if (id == null || !_validId(id)) {
      _failElement(
        element,
        '@$name must declare a stable ID using ASCII letters or digits separated by single dots, hyphens, or underscores.',
      );
    }
    return id;
  }

  Map<String, String> _roleAnnotationIds(Element element) {
    const List<String> names = <String>[
      'AdeleService',
      'AdeleValue',
      'AdeleFailure',
    ];
    final Map<String, String> roles = <String, String>{};
    for (final String name in names) {
      final String? id = _declaredAnnotationId(element, name);
      if (id != null) roles[name] = id;
    }
    if (roles.length > 1) {
      _failElement(
        element,
        'A contract class must declare exactly one role annotation; mixed roles are not allowed.',
      );
    }
    return roles;
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

const Set<String> _fixedGeneratedSymbols = <String>{
  '_contractMap',
  '_contractFields',
  '_contractList',
  '_contractJsonMaxDepth',
  '_contractJsonMap',
  '_contractVoid',
  '_contractString',
  '_contractBool',
  '_contractInt',
  '_contractDouble',
  '_contractFiniteDouble',
  '_contractUri',
  '_contractUriString',
  '_contractConstruct',
  '_decodeContractEnvelope',
  '_ContractUnknownMethod',
  '_contractFailure',
};

final class DartContractEmitter {
  int _nextLocal = 0;

  String emit(ContractModel model) {
    _nextLocal = 0;
    final StringBuffer out = StringBuffer(
      '// GENERATED CODE - DO NOT MODIFY BY HAND.\n'
      '// ignore_for_file: curly_braces_in_flow_control_structures, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unused_catch_clause, unused_element, use_null_aware_elements\n\n'
      'part of ${_literal(p.basename(model.sourcePath))};\n\n',
    );
    for (final ServiceModel service in model.services) {
      out.writeln(
        'const String ${_lower(service.name)}Id = ${_literal(service.id)};',
      );
      for (final MethodModel method in service.methods) {
        out.writeln(
          'const String ${_lower(service.name)}${_cap(method.name)}Id = ${_literal('${service.id}.${method.id}')};',
        );
      }
      _client(out, service, model.failures);
      _dispatcher(out, service, model.failures);
    }
    for (final FailureModel failure in model.failures) {
      out.writeln(
        'const String ${_lower(failure.name)}TypeId = ${_literal(failure.id)};',
      );
    }
    for (final ValueModel value in model.values) {
      out.writeln(
        'const String ${_lower(value.name)}TypeId = ${_literal(value.id)};',
      );
      final String input = _local('value');
      out.writeln(
        'Map<String, Object?> _encode${value.name}(${value.name} $input) => <String, Object?>{${value.fields.map((FieldModel f) => '${_literal(f.id)}: ${_encode(f.type, '$input.${f.name}')}').join(',')}};',
      );
      final String encoded = _local('value');
      final String map = _local('map');
      final List<String> decoded = <String>[
        for (int index = 0; index < value.fields.length; index++)
          _local('field'),
      ];
      out.writeln(
        '${value.name} _decode${value.name}(Object? $encoded) { final $map = _contractMap($encoded, ${_literal(value.name)}); _contractFields($map, const {${value.fields.map((FieldModel f) => _literal(f.id)).join(',')}}, ${_literal(value.name)}); ${value.fields.indexed.map((entry) => 'final ${decoded[entry.$1]} = ${_decode(entry.$2.type, '$map[${_literal(entry.$2.id)}]', entry.$2.name)};').join(' ')} return _contractConstruct(${_literal(value.name)}, () => ${value.name}(${value.fields.indexed.map((entry) => '${entry.$2.name}: ${decoded[entry.$1]}').join(',')})); }',
      );
    }
    for (final EnumModel value in model.enums) {
      final String encoded = _local('value');
      out.writeln(
        '${value.name} _decode${value.name}(Object? $encoded) { if ($encoded is! String) throw AdeleProtocolException(${_literal('Expected ${value.name}.')}); return switch($encoded) { ${value.values.map((String e) => '${_literal(e)} => ${value.name}.$e').join(',')}, _ => throw AdeleProtocolException(${_literal('Unknown ${value.name}: ')} + $encoded + ${_literal('.')}) }; }',
      );
    }
    out.writeln(
      "Map<Object?, Object?> _contractMap(Object? _adeleValue0, String _adeleLabel1) { if (_adeleValue0 is! Map<Object?, Object?>) throw AdeleProtocolException('Expected map for \$_adeleLabel1.'); for (final _adeleKey2 in _adeleValue0.keys) { if (_adeleKey2 is! String) throw AdeleProtocolException('Expected string keys for \$_adeleLabel1.'); } return _adeleValue0; }",
    );
    out.writeln(
      "void _contractFields(Map<Object?, Object?> _adeleValue0, Set<String> _adeleExpected1, String _adeleLabel2) { for (final _adeleKey3 in _adeleValue0.keys) { if (_adeleKey3 is! String || !_adeleExpected1.contains(_adeleKey3)) throw AdeleProtocolException('Unknown field in \$_adeleLabel2: \$_adeleKey3.'); } for (final _adeleKey4 in _adeleExpected1) { if (!_adeleValue0.containsKey(_adeleKey4)) throw AdeleProtocolException('Missing field in \$_adeleLabel2: \$_adeleKey4.'); } }",
    );
    out.writeln(
      "List<Object?> _contractList(Object? _adeleValue0, String _adeleLabel1) { if (_adeleValue0 is! List) throw AdeleProtocolException('Expected list for \$_adeleLabel1.'); return List<Object?>.of(_adeleValue0); }",
    );
    out.writeln(
      "const int _contractJsonMaxDepth = 64; Map<String, Object?> _contractJsonMap(Object? _adeleValue0, String _adeleLabel1) { final _adeleMap2 = _contractMap(_adeleValue0, _adeleLabel1); final _adeleActive3 = Set<Object>.identity(); Object? _adeleValidate4(Object? _adeleItem5, int _adeleDepth6) { if (_adeleItem5 == null || _adeleItem5 is String || _adeleItem5 is bool || _adeleItem5 is int) return _adeleItem5; if (_adeleItem5 is double) { _contractFiniteDouble(_adeleItem5, _adeleLabel1); return _adeleItem5; } if (_adeleDepth6 >= _contractJsonMaxDepth) throw AdeleProtocolException('JSON value for \$_adeleLabel1 exceeds maximum depth \$_contractJsonMaxDepth.'); if (_adeleItem5 is List) { if (!_adeleActive3.add(_adeleItem5)) throw AdeleProtocolException('Cyclic JSON value for \$_adeleLabel1.'); try { return _adeleItem5.map((_adeleElement7) => _adeleValidate4(_adeleElement7, _adeleDepth6 + 1)).toList(growable: false); } finally { _adeleActive3.remove(_adeleItem5); } } if (_adeleItem5 is Map) { if (!_adeleActive3.add(_adeleItem5)) throw AdeleProtocolException('Cyclic JSON value for \$_adeleLabel1.'); try { final _adeleResult8 = <String, Object?>{}; for (final _adeleEntry9 in _adeleItem5.entries) { if (_adeleEntry9.key is! String) throw AdeleProtocolException('Expected string keys for \$_adeleLabel1.'); _adeleResult8[_adeleEntry9.key as String] = _adeleValidate4(_adeleEntry9.value, _adeleDepth6 + 1); } return _adeleResult8; } finally { _adeleActive3.remove(_adeleItem5); } } throw AdeleProtocolException('Expected recursively JSON-compatible values for \$_adeleLabel1.'); } return _adeleValidate4(_adeleMap2, 0) as Map<String, Object?>; }",
    );
    out.writeln(
      "void _contractVoid(Object? _adeleValue0, String _adeleLabel1) { if (_adeleValue0 != null) throw AdeleProtocolException('Expected null for \$_adeleLabel1.'); }",
    );
    out.writeln(
      "String _contractString(Object? _adeleValue0, String _adeleLabel1) { if (_adeleValue0 is! String) throw AdeleProtocolException('Expected String for \$_adeleLabel1.'); return _adeleValue0; }",
    );
    out.writeln(
      "bool _contractBool(Object? _adeleValue0, String _adeleLabel1) { if (_adeleValue0 is! bool) throw AdeleProtocolException('Expected bool for \$_adeleLabel1.'); return _adeleValue0; }",
    );
    out.writeln(
      "int _contractInt(Object? _adeleValue0, String _adeleLabel1) { if (_adeleValue0 is! int) throw AdeleProtocolException('Expected int for \$_adeleLabel1.'); return _adeleValue0; }",
    );
    out.writeln(
      "double _contractDouble(Object? _adeleValue0, String _adeleLabel1) { if (_adeleValue0 is! double) throw AdeleProtocolException('Expected double for \$_adeleLabel1.'); return _contractFiniteDouble(_adeleValue0, _adeleLabel1); } double _contractFiniteDouble(double _adeleValue0, String _adeleLabel1) { if (!_adeleValue0.isFinite) throw AdeleProtocolException('Expected finite double for \$_adeleLabel1.'); return _adeleValue0; }",
    );
    out.writeln(
      "Uri _contractUri(Object? _adeleValue0, String _adeleLabel1) { final _adeleText2 = _contractString(_adeleValue0, _adeleLabel1); final Uri _adeleUri3; try { _adeleUri3 = Uri.parse(_adeleText2); } on FormatException { throw AdeleProtocolException('Malformed Uri for \$_adeleLabel1.'); } if (!_adeleUri3.hasScheme) throw AdeleProtocolException('Malformed Uri for \$_adeleLabel1.'); return _adeleUri3; }",
    );
    out.writeln(
      "String _contractUriString(Uri _adeleValue0, String _adeleLabel1) => _contractUri(_adeleValue0.toString(), _adeleLabel1).toString();",
    );
    out.writeln(
      "T _contractConstruct<T>(String _adeleLabel0, T Function() _adeleConstruct1) { try { return _adeleConstruct1(); } on Object { throw AdeleProtocolException('Invalid value for \$_adeleLabel0.'); } }",
    );
    if (_usesExternal(model)) {
      out.writeln(
        "Map<String, Object?> _contractResourceRef(ResourceRef _adeleValue0) => {'uri': _contractUriString(_adeleValue0.uri, 'ResourceRef uri'), 'mediaType': _adeleValue0.mediaType}; ResourceRef _decodeResourceRef(Object? _adeleValue0) { final _adeleMap1 = _contractMap(_adeleValue0, 'ResourceRef'); _contractFields(_adeleMap1, const {'uri', 'mediaType'}, 'ResourceRef'); final _adeleUri2 = _contractUri(_adeleMap1['uri'], 'ResourceRef uri'); final _adeleMediaType3 = _adeleMap1['mediaType']; if (_adeleMediaType3 != null && _adeleMediaType3 is! String) throw const AdeleProtocolException('Malformed ResourceRef.'); return _contractConstruct('ResourceRef', () => ResourceRef(uri: _adeleUri2, mediaType: _adeleMediaType3 as String?)); }",
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
      'final class ${service.name}Client implements ${service.name} { const ${service.name}Client(this._adeleChannel); final AdeleRequestChannel _adeleChannel;',
    );
    for (final MethodModel method in service.methods) {
      final String error = _local('error');
      out.writeln(
        '@override Future<${method.returnType.dart}> ${method.name}(${method.parameters.map((FieldModel p) => '${p.type.dart} ${p.name}').join(',')}) async { try { ${_clientResult(service, method)} } on AdeleRemoteFailure catch($error) { ${_failureSwitch(failures, error)} } }',
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
      'abstract interface class ${service.name}RequestDispatcher { Future<Map<String, Object?>> dispatch(Map<Object?, Object?> _adeleRequest0); } final class ${service.name}Dispatcher implements ${service.name}RequestDispatcher { const ${service.name}Dispatcher(this._adeleService); final ${service.name} _adeleService; @override Future<Map<String, Object?>> dispatch(Map<Object?, Object?> _adeleRequest0) async { final _adeleRequestId1 = _adeleRequest0[\'requestId\']; late final String _adeleMethod2; try { _adeleMethod2 = _decodeContractEnvelope(_adeleRequest0); } on AdeleProtocolException catch(_adeleError3) { return _contractFailure(_adeleRequestId1, null, \'invalid_request\', _adeleError3.message, const {}); } if (!const {${service.methods.map((MethodModel method) => '${_lower(service.name)}${_cap(method.name)}Id').join(',')}}.contains(_adeleMethod2)) return _contractFailure(_adeleRequestId1, null, \'unknown_method\', \'Unknown method.\', const {}); late final Map<Object?, Object?> _adelePayload4; try { _adelePayload4 = _contractMap(_adeleRequest0[\'payload\'], \'request payload\'); } on AdeleProtocolException catch(_adeleError5) { return _contractFailure(_adeleRequestId1, null, \'invalid_request\', _adeleError5.message, const {}); } late final Object? _adeleArguments6; try { _adeleArguments6 = switch(_adeleMethod2) {',
    );
    for (final MethodModel method in service.methods) {
      out.writeln(
        '${_lower(service.name)}${_cap(method.name)}Id => ${_decodeArguments(method, '_adelePayload4')},',
      );
    }
    out.writeln(
      "_ => throw const _ContractUnknownMethod(), }; } on _ContractUnknownMethod { return _contractFailure(_adeleRequestId1, null, 'unknown_method', 'Unknown method.', const {}); } on AdeleProtocolException catch(_adeleError7) { return _contractFailure(_adeleRequestId1, null, 'invalid_request', _adeleError7.message, const {}); } late final Object? _adeleResult8; try { _adeleResult8 = await switch(_adeleMethod2) {",
    );
    for (final MethodModel method in service.methods) {
      out.writeln(
        '${_lower(service.name)}${_cap(method.name)}Id => ${_invokeMethod(method, '_adeleArguments6')},',
      );
    }
    out.writeln("_ => throw const _ContractUnknownMethod(), };");
    for (final FailureModel failure in failures) {
      out.writeln(
        "} on ${failure.name} catch(_adeleError9) { try { return _contractFailure(_adeleRequestId1, ${_lower(failure.name)}TypeId, _adeleError9.code, _adeleError9.message, _contractJsonMap(_adeleError9.details, 'failure details')); } on Object { return _contractFailure(_adeleRequestId1, null, 'backend_contract_violation', 'The backend violated its generated contract.', const {}); }",
      );
    }
    out.writeln(
      "} on _ContractUnknownMethod { return _contractFailure(_adeleRequestId1, null, 'unknown_method', 'Unknown method.', const {}); } on Object catch(_adeleError10) { return _contractFailure(_adeleRequestId1, null, 'internal_error', 'The backend request failed unexpectedly.', const {}); } try { final _adeleEncoded11 = switch(_adeleMethod2) {",
    );
    for (final MethodModel method in service.methods) {
      out.writeln(
        '${_lower(service.name)}${_cap(method.name)}Id => ${_encode(method.returnType, '(_adeleResult8 as ${method.returnType.dart})')},',
      );
    }
    out.writeln(
      "_ => throw const _ContractUnknownMethod(), }; return {'kind': 'response', 'requestId': _adeleRequestId1, 'ok': true, 'payload': _adeleEncoded11}; } on Object { return _contractFailure(_adeleRequestId1, null, 'backend_contract_violation', 'The backend violated its generated contract.', const {}); } } } String _decodeContractEnvelope(Map<Object?, Object?> _adeleRequest0) { _contractFields(_adeleRequest0, const {'kind', 'requestId', 'method', 'payload'}, 'request envelope'); if (_adeleRequest0['requestId'] is! int || _adeleRequest0['kind'] != 'request' || _adeleRequest0['method'] is! String) throw const AdeleProtocolException('Malformed request envelope.'); return _adeleRequest0['method'] as String; } final class _ContractUnknownMethod implements Exception { const _ContractUnknownMethod(); }",
    );
    out.writeln(
      "Map<String, Object?> _contractFailure(Object? _adeleRequestId0, String? _adeleDeclaredFailureType1, String _adeleCode2, String _adeleMessage3, Map<String, Object?> _adeleDetails4) => {'kind': 'response', if(_adeleRequestId0 is int) 'requestId': _adeleRequestId0, 'ok': false, 'error': {if(_adeleDeclaredFailureType1 != null) 'declaredFailureType': _adeleDeclaredFailureType1, 'code': _adeleCode2, 'message': _adeleMessage3, 'details': _adeleDetails4}};",
    );
  }

  String _failureSwitch(List<FailureModel> failures, String error) =>
      "switch($error.declaredFailureType) { ${failures.map((FailureModel f) => "case ${_lower(f.name)}TypeId: final _adeleDetails0 = _contractJsonMap($error.details, 'failure details'); throw _contractConstruct(${_literal(f.name)}, () => ${f.name}(code: $error.code, message: $error.message, details: _adeleDetails0));").join()} default: rethrow; }";
  String _decodeArguments(MethodModel method, String payload) {
    final String fields = method.parameters
        .map((FieldModel parameter) => _literal(parameter.id))
        .join(',');
    final String values = method.parameters
        .map(
          (FieldModel parameter) => _decode(
            parameter.type,
            '$payload[${_literal(parameter.id)}]',
            parameter.name,
          ),
        )
        .join(',');
    return "(() { _contractFields($payload, const {$fields}, ${_literal('${method.name} payload')}); return <Object?>[$values]; })()";
  }

  String _invokeMethod(MethodModel method, String arguments) {
    final String values = <String>[
      for (int index = 0; index < method.parameters.length; index++)
        '_adeleValues0[$index] as ${method.parameters[index].type.dart}',
    ].join(',');
    final String invocation = 'await _adeleService.${method.name}($values)';
    return "(() async { final _adeleValues0 = $arguments as List<Object?>; ${method.returnType.kind == TypeKind.void_ ? '$invocation; return null;' : 'return $invocation;'} })()";
  }

  String _encode(TypeModel type, String value) {
    final String element = _local('element');
    final String nonNullValue = _local('nonNullValue');
    final String encoded = switch (type.kind) {
      TypeKind.void_ => 'null',
      TypeKind.string || TypeKind.boolean || TypeKind.integer => value,
      TypeKind.double_ => '_contractFiniteDouble($value, \'double\')',
      TypeKind.list =>
        '$value.map(($element) => ${_encode(type.argument!, element)}).toList(growable: false)',
      TypeKind.map => '_contractJsonMap($value, \'map\')',
      TypeKind.uri => "_contractUriString($value, 'Uri')",
      TypeKind.enumeration => '$value.name',
      TypeKind.value => '_encode${_base(type.dart)}($value)',
      TypeKind.external => '_contractResourceRef($value)',
    };
    return type.nullable
        ? 'switch ($value) { final $nonNullValue? => ${_encode(type.nonNullable, nonNullValue)}, null => null }'
        : encoded;
  }

  String _decode(TypeModel type, String value, String label) {
    final String element = _local('element');
    final String nonNullValue = _local('nonNullValue');
    final String decoded = switch (type.kind) {
      TypeKind.void_ => '_contractVoid($value, ${_literal(label)})',
      TypeKind.string => '_contractString($value, ${_literal(label)})',
      TypeKind.boolean => '_contractBool($value, ${_literal(label)})',
      TypeKind.integer => '_contractInt($value, ${_literal(label)})',
      TypeKind.double_ => '_contractDouble($value, ${_literal(label)})',
      TypeKind.list =>
        'List<${type.argument!.dart}>.unmodifiable(_contractList($value, ${_literal(label)}).map(($element) => ${_decode(type.argument!, element, '$label element')}))',
      TypeKind.map => '_contractJsonMap($value, ${_literal(label)})',
      TypeKind.uri => '_contractUri($value, ${_literal(label)})',
      TypeKind.enumeration => '_decode${_base(type.dart)}($value)',
      TypeKind.value => '_decode${_base(type.dart)}($value)',
      TypeKind.external => '_decodeResourceRef($value)',
    };
    return type.nullable
        ? 'switch ($value) { final $nonNullValue? => ${_decode(type.nonNullable, nonNullValue, label)}, null => null }'
        : decoded;
  }

  String _clientResult(ServiceModel service, MethodModel method) {
    final String response =
        "await _adeleChannel.request(${_lower(service.name)}${_cap(method.name)}Id, <String, Object?>{${method.parameters.map((FieldModel p) => '${_literal(p.id)}: ${_encode(p.type, p.name)}').join(',')}})";
    if (method.returnType.kind == TypeKind.void_) {
      final String result = _local('response');
      return 'final $result = $response; _contractVoid($result, ${_literal(method.name)}); return;';
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

  String _local(String role) => '_adele${_cap(role)}${_nextLocal++}';

  String _literal(String value) {
    final StringBuffer escaped = StringBuffer("'");
    for (final int rune in value.runes) {
      switch (rune) {
        case 0x27:
          escaped.write(r"\'");
        case 0x5c:
          escaped.write(r'\\');
        case 0x24:
          escaped.write(r'\$');
        case 0x0a:
          escaped.write(r'\n');
        case 0x0d:
          escaped.write(r'\r');
        case 0x09:
          escaped.write(r'\t');
        case 0x08:
          escaped.write(r'\b');
        case 0x0c:
          escaped.write(r'\f');
        default:
          if (rune < 0x20 || rune == 0x7f) {
            escaped.write('\\u{${rune.toRadixString(16)}}');
          } else {
            escaped.writeCharCode(rune);
          }
      }
    }
    escaped.write("'");
    return escaped.toString();
  }
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
