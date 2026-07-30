import 'package:adele_desktop/phase1/development_plugin_controller.dart';
import 'package:flutter/material.dart';

final class Phase1ConfigurationError extends StatelessWidget {
  const Phase1ConfigurationError({required this.error, super.key});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Text('Phase 1 configuration failure: $error'),
      ),
    );
  }
}

final class Phase1Shell extends StatefulWidget {
  const Phase1Shell({required this.controller, super.key});

  final DevelopmentPluginController controller;

  @override
  State<Phase1Shell> createState() => _Phase1ShellState();
}

final class _Phase1ShellState extends State<Phase1Shell> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final DevelopmentPluginController controller = widget.controller;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'ADELE Phase 1',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  FilledButton(
                    onPressed: controller.busy
                        ? null
                        : controller.buildAndStart,
                    child: const Text('Build and start'),
                  ),
                  OutlinedButton(
                    onPressed: controller.busy ? null : controller.stop,
                    child: const Text('Stop'),
                  ),
                  OutlinedButton(
                    onPressed: controller.busy
                        ? null
                        : controller.rebuildAndReload,
                    child: const Text('Rebuild and reload'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Plugin: ${controller.configuration.pluginDirectory.path}'),
              Text(
                'Development directory: ${controller.configuration.developmentDirectory.path}',
              ),
              const Text(
                'Flutter: 3.38.10 (c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80)',
              ),
              const Text('Dart: 3.10.9'),
              const Text('dart_eval: 0.8.5; flutter_eval: 0.8.2'),
              Text('Build ID: ${controller.buildId ?? 'none'}'),
              Text('Build phase: ${controller.phase}'),
              Text('Backend: ${controller.backendState}'),
              Text('Frontend: ${controller.frontendState}'),
              Text('Connection: ${controller.connectionState}'),
              Text('Last failure: ${controller.lastFailure ?? 'none'}'),
              const Divider(),
              Expanded(
                child: controller.interpretedWidget == null
                    ? ListView(
                        children: controller.diagnostics.reversed
                            .take(30)
                            .map(Text.new)
                            .toList(growable: false),
                      )
                    : KeyedSubtree(
                        key: ValueKey<String>(controller.buildId ?? 'inactive'),
                        child: controller.interpretedWidget!,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
