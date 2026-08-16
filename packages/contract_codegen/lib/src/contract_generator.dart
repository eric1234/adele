import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:dart_style/dart_style.dart';
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
  const MethodModel(
    this.name,
    this.id,
    this.kind,
    this.returnType,
    this.parameters,
  );
  final String name;
  final String id;
  final MethodKind kind;
  final TypeModel returnType;
  final List<FieldModel> parameters;
}

enum MethodKind { unary, serverStream }

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
    final String formatted = DartFormatter(
      languageVersion: DartFormatter.latestLanguageVersion,
    ).format(unformatted, uri: source.uri);
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
  final Set<EnumElement> _reachableEnums = <EnumElement>{};

  static const String _contractLibrary =
      'package:adele_contract/adele_contract.dart';
  static const String _pluginApiLibrary =
      'package:adele_plugin_api/adele_plugin_api.dart';
  static const String _resourceRefLibrary =
      'package:adele_plugin_api/src/resource_ref.dart';

  ContractModel extract() {
    _validateImports();
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
    final Map<EnumElement, EnumDeclaration> enumDeclarations =
        <EnumElement, EnumDeclaration>{};
    final List<FailureModel> failures = <FailureModel>[];
    final List<ServiceModel> services = <ServiceModel>[];
    for (final CompilationUnitMember declaration in result.unit.declarations) {
      if (declaration case final EnumDeclaration value) {
        enumDeclarations[value.declaredFragment!.element] = value;
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
    final List<EnumModel> enums = <EnumModel>[
      for (final EnumElement element in _reachableEnums)
        if (enumDeclarations[element] case final EnumDeclaration declaration)
          EnumModel(
            declaration.name.lexeme,
            declaration.constants
                .map((EnumConstantDeclaration value) => value.name.lexeme)
                .toList(growable: false),
          ),
    ];
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
    _validateImports(usesResourceRef: _usesExternalTypes(services, values));
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
    _validateSchemaIdentifier(node.name.lexeme, 'value', node);
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
        !_isSdkType(element.supertype, 'dart:core', 'Object') ||
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
      final VariableDeclaration fieldNode = _fieldNode(field);
      _validateSchemaIdentifier(field.name!, 'value field', fieldNode);
      final FormalParameterElement? parameter = constructor.formalParameters
          .where((FormalParameterElement p) => p.name == field.name)
          .firstOrNull;
      if (parameter == null) {
        _fail(
          node,
          'Field ${field.name} must have a matching constructor parameter.',
        );
      }
      final FormalParameter parameterNode = _parameterNode(parameter);
      _validateSchemaIdentifier(
        parameter.name!,
        'value constructor parameter',
        parameterNode,
      );
      if (!parameter.isRequired || !parameter.isNamed) {
        _fail(node, 'Value constructor parameters must be required and named.');
      }
      if (parameter.type != field.type) {
        _fail(
          node,
          'Field ${field.name} and its required named constructor parameter must have exactly the same type.',
        );
      }
      final bool fieldFormal =
          parameter is FieldFormalParameterElement &&
          parameter.field?.name == field.name;
      final bool snapshotCollection =
          parameter is! FieldFormalParameterElement &&
          (_isSdkType(field.type, 'dart:core', 'List') ||
              _isCanonicalJsonMap(field.type)) &&
          _isCanonicalSnapshotInitializer(constructor, field, parameter);
      if (!fieldFormal && !snapshotCollection) {
        _fail(
          node,
          'Value constructor parameters must be required named field-formal parameters, except exact-type List and Map<String, Object?> snapshot parameters.',
        );
      }
      fields.add(
        FieldModel(
          field.name!,
          _annotationId(field, 'AdeleField') ?? field.name!,
          _type(field.type, _fieldTypeNode(fieldNode)),
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
    _validateSchemaIdentifier(node.name.lexeme, 'failure', node);
    _unique(node, node.name.lexeme, id);
    if (node.finalKeyword == null ||
        !_isSdkType(element.supertype, 'dart:core', 'Object') ||
        element.mixins.isNotEmpty ||
        element.interfaces.length != 1 ||
        !_isSdkType(element.interfaces.single, 'dart:core', 'Exception')) {
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
    if (!_isCanonicalString(byName['code']?.type) ||
        !_isCanonicalString(byName['message']?.type) ||
        !_isCanonicalJsonMap(byName['details']?.type)) {
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
    _validateSchemaIdentifier(node.name.lexeme, 'service', node);
    _unique(node, node.name.lexeme, id);
    if (node.abstractKeyword == null ||
        node.interfaceKeyword == null ||
        !_isSdkType(element.supertype, 'dart:core', 'Object') ||
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
      final MethodDeclaration methodNode = _methodNode(method);
      _validateSchemaIdentifier(method.name!, 'service method', methodNode);
      if (method.typeParameters.isNotEmpty) {
        _failElement(method, 'Generic service methods are not supported.');
      }
      final String? methodId = _declaredAnnotationId(method, 'AdeleMethod');
      if (methodId == null) {
        _failElement(method, 'Every service method must have @AdeleMethod.');
      }
      final DartType returnType = method.returnType;
      final TypeAnnotation? returnTypeNode = methodNode.returnType;
      if (returnTypeNode == null) {
        _fail(
          methodNode,
          'Service methods must return Future<T> or Stream<T>.',
        );
      }
      final MethodKind methodKind;
      if (returnType is! InterfaceType ||
          returnType.alias != null ||
          returnType.nullabilitySuffix == NullabilitySuffix.question ||
          returnType.typeArguments.length != 1) {
        _fail(
          returnTypeNode,
          'Service methods must return Future<T> or Stream<T>.',
        );
      } else if (_isSdkType(returnType, 'dart:async', 'Future')) {
        methodKind = MethodKind.unary;
      } else if (_isSdkType(returnType, 'dart:async', 'Stream')) {
        methodKind = MethodKind.serverStream;
      } else {
        _fail(
          returnTypeNode,
          'Service methods must return Future<T> or Stream<T>.',
        );
      }
      if (methodKind == MethodKind.serverStream &&
          returnType.typeArguments.single is VoidType) {
        _fail(
          _returnArgumentNode(returnTypeNode),
          'Stream<void> service methods are not supported.',
        );
      }
      final List<FieldModel> parameters = <FieldModel>[];
      for (final FormalParameterElement parameter in method.formalParameters) {
        final FormalParameter parameterNode = _parameterNode(parameter);
        final String? parameterName = parameter.name;
        if (parameterName == null || parameterName == '_') {
          _fail(
            parameterNode,
            'Service parameters must declare public ASCII names matching [A-Za-z][A-Za-z0-9_]*.',
          );
        }
        _validateSchemaIdentifier(
          parameterName,
          'service parameter',
          parameterNode,
        );
        if (parameter.isCovariant) {
          _fail(
            parameterNode,
            'Covariant service parameters are not supported.',
          );
        }
        if (parameter.isOptional || parameter.isNamed) {
          _failElement(
            parameter,
            'Service parameters must be required positional parameters.',
          );
        }
        parameters.add(
          FieldModel(
            parameterName,
            _annotationId(parameter, 'AdeleField') ?? parameterName,
            _type(parameter.type, _parameterTypeNode(parameterNode)),
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
          methodKind,
          _type(
            returnType.typeArguments.single,
            _returnArgumentNode(returnTypeNode),
          ),
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
      add('ResourceRef', 'ResourceRef type');
      add('_contractResourceRef', 'ResourceRef encoder');
      add('_decodeResourceRef', 'ResourceRef decoder');
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
    for (final EnumModel value in enums) {
      add('_decode${value.name}', 'enum ${value.name}');
    }
  }

  Set<String> _topLevelNames() {
    final Set<String> names = <String>{};
    names.addAll(
      result.unit.directives
          .whereType<ImportDirective>()
          .map((ImportDirective directive) => directive.prefix?.name)
          .nonNulls,
    );
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

  void _validateSchemaIdentifier(String value, String source, AstNode node) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(value) ||
        Keyword.keywords.containsKey(value)) {
      _fail(
        node,
        'Schema $source name $value must match [A-Za-z][A-Za-z0-9_]*.',
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

  void _validateImports({bool? usesResourceRef}) {
    final List<ImportDirective> imports = result.unit.directives
        .whereType<ImportDirective>()
        .toList(growable: false);
    for (final ImportDirective directive in imports) {
      final String? uri = directive.uri.stringValue;
      final String? canonicalPackage = _canonicalPackage(directive);
      if (canonicalPackage != null) {
        if (directive.configurations.isNotEmpty) {
          _fail(
            directive,
            'Conditional imports from the $canonicalPackage package are not supported.',
          );
        }
        final String canonicalUri = canonicalPackage == 'adele_contract'
            ? _contractLibrary
            : _pluginApiLibrary;
        if (uri != canonicalUri && directive.prefix == null) {
          _fail(
            directive,
            'Additional imports from the $canonicalPackage package must be prefixed.',
          );
        }
      } else if (directive.prefix == null) {
        _fail(
          directive,
          'Every other contract library import must be prefixed.',
        );
      }
    }
    _validateCanonicalImport(_contractLibrary, required: true);
    if (usesResourceRef == null) return;
    final bool hasPluginApiImport = imports.any(
      (ImportDirective directive) =>
          directive.uri.stringValue == _pluginApiLibrary &&
          directive.prefix == null,
    );
    if (usesResourceRef || hasPluginApiImport) {
      _validateCanonicalImport(
        _pluginApiLibrary,
        required: usesResourceRef || hasPluginApiImport,
      );
    }
  }

  String? _canonicalPackage(ImportDirective directive) {
    final Iterable<String?> uris = <String?>[
      directive.uri.stringValue,
      ...directive.configurations.map(
        (Configuration configuration) => configuration.uri.stringValue,
      ),
    ];
    for (final String? uri in uris) {
      if (_isPackageUri(uri, 'adele_contract')) return 'adele_contract';
      if (_isPackageUri(uri, 'adele_plugin_api')) return 'adele_plugin_api';
    }
    return null;
  }

  bool _isPackageUri(String? uri, String packageName) =>
      uri != null && uri.startsWith('package:$packageName/');

  void _validateCanonicalImport(String uri, {required bool required}) {
    final List<ImportDirective> imports = result.unit.directives
        .whereType<ImportDirective>()
        .where((ImportDirective directive) => directive.uri.stringValue == uri)
        .toList(growable: false);
    final List<ImportDirective> canonical = imports
        .where(
          (ImportDirective directive) =>
              directive.prefix == null &&
              directive.combinators.isEmpty &&
              directive.configurations.isEmpty,
        )
        .toList(growable: false);
    ImportDirective? invalidUnprefixed;
    for (final ImportDirective directive in imports) {
      if (directive.prefix == null && !canonical.contains(directive)) {
        invalidUnprefixed = directive;
        break;
      }
    }
    if (canonical.length > 1 ||
        required && canonical.length != 1 ||
        invalidUnprefixed != null) {
      _fail(
        canonical.length > 1
            ? canonical[1]
            : invalidUnprefixed ?? imports.firstOrNull ?? result.unit,
        'Contract library must contain exactly one canonical unprefixed import of $uri without combinators or configurations.',
      );
    }
  }

  bool _isSdkType(DartType? type, String uri, String name) =>
      type is InterfaceType &&
      type.element.name == name &&
      type.element.library.uri.toString() == uri;

  bool _isCanonicalString(DartType? type) =>
      type != null && type.alias == null && type.isDartCoreString;

  bool _isCanonicalNullableObject(DartType? type) =>
      type != null &&
      type.alias == null &&
      type.isDartCoreObject &&
      type.nullabilitySuffix == NullabilitySuffix.question;

  bool _isCanonicalJsonMap(DartType? type) =>
      type is InterfaceType &&
      type.alias == null &&
      type.isDartCoreMap &&
      type.typeArguments.length == 2 &&
      _isCanonicalString(type.typeArguments.first) &&
      _isCanonicalNullableObject(type.typeArguments.last);

  bool _isCanonicalSnapshotInitializer(
    ConstructorElement constructor,
    FieldElement field,
    FormalParameterElement parameter,
  ) {
    final ConstructorDeclaration declaration = result.unit.declarations
        .whereType<ClassDeclaration>()
        .expand((ClassDeclaration value) => value.members)
        .whereType<ConstructorDeclaration>()
        .firstWhere(
          (ConstructorDeclaration value) =>
              value.declaredFragment?.element == constructor,
        );
    final ConstructorFieldInitializer? initializer = declaration.initializers
        .whereType<ConstructorFieldInitializer>()
        .where(
          (ConstructorFieldInitializer value) =>
              value.fieldName.element == field,
        )
        .firstOrNull;
    if (initializer == null) return false;
    final Expression expression = initializer.expression;
    if (_isSdkType(field.type, 'dart:core', 'List')) {
      if (expression is! InstanceCreationExpression ||
          expression.argumentList.arguments.length != 1 ||
          expression.argumentList.arguments.single is! SimpleIdentifier ||
          (expression.argumentList.arguments.single as SimpleIdentifier)
                  .element !=
              parameter) {
        return false;
      }
      final ConstructorElement? target = expression.constructorName.element;
      return expression.constructorName.name?.name == 'unmodifiable' &&
          target?.enclosingElement.name == 'List' &&
          target?.library.uri.toString() == 'dart:core';
    }
    if (expression is! MethodInvocation ||
        expression.argumentList.arguments.length != 1 ||
        expression.argumentList.arguments.single is! SimpleIdentifier ||
        (expression.argumentList.arguments.single as SimpleIdentifier)
                .element !=
            parameter) {
      return false;
    }
    return expression.target == null &&
        expression.methodName.element is TopLevelFunctionElement &&
        expression.methodName.element!.name == 'adeleSnapshotJsonMap' &&
        expression.methodName.element!.library?.uri.toString() ==
            'package:adele_contract/adele_contract.dart';
  }

  TypeModel _type(DartType type, AstNode node) {
    if (type.alias != null) {
      _fail(
        node,
        'Type aliases are not supported in transported contract types.',
      );
    }
    if (type is DynamicType || type is TypeParameterType) {
      _failSource(
        node,
        'Dynamic or unconstrained contract types are not supported.',
      );
    }
    final bool nullable = type.nullabilitySuffix == NullabilitySuffix.question;
    if (type is VoidType) return const TypeModel(TypeKind.void_, 'void');
    if (type is InterfaceType) {
      final InterfaceType base = type;
      final String name = base.element.name ?? '';
      final TypeKind? scalar = base.isDartCoreString
          ? TypeKind.string
          : base.isDartCoreBool
          ? TypeKind.boolean
          : base.isDartCoreInt
          ? TypeKind.integer
          : base.isDartCoreDouble
          ? TypeKind.double_
          : null;
      if (scalar != null) {
        return TypeModel(
          scalar,
          '$name${nullable ? '?' : ''}',
          nullable: nullable,
        );
      }
      if (base.isDartCoreList && base.typeArguments.length == 1) {
        return TypeModel(
          TypeKind.list,
          type.getDisplayString(),
          argument: _type(base.typeArguments.single, node),
          nullable: nullable,
        );
      }
      if (base.isDartCoreMap) {
        if (base.typeArguments.length != 2 ||
            !_isCanonicalString(base.typeArguments.first) ||
            !_isCanonicalNullableObject(base.typeArguments.last)) {
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
      if (base.isDartAsyncStream) {
        _failSource(node, 'Stream contract types are not supported.');
      }
      if (_isSdkType(base, 'dart:core', 'Uri')) {
        return TypeModel(
          TypeKind.uri,
          type.getDisplayString(),
          nullable: nullable,
        );
      }
      if (base.element is EnumElement) {
        _requireLocalType(base.element, node);
        final EnumElement enumElement = base.element as EnumElement;
        final EnumDeclaration declaration = _enumNode(enumElement);
        _validateSchemaIdentifier(enumElement.name!, 'enum', declaration);
        for (final FieldElement value in enumElement.fields.where(
          (FieldElement value) => value.isEnumConstant,
        )) {
          _validateSchemaIdentifier(
            value.name!,
            'enum value',
            _enumValueNode(declaration, value.name!),
          );
        }
        _reachableEnums.add(enumElement);
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
          base.element.library.uri.toString() == _resourceRefLibrary) {
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

  MethodDeclaration _methodNode(MethodElement element) => result
      .unit
      .declarations
      .whereType<ClassDeclaration>()
      .expand((ClassDeclaration declaration) => declaration.members)
      .whereType<MethodDeclaration>()
      .firstWhere(
        (MethodDeclaration declaration) =>
            declaration.declaredFragment?.element == element,
      );

  FormalParameter _parameterNode(FormalParameterElement element) => result
      .unit
      .declarations
      .whereType<ClassDeclaration>()
      .expand((ClassDeclaration declaration) => declaration.members)
      .expand((ClassMember member) sync* {
        if (member case final MethodDeclaration declaration) {
          yield* declaration.parameters?.parameters ??
              const <FormalParameter>[];
        } else if (member case final ConstructorDeclaration declaration) {
          yield* declaration.parameters.parameters;
        }
      })
      .firstWhere(
        (FormalParameter parameter) =>
            parameter.declaredFragment?.element == element,
      );

  VariableDeclaration _fieldNode(FieldElement element) => result
      .unit
      .declarations
      .whereType<ClassDeclaration>()
      .expand((ClassDeclaration declaration) => declaration.members)
      .whereType<FieldDeclaration>()
      .expand((FieldDeclaration declaration) => declaration.fields.variables)
      .firstWhere(
        (VariableDeclaration variable) =>
            variable.declaredFragment?.element == element,
      );

  AstNode _fieldTypeNode(VariableDeclaration node) {
    final AstNode? parent = node.parent;
    if (parent is VariableDeclarationList && parent.type != null) {
      return parent.type!;
    }
    return node;
  }

  AstNode _parameterTypeNode(FormalParameter node) {
    FormalParameter current = node;
    while (current is DefaultFormalParameter) {
      current = current.parameter;
    }
    return switch (current) {
      SimpleFormalParameter(:final type?) => type,
      FieldFormalParameter(:final type?) => type,
      SuperFormalParameter(:final type?) => type,
      _ => current,
    };
  }

  TypeAnnotation _returnArgumentNode(TypeAnnotation node) {
    if (node case NamedType(:final typeArguments?)) {
      return typeArguments.arguments.single;
    }
    return node;
  }

  EnumDeclaration _enumNode(EnumElement element) =>
      result.unit.declarations.whereType<EnumDeclaration>().firstWhere(
        (EnumDeclaration declaration) =>
            declaration.declaredFragment?.element == element,
      );

  AstNode _enumValueNode(EnumDeclaration declaration, String name) =>
      declaration.constants.firstWhere(
        (EnumConstantDeclaration value) => value.name.lexeme == name,
      );

  List<ElementAnnotation> _annotations(Element element, String name) => element
      .metadata
      .annotations
      .where(
        (ElementAnnotation annotation) =>
            annotation.element?.enclosingElement?.name == name &&
            annotation.element?.library?.uri.toString() == _contractLibrary,
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
  'AdeleProtocolException',
  'AdeleRemoteFailure',
  'AdeleRequestChannel',
  'AdeleStreamChannel',
  'AdeleBackendDispatcher',
  'AdeleStreamIterator',
  'AdeleCompleter',
  'AdeleLazyStream',
  'adeleDecodedStream',
  'Future',
  'Stream',
  'StreamController',
  'Completer',
  'String',
  'bool',
  'int',
  'double',
  'List',
  'Map',
  'Set',
  'Uri',
  'Object',
  'Exception',
  'FormatException',
  'StateError',
  'TypeError',
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
  '_contractStreamFailure',
  '_ContractStreamState',
};

final class DartContractEmitter {
  int _nextLocal = 0;

  String emit(ContractModel model) {
    _nextLocal = 0;
    final StringBuffer out = StringBuffer(
      '// GENERATED CODE - DO NOT MODIFY BY HAND.\n'
      '// ignore_for_file: curly_braces_in_flow_control_structures, dead_code, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, unused_local_variable, use_null_aware_elements\n\n'
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
      'final class ${service.name}Client implements ${service.name} { const ${service.name}Client(AdeleRequestChannel _adeleChannel) : _adeleChannel = _adeleChannel; final AdeleRequestChannel _adeleChannel;',
    );
    for (final MethodModel method in service.methods) {
      final String error = _local('error');
      if (method.kind == MethodKind.unary) {
        out.writeln(
          '@override Future<${method.returnType.dart}> ${method.name}(${method.parameters.map((FieldModel p) => '${p.type.dart} ${p.name}').join(',')}) async { try { ${_clientResult(service, method)} } on AdeleRemoteFailure catch($error) { ${_failureSwitch(failures, error)} } }',
        );
      } else {
        final String raw = _local('raw');
        out.writeln(
          '@override Stream<${method.returnType.dart}> ${method.name}(${method.parameters.map((FieldModel p) => '${p.type.dart} ${p.name}').join(',')}) => AdeleLazyStream<${method.returnType.dart}>((_adeleOnData0, _adeleOnError1, _adeleOnDone2, _adeleCancelOnError3) { final _adeleStreamChannel4 = this._adeleChannel; if (_adeleStreamChannel4 is! AdeleStreamChannel) throw StateError(${_literal('This generated method requires an AdeleStreamChannel.')}); final $raw = _adeleStreamChannel4.stream(${_lower(service.name)}${_cap(method.name)}Id, <String, Object?>{${method.parameters.map((FieldModel p) => '${_literal(p.id)}: ${_encode(p.type, p.name)}').join(',')}}); return adeleDecodedStream<${method.returnType.dart}>($raw, (Object? _adeleItem5) => ${_decode(method.returnType, '_adeleItem5', method.name)}, (Object $error) { if ($error is AdeleRemoteFailure) { ${_streamFailureSwitch(failures, error)} } return $error; }).listen(_adeleOnData0, onError: _adeleOnError1, onDone: _adeleOnDone2, cancelOnError: _adeleCancelOnError3); });',
        );
      }
    }
    out.writeln('}');
  }

  void _dispatcher(
    StringBuffer out,
    ServiceModel service,
    List<FailureModel> failures,
  ) {
    final List<MethodModel> unary = service.methods
        .where((MethodModel method) => method.kind == MethodKind.unary)
        .toList(growable: false);
    final List<MethodModel> streams = service.methods
        .where((MethodModel method) => method.kind == MethodKind.serverStream)
        .toList(growable: false);
    final String unaryIds = unary.isEmpty
        ? '<String>{}'
        : '{${unary.map((MethodModel method) => '${_lower(service.name)}${_cap(method.name)}Id').join(',')}}';
    final String streamIds = streams.isEmpty
        ? '<String>{}'
        : '{${streams.map((MethodModel method) => '${_lower(service.name)}${_cap(method.name)}Id').join(',')}}';
    final String streamFields = streams.isEmpty
        ? 'Future<void> _adeleOrdinaryTail = Future<void>.value(); final Set<Future<void>> _adeleOperations = <Future<void>>{}; Future<void>? _adeleCloseFuture; bool _adeleClosed = false;'
        : 'final Map<int, _ContractStreamState> _adeleStreams = <int, _ContractStreamState>{}; Future<void> _adeleOrdinaryTail = Future<void>.value(); final Set<Future<void>> _adeleOperations = <Future<void>>{}; final Set<Future<void>> _adeleCancellations = <Future<void>>{}; Future<void>? _adeleCloseFuture; bool _adeleClosed = false;';
    out.writeln(
      'abstract interface class ${service.name}RequestDispatcher implements AdeleBackendDispatcher {} final class ${service.name}Dispatcher implements ${service.name}RequestDispatcher { ${service.name}Dispatcher(this._adeleService); final ${service.name} _adeleService; $streamFields @override Future<Map<String, Object?>> dispatch(Map<Object?, Object?> _adeleRequest0) { if (_adeleClosed) return Future<Map<String, Object?>>.error(StateError(\'The dispatcher is closed.\')); return _adeleScheduleOrdinary<Map<String, Object?>>(() => _adeleDispatchCore(_adeleRequest0)); } Future<Map<String, Object?>> _adeleDispatchCore(Map<Object?, Object?> _adeleRequest0) async { final _adeleRequestId1 = _adeleRequest0[\'requestId\']; late final String _adeleMethod2; try { _adeleMethod2 = _decodeContractEnvelope(_adeleRequest0, \'request\'); } on AdeleProtocolException catch(_adeleError3) { return _contractFailure(_adeleRequestId1, null, \'invalid_request\', _adeleError3.message, const {}); } if (!const $unaryIds.contains(_adeleMethod2)) return _contractFailure(_adeleRequestId1, null, ${streams.isEmpty ? "'unknown_method'" : "const $streamIds.contains(_adeleMethod2) ? 'wrong_method_kind' : 'unknown_method'"}, ${streams.isEmpty ? "'Unknown method.'" : "const $streamIds.contains(_adeleMethod2) ? 'Streaming method requires stream-open.' : 'Unknown method.'"}, const {}); late final Map<Object?, Object?> _adelePayload4; try { _adelePayload4 = _contractMap(_adeleRequest0[\'payload\'], \'request payload\'); } on AdeleProtocolException catch(_adeleError5) { return _contractFailure(_adeleRequestId1, null, \'invalid_request\', _adeleError5.message, const {}); } late final Object? _adeleArguments6; try { _adeleArguments6 = switch(_adeleMethod2) {',
    );
    for (final MethodModel method in unary) {
      out.writeln(
        '${_lower(service.name)}${_cap(method.name)}Id => ${_decodeArguments(method, '_adelePayload4')},',
      );
    }
    out.writeln(
      "_ => throw const _ContractUnknownMethod(), }; } on _ContractUnknownMethod { return _contractFailure(_adeleRequestId1, null, 'unknown_method', 'Unknown method.', const {}); } on AdeleProtocolException catch(_adeleError7) { return _contractFailure(_adeleRequestId1, null, 'invalid_request', _adeleError7.message, const {}); } late final Object? _adeleResult8; try { _adeleResult8 = await switch(_adeleMethod2) {",
    );
    for (final MethodModel method in unary) {
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
    for (final MethodModel method in unary) {
      out.writeln(
        '${_lower(service.name)}${_cap(method.name)}Id => ${_encode(method.returnType, '(_adeleResult8 as ${method.returnType.dart})')},',
      );
    }
    out.writeln(
      "_ => throw const _ContractUnknownMethod(), }; return {'kind': 'response', 'requestId': _adeleRequestId1, 'ok': true, 'payload': _adeleEncoded11}; } on Object { return _contractFailure(_adeleRequestId1, null, 'backend_contract_violation', 'The backend violated its generated contract.', const {}); } }",
    );
    if (streams.isEmpty) {
      out.writeln(
        '@override Future<void> handle(Map<Object?, Object?> _adeleCommand0, void Function(Map<String, Object?>) _adeleSend1) { if (_adeleClosed) return Future<void>.value(); return _adeleScheduleOrdinary<void>(() async => _adeleSend1(await _adeleDispatchCore(_adeleCommand0))); } Future<T> _adeleScheduleOrdinary<T>(Future<T> Function() _adeleBody0) { final Future<T> _adeleResult1 = _adeleOrdinaryTail.then((_) => _adeleBody0()); late final Future<void> _adeleSettlement2; _adeleSettlement2 = _adeleResult1.then<void>((_) {}, onError: (_, _) {}).whenComplete(() => _adeleOperations.remove(_adeleSettlement2)); _adeleOrdinaryTail = _adeleSettlement2; _adeleOperations.add(_adeleSettlement2); return _adeleResult1; } @override Future<void> close() => _adeleCloseFuture ??= _adeleClose(); Future<void> _adeleClose() async { _adeleClosed = true; await Future.wait<void>(_adeleOperations.toList(growable: false)); } }',
      );
    } else {
      out.writeln(
        '@override Future<void> handle(Map<Object?, Object?> _adeleCommand0, void Function(Map<String, Object?>) _adeleSend1) { final _adeleKind2 = _adeleCommand0[\'kind\']; if (_adeleKind2 == \'request\') { if (_adeleClosed) return Future<void>.value(); return _adeleScheduleOrdinary<void>(() async => _adeleSend1(await _adeleDispatchCore(_adeleCommand0))); } if (_adeleKind2 == \'streamOpen\') { if (_adeleClosed) return Future<void>.value(); final _adeleRequestId3 = _adeleCommand0[\'requestId\']; if (_adeleRequestId3 is! int || _adeleStreams.containsKey(_adeleRequestId3)) { _adeleSend1(_contractStreamFailure(_adeleRequestId3, null, \'invalid_request\', \'Malformed stream-open request.\', const {})); return Future<void>.value(); } final _adeleState4 = _ContractStreamState.opening(_adeleRequestId3); _adeleStreams[_adeleRequestId3] = _adeleState4; return _adeleScheduleOrdinary<void>(() => _adeleOpenStream(_adeleState4, _adeleCommand0, _adeleSend1)); } final _adeleRequestId3 = _adeleCommand0[\'requestId\']; if (_adeleRequestId3 is! int) return Future<void>.value(); final _adeleState4 = _adeleStreams[_adeleRequestId3]; if (_adeleKind2 == \'streamCredit\') { final _adeleCredit5 = _adeleCommand0[\'credit\']; if (_adeleState4 != null && _adeleCredit5 is int && _adeleCredit5 > 0) { _adeleState4.credit += _adeleCredit5; _adelePump(_adeleState4, _adeleSend1); } return Future<void>.value(); } if (_adeleKind2 == \'streamCancel\') return _adeleCancelAndAcknowledge(_adeleRequestId3, _adeleSend1); return Future<void>.value(); } Future<T> _adeleScheduleOrdinary<T>(Future<T> Function() _adeleBody0) { final Future<T> _adeleResult1 = _adeleOrdinaryTail.then((_) => _adeleBody0()); late final Future<void> _adeleSettlement2; _adeleSettlement2 = _adeleResult1.then<void>((_) {}, onError: (_, _) {}).whenComplete(() => _adeleOperations.remove(_adeleSettlement2)); _adeleOrdinaryTail = _adeleSettlement2; _adeleOperations.add(_adeleSettlement2); return _adeleResult1; }',
      );
      out.writeln(
        'Future<void> _adeleOpenStream(_ContractStreamState _adeleState0, Map<Object?, Object?> _adeleRequest0, void Function(Map<String, Object?>) _adeleSend1) async { final _adeleRequestId2 = _adeleState0.requestId; try { if (_adeleState0.done) return; late final String _adeleMethod3; late final Map<Object?, Object?> _adelePayload4; late final List<Object?> _adeleArguments5; try { _adeleMethod3 = _decodeContractEnvelope(_adeleRequest0, \'streamOpen\'); if (!const $streamIds.contains(_adeleMethod3)) { final _adeleWrongKind6 = const $unaryIds.contains(_adeleMethod3); _adeleFinish(_adeleState0, _adeleSend1, _contractStreamFailure(_adeleRequestId2, null, _adeleWrongKind6 ? \'wrong_method_kind\' : \'unknown_method\', _adeleWrongKind6 ? \'Unary method requires request.\' : \'Unknown method.\', const {})); return; } _adelePayload4 = _contractMap(_adeleRequest0[\'payload\'], \'request payload\'); _adeleArguments5 = switch (_adeleMethod3) {',
      );
      for (final MethodModel method in streams) {
        out.writeln(
          '${_lower(service.name)}${_cap(method.name)}Id => ${_decodeArguments(method, '_adelePayload4')},',
        );
      }
      out.writeln(
        "_ => throw const _ContractUnknownMethod(), }; } on AdeleProtocolException catch(_adeleError7) { _adeleFinish(_adeleState0, _adeleSend1, _contractStreamFailure(_adeleRequestId2, null, 'invalid_request', _adeleError7.message, const {})); return; } try { final Stream<Object?> _adeleSource8 = switch (_adeleMethod3) {",
      );
      for (final MethodModel method in streams) {
        out.writeln(
          '${_lower(service.name)}${_cap(method.name)}Id => ${_invokeStreamMethod(method, '_adeleArguments5')},',
        );
      }
      out.writeln(
        "_ => throw const _ContractUnknownMethod(), }; if (_adeleState0.done) { await AdeleStreamIterator<Object?>(_adeleSource8).cancel(); return; } _adeleState0.method = _adeleMethod3; _adeleState0.iterator = AdeleStreamIterator<Object?>(_adeleSource8); _adelePump(_adeleState0, _adeleSend1); }",
      );
      for (final FailureModel failure in failures) {
        out.writeln(
          "on ${failure.name} catch(_adeleError9) { try { _adeleFinish(_adeleState0, _adeleSend1, _contractStreamFailure(_adeleRequestId2, ${_lower(failure.name)}TypeId, _adeleError9.code, _adeleError9.message, _contractJsonMap(_adeleError9.details, 'failure details'))); } on Object { _adeleFinish(_adeleState0, _adeleSend1, _contractStreamFailure(_adeleRequestId2, null, 'backend_contract_violation', 'The backend violated its generated contract.', const {})); } }",
        );
      }
      out.writeln(
        "on TypeError { _adeleFinish(_adeleState0, _adeleSend1, _contractStreamFailure(_adeleRequestId2, null, 'backend_contract_violation', 'The backend violated its generated contract.', const {})); }",
      );
      out.writeln(
        "on Object { _adeleFinish(_adeleState0, _adeleSend1, _contractStreamFailure(_adeleRequestId2, null, 'internal_error', 'The backend stream failed unexpectedly.', const {})); } } finally { if (!_adeleState0.openingSettled.isCompleted) _adeleState0.openingSettled.complete(); } }",
      );
      out.writeln(
        'Future<void> _adelePump(_ContractStreamState _adeleState0, void Function(Map<String, Object?>) _adeleSend1) async { final _adeleIterator2 = _adeleState0.iterator; if (_adeleState0.pumping || _adeleState0.done || _adeleIterator2 == null) return; _adeleState0.pumping = true; try { while (!_adeleState0.done && _adeleState0.credit > 0) { _adeleState0.credit--; late final bool _adeleHasItem2; try { _adeleHasItem2 = await _adeleIterator2.moveNext(); }',
      );
      for (final FailureModel failure in failures) {
        out.writeln(
          "on ${failure.name} catch(_adeleError3) { try { _adeleFinish(_adeleState0, _adeleSend1, _contractStreamFailure(_adeleState0.requestId, ${_lower(failure.name)}TypeId, _adeleError3.code, _adeleError3.message, _contractJsonMap(_adeleError3.details, 'failure details'))); } on Object { _adeleFinish(_adeleState0, _adeleSend1, _contractStreamFailure(_adeleState0.requestId, null, 'backend_contract_violation', 'The backend violated its generated contract.', const {})); } return; }",
        );
      }
      out.writeln(
        "on TypeError { _adeleFailAndCancel(_adeleState0, _adeleSend1, _contractStreamFailure(_adeleState0.requestId, null, 'backend_contract_violation', 'The backend violated its generated contract.', const {})); return; }",
      );
      out.writeln(
        "on Object { _adeleFinish(_adeleState0, _adeleSend1, _contractStreamFailure(_adeleState0.requestId, null, 'internal_error', 'The backend stream failed unexpectedly.', const {})); return; } if (_adeleState0.done || _adeleStreams[_adeleState0.requestId] != _adeleState0) return; if (!_adeleHasItem2) { _adeleFinish(_adeleState0, _adeleSend1, {'kind': 'streamDone', 'requestId': _adeleState0.requestId}); return; } try { final _adeleEncoded4 = switch (_adeleState0.method) {",
      );
      for (final MethodModel method in streams) {
        out.writeln(
          '${_lower(service.name)}${_cap(method.name)}Id => ${_encode(method.returnType, '(_adeleIterator2.current as ${method.returnType.dart})')},',
        );
      }
      out.writeln(
        "_ => throw const _ContractUnknownMethod(), }; _adeleSend1({'kind': 'streamItem', 'requestId': _adeleState0.requestId, 'payload': _adeleEncoded4}); } on Object { _adeleFailAndCancel(_adeleState0, _adeleSend1, _contractStreamFailure(_adeleState0.requestId, null, 'backend_contract_violation', 'The backend violated its generated contract.', const {})); return; } } } finally { _adeleState0.pumping = false; if (!_adeleState0.done && _adeleState0.credit > 0 && _adeleState0.iterator != null) _adelePump(_adeleState0, _adeleSend1); } } void _adeleFinish(_ContractStreamState _adeleState0, void Function(Map<String, Object?>) _adeleSend1, Map<String, Object?> _adeleTerminal2) { if (_adeleState0.done || _adeleStreams.remove(_adeleState0.requestId) != _adeleState0) return; _adeleState0.done = true; _adeleSend1(_adeleTerminal2); } void _adeleFailAndCancel(_ContractStreamState _adeleState0, void Function(Map<String, Object?>) _adeleSend1, Map<String, Object?> _adeleTerminal2) { if (_adeleState0.done || _adeleStreams.remove(_adeleState0.requestId) != _adeleState0) return; _adeleState0.done = true; _adeleTrackCancellation(_adeleState0, onSettled: () => _adeleSend1(_adeleTerminal2)); } Future<void> _adeleCancelAndAcknowledge(int _adeleRequestId0, void Function(Map<String, Object?>) _adeleSend1) async { if (await _adeleCancel(_adeleRequestId0)) _adeleSend1({'kind': 'streamCancelled', 'requestId': _adeleRequestId0}); } Future<void> _adeleTrackCancellation(_ContractStreamState _adeleState0, {void Function()? onSettled}) { late final Future<void> _adeleCancellation1; _adeleCancellation1 = (() async { await _adeleState0.openingSettled.future; try { await _adeleState0.iterator?.cancel(); } on Object { return; } })().then<void>((_) => onSettled?.call()).whenComplete(() => _adeleCancellations.remove(_adeleCancellation1)); _adeleCancellations.add(_adeleCancellation1); return _adeleCancellation1; } Future<bool> _adeleCancel(int _adeleRequestId0) { final _adeleState1 = _adeleStreams.remove(_adeleRequestId0); if (_adeleState1 == null || _adeleState1.done) return Future<bool>.value(false); _adeleState1.done = true; return _adeleTrackCancellation(_adeleState1).then((_) => true); } @override Future<void> close() => _adeleCloseFuture ??= _adeleClose(); Future<void> _adeleClose() async { _adeleClosed = true; final _adeleIds0 = _adeleStreams.keys.toList(growable: false); await Future.wait<bool>(_adeleIds0.map(_adeleCancel)); await Future.wait<void>(_adeleOperations.toList(growable: false)); await Future.wait<void>(_adeleCancellations.toList(growable: false)); } } String _decodeContractEnvelope(Map<Object?, Object?> _adeleRequest0, String _adeleKind1) { _contractFields(_adeleRequest0, const {'kind', 'requestId', 'method', 'payload'}, 'request envelope'); if (_adeleRequest0['requestId'] is! int || _adeleRequest0['kind'] != _adeleKind1 || _adeleRequest0['method'] is! String) throw const AdeleProtocolException('Malformed request envelope.'); return _adeleRequest0['method'] as String; } final class _ContractUnknownMethod implements Exception { const _ContractUnknownMethod(); } final class _ContractStreamState { _ContractStreamState.opening(this.requestId); final int requestId; final AdeleCompleter<void> openingSettled = AdeleCompleter<void>(); String? method; AdeleStreamIterator<Object?>? iterator; int credit = 0; bool pumping = false; bool done = false; } ",
      );
    }
    if (streams.isEmpty) {
      out.writeln(
        "String _decodeContractEnvelope(Map<Object?, Object?> _adeleRequest0, String _adeleKind1) { _contractFields(_adeleRequest0, const {'kind', 'requestId', 'method', 'payload'}, 'request envelope'); if (_adeleRequest0['requestId'] is! int || _adeleRequest0['kind'] != _adeleKind1 || _adeleRequest0['method'] is! String) throw const AdeleProtocolException('Malformed request envelope.'); return _adeleRequest0['method'] as String; } final class _ContractUnknownMethod implements Exception { const _ContractUnknownMethod(); }",
      );
    }
    out.writeln(
      "Map<String, Object?> _contractFailure(Object? _adeleRequestId0, String? _adeleDeclaredFailureType1, String _adeleCode2, String _adeleMessage3, Map<String, Object?> _adeleDetails4) => {'kind': 'response', if(_adeleRequestId0 is int) 'requestId': _adeleRequestId0, 'ok': false, 'error': {if(_adeleDeclaredFailureType1 != null) 'declaredFailureType': _adeleDeclaredFailureType1, 'code': _adeleCode2, 'message': _adeleMessage3, 'details': _adeleDetails4}};",
    );
    if (streams.isNotEmpty) {
      out.writeln(
        "Map<String, Object?> _contractStreamFailure(Object? _adeleRequestId0, String? _adeleDeclaredFailureType1, String _adeleCode2, String _adeleMessage3, Map<String, Object?> _adeleDetails4) => {'kind': 'streamFailure', if(_adeleRequestId0 is int) 'requestId': _adeleRequestId0, 'error': {if(_adeleDeclaredFailureType1 != null) 'declaredFailureType': _adeleDeclaredFailureType1, 'code': _adeleCode2, 'message': _adeleMessage3, 'details': _adeleDetails4}};",
      );
    }
  }

  String _failureSwitch(List<FailureModel> failures, String error) =>
      "switch($error.declaredFailureType) { ${failures.map((FailureModel f) => "case ${_lower(f.name)}TypeId: final _adeleDetails0 = _contractJsonMap($error.details, 'failure details'); throw _contractConstruct(${_literal(f.name)}, () => ${f.name}(code: $error.code, message: $error.message, details: _adeleDetails0));").join()} default: rethrow; }";
  String _streamFailureSwitch(List<FailureModel> failures, String error) =>
      "switch($error.declaredFailureType) { ${failures.map((FailureModel f) => "case ${_lower(f.name)}TypeId: final _adeleDetails8 = _contractJsonMap($error.details, 'failure details'); throw _contractConstruct(${_literal(f.name)}, () => ${f.name}(code: $error.code, message: $error.message, details: _adeleDetails8));").join()} default: break; }";
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
    final String invocation = method.parameters.isEmpty
        ? 'await this._adeleService.${method.name}()'
        : 'await this._adeleService.${method.name}($values)';
    final String argumentsLocal = method.parameters.isEmpty
        ? ''
        : 'final _adeleValues0 = $arguments as List<Object?>;';
    return "(() async { $argumentsLocal ${method.returnType.kind == TypeKind.void_ ? '$invocation; return null;' : 'return $invocation;'} })()";
  }

  String _invokeStreamMethod(MethodModel method, String arguments) {
    final String values = <String>[
      for (int index = 0; index < method.parameters.length; index++)
        '$arguments[$index] as ${method.parameters[index].type.dart}',
    ].join(',');
    return 'this._adeleService.${method.name}($values).map<Object?>((Object? _adeleItem) => _adeleItem)';
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
        "await this._adeleChannel.request(${_lower(service.name)}${_cap(method.name)}Id, <String, Object?>{${method.parameters.map((FieldModel p) => '${_literal(p.id)}: ${_encode(p.type, p.name)}').join(',')}})";
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
