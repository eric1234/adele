import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_backend/git_backend.dart';

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
  final Object? hostInfrastructureContext =
      bootstrapMessage['hostInfrastructureContext'];
  if (bootstrapPort is! SendPort ||
      responsePort is! SendPort ||
      defaultConfigurationContext is! String ||
      hostInfrastructureContext is! String) {
    throw ArgumentError.value(bootstrapMessage, 'bootstrapMessage');
  }

  final GitWorktreeEnvironmentProvider provider =
      GitWorktreeEnvironmentProvider(ptyHelperPath: helperPath);
  final EnvironmentProviderServiceDispatcher dispatcher =
      EnvironmentProviderServiceDispatcher(
        EnvironmentProviderServiceAdapter(provider),
      );
  final hostRequests = AdeleHostRequestMultiplexer(send: responsePort.send);
  final anchors = GitTaskAnchorStore(
    ProjectStorageServiceClient(
      hostRequests.bindInfrastructure(
        hostInfrastructureContext: hostInfrastructureContext,
        serviceId: projectStorageServiceId,
      ),
    ),
  );
  final router = AdeleConfigurationContextRouter(
    contexts: {
      defaultConfigurationContext: {
        environmentProviderServiceId: dispatcher,
        changeSetSourceServiceId: AdeleContextualServiceDispatcher(
          hostRequests: hostRequests,
          createDispatcher: (context) => ChangeSetSourceServiceDispatcher(
            GitPersistedChangeSetSourceService(
              anchors: anchors,
              processes: AuthorizedEnvironmentBufferedProcessServiceClient(
                context.bind(authorizedEnvironmentBufferedProcessServiceId),
              ),
            ),
          ),
        ),
        reviewApprovalHandlerServiceId: AdeleContextualServiceDispatcher(
          hostRequests: hostRequests,
          createDispatcher: (context) => ReviewApprovalHandlerServiceDispatcher(
            GitPortableReviewApprovalService(
              processes: AuthorizedEnvironmentBufferedProcessServiceClient(
                context.bind(authorizedEnvironmentBufferedProcessServiceId),
              ),
            ),
          ),
        ),
      },
    },
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
      AdeleCapabilityExposure(
        providerId: gitChangeSetSourceProviderId,
        capabilityId: changeSetSourceCapability.id.value,
        capabilityMajorVersion: changeSetSourceCapability.majorVersion,
        serviceId: changeSetSourceServiceId,
        displayName: 'Git Changes',
        configurationContext: defaultConfigurationContext,
        environmentBound: true,
        environmentHostServices: const [
          AdeleEnvironmentHostService.bufferedProcess,
        ],
      ).toMap(),
      AdeleCapabilityExposure(
        providerId: gitReviewApprovalProviderId,
        capabilityId: reviewApprovalCapability.id.value,
        capabilityMajorVersion: reviewApprovalCapability.majorVersion,
        serviceId: reviewApprovalHandlerServiceId,
        displayName: 'Git Review Approval',
        configurationContext: defaultConfigurationContext,
        environmentBound: true,
        environmentHostServices: const [
          AdeleEnvironmentHostService.bufferedProcess,
        ],
      ).toMap(),
    ],
  });

  await for (final Object? request in requests) {
    if (hostRequests.handleResponse(request)) continue;
    if (request is! Map) continue;
    if (request['method'] == 'shutdown' && request['requestId'] is int) {
      // Fence lazy starts before router cancellation or queued dispatch can run.
      final Future<void> closingProvider = provider.close();
      hostRequests.close();
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
