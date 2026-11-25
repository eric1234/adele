import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_ui/capability_bridge.dart';
import 'package:adele_ui/inspection_display.dart';
import 'package:adele_ui/presentation_dialog.dart';
import 'package:adele_ui/settings_field_editor_bridge.dart';
import 'package:flutter/material.dart';

List<Map<String, dynamic>>? observeModelProviders(bool capture) =>
    observeAssociatedProviders(
      'dev.adele.model.provider',
      1,
      'modelProvider',
      'dev.adele.model.catalog',
      1,
      modelCatalogServiceId,
      capture,
    );

class BrowserSelection {
  BrowserSelection(this.revision, this.provider, this.model);

  final int revision;
  String provider;
  String model;
  String name = '';
  bool confirmed = false;
}

class ModelBrowser extends StatefulWidget {
  ModelBrowser(this.selection);
  final BrowserSelection selection;

  @override
  State<ModelBrowser> createState() => _BrowserState(selection);
}

class _Offer {
  _Offer(this.id, this.display, this.label, this.handle, this.status);
  final String id;
  final String display;
  String label;
  String handle;
  String status;

  void release() {
    if (handle.isEmpty) return;
    releaseCapabilityProvider(handle);
    handle = '';
  }
}

class _Model {
  _Model(this.offer, this.id, this.name, this.efforts);
  final _Offer offer;
  final String id;
  final String name;
  final List<String>? efforts;
}

const _stale = 'Catalog changed; refresh to browse again.';
const _maxProviders = 64;
const _maxRows = 2048;
const _maxText = modelCatalogMaxTextLength;
const _workers = 4;

bool _validOptionalText(String? value) {
  if (value == null) return true;
  if (value.trim().isEmpty) return false;
  return !value.codeUnits.contains(0);
}

class _BrowserState extends State<ModelBrowser> {
  _BrowserState(this.selection)
    : providerInput = TextEditingController(text: selection.provider),
      modelInput = TextEditingController(text: selection.model);

  final BrowserSelection selection;
  final TextEditingController providerInput;
  final TextEditingController modelInput;
  final TextEditingController search = TextEditingController();
  late BuildContext dialogContext;
  // ignore: avoid_init_to_null
  _Model? selected = null;
  List<_Offer> offers = <_Offer>[];
  List<_Model> models = <_Model>[];
  List<_Model> visible = <_Model>[];
  int epoch = 0;
  int cursor = 0;
  int pending = 0;
  int retainedText = 0;
  bool closed = false;
  bool byProvider = false;
  bool descending = false;
  bool manual = false;
  bool advanced = false;
  bool details = false;
  String filter = '';
  String manualProvider = '';
  String notice = '';

  bool current() {
    return !closed &&
        isPresentationDialogCurrent(dialogContext) &&
        settingsFieldEditingEnabled();
  }

  void release() {
    for (final offer in offers) {
      offer.release();
    }
    offers = <_Offer>[];
    models = <_Model>[];
    visible = <_Model>[];
    selected = null;
  }

  @override
  void dispose() {
    closed = true;
    release();
    providerInput.dispose();
    modelInput.dispose();
    search.dispose();
    super.dispose();
  }

  void capture() {
    if (!current()) return;
    epoch++;
    release();
    retainedText = 0;
    cursor = 0;
    filter = '';
    notice = '';
    final entries = observeModelProviders(true);
    if (entries == null) {
      notice = 'Configured provider discovery is unavailable.';
      return;
    }
    final counts = <String, int>{};
    final qualified = <String, bool>{};
    for (final entry in entries) {
      final status = entry['status'] as String;
      final handle = status == 'ready' ? entry['handle'] as String : '';
      if (offers.length >= _maxProviders) {
        if (handle.isNotEmpty) releaseCapabilityProvider(handle);
        notice = 'Showing the first $_maxProviders configured providers.';
      } else {
        final id = entry['providerId'] as String;
        final display = entry['displayName'] as String;
        final name = compactDisplayText(
          display.trim().isEmpty ? id : display,
          maximumCharacters: 60,
        );
        counts[name] = (counts[name] ?? 0) + 1;
        qualified['$name (${inspectionDisplayText(id)})'] = true;
        String label = 'Catalog unavailable.';
        if (status == 'missing') label = 'No catalog.';
        if (status == 'ambiguous') label = 'Ambiguous association.';
        if (status == 'stale') label = _stale;
        if (status == 'limit') label = 'Catalog limit reached.';
        if (status == 'ready') label = 'Loading...';
        offers.add(_Offer(id, display, name, handle, label));
      }
    }
    for (final offer in offers) {
      final name = offer.label;
      if (name == 'All' || counts[name]! > 1 || qualified.containsKey(name)) {
        offer.label = '$name (${inspectionDisplayText(offer.id)})';
      }
    }
    if (offers.isEmpty) notice = 'No configured providers.';
    startRequests();
  }

