import 'dart:async';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Global shell presentation only. The caller dispatches the returned exact
/// binding after dismissal, so a command can itself present an input surface.
final class CommandPalette extends StatefulWidget {
  const CommandPalette({
    super.key,
    required this.extensions,
    required this.isInteractive,
  });

  final ExtensionRegistry extensions;
  final bool Function() isInteractive;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

final class _CommandPaletteState extends State<CommandPalette> {
  late final CommandResolver _commands = CommandResolver(widget.extensions);
  late final StreamSubscription<void> _changes;
  final _search = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  List<({ResolvedCommand command, CommandAvailability availability})> _results =
      [];
  ResolvedCommand? _selected;
  bool _selectFirst = true;

  @override
  void initState() {
    super.initState();
    _changes = widget.extensions.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    _search.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  int get _selectedIndex => _results.indexWhere(
    (entry) =>
        _selected?.binding.isSameRegistration(entry.command.binding) ?? false,
  );

  void _move(int delta) {
    if (_results.isEmpty) return;
    final current = _selectedIndex;
    final next = current < 0
        ? (delta > 0 ? 0 : _results.length - 1)
        : (current + delta) % _results.length;
    setState(() => _selected = _results[next].command);
    if (_scroll.hasClients) {
      final top = next * 72.0;
      final bottom = top + 72;
      final position = _scroll.position;
      if (top < position.pixels) {
        _scroll.jumpTo(top.clamp(0, position.maxScrollExtent));
      } else if (bottom > position.pixels + position.viewportDimension) {
        _scroll.jumpTo(
          (bottom - position.viewportDimension).clamp(
            0,
            position.maxScrollExtent,
          ),
        );
      }
    }
  }

  void _choose(ResolvedCommand command) {
    if (!mounted ||
        !widget.isInteractive() ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    if (command.availability != CommandAvailability.enabled) {
      setState(() {});
      return;
    }
    Navigator.of(context).pop(command);
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final results =
        <({ResolvedCommand command, CommandAvailability availability})>[];
    for (final discovered in _commands.discover()) {
      // Preserve row/focus identity only for the same exact registration.
      final command =
          _results
              .where(
                (entry) => entry.command.binding.isSameRegistration(
                  discovered.binding,
                ),
              )
              .firstOrNull
              ?.command ??
          discovered;
      final availability = command.availability;
      if (availability != CommandAvailability.hidden &&
          (command.label.toLowerCase().contains(query) ||
              command.id.value.toLowerCase().contains(query))) {
        results.add((command: command, availability: availability));
      }
    }
    _results = results;
    if (_selectFirst) {
      _selected = _results.firstOrNull?.command;
      _selectFirst = false;
    } else if (_selectedIndex < 0) {
      // Retirement clears selection, even if the same IDs reappear. Only a fresh
      // user selection may choose the replacement registration.
      _selected = null;
    }
    final interactive = widget.isInteractive();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Command Palette',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close Command Palette',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                        _move(-1),
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                        _move(1),
                    const SingleActivator(LogicalKeyboardKey.enter): () {
                      if (_selected case final command?) _choose(command);
                    },
                    const SingleActivator(LogicalKeyboardKey.numpadEnter): () {
                      if (_selected case final command?) _choose(command);
                    },
                  },
                  child: TextField(
                    key: const ValueKey('command-palette-search'),
                    controller: _search,
                    focusNode: _focus,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Search commands',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (_) {
                      setState(() => _selectFirst = true);
                      if (_scroll.hasClients) _scroll.jumpTo(0);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_results.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    query.isEmpty
                        ? 'No commands are available.'
                        : 'No matching commands.',
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    controller: _scroll,
                    shrinkWrap: true,
                    itemExtent: 72,
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final entry = _results[index];
                      final enabled =
                          interactive &&
                          entry.availability == CommandAvailability.enabled;
                      return ListTile(
                        key: ObjectKey(entry.command),
                        selected: index == _selectedIndex,
                        enabled: enabled,
                        title: Text(
                          entry.command.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          entry.command.id.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: enabled ? null : const Text('Unavailable'),
                        onTap: enabled ? () => _choose(entry.command) : null,
                      );
                    },
                  ),
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
