import 'package:adele_ui/inspection_display.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/session_accessory_bridge.dart';
import 'package:flutter/material.dart';
import 'package:model_configuration_contract/model_configuration_contract.dart';

Widget buildModelPresetSelector() => _ModelPresetSelector(
  readSessionAccessorySessionId(),
  ModelPresetSelectionServiceClient(
    OwningBackendRequestChannel(modelPresetSelectionServiceId),
  ),
  ModelPresetCatalogServiceClient(
    OwningBackendRequestChannel(modelPresetCatalogServiceId),
  ),
);

class _ModelPresetSelector extends StatefulWidget {
  _ModelPresetSelector(this.sessionId, this.selections, this.catalog);

  final String sessionId;
  final ModelPresetSelectionServiceClient selections;
  final ModelPresetCatalogServiceClient catalog;

  @override
  State<_ModelPresetSelector> createState() => _ModelPresetSelectorState();
}

const _noPreset = 'No Model Preset';

class _ModelPresetSelectorState extends State<_ModelPresetSelector> {
  // The evaluator needs explicit initializers to box nullable fields.
  // ignore: avoid_init_to_null
  ModelPresetSelectionSnapshot? selection = null;
  // ignore: avoid_init_to_null
  bool? catalogComplete = null;
  List<String> ids = <String>[];
  Map<String, String> labels = <String, String>{};
  Map<String, ModelPresetDefinition> presets =
      <String, ModelPresetDefinition>{};
  bool reading = false;
  bool saving = false;
  bool expanded = false;
  bool unconfirmed = false;
  bool disposed = false;

