import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../services/custom_ssml_tts.dart';
import '../services/system_tts.dart';
import 'reader_language_segments.dart';
import 'reader_tts_core.dart';
import 'reader_speech_session.dart';

/// Synthesizes offline speech through the selected Android TTS engine into a
/// WAV file inside Yomiru's temporary speech cache.
class SystemFileSpeechSynthesizer implements SpeechAudioSynthesizer {
  SystemFileSpeechSynthesizer(this.systemTts);
  final SystemTts systemTts;

  @override
  Future<File> synthesize(
    String text,
    SpeechSynthesisConfig config,
    String cachePath,
  ) async {
    if (config.source != 'system') {
      throw ArgumentError.value(config.source, 'source', 'Expected system TTS');
    }
    final language = const ReaderLanguageSegments()
        .classify(<TtsSegment>[
          TtsSegment(
            blockIndex: 0,
            startOffset: 0,
            endOffset: text.length,
            text: text,
          ),
        ])
        .first
        .language
        .name;
    final overrides = config.options['voiceByLanguage'];
    final locales = config.options['localeByLanguage'];
    String? selectedVoice =
        config.voice.isEmpty || config.voice == 'default' ? null : config.voice;
    String? selectedLocale = config.language;
    if (overrides is Map && overrides[language] is String) {
      selectedVoice = overrides[language] as String;
    }
    if (locales is Map && locales[language] is String) {
      selectedLocale = locales[language] as String;
    }
    final catalog = config.options['voiceCatalog'];
    if (selectedVoice != null && catalog is List) {
      for (final raw in catalog.whereType<Map>()) {
        if (raw['id'] == selectedVoice && raw['locale'] is String) {
          selectedLocale = raw['locale'] as String;
          break;
        }
      }
    }
    if (selectedVoice == null && catalog is List) {
      final prefix = switch (language) {
        'japanese' => 'ja',
        'korean' => 'ko',
        'chinese' => 'zh',
        _ => '',
      };
      for (final raw in catalog.whereType<Map>()) {
        final locale = raw['locale'];
        final id = raw['id'];
        if (prefix.isNotEmpty &&
            locale is String &&
            locale.toLowerCase().startsWith(prefix) &&
            id is String) {
          selectedLocale = locale;
          selectedVoice = id;
          break;
        }
      }
    }
    final path = await systemTts.synthesizeToFile(
      text,
      cachePath,
      selectedLocale,
      selectedVoice,
      config.rate,
    );
    return File(path);
  }
}

/// Synthesizes speech through an Azure-compatible SSML REST endpoint.
/// Credentials are resolved by CustomSsmlTts from secure storage; this config
/// object only contains endpoint and voice metadata.
class CustomFileSpeechSynthesizer implements SpeechAudioSynthesizer {
  CustomFileSpeechSynthesizer({
    required this.client,
    required this.configFor,
  });

  final CustomSsmlTts client;
  final CustomSsmlTtsConfig Function(SpeechSynthesisConfig config) configFor;

