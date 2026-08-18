import 'dart:convert';
import 'dart:io';

import 'package:openai_model_provider_backend/src/openai_chatgpt_auth.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 4) {
    stderr.writeln(
      'Usage: <credential-file> <ready-file> <instance-id> <candidate>',
    );
    exitCode = 64;
    return;
  }
  final String credentialPath = arguments[0];
  final String readyPath = arguments[1];
  final String instanceId = arguments[2];
  final String candidate = arguments[3];
  await File(readyPath).writeAsString('ready', flush: true);
  await stdin.first;

  final OpenAiCredentialState result =
      await FileOpenAiCredentialStore(File(credentialPath)).compareAndSwap(
        instanceId,
        1,
        OpenAiChatGptCredential(
          idToken: _idToken('cross-process-account'),
          accessToken: 'access-$candidate',
          refreshToken: 'refresh-$candidate',
          accountId: 'cross-process-account',
          fedRamp: false,
          expiresAt: null,
        ),
      );
  stdout.write(
    jsonEncode(<String, Object?>{
      'candidate': candidate,
      'revision': result.revision,
      'committed': result.committed,
    }),
  );
}

String _idToken(String accountId) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode(<String, Object?>{'alg': 'none'})}.${encode(<String, Object?>{
    'https://api.openai.com/auth': <String, Object?>{'chatgpt_account_id': accountId, 'chatgpt_account_is_fedramp': false},
  })}.';
}
