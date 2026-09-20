part of 'contract_generator.dart';

/// Compile-only contract support. Native bridges still validate routing,
/// liveness and JSON bounds before/after crossing the interpreter boundary.
const String evalContractSupportSource = '''
abstract class AdeleRequestChannel {
  Future<Object?> request(String method, Map<String, Object?> payload);
}
class AdeleProtocolException implements Exception {
  AdeleProtocolException(this.message);
  final String message;
  String toString() => message;
}
''';

/// Intentionally bounded to unary scalar, nullable, JSON, list and value transport.
/// This is a generated wire view, not an alternate semantic implementation.
final class _EvalClientEmitter {
  final DartContractEmitter _names = DartContractEmitter();
  final Map<String, TypeModel> _types = {};

  String _encode(TypeModel type, String value) {
    if (type.kind == TypeKind.string ||
        type.kind == TypeKind.boolean ||
        type.kind == TypeKind.integer) {
      return value;
    }
    return '${_codec(type)}Encode($value)';
  }

  String _codec(TypeModel type) {
    if (type.kind == TypeKind.uri ||
        type.kind == TypeKind.enumeration ||
        type.kind == TypeKind.external) {
      throw UnsupportedError('Eval client does not support ${type.dart}.');
    }
    if (type.nullable) _codec(type.nonNullable);
    if (type.argument != null) _codec(type.argument!);
    _types.putIfAbsent(type.dart, () => type);
    return '_wire${_types.keys.toList().indexOf(type.dart)}';
  }

