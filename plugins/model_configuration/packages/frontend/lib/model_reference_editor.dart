import 'package:adele_ui/inspection_display.dart';
import 'package:adele_ui/presentation_dialog.dart';
import 'package:adele_ui/settings_field_editor_bridge.dart';
import 'package:flutter/material.dart';

import 'model_browser.dart';

Widget buildModelReferenceEditor() => _ModelReferenceEditor();

class _ModelReferenceEditor extends StatefulWidget {
  @override
  State<_ModelReferenceEditor> createState() => _ModelReferenceEditorState();
}

class _ModelReferenceEditorState extends State<_ModelReferenceEditor> {
  bool disposed = false;
  bool browsing = false;
  bool showIds = false;
  String knownProvider = '';
  String knownId = '';
  String knownName = '';

  Future<void> browse(
    BuildContext context,
    int revision,
    String provider,
    String model,
  ) async {
    if (disposed ||
        browsing ||
        !settingsFieldEditingEnabled() ||
        revision != readSettingsFieldRevision()) {
      return;
    }
    browsing = true;
    final selection = BrowserSelection(revision, provider, model);
    await showPresentationDialog(context, ModelBrowser(selection));
    if (disposed) return;
    browsing = false;
    if (selection.confirmed) {
      showIds = false;
      knownProvider = selection.provider;
      knownId = selection.model;
      knownName = selection.name;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final revision = readSettingsFieldRevision();
    final value = readSettingsFieldValue();
    final provider = value == null
        ? ''
        : (value as Map)['provider-id'] as String;
    final model = value == null ? '' : (value as Map)['model-id'] as String;
    final widgets = <Widget>[];
    if (value == null) {
      widgets.add(Text('No model selected.'));
    } else {
      final name = provider == knownProvider && model == knownId
          ? knownName
          : '';
      widgets.add(
        Text(
          inspectionDisplayText(name.isEmpty ? model : name),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      );
      widgets.add(Text(providerSummary(provider)));
      if (name.isEmpty) widgets.add(Text('Model not verified.'));
    }
    final actions = <Widget>[];
    if (settingsFieldEditingEnabled()) {
      actions.add(
        TextButton(
          onPressed: () => browse(context, revision, provider, model),
          child: Text('Browse models...'),
        ),
      );
    }
    if (value != null) {
      actions.add(
        TextButton(
          onPressed: () => setState(() {
            showIds = !showIds;
          }),
          child: Text(showIds ? 'Hide IDs' : 'Show IDs'),
        ),
      );
    }
    widgets.add(Row(children: actions));
    if (value != null && showIds) {
      widgets.add(Text('Model ID: ${inspectionDisplayText(model)}'));
      widgets.add(Text('Provider ID: ${inspectionDisplayText(provider)}'));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  String providerSummary(String id) {
    final metadata = observeModelProviders(false);
    if (metadata != null) {
      for (final entry in metadata) {
        if (entry['providerId'] == id) {
          final display = entry['displayName'] as String;
          if (display.trim().isEmpty) {
            return 'Configured provider: ${inspectionDisplayText(id)}';
          }
          final name = inspectionDisplayText(display);
          for (final peer in metadata) {
            if (peer['providerId'] != id && peer['displayName'] == display) {
              return 'Configured provider: $name (${inspectionDisplayText(id)})';
            }
          }
          return 'Configured provider: $name';
        }
      }
    }
    return 'Unverified provider: ${inspectionDisplayText(id)}';
  }
}
