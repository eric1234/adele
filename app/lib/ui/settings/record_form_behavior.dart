part of 'record_collection_panel.dart';

/// One visible draft and exact frontend. The parent replaces this mount on
/// navigation or reload even when the *authored* creation draft is retained.
final class _BehaviorHost extends StatefulWidget {
  const _BehaviorHost({required super.key, required this.form});

  final _RecordForm form;

  @override
  State<_BehaviorHost> createState() => _BehaviorHostState();
}

final class _BehaviorHostState extends State<_BehaviorHost> {
  _RecordDraft get draft => widget.form.draft;
  ExtensionBinding<SettingsFormBehaviorContribution>? _binding;
  VoidCallback? _detach;
  StreamSubscription<ApplicationFrontendState>? _starting;
  final _contexts = <String, List<String>>{};
  Map<String, Object?> _previous = const {};
  Map<String, SettingsFieldPresentation> fields = const {};
  bool unavailable = false;
  bool _initialized = false;
  int _revision = 0;
  late (int?, int) _scope;
  ModalRoute<Object?>? _route;

  bool get _current =>
      mounted &&
      !draft.disposed &&
      (_route?.isActive ?? true) &&
      widget.form.formScope() == _scope;
  bool allows(RecordFieldDefinition<Object> field) =>
      _current && _initialized && (fields[field.id.value]?.enabled ?? true);
  bool offers(RecordFieldDefinition<Object> field, Object value) =>
      fields[field.id.value]?.choices?.contains(value) ?? true;

  @override
  void initState() {
    super.initState();
    _resolve();
    draft.addListener(_markdownChanged);
  }

  void _resolve() {
    final frontends = widget.form.frontends;
    _binding = frontends?.resolveSettingsFormBehavior(draft.definition);
    if (_binding case final binding?) {
      _detach = binding.onRetire(() {
        // Retire synchronously, including callbacks held before the next frame.
        _revision++;
        _binding = null;
        _contexts.clear();
        fields = const {};
        unavailable = true;
        scheduleMicrotask(() {
          if (mounted) setState(() {});
        });
      });
    } else if (frontends != null &&
        (frontends.state == ApplicationFrontendState.starting ||
            frontends.state == ApplicationFrontendState.unconfigured)) {
      _starting ??= frontends.changes.listen((_) {
        if (!mounted) return;
        _resolve();
        if (_binding != null && _current) setState(() => _evaluate(null));
      });
      return;
    }
    unawaited(_starting?.cancel());
  }

  void _markdownChanged() {
    // The native host also notifies for selection/composition and enablement,
    // including during layout. Only process a changed snapshot outside build.
    final revision = _revision;
    scheduleMicrotask(() {
      if (!_current ||
          revision != _revision ||
          !_initialized ||
          !widget.form.enabled) {
        return;
      }
      final values = draft.snapshot();
      for (final field in draft.markdown.keys) {
        if (_previous.containsKey(field.value) !=
                values.containsKey(field.value) ||
            _previous[field.value] != values[field.value]) {
          setState(() => _evaluate(field.value));
          return;
        }
      }
    });
  }

  void changed(RecordFieldDefinition<Object> field, List<String>? context) {
    if (!_current) return;
    final id = field.id.value;
    // Replace even on a same-value confirmation. A manual proposal, optional
    // removal or ordinary edit supplies no catalog-like evidence.
    if (context == null) {
      _contexts.remove(id);
    } else {
      _contexts[id] = context;
    }
    _evaluate(id);
  }

  void _evaluate(String? edited) {
    final binding = _binding;
    final revision = ++_revision;
    final values = draft.snapshot();
    final changed =
        edited != null &&
        (_previous.containsKey(edited) != values.containsKey(edited) ||
            !recordFieldValuesEqual(_previous[edited], values[edited]));
    _previous = values;
    _initialized = true;
    try {
      if (binding == null) throw StateError('Unavailable behavior');
      binding.validate();
      final result = binding.value.evaluate(
        values,
        Map.unmodifiable(_contexts),
        changed ? edited : null,
      );
      final declarations = {
        for (final field in draft.definition.fields) field.id.value: field,
      };
      // Validate the *entire* result before applying either part. Filtering
      // is presentation only; in particular it does not imply an unset.
      for (final entry in result.fields.entries) {
        final field = declarations[entry.key];
        if (field == null) throw const FormatException('Undeclared field');
        final choices = entry.value.choices;
        if (choices != null) {
          final type = field.type;
          if (type is! EnumSettingType ||
              choices.toSet().length != choices.length ||
              !choices.every(
                type.options.map((o) => o.value).toSet().contains,
              )) {
            throw const FormatException('Invalid enum choices');
          }
        }
      }
      final clear = declarations[result.clear];
      if (result.clear != null &&
          (!changed ||
              !widget.form.enabled ||
              clear == null ||
              clear.required ||
              clear.type is! EnumSettingType)) {
        throw const FormatException('Invalid draft clear');
      }
      binding.validate();
      if (!_current || revision != _revision) return;
      if (clear != null && values.containsKey(clear.id.value)) {
        draft.clear(clear);
        _contexts.remove(clear.id.value);
        _previous = Map.unmodifiable({...values}..remove(clear.id.value));
      }
      fields = result.fields;
      unavailable = false;
    } on Object {
      if (!_current || revision != _revision) return;
      fields = const {};
      unavailable = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    _scope = widget.form.formScope();
    _route = ModalRoute.of(context);
    if (!_initialized) {
      final scope = _scope;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_current && !_initialized && scope == _scope) {
          setState(() => _evaluate(null));
        }
      });
      return const Text('Preparing form...');
    }
    return widget.form._body(context, this);
  }

  @override
  void dispose() {
    _detach?.call();
    unawaited(_starting?.cancel());
    draft.removeListener(_markdownChanged);
    super.dispose();
  }
}
