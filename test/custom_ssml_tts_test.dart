import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomiru/services/custom_ssml_tts.dart';

class MemorySecureStorage extends FlutterSecureStorage {
  MemorySecureStorage(this.values);
  final Map<String, String> values;

  @override
  Future<String?> read(
          {required String key,
          IOSOptions? iOptions,
          AndroidOptions? aOptions,
          LinuxOptions? lOptions,
          WebOptions? webOptions,
          MacOsOptions? mOptions,
          WindowsOptions? wOptions}) async =>
      values[key];

  @override
  Future<void> write(
      {required String key,
      required String? value,
      IOSOptions? iOptions,
      AndroidOptions? aOptions,
      LinuxOptions? lOptions,
      WebOptions? webOptions,
      MacOsOptions? mOptions,
      WindowsOptions? wOptions}) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete(
          {required String key,
          IOSOptions? iOptions,
          AndroidOptions? aOptions,
          LinuxOptions? lOptions,
          WebOptions? webOptions,
          MacOsOptions? mOptions,
          WindowsOptions? wOptions}) async =>
      values.remove(key);
}

CustomSsmlTtsConfig config(
        {CustomTtsAuthMode mode = CustomTtsAuthMode.none,
        String endpoint =
            'https://eastus.tts.speech.microsoft.com/cognitiveservices/v1'}) =>
    CustomSsmlTtsConfig(
        endpoint: endpoint,
        voiceId: 'en-US-JennyNeural',
        displayName: 'Jenny',
        locale: 'en-US',
        authMode: mode);

