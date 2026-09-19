import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_inference_context.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'remote_model_tool_host.dart';
import 'remote_orchestration_host.dart';

RemoteExtensionAdapterRegistry createRemoteExtensionAdapters() =>
    RemoteExtensionAdapterRegistry([
      const RemoteInferenceContextSourceAdapter(),
      const RemoteModelToolAdapter(),
      const RemoteOrchestrationStrategyAdapter(),
    ]);

/// Transport adaptation only; composition policy stays in the public composer.
final class RemoteInferenceContextSourceAdapter
    implements RemoteExtensionAdapter<InferenceContextSourceContribution> {
  const RemoteInferenceContextSourceAdapter();

  @override
  ExtensionPoint<InferenceContextSourceContribution> get point =>
      inferenceContextSources;

  @override
  InferenceContextSourceContribution createContribution(
    RemoteExtensionContext remote,
  ) {
    final metadata = remote.exposure.metadata;
    if (metadata.length != 1 || !metadata.containsKey('failureMode')) {
      throw const ExtensionContractException(
        'Inference source metadata requires only failureMode.',
      );
    }
    final failureMode = switch (metadata['failureMode']) {
      'required' => InferenceContextFailureMode.required,
      'optional' => InferenceContextFailureMode.optional,
      _ => throw const ExtensionContractException(
        'Inference source failureMode must be required or optional.',
      ),
    };
    if (remote.exposure.serviceId != remoteInferenceContextSourceServiceId) {
      throw const ExtensionContractException(
        'Unsupported inference source service.',
      );
    }
    return InferenceContextSourceContribution(
      failureMode: failureMode,
      snapshot: (context) {
        PluginHostInvocation? invocation;
        final read = _InferenceEnvironmentRead(context, () {
          remote.validate();
          if (invocation == null || invocation!.isClosed) {
            throw StateError('The inference operation has ended.');
          }
        });
        return remote.invoke(
          {
            authorizedEnvironmentReadServiceId:
                AuthorizedEnvironmentReadServiceDispatcher(read),
          },
          (opened) async {
            invocation = opened;
            final client = RemoteInferenceContextSourceServiceClient(
              remote.channel,
            );
            final instructions = await client.snapshot(
              context.session.id.value,
              context.runId.value,
              opened.id,
            );
            read.validateResolvedBinding();
            return [
              for (final instruction in instructions)
                InferenceInstructionMaterial(
                  key: instruction.key,
                  text: instruction.text,
                  revision: instruction.revision,
                ),
            ];
          },
        );
      },
    );
  }
}

/// Captures authority, never resolves it from transported semantic identifiers.
final class _InferenceEnvironmentRead
    implements AuthorizedEnvironmentReadService {
  _InferenceEnvironmentRead(this._context, this._validateInvocation);

  final InferenceContextSourceContext _context;
  final void Function() _validateInvocation;
  Future<AuthorizedEnvironmentFileReadFacet>? _files;
  AuthorizedEnvironmentFileReadFacet? _resolved;

  void validateResolvedBinding() {
    _validateInvocation();
    _resolved?.validateBinding();
  }

  Future<AuthorizedEnvironmentFileReadFacet> _requireFiles() async {
    _validateInvocation();
    final files = await (_files ??= _context
        .requireHostService<AuthorizedEnvironmentFileReadFacet>());
    _validateInvocation();
    if (files.sessionId != _context.session.id) {
      throw StateError('The filesystem authority belongs to another Session.');
    }
    _resolved = files;
    return files;
  }

  @override
  Future<AuthorizedEnvironmentIdentity> authority() async {
    final files = await _requireFiles();
    validateResolvedBinding();
    return AuthorizedEnvironmentIdentity(
      sessionId: files.sessionId.value,
      environmentId: files.environmentId.value,
    );
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    final files = await _requireFiles();
    validateResolvedBinding();
    try {
      return await files.readFile(relativePath);
    } finally {
      // Even not_found is accepted only from the still-authoritative generation.
      _validateInvocation();
      files.validateBinding();
    }
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    final files = await _requireFiles();
    validateResolvedBinding();
    try {
      return await files.readDirectory(relativePath);
    } finally {
      _validateInvocation();
      files.validateBinding();
    }
  }
}
