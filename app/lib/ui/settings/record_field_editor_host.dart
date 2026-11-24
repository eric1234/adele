import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../frontend/application_frontend_bootstrap.dart';
import '../../frontend/prepared_frontend.dart';

/// One mount in one visible form. The form changes the key when its draft,
/// navigation scope, field presence or editing authority changes.
final class RecordFieldEditorHost extends StatefulWidget {
  const RecordFieldEditorHost({
    required super.key,
    required this.frontends,
    required this.definition,
    required this.extensionId,
    required this.field,
    required this.isCurrent,
    required this.canEdit,
    required this.readValue,
    required this.acceptValue,
    required this.permitsValue,
  });

  final ApplicationFrontendBootstrap? frontends;
  final RecordTypeDefinition definition;
  final ExtensionId extensionId;
  final RecordFieldDefinition<Object> field;
  final bool Function() isCurrent;
  final bool canEdit;
  final Object? Function() readValue;
  final void Function(Object value, List<String>? context) acceptValue;
  final bool Function(Object value) permitsValue;

  @override
  State<RecordFieldEditorHost> createState() => _RecordFieldEditorHostState();
}

final class _RecordFieldEditorHostState extends State<RecordFieldEditorHost>
    implements SettingsFieldDraft {
  Widget? _presentation;
  StreamSubscription<ApplicationFrontendState>? _starting;
  VoidCallback? _detach;
  bool _retired = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    final frontends = widget.frontends;
    if (frontends == null) return;
    _resolve(frontends);
    // Settings declarations can be available before the frontend has started.
    if (_presentation == null && _activationPending) {
      _starting = frontends.changes.listen((_) {
        if (!mounted || _retired) return;
        setState(() => _resolve(frontends));
      });
    }
  }

  void _resolve(ApplicationFrontendBootstrap frontends) {
    final binding = frontends.resolveSettingsFieldEditor(
      widget.definition,
      widget.field,
    );
    if (binding == null) {
      if (!_activationPending) unawaited(_starting?.cancel());
      return;
    }
    // Never rediscover by ID after this registration has been captured.
    unawaited(_starting?.cancel());
    _detach = binding.onRetire(() {
      _retired = true;
      scheduleMicrotask(() {
        if (mounted) setState(() {});
      });
    });
    _presentation = binding.value.createPresentation(this);
  }

  bool get _activationPending => switch (widget.frontends?.state) {
    ApplicationFrontendState.starting ||
    ApplicationFrontendState.unconfigured => true,
    _ => false,
  };

  bool get _current => mounted && !_retired && widget.isCurrent();

  @override
  bool get enabled => _current && widget.canEdit;

  @override
  Object? get value => _current ? widget.readValue() : null;

  @override
  int get revision => _revision;

  @override
  String? get error => _current ? widget.field.valueError(value) : null;

  @override
  String? propose(
    int expectedRevision,
    Object? value, {
    List<String>? context,
  }) {
    if (!enabled || expectedRevision != _revision) {
      return 'This field edit is no longer available.';
    }
    // Creating or rendering a presentation is not an edit. In particular the
    // plugin cannot dirty a draft or invalidate ancestor widgets during build.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      return 'Cannot change the field while building its editor.';
    }
    final violation = widget.field.valueError(value);
    if (violation != null) return violation;
    if (context != null &&
        (context.length > SettingsFieldDraft.maxContextItems ||
            context.any(
              (s) => s.length > SettingsFieldDraft.maxContextItemLength,
            ))) {
      return 'Invalid field context.';
    }
    final snapshot = widget.field.snapshotValue(value);
    if (!widget.permitsValue(snapshot)) {
      return 'This field choice is unavailable.';
    }
    _revision++;
    widget.acceptValue(
      snapshot,
      context == null ? null : List.unmodifiable(context),
    );
    return null;
  }

  @override
  void dispose() {
    _retired = true;
    _detach?.call();
    unawaited(_starting?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unavailable = Text('Field editor unavailable: ${widget.extensionId}');
    final presentation = _presentation;
    if (presentation == null && _activationPending) {
      return const Text('Waiting for the field editor...');
    }
    if (_retired || presentation == null) return unavailable;
    return PreparedFrontendFallback(fallback: unavailable, child: presentation);
  }
}
