// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, unnecessary_nullable_for_final_variable_declarations, unused_catch_clause, unused_element, use_null_aware_elements

part of 'workspace_demo_contract.dart';

const String workspaceDemoServiceId = 'workspaceDemo';
const String workspaceDemoServiceListDirectoryId =
    'workspaceDemo.listDirectory';
const String workspaceDemoServiceReadTextFileId = 'workspaceDemo.readTextFile';

final class WorkspaceDemoServiceClient implements WorkspaceDemoService {
  const WorkspaceDemoServiceClient(this._channel);
  final AdeleRequestChannel _channel;
  @override
  Future<DirectoryListing> listDirectory(ResourceRef directory) async {
    try {
      return _decodeDirectoryListing(
        await _channel.request(
          workspaceDemoServiceListDirectoryId,
          <String, Object?>{'directory': _contractResourceRef(directory)},
        ),
      );
    } on AdeleRemoteFailure catch (error) {
      switch (error.declaredFailureType) {
        case workspaceDemoFailureTypeId:
          throw WorkspaceDemoFailure(
            code: error.code,
            message: error.message,
            details: _contractJsonMap(error.details, 'failure details'),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<TextFileContents> readTextFile(ResourceRef file) async {
    try {
      return _decodeTextFileContents(
        await _channel.request(
          workspaceDemoServiceReadTextFileId,
          <String, Object?>{'file': _contractResourceRef(file)},
        ),
      );
    } on AdeleRemoteFailure catch (error) {
      switch (error.declaredFailureType) {
        case workspaceDemoFailureTypeId:
          throw WorkspaceDemoFailure(
            code: error.code,
            message: error.message,
            details: _contractJsonMap(error.details, 'failure details'),
          );
        default:
          rethrow;
      }
    }
  }
}

abstract interface class WorkspaceDemoServiceRequestDispatcher {
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request);
}

final class WorkspaceDemoServiceDispatcher
    implements WorkspaceDemoServiceRequestDispatcher {
  const WorkspaceDemoServiceDispatcher(this._service);
  final WorkspaceDemoService _service;
  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async {
    final requestId = request['requestId'];
    try {
      _contractFields(request, const {
        'kind',
        'requestId',
        'method',
        'payload',
      }, 'request envelope');
      if (requestId is! int ||
          request['kind'] != 'request' ||
          request['method'] is! String)
        throw const AdeleProtocolException('Malformed request envelope.');
      final payload = _contractMap(request['payload'], 'request payload');
      final Object? result = await switch (request['method']) {
        workspaceDemoServiceListDirectoryId => (() async {
          _contractFields(payload, const {
            'directory',
          }, 'listDirectory payload');
          return _encodeDirectoryListing(
            (await _service.listDirectory(
              _decodeResourceRef(payload['directory']),
            )),
          );
        })(),
        workspaceDemoServiceReadTextFileId => (() async {
          _contractFields(payload, const {'file'}, 'readTextFile payload');
          return _encodeTextFileContents(
            (await _service.readTextFile(_decodeResourceRef(payload['file']))),
          );
        })(),
        _ => throw const AdeleProtocolException('Unknown method.'),
      };
      return {
        'kind': 'response',
        'requestId': requestId,
        'ok': true,
        'payload': result,
      };
    } on WorkspaceDemoFailure catch (error) {
      return _contractFailure(
        requestId,
        workspaceDemoFailureTypeId,
        error.code,
        error.message,
        _contractJsonMap(error.details, 'failure details'),
      );
    } on AdeleProtocolException catch (error) {
      final unknown = error.message == 'Unknown method.';
      return _contractFailure(
        requestId,
        null,
        unknown ? 'unknown_method' : 'invalid_request',
        error.message,
        const {},
      );
    } on Object catch (error) {
      return _contractFailure(
        requestId,
        null,
        'internal_error',
        'The backend request failed unexpectedly.',
        const {},
      );
    }
  }
}

Map<String, Object?> _contractFailure(
  Object? requestId,
  String? declaredFailureType,
  String code,
  String message,
  Map<String, Object?> details,
) => {
  'kind': 'response',
  if (requestId is int) 'requestId': requestId,
  'ok': false,
  'error': {
    if (declaredFailureType != null) 'declaredFailureType': declaredFailureType,
    'code': code,
    'message': message,
    'details': details,
  },
};
const String workspaceDemoFailureTypeId = 'workspaceDemo.failure';
const String directoryEntryTypeId = 'workspaceDemo.directoryEntry';
Map<String, Object?> _encodeDirectoryEntry(DirectoryEntry value) =>
    <String, Object?>{
      'kind': value.kind.name,
      'name': value.name,
      'resource': _contractResourceRef(value.resource),
    };
DirectoryEntry _decodeDirectoryEntry(Object? value) {
  final map = _contractMap(value, 'DirectoryEntry');
  _contractFields(map, const {'kind', 'name', 'resource'}, 'DirectoryEntry');
  return DirectoryEntry(
    kind: _decodeDirectoryEntryKind(map['kind']),
    name: _contractString(map['name'], 'name'),
    resource: _decodeResourceRef(map['resource']),
  );
}

const String directoryListingTypeId = 'workspaceDemo.directoryListing';
Map<String, Object?> _encodeDirectoryListing(DirectoryListing value) =>
    <String, Object?>{
      'directory': _contractResourceRef(value.directory),
      'entries': value.entries
          .map((element) => _encodeDirectoryEntry(element))
          .toList(growable: false),
    };
DirectoryListing _decodeDirectoryListing(Object? value) {
  final map = _contractMap(value, 'DirectoryListing');
  _contractFields(map, const {'directory', 'entries'}, 'DirectoryListing');
  return DirectoryListing(
    directory: _decodeResourceRef(map['directory']),
    entries: List.unmodifiable(
      _contractList(
        map['entries'],
        'entries',
      ).map((element) => _decodeDirectoryEntry(element)),
    ),
  );
}

const String textFileContentsTypeId = 'workspaceDemo.textFileContents';
Map<String, Object?> _encodeTextFileContents(TextFileContents value) =>
    <String, Object?>{
      'resource': _contractResourceRef(value.resource),
      'text': value.text,
    };
TextFileContents _decodeTextFileContents(Object? value) {
  final map = _contractMap(value, 'TextFileContents');
  _contractFields(map, const {'resource', 'text'}, 'TextFileContents');
  return TextFileContents(
    resource: _decodeResourceRef(map['resource']),
    text: _contractString(map['text'], 'text'),
  );
}

DirectoryEntryKind _decodeDirectoryEntryKind(Object? value) {
  if (value is! String)
    throw AdeleProtocolException('Expected DirectoryEntryKind.');
  return switch (value) {
    'directory' => DirectoryEntryKind.directory,
    'file' => DirectoryEntryKind.file,
    _ => throw AdeleProtocolException('Unknown DirectoryEntryKind: $value.'),
  };
}

Map<Object?, Object?> _contractMap(Object? value, String label) {
  if (value is! Map<Object?, Object?>)
    throw AdeleProtocolException('Expected map for $label.');
  for (final key in value.keys) {
    if (key is! String)
      throw AdeleProtocolException('Expected string keys for $label.');
  }
  return value;
}

void _contractFields(
  Map<Object?, Object?> value,
  Set<String> expected,
  String label,
) {
  for (final key in value.keys) {
    if (key is! String || !expected.contains(key))
      throw AdeleProtocolException('Unknown field in $label: $key.');
  }
  for (final key in expected) {
    if (!value.containsKey(key))
      throw AdeleProtocolException('Missing field in $label: $key.');
  }
}

List<Object?> _contractList(Object? value, String label) {
  if (value is! List) throw AdeleProtocolException('Expected list for $label.');
  return List<Object?>.of(value);
}

Map<String, Object?> _contractJsonMap(Object? value, String label) {
  final map = _contractMap(value, label);
  Object? validate(Object? item) {
    if (item == null ||
        item is String ||
        item is bool ||
        item is int ||
        item is double)
      return item;
    if (item is List) return item.map(validate).toList(growable: false);
    if (item is Map) {
      final result = <String, Object?>{};
      for (final entry in item.entries) {
        if (entry.key is! String)
          throw AdeleProtocolException('Expected string keys for $label.');
        result[entry.key as String] = validate(entry.value);
      }
      return result;
    }
    throw AdeleProtocolException(
      'Expected recursively JSON-compatible values for $label.',
    );
  }

  return Map<String, Object?>.fromEntries(
    map.entries.map(
      (entry) => MapEntry(entry.key as String, validate(entry.value)),
    ),
  );
}

void _contractVoid(Object? value, String label) {
  if (value != null) throw AdeleProtocolException('Expected null for $label.');
}

String _contractString(Object? value, String label) {
  if (value is! String)
    throw AdeleProtocolException('Expected String for $label.');
  return value;
}

bool _contractBool(Object? value, String label) {
  if (value is! bool) throw AdeleProtocolException('Expected bool for $label.');
  return value;
}

int _contractInt(Object? value, String label) {
  if (value is! int) throw AdeleProtocolException('Expected int for $label.');
  return value;
}

double _contractDouble(Object? value, String label) {
  if (value is! double)
    throw AdeleProtocolException('Expected double for $label.');
  return value;
}

Map<String, Object?> _contractResourceRef(ResourceRef value) => {
  'uri': value.uri.toString(),
  'mediaType': value.mediaType,
};
ResourceRef _decodeResourceRef(Object? value) {
  final map = _contractMap(value, 'ResourceRef');
  _contractFields(map, const {'uri', 'mediaType'}, 'ResourceRef');
  final uri = map['uri'];
  final mediaType = map['mediaType'];
  if (uri is! String || mediaType != null && mediaType is! String)
    throw const AdeleProtocolException('Malformed ResourceRef.');
  return ResourceRef(uri: Uri.parse(uri), mediaType: mediaType as String?);
}
