import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/model_catalog_choices.dart';

/// Offers suggestions for one draft field. The form retains the editable ID.
final class ModelCatalogPicker extends StatefulWidget {
  const ModelCatalogPicker({
    super.key,
    required this.discover,
    required this.provider,
    required this.currentId,
    required this.isCurrent,
    required this.onSelected,
  });

  final DiscoverModels? discover;
  final TextEditingController? provider;
  final String currentId;
  final bool Function() isCurrent;
  final ValueChanged<String> onSelected;

  @override
  State<ModelCatalogPicker> createState() => _ModelCatalogPickerState();
}

final class _ModelCatalogPickerState extends State<ModelCatalogPicker> {
  String? _providerId;
  int _revision = 0;
  bool _open = false;
  ModelDiscoveryResult? _result;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _providerId = widget.provider?.text;
    widget.provider?.addListener(_providerChanged);
  }

  @override
  void didUpdateWidget(ModelCatalogPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider ||
        oldWidget.discover != widget.discover) {
      oldWidget.provider?.removeListener(_providerChanged);
      widget.provider?.addListener(_providerChanged);
      _providerId = widget.provider?.text;
      _reset();
    }
  }

  void _providerChanged() {
    // Selection and IME notifications with unchanged text aren't route changes.
    final current = widget.provider?.text;
    if (current == _providerId) return;
    setState(() {
      _providerId = current;
      _reset();
    });
  }

  void _reset() {
    _revision++;
    _open = false;
    _result = null;
    unawaited(_changes?.cancel());
    _changes = null;
  }

  bool _current(int revision) =>
      mounted && revision == _revision && widget.isCurrent();

  @override
  void dispose() {
    widget.provider?.removeListener(_providerChanged);
    _reset();
    super.dispose();
  }

  Future<void> _query(int buttonRevision, String providerId) async {
    if (!_current(buttonRevision)) return;
    setState(() {
      _reset();
      _open = true;
    });
    final request = _revision;
    ModelDiscoveryResult result;
    try {
      result =
          await widget.discover?.call(providerId) ??
          const ModelDiscoveryResult.unavailable();
    } on Object {
      result = const ModelDiscoveryResult.failed();
    }
    if (!_current(request)) return;
    if (result.status == ModelDiscoveryStatus.success) {
      // Registry notifications can arrive after a tap. The predicate checks
      // the captured registrations synchronously at both delivery and use.
      if (!result.isCurrent!()) {
        result = const ModelDiscoveryResult.unavailable();
      } else {
        _changes = result.changes?.listen((_) {
          if (_current(request) && !result.isCurrent!()) _retired();
        });
      }
    }
    setState(() => _result = result);
  }

  void _retired() {
    setState(() {
      _reset();
      _open = true;
      _result = const ModelDiscoveryResult.unavailable();
    });
  }

  @override
  Widget build(BuildContext context) {
    final revision = _revision;
    final providerId = _providerId;
    final result = _result;
    final choices = result?.snapshot?.models;
    final canQuery = providerId != null && providerId.isNotEmpty;
    final message = switch (result?.status) {
      null when _open => 'Loading models...',
      null when !canQuery => 'Enter a provider ID to choose a model.',
      ModelDiscoveryStatus.unavailable =>
        'Model discovery is unavailable for this provider.',
      ModelDiscoveryStatus.unsupported =>
        'This provider does not support model discovery.',
      ModelDiscoveryStatus.ambiguous =>
        'More than one model catalog is associated with this provider.',
      ModelDiscoveryStatus.failed =>
        'Could not load models. Refresh to try again or enter a model ID manually.',
      ModelDiscoveryStatus.success when choices!.isEmpty =>
        'This provider reported no models.',
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          children: [
            TextButton(
              onPressed: !canQuery
                  ? null
                  : _open
                  ? () {
                      if (_current(revision)) setState(_reset);
                    }
                  : () => _query(revision, providerId),
              child: Text(_open ? 'Hide models' : 'Choose model...'),
            ),
            if (_open && canQuery)
              TextButton.icon(
                onPressed: () => _query(revision, providerId),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh models'),
              ),
          ],
        ),
        if (message != null) Semantics(liveRegion: true, child: Text(message)),
        if (choices != null && choices.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: ListView.builder(
              primary: false,
              shrinkWrap: true,
              itemCount: choices.length,
              itemBuilder: (context, index) {
                final choice = choices[index];
                // IDs can differ only at the very end. Keep the full spelling
                // available without letting untrusted metadata size the row.
                final id = Tooltip(
                  message: choice.modelId,
                  excludeFromSemantics: true,
                  child: Text(
                    choice.modelId,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
                return ListTile(
                  key: ValueKey('model-choice-${choice.modelId}'),
                  title: choice.displayName == null
                      ? id
                      : Text(
                          choice.displayName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  minVerticalPadding: 8,
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (choice.displayName != null) id,
                      if (choice.description case final description?)
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                  selected: widget.currentId == choice.modelId,
                  onTap: () {
                    if (!_current(revision)) return;
                    if (!result!.isCurrent!()) {
                      _retired();
                      return;
                    }
                    setState(_reset);
                    widget.onSelected(choice.modelId);
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}
