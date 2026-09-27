import 'package:adele_product/adele_product.dart';

String projectDisplayName(Project project) {
  final source = project.sourceLocation;
  for (final segment in source.pathSegments.reversed) {
    if (segment.isNotEmpty) return segment;
  }
  return source.host.isNotEmpty ? source.host : source.toString();
}
