import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';

import 'backend_test_sdk.dart';
import 'git_worktree_fixture.dart';

const String openaiPluginId = 'dev.adele.openai';
final ProviderId _chatGptProviderId = ProviderId(
  'dev.adele.openai.chatgpt-experimental',
);

final Matcher staleProvider = isA<ProviderUnavailable>().having(
  (error) => error.stale,
  'stale',
  isTrue,
);

/// Compiled once per suite. Installations and running backends are never shared.
final class PreparedNormalTaskGit {
  PreparedNormalTaskGit(this.repositoryRoot);

  final Directory repositoryRoot;
  late final sdk = backendTestSdk();
  late final File hostArtifact;
  late final File gitArtifact;
  late final File _openaiArtifact;

  Future<void> prepare() async {
    final artifacts = await Directory.systemTemp.createTemp(
      'adele-normal-backends-',
    );
    addTearDown(() => artifacts.delete(recursive: true));
    hostArtifact = File.fromUri(artifacts.uri.resolve('host.aot'));
    gitArtifact = File.fromUri(artifacts.uri.resolve('git.aot'));
    _openaiArtifact = File.fromUri(artifacts.uri.resolve('openai.aot'));
    // Compile real artifacts once; startup only consumes their installed copies.
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
        stage: 'normal-bootstrap-host',
      ),
      (
        entrypoint: 'plugins/git/packages/backend/bin/git_backend.dart',
        artifact: gitArtifact,
        stage: 'normal-bootstrap-git',
      ),
      (
        entrypoint:
            'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
        artifact: _openaiArtifact,
        stage: 'normal-bootstrap-openai',
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: sdk.dart,
        workingDirectory: repositoryRoot,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: target.stage,
      );
    }
  }

  Future<NormalTaskGitCase> createCase() async {
    final fixture = NormalTaskGitCase._(this);
    await fixture._prepare();
    return fixture;
  }
}

final class NormalTaskGitCase {
  NormalTaskGitCase._(this._suite);

  final PreparedNormalTaskGit _suite;
  late final Directory container;
  late final Directory installationRoot;
  late final AdeleRuntime runtime;
  late final File credentialFile;
  late final Map<String, List<String>> startupArguments;
  int _requests = 0;

  Future<void> _prepare() async {
    container = await Directory.systemTemp.createTemp('adele-normal-startup-');
    addTearDown(() => container.delete(recursive: true));
    installationRoot = await Directory(
      '${container.path}/installations',
    ).create();
    credentialFile = File('${container.path}/never-created-credentials.json');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      _requests++;
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
      expect(
        _requests,
        0,
        reason: 'Bootstrap must not make OAuth or model calls.',
      );
      expect(await credentialFile.exists(), isFalse);
    });
    final String endpoint = 'http://${server.address.address}:${server.port}';
    startupArguments = {
      openaiPluginId: [
        '--chatgpt-only',
        jsonEncode({
          'credentialFile': credentialFile.path,
          'clientId': 'adele-test-client',
          'issuer': endpoint,
          'endpoint': '$endpoint/responses',
        }),
      ],
    };
    runtime = AdeleRuntime(ids: MonotonicProductIdSource(seed: 'normal'));
    addTearDown(runtime.close);
  }

  Future<void> installBackends() async {
    await install('10-git', gitPluginId, _suite.gitArtifact);
    await install('30-openai', openaiPluginId, _suite._openaiArtifact);
  }

  Future<void> start({bool argumentsFromFile = true}) async {
    String argumentsFile = '';
    if (argumentsFromFile) {
      argumentsFile = '${container.path}/startup-arguments.json';
      await File(argumentsFile).writeAsString(jsonEncode(startupArguments));
    }
    await runtime.plugins.start(
      installationRoot: installationRoot.path,
      dartaotruntimeExecutable: _suite.sdk.aotRuntime,
      hostArtifactPath: _suite.hostArtifact.path,
      startupArgumentsFile: argumentsFile,
      startupArguments: argumentsFromFile ? null : startupArguments,
    );
  }

  InstalledBackendActivation backend(String id) => runtime.plugins.backends
      .singleWhere((entry) => entry.installation.metadata.id.value == id);

  void expectBothActive() {
    expect(runtime.plugins.state, ApplicationPluginState.ready);
    expect(runtime.plugins.failure, isNull);
    expect(runtime.plugins.registry, same(runtime.registry));
    expect(runtime.plugins.host!.isClosed, isFalse);
    expect(runtime.plugins.catalog!.issues, isEmpty);
    for (final id in [gitPluginId, openaiPluginId]) {
      final InstalledBackendActivation entry = backend(id);
      expect(entry.state, InstalledBackendState.active);
      expect(entry.failure, isNull);
      expect(entry.connection!.isClosed, isFalse);
      expect(entry.connection!.pluginId, id);
      expect(
        runtime.plugins.catalog!.installations,
        contains(same(entry.installation)),
      );
      expect(
        entry.installation.backendArtifactUri!.path,
        startsWith(installationRoot.uri.path),
      );
    }
    final ProviderDescriptor git = runtime.registry
        .providersFor(environmentProviderCapability)
        .single;
    expect(git.id, gitProviderId);
    expect(git.pluginId, gitPluginId);
    final ProviderDescriptor openai = runtime.registry
        .providersFor(modelProviderCapability)
        .single;
    expect(openai.id, _chatGptProviderId);
    expect(openai.pluginId, openaiPluginId);
    expect(_requests, 0);
    expect(credentialFile.existsSync(), isFalse);
  }

  Future<void> install(String name, String id, File artifact) async {
    final Directory directory = await Directory(
      '${installationRoot.path}/$name',
    ).create();
    await artifact.copy('${directory.path}/backend.aot');
    await File(
      '${directory.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': id, 'version': '1.0.0', 'displayName': name},
        'components': {
          'backend': {'artifact': 'backend.aot'},
        },
      }),
    );
  }
}