  void startRequests() {
    while (pending < _workers && cursor < offers.length) {
      final offer = offers[cursor];
      cursor++;
      if (offer.handle.isNotEmpty) {
        pending++;
        load(offer, epoch);
      }
    }
  }

  Future<void> load(_Offer offer, int observedEpoch) async {
    final client = ModelCatalogServiceClient(
      CapabilityRequestChannel(offer.handle),
    );
    final result = await settleCapabilityOperation(
      client.listModels(),
      'modelCatalog.failure',
      'unsupported_discovery',
    );
    pending--;
    if (!current()) return;
    if (observedEpoch == epoch) {
      final before = models.length;
      if (!isCapabilityProviderCurrent(offer.handle)) {
        offer.status = _stale;
      } else if (result[0] != true) {
        offer.status = result[1] == 'unsupported_discovery'
            ? 'Discovery not supported.'
            : 'Catalog request failed.';
      } else {
        retain(offer, result[1] as ModelCatalogSnapshot);
      }
      if (models.length == before) {
        offer.release(); // No offered row needs to establish currentness later.
      } else {
        project();
      }
    }
    // Old requests still count until settlement, even across refreshes.
    startRequests();
    setState(() {});
  }

  void retain(_Offer offer, ModelCatalogSnapshot snapshot) {
    // The generated eval client projects DTOs; it does not run the native
    // value constructors. Bound and check the display data before retaining it.
    if (snapshot.models.length > modelCatalogMaxModels) {
      offer.status = 'Catalog exceeds the entry limit.';
      return;
    }
    final seen = <String, bool>{};
    final accepted = <_Model>[];
    int size = 0;
    int catalogText = 0;
    for (final entry in snapshot.models) {
      final id = entry.modelId;
      final display = entry.displayName ?? '';
      final description = entry.description ?? '';
      catalogText += id.length + display.length + description.length;
      final efforts = entry.supportedReasoningEfforts;
      List<String>? supported;
      int effortText = 0;
      if (efforts != null) {
        final values = efforts.values;
        if (values.length > modelCatalogReasoningEffortNames.length) {
          offer.status = 'Invalid reasoning effort metadata.';
          return;
        }
        supported = <String>[];
        int previous = -1;
        for (final value in values) {
          final index = modelCatalogReasoningEffortNames.indexOf(value);
          if (index <= previous) {
            offer.status = 'Invalid reasoning effort metadata.';
            return;
          }
          previous = index;
          supported.add(value);
          effortText += value.length;
        }
        catalogText += effortText;
      }
      if (id.length > modelCatalogMaxModelIdLength ||
          id.trim().isEmpty ||
          seen.containsKey(id)) {
        offer.status = 'Invalid model ID.';
        return;
      }
      for (final unit in id.codeUnits) {
        if (unit < 32 || unit == 127) {
          offer.status = 'Invalid model ID.';
          return;
        }
      }
      if (display.length > modelCatalogMaxDisplayNameLength ||
          description.length > modelCatalogMaxDescriptionLength ||
          catalogText > modelCatalogMaxTextLength) {
        offer.status = 'Catalog exceeds the text limit.';
        return;
      }
      if (!_validOptionalText(entry.displayName) ||
          !_validOptionalText(entry.description)) {
        offer.status = 'Invalid model display metadata.';
        return;
      }
      seen[id] = true;
      final name = display.isEmpty ? id : display;
      final cost = id.length + name.length + effortText;
      if (models.length + accepted.length < _maxRows &&
          retainedText + size + cost <= _maxText) {
        size += cost;
        accepted.add(_Model(offer, id, name, supported));
      }
    }
    for (final row in accepted) {
      models.add(row);
      if (epoch == 1 &&
          selected == null &&
          row.offer.id == selection.provider &&
          row.id == selection.model) {
        selected = row;
      }
    }
    retainedText += size;
    offer.status = accepted.isEmpty
        ? 'Empty catalog.'
        : '${accepted.length} models.';
    if (accepted.length != snapshot.models.length) {
      offer.status = '${accepted.length} shown (browser limit).';
    }
  }

  int compare(_Model a, _Model b) {
    final left = descending ? b : a;
    final right = descending ? a : b;
    final nameA = left.name.toLowerCase();
    final nameB = right.name.toLowerCase();
    final providerA = left.offer.display.toLowerCase();
    final providerB = right.offer.display.toLowerCase();
    if (byProvider && providerA != providerB) {
      return providerA.compareTo(providerB);
    }
    if (nameA != nameB) return nameA.compareTo(nameB);
    if (providerA != providerB) return providerA.compareTo(providerB);
    if (left.offer.id != right.offer.id) {
      return left.offer.id.compareTo(right.offer.id);
    }
    return left.id.compareTo(right.id);
  }

