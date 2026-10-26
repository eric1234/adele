import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/global_settings_service.dart';
import 'record_collection_panel.dart';
import 'scalar_settings_panel.dart';

/// Application-owned presentation; the shared host service owns all disk work.
final class GlobalSettingsDialog extends StatefulWidget {
  const GlobalSettingsDialog({
    super.key,
    required this.service,
    this.declarationIssues,
    this.recordDeclarationIssues,
  });

  final Future<GlobalSettingsService> Function() service;
  final List<String> Function()? declarationIssues;
  final List<String> Function()? recordDeclarationIssues;

  @override
  State<GlobalSettingsDialog> createState() => _GlobalSettingsDialogState();
}

final class _GlobalSettingsDialogState extends State<GlobalSettingsDialog> {
  static const _recordDiagnostics = '@record-diagnostics';
  GlobalSettingsService? _service;
  String _section = '';
  final _panels = <String, Widget>{};

  @override
  void initState() {
    super.initState();
    // Navigation reuses these children, including their controls and drafts.
    _panels[''] = ScalarSettingsPanel(
      service: _resolveService,
      declarationIssues: widget.declarationIssues,
    );
  }

  Future<GlobalSettingsService> _resolveService() async {
    try {
      return _service ??= await widget.service();
    } finally {
      // Navigation and declaration diagnostics do not depend on the scalar load.
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.of(context).pop(),
    },
    child: Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Global Settings',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close Settings',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: DropdownButtonFormField<String>(
                key: const ValueKey('settings-section'),
                initialValue: _section,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Settings section',
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Preferences')),
                  for (final collection
                      in _service?.records.collections ??
                          <RecordCollectionId>[])
                    DropdownMenuItem(
                      value: collection.value,
                      child: Text(
                        _service!.records.collectionLabel(collection),
                      ),
                    ),
                  if (widget.recordDeclarationIssues?.call().isNotEmpty ??
                      false)
                    const DropdownMenuItem(
                      value: _recordDiagnostics,
                      child: Text('Record diagnostics'),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _section = value;
                    _panels.putIfAbsent(
                      value,
                      () => value == _recordDiagnostics
                          ? _RecordDeclarationIssues(
                              issues: widget.recordDeclarationIssues!,
                            )
                          : RecordCollectionPanel(
                              service: _service!,
                              collection: RecordCollectionId(value),
                              declarationIssues: widget.recordDeclarationIssues,
                            ),
                    );
                  });
                },
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  for (final entry in _panels.entries)
                    Offstage(
                      key: ValueKey(entry.key),
                      offstage: entry.key != _section,
                      child: ExcludeFocus(
                        excluding: entry.key != _section,
                        child: entry.value,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

final class _RecordDeclarationIssues extends StatelessWidget {
  const _RecordDeclarationIssues({required this.issues});

  final List<String> Function() issues;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final issue in issues())
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Semantics(
              liveRegion: true,
              child: Text(
                'Record declarations unavailable: $issue\n'
                'Correct the installation and restart ADELE.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
      ],
    ),
  );
}
