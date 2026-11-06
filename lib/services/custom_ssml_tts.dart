import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Authentication mode for the Microsoft-compatible Speech REST endpoint.
enum CustomTtsAuthMode { none, azureKey, bearer }

Map<String, String> _safeStringMap(Object? value) {
  if (value is! Map) return const <String, String>{};
  return <String, String>{
    for (final entry in value.entries)
      if (entry.key is String &&
          entry.value is String &&
          (entry.value as String).trim().isNotEmpty)
        entry.key as String: (entry.value as String).trim(),
  };
}

/// Non-secret settings. Credentials are deliberately kept outside this object.
class CustomSsmlTtsConfig {
  const CustomSsmlTtsConfig({
    required this.endpoint,
    required this.voiceId,
    required this.displayName,
    required this.locale,
    required this.authMode,
    this.audioFormat = 'audio-24khz-48kbitrate-mono-mp3',
    this.timeout = const Duration(seconds: 30),
    this.voiceByLanguage = const <String, String>{},
    this.localeByLanguage = const <String, String>{},
  });

  final String endpoint;
  final String voiceId;
  final String displayName;
  final String locale;
  final CustomTtsAuthMode authMode;
  final String audioFormat;
  final Duration timeout;
  final Map<String, String> voiceByLanguage;
  final Map<String, String> localeByLanguage;

  /// Safe for ordinary preferences; contains metadata only, never a credential.
  Map<String, Object> toMetadata() => <String, Object>{
        'endpoint': endpoint,
        'voiceId': voiceId,
        'displayName': displayName,
        'locale': locale,
        'authMode': authMode.name,
        'audioFormat': audioFormat,
        'timeoutMs': timeout.inMilliseconds,
        'voiceByLanguage': voiceByLanguage,
        'localeByLanguage': localeByLanguage,
      };

  factory CustomSsmlTtsConfig.fromMetadata(Map<String, dynamic> value) {
    final mode = CustomTtsAuthMode.values.firstWhere(
      (item) => item.name == value['authMode'],
      orElse: () => CustomTtsAuthMode.none,
    );
    return CustomSsmlTtsConfig(
      endpoint: value['endpoint'] as String? ?? '',
      voiceId: value['voiceId'] as String? ?? '',
      displayName: value['displayName'] as String? ?? '',
      locale: value['locale'] as String? ?? '',
      authMode: mode,
      audioFormat:
          value['audioFormat'] as String? ?? 'audio-24khz-48kbitrate-mono-mp3',
      timeout: Duration(milliseconds: value['timeoutMs'] as int? ?? 30000),
      voiceByLanguage: _safeStringMap(value['voiceByLanguage']),
      localeByLanguage: _safeStringMap(value['localeByLanguage']),
    );
  }
}

enum CustomTtsErrorCode {
  invalidEndpoint,
  missingCredential,
  timeout,
  cancelled,
  network,
  http,
  invalidContentType,
  emptyAudio,
  invalidConfiguration,
}

class CustomTtsError implements Exception {
  const CustomTtsError(this.code, this.message, {this.statusCode});
  final CustomTtsErrorCode code;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'CustomTtsError(${code.name}, $message)';
}

class AzureSpeechVoice {
  const AzureSpeechVoice({
    required this.id,
    required this.name,
    required this.locale,
    this.gender,
  });

  final String id;
  final String name;
  final String locale;
  final String? gender;
}

class CustomTtsResult {
  const CustomTtsResult._(this.audio, this.error);
  const CustomTtsResult.success(Uint8List audio) : this._(audio, null);
  const CustomTtsResult.failure(CustomTtsError error) : this._(null, error);
  final Uint8List? audio;
  final CustomTtsError? error;
  bool get isSuccess => audio != null;
}

/// Makes a synthesizer request; it does not play or otherwise own the audio.
class CustomSsmlTts {
  CustomSsmlTts({
    http.Client? client,
    FlutterSecureStorage? secureStorage,
    this.credentialStorageKey = 'custom_ssml_tts_credential',
  })  : _client = client ?? http.Client(),
        _storage = secureStorage ?? const FlutterSecureStorage();

