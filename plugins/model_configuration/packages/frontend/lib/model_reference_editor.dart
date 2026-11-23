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
      widgets.add(Text(inspectionDisplayText(name.isEmpty ? model : name)));
      if (name.isNotEmpty && name != model) {
        widgets.add(Text('Model ID: ${inspectionDisplayText(model)}'));
      }
      widgets.add(Text('Configured provider: ${providerLabel(provider)}'));
    }
    if (settingsFieldEditingEnabled()) {
      widgets.add(
        TextButton(
          onPressed: () => browse(context, revision, provider, model),
          child: Text('Browse models...'),
        ),
      );
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

  String providerLabel(String id) {
    final label = inspectionDisplayText(id);
    final metadata = observeModelProviders(false);
    if (metadata != null) {
      for (final entry in metadata) {
        if (entry['providerId'] == id) {
          final display = entry['displayName'] as String;
          if (display.isNotEmpty && display != id) {
            return '${inspectionDisplayText(display)} ($label)';
          }
        }
      }
    }
    return label;
  }
}
