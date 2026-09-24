import 'package:adele_capabilities/adele_capabilities.dart' as capabilities;
import 'package:adele_contract/adele_contract.dart';

part 'project_provider.g.dart';

final capabilities.CapabilityKey projectProviderCapability =
    capabilities.CapabilityKey(
      id: capabilities.CapabilityId('dev.adele.project.provider'),
      majorVersion: 1,
    );

/// Describes source backing, not an open database or a Project identity.
/// The host validates the location and confinement before opening storage.
@AdeleValue('project.backing')
final class ProjectBacking {
  const ProjectBacking({
    required this.sourceLocation,
    required this.databaseRelativePath,
  });

  final Uri sourceLocation;

  /// Portable source-relative file path owned by the provider's placement policy.
  final String databaseRelativePath;
}

@AdeleService('dev.adele.project.provider')
abstract interface class ProjectProviderService {
  @AdeleMethod('prepareSource')
  Future<ProjectBacking> prepareSource(Uri sourceLocation);
}