  final http.Client _client;
  final FlutterSecureStorage _storage;
  final String credentialStorageKey;

  /// Save only API key/Bearer token here; secure storage encrypts it on device.
  Future<void> saveCredential(String credential) async {
    await _storage.write(key: credentialStorageKey, value: credential);
  }

  Future<void> clearCredential() => _storage.delete(key: credentialStorageKey);

  /// Fetch the Azure Neural voice catalog using a draft or securely stored key.
  /// [credentialOverride] is request-only and is never persisted.
  /// The result is limited to the requested locale when the service supports it.
  Future<List<AzureSpeechVoice>> listAzureVoices({
    required String endpoint,
    String? locale,
    String? credentialOverride,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final source = Uri.tryParse(endpoint.trim());
    if (source == null ||
        source.scheme.toLowerCase() != 'https' ||
        source.host.isEmpty ||
        source.userInfo.isNotEmpty ||
        (source.hasPort && source.port != 443) ||
        !source.host.toLowerCase().endsWith('.tts.speech.microsoft.com')) {
      throw const CustomTtsError(
        CustomTtsErrorCode.invalidEndpoint,
        'Azure voice discovery requires a regional HTTPS Speech endpoint.',
      );
    }
    final key = (credentialOverride ??
            await _storage.read(key: credentialStorageKey) ??
            '')
        .trim();
    if (key.isEmpty || key.contains('\r') || key.contains('\n')) {
      throw const CustomTtsError(
        CustomTtsErrorCode.missingCredential,
        'Azure Speech Key is required to list voices.',
      );
    }
    final uri = source.replace(
      path: '/cognitiveservices/voices/list',
      queryParameters: locale == null || locale.trim().isEmpty
          ? null
          : <String, String>{'language': locale.trim()},
    );
    try {
      final response = await _client.get(uri, headers: <String, String>{
        'Ocp-Apim-Subscription-Key': key,
        'User-Agent': 'Yomiru-Custom-SSML-TTS',
      }).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CustomTtsError(
          CustomTtsErrorCode.http,
          'Azure voice list returned HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
        );
      }
      final raw = jsonDecode(response.body);
      if (raw is! List) {
        throw const CustomTtsError(
          CustomTtsErrorCode.invalidConfiguration,
          'Azure voice list response format is invalid.',
        );
      }
      return raw
          .whereType<Map>()
          .map((value) {
            final id =
                value['ShortName'] ?? value['shortName'] ?? value['Name'];
            final name = value['LocalName'] ?? value['localName'] ?? id;
            final language = value['Locale'] ?? value['locale'];
            final gender = value['Gender'] ?? value['gender'];
            return AzureSpeechVoice(
              id: id is String ? id : '',
              name: name is String ? name : (id is String ? id : ''),
              locale: language is String ? language : '',
              gender: gender is String ? gender : null,
            );
          })
          .where((voice) => voice.id.isNotEmpty && voice.locale.isNotEmpty)
          .toList();
    } on TimeoutException {
      throw const CustomTtsError(
        CustomTtsErrorCode.timeout,
        'Azure voice list request timed out.',
      );
    } on CustomTtsError {
      rethrow;
    } catch (_) {
      throw const CustomTtsError(
        CustomTtsErrorCode.network,
        'Azure voice list request failed.',
      );
    }
  }

  Future<CustomTtsResult> synthesize({
    required CustomSsmlTtsConfig config,
    required String text,
    Completer<void>? abortTrigger,
    String? credentialOverride,
    double rate = 1.0,
  }) async {
    final uri = Uri.tryParse(config.endpoint.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.port != 443 && uri.hasPort)) {
      return const CustomTtsResult.failure(CustomTtsError(
        CustomTtsErrorCode.invalidEndpoint,
        'Endpoint must be an HTTPS URL on the default port.',
      ));
    }
    if (config.voiceId.trim().isEmpty ||
        config.locale.trim().isEmpty ||
        text.trim().isEmpty ||
        config.timeout <= Duration.zero ||
        config.audioFormat.trim().isEmpty ||
        !rate.isFinite ||
        rate < 0.5 ||
        rate > 3.0) {
      return const CustomTtsResult.failure(CustomTtsError(
        CustomTtsErrorCode.invalidConfiguration,
        'Voice, locale, text, format, and positive timeout are required.',
      ));
    }