  @override
  void initState() {
    super.initState();
    refresh(true);
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  Future<void> refresh(bool readSelection) async {
    if (disposed || reading || saving) return;
    setState(() {
      reading = true;
    });
    if (readSelection) {
      final ModelPresetSelectionServiceClient client = widget.selections;
      final result = await settleOwningBackendOperation(
        client.readSessionSelection(widget.sessionId),
      );
      if (disposed) return;
      selection = null;
      if (result[0] == true) {
        final next = result[1] as ModelPresetSelectionSnapshot;
        if (next.sessionId == widget.sessionId &&
            next.revision >= 0 &&
            (next.revision != 0 || next.selectedPresetId == null)) {
          selection = next;
          unconfirmed = false;
        }
      }
    }
    final ModelPresetCatalogServiceClient client = widget.catalog;
    final result = await settleOwningBackendOperation(client.readPresets());
    if (disposed) return;
    if (result[0] == true) {
      showCatalog(result[1] as ModelPresetCatalogSnapshot);
    } else {
      catalogComplete = null;
      ids = <String>[];
      labels = <String, String>{};
      presets = <String, ModelPresetDefinition>{};
    }
    setState(() {
      reading = false;
    });
  }

  void showCatalog(ModelPresetCatalogSnapshot snapshot) {
    final nextIds = <String>[];
    final names = <String, String>{};
    final definitions = <String, ModelPresetDefinition>{};
    final counts = <String, int>{};
    final qualifiedLabels = <String, bool>{};
    for (final preset in snapshot.presets) {
      final id = preset.presetId;
      final name = preset.name.trim();
      final label = name.isEmpty
          ? id
          : compactDisplayText(name, maximumCharacters: 40);
      nextIds.add(id);
      definitions[id] = preset;
      names[id] = label;
      counts[label] = (counts[label] ?? 0) + 1;
      qualifiedLabels['$label ($id)'] = true;
    }
    for (final id in nextIds) {
      final label = names[id]!;
      // An authored name can itself look like another choice's qualified label.
      if (label == _noPreset ||
          counts[label]! > 1 ||
          qualifiedLabels.containsKey(label)) {
        names[id] = '$label ($id)';
      }
    }
    labels = names;
    presets = definitions;
    // Keep the evaluator's native sort callback independent of loop locals.
    nextIds.sort((String a, String b) => compareLabels(a, b));
    ids = nextIds;
    catalogComplete = snapshot.isComplete;
  }

  int compareLabels(String a, String b) {
    final order = labels[a]!.compareTo(labels[b]!);
    return order == 0 ? a.compareTo(b) : order;
  }

  void toggleChoices() {
    if (disposed || reading || saving || unconfirmed || selection == null) {
      return;
    }
    setState(() {
      expanded = !expanded;
    });
    if (expanded) refresh(false);
  }

  Future<void> choose(String? id, int offeredRevision) async {
    final current = selection;
    if (disposed ||
        reading ||
        saving ||
        !expanded ||
        unconfirmed ||
        current == null) {
      return;
    }
    // Old buttons may survive a frame. They cannot borrow a newer baseline.
    if (current.revision != offeredRevision) return;
    if (id != null && !presets.containsKey(id)) return;
    setState(() {
      saving = true;
      expanded = false;
    });
    final ModelPresetSelectionServiceClient client = widget.selections;
    final result = await settleOwningBackendOperation(
      client.updateSessionSelection(widget.sessionId, id, offeredRevision),
    );
    if (disposed) return;
    // Failure could be a conflict or a lost reply after commit. Only a fresh
    // selection read can re-enable choices; never replay the requested ID.
    unconfirmed = true;
    if (result[0] == true) {
      final next = result[1] as ModelPresetSelectionSnapshot;
      if (next.sessionId == widget.sessionId &&
          next.selectedPresetId == id &&
          next.revision == offeredRevision + 1) {
        selection = next;
        unconfirmed = false;
      }
    }
    setState(() {
      saving = false;
    });
  }

  String selectedLabel(ModelPresetSelectionSnapshot current) {
    final id = current.selectedPresetId;
    if (id == null) return _noPreset;
    final label = labels[id];
    if (label != null) return label;
    return catalogComplete == true
        ? 'Missing Model Preset: $id'
        : 'Unresolved Model Preset: $id';
  }

  Widget choice(String? id, String label, int revision) =>
      TextButton(onPressed: () => choose(id, revision), child: Text(label));

  Widget choices(
    List<String> offeredIds,
    Map<String, String> offeredLabels,
    int revision,
  ) => Container(
    constraints: BoxConstraints(maxHeight: 192),
    child: ListView.builder(
      primary: false,
      shrinkWrap: true,
      itemCount: offeredIds.length + 1,
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) return choice(null, _noPreset, revision);
        final id = offeredIds[index - 1];
        return choice(id, offeredLabels[id]!, revision);
      },
    ),
  );

  void addDetails(List<Widget> widgets, String? id) {
    if (id == null) return;
    final preset = presets[id];
    if (preset == null) return;
    final provider = compactDisplayText(
      preset.providerId,
      maximumCharacters: 40,
    );
    final model = compactDisplayText(preset.modelId, maximumCharacters: 40);
    final effort = preset.reasoningEffort ?? 'unspecified';
    widgets.add(Text('Configured provider: $provider'));
    widgets.add(Text('Configured model: $model'));
    widgets.add(Text('Requested effort: $effort'));
  }

  @override
  Widget build(BuildContext context) {
    final current = selection;
    final widgets = <Widget>[];
    final header = <Widget>[];
    if (current != null) {
      final title = Text('Model Preset: ${selectedLabel(current)}');
      header.add(
        Expanded(
          // The pinned eval bridge does not supply Flutter's default flex.
          flex: 1,
          child: reading || saving || unconfirmed
              ? title
              : TextButton(onPressed: () => toggleChoices(), child: title),
        ),
      );
    }
    if (!reading && !saving) {
      header.add(
        TextButton(onPressed: () => refresh(true), child: Text('Refresh')),
      );
    }
    if (header.isNotEmpty) widgets.add(Row(children: header));
    if (reading) {
      widgets.add(Text('Loading Model Presets...'));
    } else {
      if (saving) widgets.add(Text('Saving selection...'));
      if (current == null) {
        widgets.add(Text('Model Preset selection is unavailable.'));
      } else {
        addDetails(widgets, current.selectedPresetId);
      }
      if (catalogComplete == null) {
        widgets.add(Text('Model Preset catalog is unavailable.'));
      } else if (catalogComplete == false) {
        widgets.add(Text('Model Preset catalog is incomplete.'));
      } else if (ids.isEmpty) {
        widgets.add(
          Text(
            'No Model Presets configured. Create Model Presets in Global Settings.',
          ),
        );
      }
      if (unconfirmed) {
        widgets.add(
          Text('Change not confirmed. Refresh to check the current selection.'),
        );
      }
      if (expanded && !saving && !unconfirmed && current != null) {
        widgets.add(choices(ids, labels, current.revision));
      }
    }
    widgets.add(Text('Model Preset changes apply to newly prepared Runs.'));
    return SizedBox(
      width: 300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: widgets,
      ),
    );
  }
}