void main() {
  test('posts SSML, output format, returns audio bytes', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response.bytes(<int>[1, 2, 3], 200,
          headers: {'content-type': 'audio/mpeg'});
    });
    final service =
        CustomSsmlTts(client: client, secureStorage: MemorySecureStorage({}));
    final result = await service.synthesize(
        config: config(), text: 'A & B', abortTrigger: Completer<void>());
    expect(result.isSuccess, isTrue);
    expect(result.audio, Uint8List.fromList([1, 2, 3]));
    expect(captured.method, 'POST');
    expect(
        captured.headers['content-type'], startsWith('application/ssml+xml'));
    expect(captured.headers['x-microsoft-outputformat'], contains('mp3'));
    expect(captured.body, contains('A &amp; B'));
    service.close();
  });

  test('uses Azure key from secure storage and metadata excludes it', () async {
    final storage = MemorySecureStorage({});
    final service = CustomSsmlTts(
        client: MockClient((request) async {
          expect(request.headers['ocp-apim-subscription-key'], 'secret-key');
          return http.Response.bytes([4], 200,
              headers: {'content-type': 'audio/wav'});
        }),
        secureStorage: storage);
    await service.saveCredential('secret-key');
    expect(config(mode: CustomTtsAuthMode.azureKey).toMetadata().values,
        isNot(contains('secret-key')));
    final result = await service.synthesize(
        config: config(mode: CustomTtsAuthMode.azureKey),
        text: 'hello',
        abortTrigger: Completer<void>());
    expect(result.isSuccess, isTrue);
    service.close();
  });

  test('uses bearer credential; invalid endpoint rejected before request',
      () async {
    final storage =
        MemorySecureStorage({'custom_ssml_tts_credential': 'token'});
    var called = false;
    final service = CustomSsmlTts(
        client: MockClient((_) async {
          called = true;
          return http.Response.bytes([1], 200,
              headers: {'content-type': 'audio/mpeg'});
        }),
        secureStorage: storage);
    final invalid = await service.synthesize(
        config: config(
            mode: CustomTtsAuthMode.bearer, endpoint: 'http://example.org/tts'),
        text: 'x',
        abortTrigger: Completer<void>());
    expect(invalid.error?.code, CustomTtsErrorCode.invalidEndpoint);
    expect(called, isFalse);
    service.close();
  });

  test('rejects non-audio response and returns structured HTTP error',
      () async {
    final service = CustomSsmlTts(
        client: MockClient((_) async => http.Response('details', 401,
            headers: {'content-type': 'application/json'})),
        secureStorage: MemorySecureStorage({}));
    final result = await service.synthesize(
        config: config(), text: 'x', abortTrigger: Completer<void>());
    expect(result.error?.code, CustomTtsErrorCode.http);
    expect(result.error?.statusCode, 401);
    service.close();
  });

  test('reports malformed successful response as content type error', () async {
    final service = CustomSsmlTts(
        client: MockClient((_) async => http.Response('not audio', 200,
            headers: {'content-type': 'text/plain'})),
        secureStorage: MemorySecureStorage({}));
    final result = await service.synthesize(
        config: config(), text: 'x', abortTrigger: Completer<void>());
    expect(result.error?.code, CustomTtsErrorCode.invalidContentType);
    service.close();
  });

  test('lists Azure voices using the protected Key without exposing it',
      () async {
    final storage =
        MemorySecureStorage({'custom_ssml_tts_credential': 'azure-secret'});
    late http.Request captured;
    final service = CustomSsmlTts(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          '[{"ShortName":"ja-JP-NanamiNeural","LocalName":"七海","Locale":"ja-JP","Gender":"Female"}]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      secureStorage: storage,
    );
    final voices = await service.listAzureVoices(
      endpoint: 'https://eastus.tts.speech.microsoft.com/cognitiveservices/v1',
      locale: 'ja-JP',
    );
    expect(captured.method, 'GET');
    expect(captured.url.path, '/cognitiveservices/voices/list');
    expect(captured.url.queryParameters['language'], 'ja-JP');
    expect(captured.headers['ocp-apim-subscription-key'], 'azure-secret');
    expect(voices.single.id, 'ja-JP-NanamiNeural');
    expect(voices.single.locale, 'ja-JP');
    service.close();
  });

  test('Azure catalog uses a draft key without persisting it', () async {
    final values = {'custom_ssml_tts_credential': 'previous-key'};
    final service = CustomSsmlTts(
      client: MockClient((request) async {
        expect(request.headers['ocp-apim-subscription-key'], 'draft-key');
        return http.Response('[]', 200);
      }),
      secureStorage: MemorySecureStorage(values),
    );
    addTearDown(service.close);
    final voices = await service.listAzureVoices(
      endpoint: 'https://eastus.tts.speech.microsoft.com/cognitiveservices/v1',
      credentialOverride: ' draft-key ',
    );
    expect(voices, isEmpty);
    expect(values, {'custom_ssml_tts_credential': 'previous-key'});
  });

  test('failed Azure catalog with draft key leaves stored credential intact',
      () async {
    final values = {'custom_ssml_tts_credential': 'previous-key'};
    final service = CustomSsmlTts(
      client: MockClient((request) async {
        expect(request.headers['ocp-apim-subscription-key'], 'draft-key');
        return http.Response('credential-rejected', 401);
      }),
      secureStorage: MemorySecureStorage(values),
    );
    addTearDown(service.close);
    await expectLater(
      service.listAzureVoices(
        endpoint:
            'https://eastus.tts.speech.microsoft.com/cognitiveservices/v1',
        credentialOverride: 'draft-key',
      ),
      throwsA(isA<CustomTtsError>()
          .having((error) => error.statusCode, 'statusCode', 401)),
    );
    expect(values, {'custom_ssml_tts_credential': 'previous-key'});
  });

  test('empty draft catalog key does not silently use saved credential',
      () async {
    var requested = false;
    final service = CustomSsmlTts(
      client: MockClient((_) async {
        requested = true;
        return http.Response('[]', 200);
      }),
      secureStorage:
          MemorySecureStorage({'custom_ssml_tts_credential': 'previous-key'}),
    );
    addTearDown(service.close);
    await expectLater(
      service.listAzureVoices(
        endpoint:
            'https://eastus.tts.speech.microsoft.com/cognitiveservices/v1',
        credentialOverride: '',
      ),
      throwsA(isA<CustomTtsError>().having(
          (error) => error.code, 'code', CustomTtsErrorCode.missingCredential)),
    );
    expect(requested, isFalse);
  });

  test('cancellation returns cancellation error without leaking request',
      () async {
    final completer = Completer<void>();
    final trigger = completer;
    final service = CustomSsmlTts(
        client: MockClient((_) async => http.Response.bytes([1], 200,
            headers: {'content-type': 'audio/mpeg'})),
        secureStorage: MemorySecureStorage({}));
    trigger.complete();
    final result = await service.synthesize(
        config: config(), text: 'x', abortTrigger: trigger);
    expect(result.error?.code, CustomTtsErrorCode.cancelled);
    service.close();
  });
}