    var credential = '';
    if (config.authMode != CustomTtsAuthMode.none) {
      try {
        credential = (credentialOverride ??
                await _storage.read(key: credentialStorageKey) ??
                '')
            .trim();
      } catch (_) {
        return const CustomTtsResult.failure(CustomTtsError(
          CustomTtsErrorCode.missingCredential,
          'Credential is unavailable in secure storage.',
        ));
      }
      if (credential.isEmpty ||
          credential.contains('\r') ||
          credential.contains('\n')) {
        return const CustomTtsResult.failure(CustomTtsError(
          CustomTtsErrorCode.missingCredential,
          'A credential is required for the selected authentication mode.',
        ));
      }
    }

    final headers = <String, String>{
      'Content-Type': 'application/ssml+xml',
      'X-Microsoft-OutputFormat': config.audioFormat,
      'User-Agent': 'Yomiru-Custom-SSML-TTS',
    };
    switch (config.authMode) {
      case CustomTtsAuthMode.none:
        break;
      case CustomTtsAuthMode.azureKey:
        headers['Ocp-Apim-Subscription-Key'] = credential;
        break;
      case CustomTtsAuthMode.bearer:
        headers['Authorization'] = 'Bearer $credential';
        break;
    }
    final ratePercent = ((rate - 1.0) * 100).round();
    final rateValue = '${ratePercent >= 0 ? '+' : ''}$ratePercent%';
    final ssml =
        '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="${_escape(config.locale)}"><voice name="${_escape(config.voiceId)}"><prosody rate="$rateValue">${_escape(text)}</prosody></voice></speak>';
    if (abortTrigger?.isCompleted ?? false) {
      return const CustomTtsResult.failure(CustomTtsError(
        CustomTtsErrorCode.cancelled,
        'Speech request was cancelled.',
      ));
    }
    try {
      final request =
          http.AbortableRequest('POST', uri, abortTrigger: abortTrigger?.future)
            ..headers.addAll(headers)
            ..followRedirects = false
            ..body = ssml;
      final streamed = await _client.send(request).timeout(config.timeout);
      final response =
          await http.Response.fromStream(streamed).timeout(config.timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return CustomTtsResult.failure(CustomTtsError(
          CustomTtsErrorCode.http,
          'Speech service returned HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
        ));
      }
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      if (!contentType.startsWith('audio/')) {
        return const CustomTtsResult.failure(CustomTtsError(
          CustomTtsErrorCode.invalidContentType,
          'Speech service response was not an audio content type.',
        ));
      }
      if (response.bodyBytes.isEmpty) {
        return const CustomTtsResult.failure(CustomTtsError(
          CustomTtsErrorCode.emptyAudio,
          'Speech service returned an empty audio body.',
        ));
      }
      return CustomTtsResult.success(Uint8List.fromList(response.bodyBytes));
    } on http.RequestAbortedException {
      return const CustomTtsResult.failure(CustomTtsError(
        CustomTtsErrorCode.cancelled,
        'Speech request was cancelled.',
      ));
    } on TimeoutException {
      return const CustomTtsResult.failure(CustomTtsError(
        CustomTtsErrorCode.timeout,
        'Speech request timed out.',
      ));
    } catch (_) {
      // Avoid serializing exception/request details: they may contain credentials.
      return const CustomTtsResult.failure(CustomTtsError(
        CustomTtsErrorCode.network,
        'Speech request failed due to a network error.',
      ));
    }
  }

  static String _escape(String input) => const HtmlEscape().convert(input);

  void close() => _client.close();
}

/// Convenience factory for a cancellation trigger controlled by the caller.
Completer<void> createCustomTtsAbortTrigger() => Completer<void>();

/// Build a secure-storage-backed provider while keeping test injection simple.
FlutterSecureStorage defaultCustomTtsSecureStorage() =>
    const FlutterSecureStorage();

