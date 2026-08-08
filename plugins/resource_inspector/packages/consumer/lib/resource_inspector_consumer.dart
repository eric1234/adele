import 'package:flutter/material.dart';

import 'src/adele_eval_bridge.dart';

Future<Widget> buildCapabilityDemo() async {
  final List<String> lines = <String>[];
  final List<CapabilityProviderData> providers =
      await resourceInspectorProviders();
  if (providers.isEmpty) {
    lines.add('Unavailable: no provider');
  } else {
    for (final CapabilityProviderData provider in providers) {
      lines.add('Provider: ${provider.id} | ${provider.displayName}');
    }
    final ResolvedInspectorData defaultProvider =
        await resolveResourceInspector();
    lines.add('Default: ${defaultProvider.providerId}');
    final InspectionData defaultResult = await inspectResource(
      defaultProvider.token,
      'file:///tmp/example.txt',
    );
    if (!defaultResult.cancelled) {
      lines.add(
        'Default result: ${defaultResult.providerLabel}: ${defaultResult.summary}',
      );
    }
    for (final CapabilityProviderData provider in providers) {
      final ResolvedInspectorData explicit = await resolveResourceInspector(
        provider.id,
      );
      final InspectionData result = await inspectResource(
        explicit.token,
        'file:///tmp/example.txt',
      );
      if (!result.cancelled) {
        lines.add(
          'Explicit ${provider.id}: ${result.providerLabel}: ${result.summary}',
        );
      }
    }
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text('Resource Inspector Capability'),
      for (final String line in lines) Text(line),
    ],
  );
}
