import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

final class WorkspaceDemoDispatcher {
  const WorkspaceDemoDispatcher(this._service);

  final WorkspaceDemoService _service;

  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async {
    final Object? requestId = request['requestId'];
    try {
      if (requestId is! int || request['kind'] != 'request') {
        throw const WorkspaceDemoFailure(
          code: 'invalid_request',
          message: 'Malformed request envelope.',
        );
      }
      final Map<Object?, Object?> payload = _map(request['payload']);
      final Object result = switch (request['method']) {
        'workspaceDemo.listDirectory' => await _service.listDirectory(
          _decodeResource(payload['resource']),
        ),
        'workspaceDemo.readTextFile' => await _service.readTextFile(
          _decodeResource(payload['resource']),
        ),
        _ => throw const WorkspaceDemoFailure(
          code: 'unknown_method',
          message: 'Unknown workspace demo method.',
        ),
      };
      return <String, Object?>{
        'kind': 'response',
        'requestId': requestId,
        'ok': true,
        'payload': switch (result) {
          final DirectoryListing value => _encodeListing(value),
          final TextFileContents value => _encodeContents(value),
          _ => throw StateError('Unsupported result.'),
        },
      };
    } on WorkspaceDemoFailure catch (error) {
      return <String, Object?>{
        'kind': 'response',
        if (requestId is int) 'requestId': requestId,
        'ok': false,
        'error': <String, Object?>{
          'code': error.code,
          'message': error.message,
          'details': error.details,
        },
      };
    } on Object catch (error, stackTrace) {
      return <String, Object?>{
        'kind': 'response',
        if (requestId is int) 'requestId': requestId,
        'ok': false,
        'error': <String, Object?>{
          'code': 'internal_error',
          'message': 'The backend request failed unexpectedly.',
          'details': <String, Object?>{
            'developmentError': error.toString(),
            'developmentStack': stackTrace.toString(),
          },
        },
      };
    }
  }
}

ResourceRef _decodeResource(Object? value) {
  final Map<Object?, Object?> map = _map(value);
  final Object? uri = map['uri'];
  final Object? mediaType = map['mediaType'];
  if (uri is! String || (mediaType != null && mediaType is! String)) {
    throw const WorkspaceDemoFailure(
      code: 'invalid_resource',
      message: 'Malformed resource.',
    );
  }
  return ResourceRef(uri: Uri.parse(uri), mediaType: mediaType as String?);
}

Map<String, Object?> _encodeResource(ResourceRef value) => <String, Object?>{
  'uri': value.uri.toString(),
  'mediaType': value.mediaType,
};

Map<String, Object?> _encodeListing(DirectoryListing value) =>
    <String, Object?>{
      'directory': _encodeResource(value.directory),
      'entries': value.entries
          .map(
            (DirectoryEntry entry) => <String, Object?>{
              'resource': _encodeResource(entry.resource),
              'name': entry.name,
              'kind': entry.kind.name,
            },
          )
          .toList(growable: false),
    };

Map<String, Object?> _encodeContents(TextFileContents value) =>
    <String, Object?>{
      'resource': _encodeResource(value.resource),
      'text': value.text,
    };

Map<Object?, Object?> _map(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  if (value is Map) return value.cast<Object?, Object?>();
  throw const WorkspaceDemoFailure(
    code: 'invalid_request',
    message: 'Expected a map value.',
  );
}