  @override
  Future<File> synthesize(
    String text,
    SpeechSynthesisConfig config,
    String cachePath,
  ) async {
    final localized = localizeSpeechConfig(config, text);
    final result = await client.synthesize(
      config: configFor(localized),
      text: text,
      rate: localized.rate,
    );
    final bytes = result.audio;
    if (bytes == null || bytes.isEmpty) {
      throw result.error ??
          const CustomTtsError(
            CustomTtsErrorCode.emptyAudio,
            'Speech service returned no audio.',
          );
    }
    final file = File(cachePath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}

/// Built-in Microsoft Azure Neural TTS preset. The caller stores the Azure
/// subscription key in a CustomSsmlTts instance dedicated to this provider.
class AzureNeuralSpeechSynthesizer extends CustomFileSpeechSynthesizer {
  AzureNeuralSpeechSynthesizer({
    required super.client,
    required String Function(SpeechSynthesisConfig config) regionFor,
  }) : super(
          configFor: (config) => azureNeuralConfigFor(
            config,
            region: regionFor(config),
          ),
        );
}

CustomSsmlTtsConfig azureNeuralConfigFor(
  SpeechSynthesisConfig config, {
  required String region,
}) {
  final normalizedRegion = region.trim();
  if (!RegExp(r'^[a-z0-9-]+$', caseSensitive: false)
      .hasMatch(normalizedRegion)) {
    throw const CustomTtsError(
      CustomTtsErrorCode.invalidConfiguration,
      'Azure Speech region is invalid.',
    );
  }
  return CustomSsmlTtsConfig(
    endpoint:
        'https://$normalizedRegion.tts.speech.microsoft.com/cognitiveservices/v1',
    voiceId: config.voice,
    displayName: config.voice,
    locale: config.language,
    authMode: CustomTtsAuthMode.azureKey,
    audioFormat:
        config.options['audioFormat'] as String? ?? defaultCustomTtsAudioFormat,
  );
}

SpeechSynthesisConfig localizeSpeechConfig(
  SpeechSynthesisConfig config,
  String text,
) {
  final language = const ReaderLanguageSegments()
      .classify(<TtsSegment>[
        TtsSegment(
          blockIndex: 0,
          startOffset: 0,
          endOffset: text.length,
          text: text,
        ),
      ])
      .first
      .language
      .name;
  final voices = config.options['voiceByLanguage'];
  final locales = config.options['localeByLanguage'];
  final voice = voices is Map && voices[language] is String
      ? voices[language] as String
      : config.voice;
  final localeOverride = locales is Map && locales[language] is String
      ? locales[language] as String
      : null;
  final inferredLocale = RegExp(r'^(zh|ja|ko)-[A-Za-z0-9]+-[^ ]+')
      .firstMatch(voice)
      ?.group(0)
      ?.split('-')
      .take(2)
      .join('-');
  return SpeechSynthesisConfig(
    source: config.source,
    voice: voice,
    language: localeOverride ?? inferredLocale ?? config.language,
    rate: config.rate,
    options: config.options,
    fileExtension: config.fileExtension,
  );
}

CustomSsmlTtsConfig customConfigFromSpeech(SpeechSynthesisConfig config) {
  final rawMode = config.options['authMode'] as String?;
  final mode = CustomTtsAuthMode.values.firstWhere(
    (value) => value.name == rawMode,
    orElse: () => CustomTtsAuthMode.none,
  );
  return CustomSsmlTtsConfig(
    endpoint: config.options['endpoint'] as String? ?? '',
    voiceId: config.voice,
    displayName: config.options['displayName'] as String? ?? config.voice,
    locale: config.language,
    authMode: mode,
    audioFormat:
        config.options['audioFormat'] as String? ?? defaultCustomTtsAudioFormat,
  );
}

class ConfiguredCustomSpeechSynthesizer extends CustomFileSpeechSynthesizer {
  ConfiguredCustomSpeechSynthesizer({required super.client})
      : super(configFor: customConfigFromSpeech);
}

/// Parse a persisted custom TTS metadata map and turn it into a cache-safe
/// config. The auth credential itself is deliberately absent from the map.
SpeechSynthesisConfig speechConfigFromCustomMetadata(
  Map<String, dynamic> metadata, {
  required double rate,
}) {
  final custom = CustomSsmlTtsConfig.fromMetadata(metadata);
  return SpeechSynthesisConfig(
    source: 'custom',
    voice: custom.voiceId,
    language: custom.locale,
    rate: rate,
    fileExtension: 'mp3',
    options: <String, Object?>{
      'endpoint': custom.endpoint,
      'authMode': custom.authMode.name,
      'displayName': custom.displayName,
      'audioFormat': custom.audioFormat,
      'voiceByLanguage': custom.voiceByLanguage,
      'localeByLanguage': custom.localeByLanguage,
    },
  );
}

/// A cache identity for the official Azure preset; no secret is included.
SpeechSynthesisConfig azureSpeechConfig({
  required String region,
  required String voice,
  required String language,
  required double rate,
}) =>
    SpeechSynthesisConfig(
      source: 'cloud',
      voice: voice,
      language: language,
      rate: rate,
      fileExtension: 'mp3',
      options: <String, Object?>{'region': region},
    );

/// A cache identity for the system engine; native engine/voice IDs remain
/// explicit so changing voices never reuses audio generated by another voice.
SpeechSynthesisConfig systemSpeechConfig({
  String? engineId,
  required String voice,
  required String language,
  required double rate,
  Iterable<SystemTtsVoice> availableVoices = const [],
  Map<String, String> voiceByLanguage = const {},
  Map<String, String> localeByLanguage = const {},
}) =>
    SpeechSynthesisConfig(
      source: 'system',
      voice: voice,
      language: language,
      rate: rate,
      fileExtension: 'wav',
      options: <String, Object?>{
        'engineId': engineId ?? 'default',
        'voiceCatalog': [
          for (final item in availableVoices)
            if (item.locale != null)
              <String, String>{'id': item.id, 'locale': item.locale!},
        ],
        'voiceByLanguage': Map<String, String>.unmodifiable(voiceByLanguage),
        'localeByLanguage': Map<String, String>.unmodifiable(localeByLanguage),
      },
    );

/// Synthesizes speech through GPT-SoVITS local voice packs or HTTP inference API.
class GptSoVitsSpeechSynthesizer implements SpeechAudioSynthesizer {
  GptSoVitsSpeechSynthesizer({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<File> synthesize(
    String text,
    SpeechSynthesisConfig config,
    String cachePath,
  ) async {
    final endpoint = config.options['apiEndpoint'] as String?;
    if (endpoint != null && endpoint.trim().isNotEmpty) {
      final uri = Uri.parse(endpoint.trim());
      final payload = jsonEncode({
        'text': text,
        'text_lang': config.language,
        'ref_audio_path': config.options['refAudioPath'] ?? '',
        'prompt_text': config.options['promptText'] ?? '',
        'prompt_lang': config.options['promptLang'] ?? 'ja',
        'top_k': config.options['top_k'] ?? 10,
        'top_p': config.options['top_p'] ?? 0.75,
        'temperature': config.options['temperature'] ?? 0.65,
        'speed_factor': config.rate,
        'media_type': 'wav',
        'streaming_mode': false,
      });

      final response = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: payload,
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw SystemTtsException(
          'GPT-SoVITS API 返回状态码 ${response.statusCode}',
          code: 'GPTSOVITS_HTTP_${response.statusCode}',
        );
      }
      final file = File(cachePath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(response.bodyBytes, flush: true);
      return file;
    }

    // A desktop export and an ORT dependency are not a mobile inference backend.
    // Never create/cache fake audio or silently send text to a remote service.
    throw const SystemTtsException(
      '本地 GPT-SoVITS 推理后端尚未实现，此版本暂不可用；声线包不是可直接播放的音频。',
      code: 'LOCAL_GPTSOVITS_NOT_IMPLEMENTED',
    );
  }
}

/// Helper to build a cache-safe config for GPT-SoVITS inference.
SpeechSynthesisConfig gptSoVitsSpeechConfig({
  required String voiceId,
  required String language,
  required double rate,
  String? packDir,
  String? apiEndpoint,
  String? refAudioPath,
  String? promptText,
  String? promptLang,
  int topK = 10,
  double topP = 0.75,
  double temperature = 0.65,
}) =>
    SpeechSynthesisConfig(
      source: 'gpt_sovits',
      voice: voiceId,
      language: language,
      rate: rate,
      fileExtension: 'wav',
      options: <String, Object?>{
        'packDir': packDir,
        'apiEndpoint': apiEndpoint,
        'refAudioPath': refAudioPath,
        'promptText': promptText,
        'promptLang': promptLang ?? 'ja',
        'top_k': topK,
        'top_p': topP,
        'temperature': temperature,
      },
    );