  void project() {
    final query = search.text.trim().toLowerCase();
    final matches = <_Model>[];
    for (final row in models) {
      if (row.offer.handle.isNotEmpty &&
          (filter.isEmpty || row.offer.id == filter) &&
          (query.isEmpty ||
              row.name.toLowerCase().contains(query) ||
              row.id.toLowerCase().contains(query) ||
              row.offer.display.toLowerCase().contains(query) ||
              row.offer.label.toLowerCase().contains(query))) {
        matches.add(row);
      }
    }
    matches.sort((_Model a, _Model b) => compare(a, b));
    visible = matches;
  }

  void sort(bool provider) {
    if (!current() || manual) return;
    descending = byProvider == provider && !descending;
    byProvider = provider;
    project();
    setState(() {});
  }

  bool verify(_Model row) {
    if (isCapabilityProviderCurrent(row.offer.handle)) return true;
    row.offer.status = _stale;
    row.offer.release();
    final chosen = selected;
    if (chosen != null && chosen.offer.id == row.offer.id) selected = null;
    project();
    notice = _stale;
    setState(() {});
    return false;
  }

  void confirm(String provider, String id, String name, List<String>? efforts) {
    if (!current()) return;
    final pair = <String, Object>{'provider-id': provider, 'model-id': id};
    final error = efforts == null
        ? proposeSettingsFieldValue(selection.revision, pair)
        : proposeSettingsFieldValueWithContext(
            selection.revision,
            pair,
            efforts,
          );
    if (error != null) {
      notice = error;
      setState(() {});
      return;
    }
    selection.provider = provider;
    selection.model = id;
    selection.name = name;
    selection.confirmed = true;
    close();
  }

  void close() {
    if (closed || !isPresentationDialogCurrent(dialogContext)) return;
    closed = true;
    release();
    dismissPresentationDialog(dialogContext);
  }

