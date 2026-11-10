import 'package:adele_contract/adele_contract.dart';

part 'backend_local_state.g.dart';

/// Path-only lookup through an exact backend generation's infrastructure grant.
///
/// The host owns platform location policy. The returned path need not exist;
/// lookup creates nothing and grants no filesystem or persistence authority.
@AdeleService('adele.backendLocalState')
abstract interface class BackendLocalStateService {
  @AdeleMethod('getLocalStateRoot')
  Future<String> getLocalStateRoot();
}
