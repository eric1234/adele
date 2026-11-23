import 'package:flutter/widgets.dart';

/// Shows one modal owned by the mounted interpreted presentation, with [child]
/// as its content. Completes when dismissed, including by the barrier, Escape,
/// or the host retiring the presentation. Does not replace an existing dialog.
Future<void> showPresentationDialog(BuildContext context, Widget child) =>
    throw UnsupportedError('Interpreted host only.');

/// Tests the exact dialog containing [context], not a later dialog opened by
/// the same presentation. False immediately after pop, before widget disposal.
bool isPresentationDialogCurrent(BuildContext context) =>
    throw UnsupportedError('Interpreted host only.');

/// Dismisses only this presentation's current dialog containing [context].
void dismissPresentationDialog(BuildContext context) =>
    throw UnsupportedError('Interpreted host only.');
