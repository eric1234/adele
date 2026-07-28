/// A reference to a resource identified independently of its storage system.
final class ResourceRef {
  const ResourceRef({required this.uri, this.mediaType});

  final Uri uri;
  final String? mediaType;
}
