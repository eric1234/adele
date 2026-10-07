import 'package:adele_contract/adele_contract.dart';

part 'remote_command.g.dart';

@AdeleService('dev.adele.command.remote')
abstract interface class RemoteCommandService {
  /// Invokes an opaque backend route, not a semantic Command ID or method ID.
  /// The route is payload; the host validates it when accepting its exposure.
  @AdeleMethod('invoke')
  Future<void> invoke(String routeId);
}
