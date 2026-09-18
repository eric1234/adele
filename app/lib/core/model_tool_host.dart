import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart'
    show ModelToolComposer, ToolCatalog;

import 'product_lifecycle.dart';

Future<ToolCatalog> buildModelToolCatalogForSession({
  required SessionId sessionId,
  required EnvironmentRuntime environmentRuntime,
  required ExtensionRegistry extensions,
}) => ModelToolComposer(extensions).materialize(
  SessionModelToolHostContext(
    sessionId: sessionId,
    environmentRuntime: environmentRuntime,
  ),
);

final class SessionModelToolHostContext implements ModelToolHostContext {
  SessionModelToolHostContext({
    required this.sessionId,
    required EnvironmentRuntime environmentRuntime,
  }) : _environmentRuntime = environmentRuntime;

  @override
  final SessionId sessionId;
  final EnvironmentRuntime _environmentRuntime;
  Future<_SessionEnvironmentFacets>? _environmentFacets;

  @override
  Future<T> requireHostService<T extends Object>() async {
    if (T == AuthorizedEnvironmentAuthority) {
      return (await _requireEnvironmentFacets()).authority as T;
    }
    if (T == AuthorizedEnvironmentFileSystem) {
      return (await _requireEnvironmentFacets()).authority as T;
    }
    if (T == AuthorizedEnvironmentFileReadFacet) {
      return (await _requireEnvironmentFacets()).read as T;
    }
    if (T == AuthorizedEnvironmentFileMutationFacet) {
      return (await _requireEnvironmentFacets()).mutation as T;
    }
    if (T == AuthorizedEnvironmentProcessFacet) {
      return (await _requireEnvironmentFacets()).process as T;
    }
    throw StateError('No Session host service is registered for $T.');
  }

  Future<_SessionEnvironmentFacets> _requireEnvironmentFacets() =>
      _environmentFacets ??= _materializeEnvironmentFacets();

  Future<_SessionEnvironmentFacets> _materializeEnvironmentFacets() async {
    final SessionEnvironmentAuthority authority = _environmentRuntime.store
        .requireSessionAuthority(sessionId);
    final EnvironmentMaterialization materialization = await _environmentRuntime
        .materialize(authority.environmentId);
    if (materialization.environment.taskId != authority.taskId) {
      throw StateError(
        'Session $sessionId has inconsistent Task and Environment authority.',
      );
    }
    final _SessionEnvironmentAuthority environmentAuthority =
        _SessionEnvironmentAuthority(
          authority: authority,
          materialization: materialization,
        );
    return _SessionEnvironmentFacets(environmentAuthority);
  }
}

final class _SessionEnvironmentFacets {
  _SessionEnvironmentFacets(this.authority)
    : read = _SessionEnvironmentFileReadFacet(authority),
      mutation = _SessionEnvironmentFileMutationFacet(authority),
      process = _SessionEnvironmentProcessFacet(authority);

  final _SessionEnvironmentAuthority authority;
  final AuthorizedEnvironmentFileReadFacet read;
  final AuthorizedEnvironmentFileMutationFacet mutation;
  final AuthorizedEnvironmentProcessFacet process;
}