  Widget chip(String id, String label, int offeredEpoch) => Padding(
    padding: EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: id == (manual ? manualProvider : filter),
      onSelected: (bool value) {
        if (!current() || epoch != offeredEpoch) return;
        if (manual) {
          manualProvider = id;
          notice = '';
        } else {
          filter = id;
          project();
        }
        setState(() {});
      },
    ),
  );

  Widget chips() {
    final items = <Widget>[];
    if (!manual) items.add(chip('', 'All', epoch));
    for (final offer in offers) {
      items.add(chip(offer.id, offer.label, epoch));
    }
    return SizedBox(
      height: 48,
      child: ListView(
        primary: false,
        scrollDirection: Axis.horizontal,
        children: items,
      ),
    );
  }

  Widget header(bool provider, String label) {
    final direction = descending ? 'descending' : 'ascending';
    return TextButton(
      onPressed: () => sort(provider),
      child: Text(byProvider == provider ? '$label ($direction)' : label),
    );
  }

  Widget cells(Widget model, Widget provider) => Row(
    children: <Widget>[
      Expanded(flex: 3, child: model),
      Expanded(flex: 2, child: provider),
    ],
  );

  Widget tableRow(_Model row, int offeredEpoch) {
    final active = row == selected;
    final modelCell = <Widget>[
      Text(
        inspectionDisplayText(row.name),
        style: TextStyle(
          fontWeight: active ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    ];
    if (row.id != row.name) {
      modelCell.add(
        Text(inspectionDisplayText(row.id), style: TextStyle(fontSize: 12)),
      );
    }
    return TextButton(
      onPressed: () {
        if (!current() || manual || epoch != offeredEpoch || !verify(row)) {
          return;
        }
        selected = row;
        setState(() {});
      },
      child: Container(
        padding: EdgeInsets.all(8),
        child: cells(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: modelCell,
          ),
          Text(row.offer.label),
        ),
      ),
    );
  }

  void catalogWidgets(List<Widget> parts) {
    parts.add(Text('Search models and configured providers'));
    parts.add(
      TextField(
        controller: search,
        onChanged: (String value) {
          if (!current() || manual) return;
          project();
          setState(() {});
        },
      ),
    );
    parts.add(chips());
    parts.add(
      cells(header(false, 'Model'), header(true, 'Configured provider')),
    );
    final offered = visible;
    final offeredEpoch = epoch;
    if (offered.isEmpty) {
      parts.add(
        Expanded(
          flex: 1,
          child: Text(
            pending > 0 ? 'Loading catalogs...' : 'No matching models.',
          ),
        ),
      );
    } else {
      parts.add(
        Expanded(
          flex: 1,
          child: ListView.builder(
            primary: false,
            itemCount: offered.length,
            itemBuilder: (BuildContext context, int i) =>
                tableRow(offered[i], offeredEpoch),
          ),
        ),
      );
    }
    final row = selected;
    if (row != null) {
      parts.add(
        Text('Selected: ${compactDisplayText(row.id)} / ${row.offer.label}'),
      );
    }
    final actions = <Widget>[
      TextButton(
        onPressed: () {
          if (!current() || manual) return;
          manual = true;
          notice = '';
          setState(() {});
        },
        child: Text('Enter manually'),
      ),
    ];
    if (row != null) {
      actions.add(
        TextButton(
          onPressed: () {
            if (!current() ||
                manual ||
                selected != row ||
                epoch != offeredEpoch ||
                !verify(row)) {
              return;
            }
            confirm(row.offer.id, row.id, row.name, row.efforts);
          },
          child: Text('Use model'),
        ),
      );
    }
    actions.add(TextButton(onPressed: () => close(), child: Text('Cancel')));
    parts.add(Row(mainAxisAlignment: MainAxisAlignment.end, children: actions));
  }

  void manualWidgets(List<Widget> parts) {
    final form = <Widget>[
      Text(
        'Enter an exact reference. This does not verify model availability.',
      ),
    ];
    if (advanced) {
      form.add(Text('Provider ID'));
      form.add(
        TextField(
          controller: providerInput,
          onChanged: (String value) => manualChanged(),
        ),
      );
    } else {
      form.add(Text('Configured provider'));
      form.add(chips());
    }
    form.add(
      TextButton(
        onPressed: () {
          if (!current() || !manual) return;
          advanced = !advanced;
          notice = '';
          setState(() {});
        },
        child: Text(
          advanced
              ? 'Choose a configured provider'
              : 'Enter provider ID instead',
        ),
      ),
    );
    form.add(Text('Model ID'));
    form.add(
      TextField(
        controller: modelInput,
        onChanged: (String value) => manualChanged(),
      ),
    );
    parts.add(
      Expanded(flex: 1, child: ListView(primary: false, children: form)),
    );
    final provider = advanced ? providerInput.text : manualProvider;
    final id = modelInput.text;
    final actions = <Widget>[
      TextButton(
        onPressed: () {
          if (!current() || !manual) return;
          manual = false;
          notice = '';
          setState(() {});
        },
        child: Text('Back to catalog'),
      ),
    ];
    // A configured instance must be chosen. Once the inputs are offered,
    // propose them verbatim; only the field declaration validates the pair.
    if (advanced || manualProvider.isNotEmpty) {
      actions.add(
        TextButton(
          onPressed: () {
            if (current() &&
                manual &&
                provider == (advanced ? providerInput.text : manualProvider) &&
                id == modelInput.text) {
              confirm(provider, id, '', null);
            }
          },
          child: Text('Use reference'),
        ),
      );
    }
    actions.add(TextButton(onPressed: () => close(), child: Text('Cancel')));
    parts.add(Row(mainAxisAlignment: MainAxisAlignment.end, children: actions));
  }

  void manualChanged() {
    if (!current() || !manual) return;
    notice = '';
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    dialogContext = context;
    if (epoch == 0 && !closed) capture();
    final toolbar = <Widget>[
      Expanded(
        flex: 1,
        child: Text(
          manual ? 'Manual model reference' : 'Model Browser',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
      ),
    ];
    if (!manual) {
      toolbar.add(
        TextButton(
          onPressed: () {
            if (!current() || manual) return;
            details = !details;
            setState(() {});
          },
          child: Text('Provider status'),
        ),
      );
      toolbar.add(
        TextButton(
          onPressed: () {
            if (!current() || manual) return;
            capture();
            setState(() {});
          },
          child: Text('Refresh'),
        ),
      );
    }
    final parts = <Widget>[Row(children: toolbar)];
    if (details && !manual) {
      final statuses = <Widget>[];
      for (final offer in offers) {
        statuses.add(Text('${offer.label}: ${offer.status}'));
      }
      parts.add(
        Container(
          constraints: BoxConstraints(maxHeight: 84),
          child: ListView(primary: false, shrinkWrap: true, children: statuses),
        ),
      );
    }
    if (notice.isNotEmpty) parts.add(Text(notice));
    if (manual) {
      manualWidgets(parts);
    } else {
      catalogWidgets(parts);
    }
    return Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: parts,
      ),
    );
  }
}