/// Parses JSON metadata without ever handling credential fields.
Map<String, dynamic> decodeCustomTtsMetadata(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

/// Encodes non-secret metadata for preferences storage.
String encodeCustomTtsMetadata(CustomSsmlTtsConfig config) =>
    jsonEncode(config.toMetadata());

/// A small seam useful to callers that want to share a configured HTTP client.
http.Client createCustomTtsHttpClient() => http.Client();

/// Cancellation signal type accepted by package:http AbortableRequest.
typedef AbortTrigger = Future<void>;

/// Expose the standard secure storage implementation as an injectable adapter.
typedef CustomTtsSecureStorage = FlutterSecureStorage;

/// Creates a completer that callers can complete to cancel a preview request.
Completer<void> customTtsAbortRequest() => Completer<void>();

/// Utility to ensure endpoint is accepted without performing network I/O.
bool isValidCustomTtsEndpoint(String endpoint) {
  final uri = Uri.tryParse(endpoint.trim());
  return uri != null &&
      uri.scheme.toLowerCase() == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443);
}

/// Safe diagnostic representation intentionally omits secrets and request data.
String customTtsSafeError(CustomTtsError error) =>
    '${error.code.name}: ${error.message}';

/// Standard Azure Speech REST synthesis path is supplied by the configured endpoint.
String customTtsSsmlDocument(
        {required String locale,
        required String voiceId,
        required String text}) =>
    '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="${CustomSsmlTts._escape(locale)}"><voice name="${CustomSsmlTts._escape(voiceId)}">${CustomSsmlTts._escape(text)}</voice></speak>';

/// Convert auth mode to a stable metadata value.
String customTtsAuthModeName(CustomTtsAuthMode mode) => mode.name;

/// Parse auth mode metadata, defaulting safely to no authentication.
CustomTtsAuthMode parseCustomTtsAuthMode(String? value) =>
    CustomTtsAuthMode.values.where((mode) => mode.name == value).firstOrNull ??
    CustomTtsAuthMode.none;

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Tiny utility for tools that need a UTF-8 view of an SSML document.
Uint8List customTtsUtf8(String value) => Uint8List.fromList(utf8.encode(value));

/// Format expected by Azure Speech service for the configured output audio.
const String defaultCustomTtsAudioFormat = 'audio-24khz-48kbitrate-mono-mp3';

/// Authentication header names are constants to simplify mock assertions.
const String azureSpeechKeyHeader = 'Ocp-Apim-Subscription-Key';
const String azureSpeechBearerHeader = 'Authorization';
const String azureSpeechFormatHeader = 'X-Microsoft-OutputFormat';

/// SSML request media type.
const String azureSpeechSsmlContentType = 'application/ssml+xml';

/// Default service request timeout.
const Duration defaultCustomTtsTimeout = Duration(seconds: 30);

/// Generic auth-free endpoint template for compatible Microsoft Speech REST APIs.
const String defaultMicrosoftSpeechEndpoint =
    'https://[region].tts.speech.microsoft.com/cognitiveservices/v1';

/// Friendly voice display-name metadata accessor.
String customTtsDisplayName(CustomSsmlTtsConfig config) => config.displayName;

/// Locale metadata accessor.
String customTtsLocale(CustomSsmlTtsConfig config) => config.locale;

/// Voice identifier accessor.
String customTtsVoiceId(CustomSsmlTtsConfig config) => config.voiceId;

/// Endpoint accessor.
String customTtsEndpoint(CustomSsmlTtsConfig config) => config.endpoint;

/// No-secret metadata serializer alias.
Map<String, Object> customTtsMetadata(CustomSsmlTtsConfig config) =>
    config.toMetadata();

/// Validate that returned content type is an audio MIME type.
bool isCustomTtsAudioContentType(String? contentType) =>
    contentType?.toLowerCase().startsWith('audio/') ?? false;

/// Build a request body independently for deterministic unit tests.
String buildCustomTtsSsml(CustomSsmlTtsConfig config, String text) =>
    customTtsSsmlDocument(
        locale: config.locale, voiceId: config.voiceId, text: text);

/// Closeable wrapper functionality remains in [CustomSsmlTts].
