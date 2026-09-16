import 'package:adele_product/adele_product.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'prepared_frontend.dart';

/// Internal native seams for the bounded installed Session presentation roles.
/// This is not a plugin-facing controller or reverse-call API.
abstract interface class PreparedSessionAdapter {
  void validate(PreparedSessionPresentation descriptor);

  Widget createPresentation({
    required PreparedFrontend generation,
    required PreparedSessionPresentation descriptor,
    required Session session,
    required bool Function() isActive,
  });

  Future<void> close();
}
