import 'package:adele_ui/inspection_display.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/session_accessory_bridge.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';
import 'package:flutter/material.dart';

Widget buildAgentSelector() => _AgentSelector(
  readSessionAccessorySessionId(),
  AgentSelectionServiceClient(
    OwningBackendRequestChannel(agentSelectionServiceId),
  ),
  AgentCatalogServiceClient(OwningBackendRequestChannel(agentCatalogServiceId)),
);

class _AgentSelector extends StatefulWidget {
  _AgentSelector(this.sessionId, this.selections, this.catalog);

  final String sessionId;
  final AgentSelectionServiceClient selections;
  final AgentCatalogServiceClient catalog;

  @override
  State<_AgentSelector> createState() => _AgentSelectorState();
}

class _AgentSelectorState extends State<_AgentSelector> {
  // The evaluator needs explicit initializers to box nullable fields.
  // ignore: avoid_init_to_null
  AgentSelectionSnapshot? selection = null;
  // ignore: avoid_init_to_null
  bool? catalogComplete = null;
  List<String> ids = <String>[];
  Map<String, String> labels = <String, String>{};
  bool reading = false;
  bool saving = false;
  bool expanded = false;
  bool needsReconciliation = false;
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
      final AgentSelectionServiceClient client = widget.selections;
      final result = await settleOwningBackendOperation(
        client.readSessionSelection(widget.sessionId),
      );
      if (disposed) return;
      selection = null;
      if (result[0] == true) {
        final next = result[1] as AgentSelectionSnapshot;
        if (next.sessionId == widget.sessionId &&
            next.revision >= 0 &&
            (next.revision > 0 || next.selectedAgentId == null)) {
          selection = next;
          needsReconciliation = false;
        }
      }
    }
    final AgentCatalogServiceClient client = widget.catalog;
    final result = await settleOwningBackendOperation(client.readAgents());
    if (disposed) return;
    if (result[0] == true) {
      showCatalog(result[1] as AgentCatalogSnapshot);
    } else {
      catalogComplete = null;
      ids = <String>[];
      labels = <String, String>{};
    }
    setState(() {
      reading = false;
    });
  }

  void showCatalog(AgentCatalogSnapshot snapshot) {
    final nextIds = <String>[];
    final names = <String, String>{};
    final counts = <String, int>{};
    for (final agent in snapshot.agents) {
      final name = agent.name.trim();
      // Text.maxLines/overflow are not exposed by the pinned Flutter bridge.
      final label = name.isEmpty
          ? agent.id
          : compactDisplayText(name, maximumCharacters: 40);
      nextIds.add(agent.id);
      names[agent.id] = label;
      counts[label] = (counts[label] ?? 0) + 1;
    }
    for (final id in nextIds) {
      final name = names[id]!;
      if (counts[name]! > 1 || name == 'No Agent') names[id] = '$name ($id)';
    }
    labels = names;
    nextIds.sort((String a, String b) => compareNames(a, b));
    ids = nextIds;
    catalogComplete = snapshot.isComplete;
  }

  // Keep the native sort callback independent of the evaluator's loop locals.
  int compareNames(String a, String b) {
    final order = labels[a]!.compareTo(labels[b]!);
    return order == 0 ? a.compareTo(b) : order;
  }

  void toggleChoices() {
    if (disposed ||
        reading ||
        saving ||
        needsReconciliation ||
        selection == null) {
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
        needsReconciliation ||
        current == null) {
      return;
    }
    // A callback from the previous frame cannot borrow a newer baseline.
    if (current.revision != offeredRevision) return;
    if (id != null && !labels.containsKey(id)) return;
    setState(() {
      saving = true;
      expanded = false;
    });
    final AgentSelectionServiceClient client = widget.selections;
    final result = await settleOwningBackendOperation(
      client.updateSessionSelection(widget.sessionId, id, offeredRevision),
    );
    if (disposed) return;
    // The eval settlement bridge intentionally withholds native failure codes.
    // A conflict and a lost acknowledgement both require an authoritative read;
    // neither permits replay. No requested ID is retained for a later attempt.
    needsReconciliation = true;
    if (result[0] == true) {
      final next = result[1] as AgentSelectionSnapshot;
      if (next.sessionId == widget.sessionId &&
          next.selectedAgentId == id &&
          next.revision > current.revision) {
        selection = next;
        needsReconciliation = false;
      }
    }
    setState(() {
      saving = false;
    });
  }

  String selectedLabel(AgentSelectionSnapshot current) {
    final id = current.selectedAgentId;
    if (id == null) return 'No Agent';
    final name = labels[id];
    if (name != null) return name;
    return catalogComplete == true
        ? 'Missing Agent: $id'
        : 'Unresolved Agent: $id';
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
        if (index == 0) return choice(null, 'No Agent', revision);
        final id = offeredIds[index - 1];
        return choice(id, offeredLabels[id]!, revision);
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final current = selection;
    final widgets = <Widget>[];
    final header = <Widget>[];
    if (current != null) {
      final title = Text('Agent: ${selectedLabel(current)}');
      header.add(
        Expanded(
          flex: 3,
          child: reading || saving || needsReconciliation
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
      widgets.add(Text('Loading Agents...'));
    } else {
      if (saving) widgets.add(Text('Saving selection...'));
      if (current == null) widgets.add(Text('Agent selection is unavailable.'));
      if (catalogComplete == null) {
        widgets.add(Text('Agent catalog is unavailable.'));
      } else if (catalogComplete == false) {
        widgets.add(Text('Agent catalog is incomplete.'));
      } else if (ids.isEmpty) {
        widgets.add(
          Text('No Agents configured. Create Agents in Global Settings.'),
        );
      }
      if (needsReconciliation) {
        widgets.add(
          Text('Change not confirmed. Refresh to check the current selection.'),
        );
      }
      if (expanded && !saving && !needsReconciliation && current != null) {
        widgets.add(choices(ids, labels, current.revision));
      }
    }
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