final class _SessionEnvironmentAuthority
    implements AuthorizedEnvironmentFileSystem {
  const _SessionEnvironmentAuthority({
    required SessionEnvironmentAuthority authority,
    required EnvironmentMaterialization materialization,
  }) : _authority = authority,
       _materialization = materialization;

  final SessionEnvironmentAuthority _authority;
  final EnvironmentMaterialization _materialization;

  @override
  SessionId get sessionId => _authority.sessionId;

  @override
  EnvironmentId get environmentId => _authority.environmentId;

  @override
  void validateBinding() {
    try {
      _materialization.validateBinding();
    } on ProviderUnavailable catch (error) {
      if (error.stale) {
        throw AuthorizedEnvironmentBindingStale(
          'The authorized Environment provider generation is stale.',
          cause: error,
        );
      }
      throw AuthorizedEnvironmentBindingUnavailable(
        'The authorized Environment provider is unavailable.',
        cause: error,
      );
    } on ProviderEndpointUnavailable catch (error) {
      throw AuthorizedEnvironmentBindingUnavailable(
        'The authorized Environment provider endpoint is unavailable.',
        cause: error,
      );
    }
  }

  Future<EnvironmentTextFile> readFile(String relativePath) => _perform(
    () => _materialization.provider.readFile(
      _authority.environmentId,
      relativePath,
    ),
  );

  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) =>
      _perform(
        () => _materialization.provider.readDirectory(
          _authority.environmentId,
          relativePath,
        ),
      );

  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  ) => _perform(
    () => _materialization.provider.createTextFile(
      _authority.environmentId,
      relativePath,
      text,
    ),
  );

  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) {
    return _perform(
      () => _materialization.provider.replaceExistingTextFile(
        _authority.environmentId,
        relativePath,
        replacementText,
        expectedRevision,
      ),
    );
  }

  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) => _perform(
    () => _materialization.provider.deleteExistingTextFile(
      _authority.environmentId,
      relativePath,
      expectedRevision,
    ),
  );

  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentForegroundProcessRequest request,
  ) => _performStream(
    () => _materialization.provider.runForegroundProcess(
      _authority.environmentId,
      request,
    ),
  );

  Future<T> _perform<T>(Future<T> Function() operation) async {
    validateBinding();
    try {
      return await operation();
    } on ProviderUnavailable catch (error) {
      if (error.stale) {
        throw AuthorizedEnvironmentBindingStale(
          'The authorized Environment provider generation is stale.',
          cause: error,
        );
      }
      throw AuthorizedEnvironmentBindingUnavailable(
        'The authorized Environment provider is unavailable.',
        cause: error,
      );
    } on ProviderEndpointUnavailable catch (error) {
      throw AuthorizedEnvironmentBindingUnavailable(
        'The authorized Environment provider endpoint is unavailable.',
        cause: error,
      );
    }
  }

  Stream<T> _performStream<T>(Stream<T> Function() operation) {
    Object mapError(Object error) {
      if (error is ProviderUnavailable) {
        return error.stale
            ? AuthorizedEnvironmentBindingStale(
                'The authorized Environment provider generation is stale.',
                cause: error,
              )
            : AuthorizedEnvironmentBindingUnavailable(
                'The authorized Environment provider is unavailable.',
                cause: error,
              );
      }
      if (error is ProviderEndpointUnavailable) {
        return AuthorizedEnvironmentBindingUnavailable(
          'The authorized Environment provider endpoint is unavailable.',
          cause: error,
        );
      }
      if (error is EnvironmentFailure) return error;
      try {
        validateBinding();
      } on AuthorizedEnvironmentBindingStale {
        return AuthorizedEnvironmentBindingStale(
          'The authorized Environment provider generation became stale '
          'during the process stream.',
          cause: error,
        );
      } on AuthorizedEnvironmentBindingUnavailable {
        return AuthorizedEnvironmentBindingUnavailable(
          'The authorized Environment provider became unavailable during '
          'the process stream.',
          cause: error,
        );
      } on Object {
        // Revalidation is only used to recognize binding lifecycle changes.
      }
      return error;
    }

    late final StreamController<T> controller;
    StreamSubscription<T>? subscription;
    Future<void>? cancellation;
    var terminated = false;
    var failed = false;

    Future<void> cancel() {
      terminated = true;
      final current = subscription;
      if (current == null) return Future<void>.value();
      final pending = cancellation ??= Future<void>.sync(current.cancel);
      if (!failed) return pending;
      // cancelOnError must deliver the primary failure even if cleanup stalls.
      unawaited(pending.catchError((Object _) {}));
      return Future<void>.value();
    }

    void fail(Object error, StackTrace stackTrace) {
      if (terminated) return;
      failed = true;
      unawaited(cancel());
      controller.addError(error, stackTrace);
      unawaited(controller.close());
    }

    // Forward cancellation directly, even while the process produces no output.
    controller = StreamController<T>(
      sync: true,
      onListen: () {
        try {
          validateBinding();
        } on Object catch (error, stackTrace) {
          fail(error, stackTrace);
          return;
        }
        try {
          subscription = operation().listen(
            (event) {
              if (!terminated) controller.add(event);
            },
            onError: (Object error, StackTrace stackTrace) =>
                fail(mapError(error), stackTrace),
            onDone: () {
              if (terminated) return;
              terminated = true;
              unawaited(controller.close());
            },
          );
          if (terminated) {
            unawaited(cancel().catchError((Object _) {}));
          } else if (controller.isPaused) {
            subscription!.pause();
          }
        } on Object catch (error, stackTrace) {
          fail(mapError(error), stackTrace);
        }
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: cancel,
    );
    return controller.stream;
  }
}

final class _SessionEnvironmentFileReadFacet
    implements AuthorizedEnvironmentFileReadFacet {
  const _SessionEnvironmentFileReadFacet(this._authority);

  final _SessionEnvironmentAuthority _authority;

  @override
  SessionId get sessionId => _authority.sessionId;

  @override
  EnvironmentId get environmentId => _authority.environmentId;

  @override
  void validateBinding() => _authority.validateBinding();

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) =>
      _authority.readFile(relativePath);

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) =>
      _authority.readDirectory(relativePath);
}

final class _SessionEnvironmentFileMutationFacet
    implements AuthorizedEnvironmentFileMutationFacet {
  const _SessionEnvironmentFileMutationFacet(this._authority);

  final _SessionEnvironmentAuthority _authority;

  @override
  SessionId get sessionId => _authority.sessionId;

  @override
  EnvironmentId get environmentId => _authority.environmentId;

  @override
  void validateBinding() => _authority.validateBinding();

  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  ) => _authority.createTextFile(relativePath, text);

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) => _authority.replaceExistingTextFile(
    relativePath,
    replacementText,
    expectedRevision,
  );

  @override
  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) => _authority.deleteExistingTextFile(relativePath, expectedRevision);
}

final class _SessionEnvironmentProcessFacet
    implements AuthorizedEnvironmentProcessFacet {
  const _SessionEnvironmentProcessFacet(this._authority);

  final _SessionEnvironmentAuthority _authority;

  @override
  SessionId get sessionId => _authority.sessionId;

  @override
  EnvironmentId get environmentId => _authority.environmentId;

  @override
  void validateBinding() => _authority.validateBinding();

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentForegroundProcessRequest request,
  ) => _authority.runForegroundProcess(request);
}
