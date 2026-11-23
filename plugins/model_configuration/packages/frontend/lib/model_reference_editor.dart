import 'package:adele_ui/settings_field_editor_bridge.dart';
import 'package:flutter/material.dart';

Widget buildModelReferenceEditor() => _ModelReferenceEditor();

class _ModelReferenceEditor extends StatefulWidget {
  @override
  State<_ModelReferenceEditor> createState() {
    final value = readSettingsFieldValue();
    return _ModelReferenceEditorState(
      value == null ? '' : (value as Map)['provider-id'] as String,
      value == null ? '' : (value as Map)['model-id'] as String,
    );
  }
}

class _ModelReferenceEditorState extends State<_ModelReferenceEditor> {
  _ModelReferenceEditorState(String providerId, String modelId)
    : provider = TextEditingController(text: providerId),
      model = TextEditingController(text: modelId);

  final TextEditingController provider;
  final TextEditingController model;
  String rejection = '';
  bool disposed = false;

  void propose(int revision, String providerId, String modelId) {
    if (disposed || !settingsFieldEditingEnabled()) return;
    // Partial input is presentation-local, never a default for the other ID.
    if (providerId.trim().isEmpty || modelId.trim().isEmpty) {
      rejection = 'Enter both IDs to set the model reference.';
    } else {
      rejection =
          proposeSettingsFieldValue(revision, <String, Object>{
            'provider-id': providerId,
            'model-id': modelId,
          }) ??
          '';
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final revision = readSettingsFieldRevision();
    final enabled = settingsFieldEditingEnabled();
    final accepted = readSettingsFieldValue();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Provider ID'),
        TextField(
          controller: provider,
          enabled: enabled,
          onChanged: (String value) => propose(revision, value, model.text),
        ),
        Text('Model ID'),
        TextField(
          controller: model,
          enabled: enabled,
          onChanged: (String value) => propose(revision, provider.text, value),
        ),
        if (rejection.isNotEmpty) Text(rejection),
        if (rejection.isNotEmpty && accepted != null)
          Text(
            'The form still uses provider ${(accepted as Map)['provider-id']}, model ${accepted['model-id']}.',
          ),
      ],
    );
  }

  @override
  void dispose() {
    disposed = true;
    provider.dispose();
    model.dispose();
    super.dispose();
  }
}
