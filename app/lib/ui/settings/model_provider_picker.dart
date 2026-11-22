import 'package:flutter/material.dart';

import '../../core/model_provider_choices.dart';

/// Suggests an exact string for the adjacent field; never owns its value.
final class ModelProviderPicker extends StatefulWidget {
  const ModelProviderPicker({
    super.key,
    required this.discover,
    required this.currentId,
    required this.canEdit,
    required this.onSelected,
  });

  final DiscoverModelProviders? discover;
  final String currentId;
  final bool Function() canEdit;
  final ValueChanged<String> onSelected;

  @override
  State<ModelProviderPicker> createState() => _ModelProviderPickerState();
}

final class _ModelProviderPickerState extends State<ModelProviderPicker> {
  late List<ModelProviderChoice>? _choices = _observe();
  bool _open = false;

  List<ModelProviderChoice>? _observe() {
    try {
      return widget.discover?.call();
    } on Object {
      // A failed observation is not an empty registry. Keep diagnostics private.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = widget.canEdit;
    VoidCallback? guarded(VoidCallback action) => !canEdit()
        ? null
        : () {
            if (mounted && canEdit()) action();
          };
    final choices = _choices;
    final match = choices?.where((p) => p.id == widget.currentId).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          children: [
            TextButton(
              onPressed: guarded(
                () => setState(() {
                  _open = !_open;
                  if (_open) _choices = _observe();
                }),
              ),
              child: Text(
                _open ? 'Hide choices' : 'Choose configured provider...',
              ),
            ),
            if (_open)
              TextButton.icon(
                onPressed: guarded(() => setState(() => _choices = _observe())),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh providers'),
              ),
          ],
        ),
        if (choices == null)
          const Text('Provider discovery is temporarily unavailable.')
        else ...[
          if (choices.isEmpty)
            const Text('No configured providers are currently available.'),
          if (match != null)
            Text('Configured provider: ${match.displayName}')
          else if (widget.currentId.isNotEmpty)
            const Text(
              'This ID is not currently available for guided selection.',
            ),
          if (_open && choices.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.builder(
                primary: false,
                shrinkWrap: true,
                itemCount: choices.length,
                itemBuilder: (context, index) {
                  final choice = choices[index];
                  return ListTile(
                    key: ValueKey('provider-choice-${choice.id}'),
                    title: Text(choice.displayName),
                    subtitle: Text('${choice.id}\nPlugin: ${choice.pluginId}'),
                    selected: choice.id == widget.currentId,
                    enabled: canEdit(),
                    onTap: guarded(() {
                      setState(() => _open = false);
                      widget.onSelected(choice.id);
                    }),
                  );
                },
              ),
            ),
        ],
      ],
    );
  }
}
