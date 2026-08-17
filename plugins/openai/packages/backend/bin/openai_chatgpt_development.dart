import 'dart:async';
import 'dart:io';

import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:openai_model_provider_backend/openai_model_provider_backend.dart';
import 'package:openai_model_provider_backend/src/openai_chatgpt_auth.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 ||
      !const <String>{'login', 'test', 'logout'}.contains(arguments.single)) {
    stderr.writeln(
      'Usage: dart run bin/openai_chatgpt_development.dart <login|test|logout>',
    );
    exitCode = 64;
    return;
  }
  final String credentialPath =
      Platform.environment['ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE'] ??
      '${Directory.current.path}/.dart_tool/adele/development/openai-chatgpt-credentials.json';
  final OpenAiOAuthClientIdentity identity = openAiOAuthClientIdentity(
    Platform.environment,
    allowDevelopmentFallback: true,
  );
  if (identity.experimentalCodexClient) {
    stderr.writeln(
      'EXPERIMENTAL DEVELOPMENT FALLBACK: using the source-visible Codex '
      'OAuth public client. This identity is not an ADELE registration or '
      'documented OpenAI third-party contract.',
    );
  }
  final OpenAiOAuthClient oauth = OpenAiOAuthClient(
    configuration: OpenAiOAuthConfiguration(
      clientId: identity.clientId,
      issuer: Uri.parse(
        Platform.environment['ADELE_OPENAI_CHATGPT_OAUTH_ISSUER'] ??
            'https://auth.openai.com',
      ),
      redirectUri: Uri.parse(
        Platform.environment['ADELE_OPENAI_CHATGPT_REDIRECT_URI'] ??
            'http://localhost:1455/auth/callback',
      ),
      authorizationParameters: openAiChatGptAuthorizationParameters,
    ),
  );
  final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
    instanceId: openAiChatGptInstanceId(Platform.environment),
    store: FileOpenAiCredentialStore(File(credentialPath)),
    oauth: oauth,
  );
  try {
    switch (arguments.single) {
      case 'login':
        final OpenAiChatGptCredential credential = await auth.loginInBrowser(
          const _VisibleBrowserLauncher(),
        );
        stdout.writeln(
          'ChatGPT login stored for account ${credential.accountId} at $credentialPath.',
        );
      case 'test':
        await _testInference(auth);
      case 'logout':
        await auth.logout();
        stdout.writeln('Local ChatGPT credentials were removed.');
    }
  } on OpenAiAuthenticationException catch (error) {
    stderr.writeln(
      'ChatGPT authentication failed [${error.code}]: ${error.message}',
    );
    exitCode = 1;
  } finally {
    oauth.close();
  }
}

Future<void> _testInference(OpenAiChatGptAuth auth) async {
  final String? endpointValue =
      Platform.environment['ADELE_OPENAI_CHATGPT_ENDPOINT'];
  final OpenAiModelProvider provider = OpenAiModelProvider.chatGpt(
    auth: auth,
    endpoint: endpointValue == null ? null : Uri.parse(endpointValue),
  );
  try {
    final String model =
        Platform.environment['ADELE_OPENAI_CHATGPT_TEST_MODEL'] ?? 'gpt-5.4';
    final List<ModelProviderEvent> events = await provider
        .invoke(
          ModelProviderRequest(
            model: model,
            instructions: 'Reply with exactly the single word OK.',
            input: <ModelProviderInput>[
              ModelProviderInput(
                kind: ModelProviderInputKind.message,
                message: ModelProviderMessage(
                  role: ModelProviderMessageRole.user,
                  content: <ModelProviderContent>[
                    ModelProviderContent(
                      kind: ModelProviderContentKind.text,
                      text:
                          'This is an ADELE experimental ChatGPT integration test.',
                    ),
                  ],
                ),
                toolProposal: null,
                toolOutcome: null,
                itemId: null,
                nativeMetadata: null,
              ),
            ],
            tools: const <ModelProviderTool>[],
            toolChoice: ModelProviderToolChoice.none,
            maxOutputTokens: null,
            providerOptions: const <String, Object?>{},
            nativeState: null,
          ),
        )
        .toList();
    final ModelProviderTerminal? terminal = events.isEmpty
        ? null
        : events.last.terminal;
    if (terminal == null ||
        terminal.settlement != ModelProviderSettlement.completed) {
      final ModelProviderFailure? failure = terminal?.failure;
      throw StateError(
        failure == null
            ? 'ChatGPT inference did not produce a completed terminal.'
            : 'ChatGPT inference failed [${failure.providerCode ?? failure.kind.name}]: ${failure.providerMessage}',
      );
    }
    final String text = events
        .map((ModelProviderEvent event) => event.output?.text)
        .whereType<String>()
        .join();
    stdout.writeln('ChatGPT Responses live test completed with model $model.');
    stdout.writeln('Authoritative output: $text');
  } finally {
    provider.close();
  }
}

final class _VisibleBrowserLauncher implements OpenAiBrowserLauncher {
  const _VisibleBrowserLauncher();

  @override
  Future<void> open(Uri uri) async {
    stdout.writeln(
      'Open this authorization URL if the browser does not launch:',
    );
    stdout.writeln(uri);
    await const DesktopOpenAiBrowserLauncher().open(uri);
  }
}