  String emit(ContractModel model) {
    if (model.enums.isNotEmpty) {
      throw UnsupportedError('Eval client does not support enums.');
    }
    final out = StringBuffer('''
// GENERATED CODE - DO NOT MODIFY BY HAND.
// Client-only wire view; generated from the annotated native contract.
import 'package:adele_contract/adele_contract.dart';
''');
    for (final value in model.values) {
      out.writeln('class ${value.name} {');
      out.writeln(
        '${value.name}({${value.fields.map((f) => 'required this.${f.name}').join(',')}});',
      );
      for (final field in value.fields) {
        _codec(field.type);
        out.writeln('final ${field.type.dart} ${field.name};');
      }
      out.writeln('}');
      _codec(TypeModel(TypeKind.value, value.name));
    }
    for (final service in model.services) {
      out.writeln(
        'const String ${_names._lower(service.name)}Id = ${_names._literal(service.id)};',
      );
      out.writeln(
        'class ${service.name}Client { ${service.name}Client(this._channel); final AdeleRequestChannel _channel;',
      );
      for (final method in service.methods) {
        if (method.kind != MethodKind.unary) {
          throw UnsupportedError(
            'Eval client does not support server streams.',
          );
        }
        final resultCodec = _codec(method.returnType);
        // The eval pin cannot unwind a rejected native Future through an
        // interpreted await/catch. Preserve channel errors as Future errors;
        // decoding happens in a synchronous continuation, never a native codec.
        out.writeln(
          'Future<${method.returnType.dart}> ${method.name}(${method.parameters.map((f) => '${f.type.dart} ${f.name}').join(',')}) { return this._channel.request(${_names._literal('${service.id}.${method.id}')}, <String, Object?>{${method.parameters.map((f) => '${_names._literal(f.id)}: ${_encode(f.type, f.name)}').join(',')}}).then((Object? _adeleResponse) { ${method.returnType.kind == TypeKind.void_ ? '' : 'return '}${resultCodec}Decode(_adeleResponse); }); }',
        );
      }
      out.writeln('}');
    }
    for (final entry in _types.entries) {
      final type = entry.value;
      final name = _codec(type);
      out.writeln('${type.dart} ${name}Decode(Object? value) {');
      if (type.nullable) {
        out.writeln(
          'if (value == null) return null; return ${_codec(type.nonNullable)}Decode(value);',
        );
      } else if (type.kind == TypeKind.void_) {
        out.writeln(
          "if (value != null) throw AdeleProtocolException('Expected null.');",
        );
      } else if (type.kind == TypeKind.list) {
        out.writeln(
          "if (value is! List<Object?>) throw AdeleProtocolException('Expected list.'); final result = <${type.argument!.dart}>[]; for (final item in value as List<Object?>) { result.add(${_codec(type.argument!)}Decode(item)); } return List<${type.argument!.dart}>.unmodifiable(result);",
        );
      } else if (type.kind == TypeKind.map) {
        out.writeln(
          "if (value is! Map<Object?, Object?>) throw AdeleProtocolException('Expected JSON map.'); return _evalJson(value, 0) as Map<String, Object?>;",
        );
      } else if (type.kind == TypeKind.value) {
        final value = model.values.singleWhere((v) => v.name == type.dart);
        out.writeln(
          "if (value is! Map<Object?, Object?>) throw AdeleProtocolException('Expected ${value.name} map.'); final map = value as Map<Object?, Object?>;",
        );
        out.writeln(
          "final fields = <String>[${value.fields.map((f) => _names._literal(f.id)).join(',')}]; for (final key in map.keys) { if (key is! String || !fields.contains(key)) throw AdeleProtocolException('Unknown ${value.name} field.'); } for (final key in fields) { if (!map.containsKey(key)) throw AdeleProtocolException('Missing ${value.name} field.'); }",
        );
        out.writeln(
          'return ${value.name}(${value.fields.map((f) => '${f.name}: ${_codec(f.type)}Decode(map[${_names._literal(f.id)}])').join(',')});',
        );
      } else {
        out.writeln(
          "if (value is! ${type.dart}) throw AdeleProtocolException('Expected ${type.dart}.');",
        );
        if (type.kind == TypeKind.double_) {
          out.writeln(
            "if (value == double.infinity || value == double.negativeInfinity || value != value) throw AdeleProtocolException('Expected finite double.');",
          );
        }
        out.writeln('return value as ${type.dart};');
      }
      out.writeln('}');
      if (type.kind == TypeKind.void_) continue;
      final encodedType = switch (type.kind) {
        TypeKind.value || TypeKind.map => 'Map<String, Object?>',
        TypeKind.list => 'List<Object?>',
        _ => type.nonNullable.dart,
      };
      out.writeln(
        '$encodedType${type.nullable ? '?' : ''} ${name}Encode(${type.dart} value) {',
      );
      if (type.nullable) {
        out.writeln(
          'if (value == null) return null; return ${_codec(type.nonNullable)}Encode(value as ${type.nonNullable.dart});',
        );
      } else if (type.kind == TypeKind.list) {
        out.writeln(
          'final result = <Object?>[]; for (final item in value) { result.add(${_encode(type.argument!, 'item')}); } return result;',
        );
      } else if (type.kind == TypeKind.value) {
        final value = model.values.singleWhere((v) => v.name == type.dart);
        out.writeln(
          'return <String, Object?>{${value.fields.map((f) => '${_names._literal(f.id)}: ${_encode(f.type, 'value.${f.name}')}').join(',')}};',
        );
      } else if (type.kind == TypeKind.map) {
        out.writeln('return ${name}Decode(value);');
      } else {
        if (type.kind == TypeKind.double_) {
          out.writeln(
            "if (value == double.infinity || value == double.negativeInfinity || value != value) throw AdeleProtocolException('Expected finite double.');",
          );
        }
        out.writeln('return value;');
      }
      out.writeln('}');
    }
    if (_types.values.any((type) => type.kind == TypeKind.map)) {
      out.writeln('''
Object? _evalJson(Object? value, int depth) {
  if (value == null || value is String || value is bool || value is int) return value;
  if (value is double) {
    if (value == double.infinity || value == double.negativeInfinity || value != value) throw AdeleProtocolException('Expected finite JSON number.');
    return value;
  }
  // A finite nesting bound also rejects cyclic containers without identity sets.
  if (depth >= 64) throw AdeleProtocolException('JSON exceeds maximum depth 64.');
  if (value is List<Object?>) {
    final result = <Object?>[];
    for (final item in value as List<Object?>) { result.add(_evalJson(item, depth + 1)); }
    return List<Object?>.unmodifiable(result);
  }
  if (value is Map<Object?, Object?>) {
    final result = <String, Object?>{};
    final map = value as Map<Object?, Object?>;
    for (final key in map.keys) {
      if (key is! String) throw AdeleProtocolException('Expected JSON string key.');
      result[key as String] = _evalJson(map[key], depth + 1);
    }
    return result;
  }
  throw AdeleProtocolException('Expected JSON value.');
}
''');
    }
    return out.toString();
  }
}
