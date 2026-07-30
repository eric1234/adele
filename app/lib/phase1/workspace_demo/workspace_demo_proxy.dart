import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

final class WorkspaceDemoProxy implements WorkspaceDemoService {
  const WorkspaceDemoProxy(this._connection);

  final PluginBackendConnection _connection;

  @override
  Future<DirectoryListing> listDirectory(ResourceRef directory) async {
    final Object? payload = await _connection.request(
      'workspaceDemo.listDirectory',
      <String, Object?>{'resource': _encodeResource(directory)},
    );
    return _decodeListing(payload);
  }

  @override
  Future<TextFileContents> readTextFile(ResourceRef file) async {
    final Object? payload = await _connection.request(
      'workspaceDemo.readTextFile',
      <String, Object?>{'resource': _encodeResource(file)},
    );
    final Map<Object?, Object?> map = _map(payload, 'text contents');
    final Object? text = map['text'];
    if (text is! String) throw const FormatException('Invalid text contents.');
    return TextFileContents(
      resource: _decodeResource(map['resource']),
      text: text,
    );
  }
}

Map<String, Object?> _encodeResource(ResourceRef value) => <String, Object?>{
  'uri': value.uri.toString(),
  'mediaType': value.mediaType,
};

ResourceRef _decodeResource(Object? value) {
  final Map<Object?, Object?> map = _map(value, 'resource');
  final Object? uri = map['uri'];
  final Object? mediaType = map['mediaType'];
  if (uri is! String || (mediaType != null && mediaType is! String)) {
    throw const FormatException('Invalid resource.');
  }
  return ResourceRef(uri: Uri.parse(uri), mediaType: mediaType as String?);
}

DirectoryListing _decodeListing(Object? value) {
  final Map<Object?, Object?> map = _map(value, 'directory listing');
  final Object? entries = map['entries'];
  if (entries is! List) throw const FormatException('Invalid entries.');
  return DirectoryListing(
    directory: _decodeResource(map['directory']),
    entries: entries
        .map<DirectoryEntry>((Object? value) {
          final Map<Object?, Object?> entry = _map(value, 'directory entry');
          final Object? name = entry['name'];
          final Object? kind = entry['kind'];
          if (name is! String || kind is! String) {
            throw const FormatException('Invalid directory entry.');
          }
          return DirectoryEntry(
            resource: _decodeResource(entry['resource']),
            name: name,
            kind: switch (kind) {
              'directory' => DirectoryEntryKind.directory,
              'file' => DirectoryEntryKind.file,
              _ => throw FormatException('Unknown directory entry kind: $kind'),
            },
          );
        })
        .toList(growable: false),
  );
}

Map<Object?, Object?> _map(Object? value, String label) {
  if (value is Map<Object?, Object?>) return value;
  if (value is Map) return value.cast<Object?, Object?>();
  throw FormatException('Invalid $label.');
}
