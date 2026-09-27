import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:git_environment_backend/git_environment_backend.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final String? helperPath =
      arguments.length == 1 && arguments.single.startsWith('--pty-helper=')
      ? arguments.single.substring('--pty-helper='.length)
      : null;
  if (bootstrapMessage is! Map ||
      (arguments.isNotEmpty &&
          (helperPath == null ||
              !helperPath.startsWith('/') ||
              helperPath.contains('\u0000')))) {
    stderr.writeln(
      'Expected bootstrap metadata and optional --pty-helper=/absolute/prepared-executable.',
    );
    exitCode = 64;
    return;
  }
  final Object? bootstrapPort = bootstrapMessage['bootstrapPort'];
  final Object? responsePort = bootstrapMessage['responsePort'];
  final Object? defaultConfigurationContext =
      bootstrapMessage['defaultConfigurationContext'];
  if (bootstrapPort is! SendPort ||
      responsePort is! SendPort ||
      defaultConfigurationContext is! String) {
    throw ArgumentError.value(bootstrapMessage, 'bootstrapMessage');
  }

  final GitWorktreeEnvironmentProvider provider =
      GitWorktreeEnvironmentProvider(ptyHelperPath: helperPath);
  final EnvironmentProviderServiceDispatcher dispatcher =
      EnvironmentProviderServiceDispatcher(
        EnvironmentProviderServiceAdapter(provider),
      );
  final AdeleConfigurationContextRouter router =
      AdeleConfigurationContextRouter.single(
        configurationContext: defaultConfigurationContext,
        serviceId: environmentProviderServiceId,
        dispatcher: dispatcher,
      );
  final ReceivePort requests = ReceivePort();
  bootstrapPort.send(<String, Object?>{
    'kind': 'ready',
    'commandPort': requests.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    'capabilityExposures': [
      AdeleCapabilityExposure(
        providerId: gitWorktreeEnvironmentProviderId,
        capabilityId: environmentProviderCapability.id.value,
        capabilityMajorVersion: environmentProviderCapability.majorVersion,
        serviceId: environmentProviderServiceId,
        displayName: 'Git Worktree Environment',
        configurationContext: defaultConfigurationContext,
      ).toMap(),
    ],
  });

  await for (final Object? request in requests) {
    if (request is! Map) continue;
    if (request['method'] == 'shutdown' && request['requestId'] is int) {
      // Fence lazy starts before router cancellation or queued dispatch can run.
      final Future<void> closingProvider = provider.close();
      await Future.wait<void>([closingProvider, router.close()]);
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': true,
        'payload': <String, Object?>{'stopping': true},
      });
      requests.close();
      continue;
    }
    unawaited(router.handle(request, responsePort.send));
  }
}
