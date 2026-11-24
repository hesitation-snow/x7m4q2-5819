import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/lk_client.dart';
import '../reader/reader_language_segments.dart';
import 'edge_speech.dart';

/// Shared account-scoped persistence for reader listening (TTS) preferences.
@immutable
class ReaderTtsPreferences {
  const ReaderTtsPreferences({
    this.sourceMode = 'online',
    this.rate = 1.0,
    this.systemEngineId,
    this.systemVoiceId,
    this.systemVoiceByLanguage = const <String, String>{},
    this.edgeVoiceByLanguage = const <String, String>{},
    this.languageFilter = ReaderLanguageFilter.automatic,
    this.segmentInterval = Duration.zero,
    this.sleepTimer = PlaybackSleepTimer.none,
    this.continuousChapter = false,
  });

  static const ReaderTtsPreferences defaults = ReaderTtsPreferences();

  /// Incremented whenever preferences are saved from Settings or Reader so
  /// open pages stay in sync.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final String sourceMode;
  final double rate;
  final String? systemEngineId;
  final String? systemVoiceId;
  final Map<String, String> systemVoiceByLanguage;
  final Map<String, String> edgeVoiceByLanguage;
  final ReaderLanguageFilter languageFilter;
  final Duration segmentInterval;
  final PlaybackSleepTimer sleepTimer;
  final bool continuousChapter;

  static String accountKeyForUid(int uid) => uid > 0 ? 'uid:$uid' : 'guest';

  static String currentAccountKey() =>
      accountKeyForUid(LKClient.shared.session.uid);

  static String preferencesKey(String accountKey) =>
      'reader_tts_preferences_v1_${Uri.encodeComponent(accountKey)}';

  static String customMetadataKey(String accountKey) =>
      'custom_ssml_tts_metadata_${Uri.encodeComponent(accountKey)}';

  static String customCredentialKey(String accountKey) =>
      'custom_ssml_tts_credential_${Uri.encodeComponent(accountKey)}';

  String get sourceLabel => switch (sourceMode) {
        'system' => '系统引擎',
        'custom' => '自定义语音',
        _ => '在线自然音',
      };

  String get summaryLabel => '$sourceLabel · ${rate.toStringAsFixed(2)}×';

  ReaderTtsPreferences copyWith({
    String? sourceMode,
    double? rate,
    String? systemEngineId,
    bool clearSystemEngineId = false,
    String? systemVoiceId,
    bool clearSystemVoiceId = false,
    Map<String, String>? systemVoiceByLanguage,
    Map<String, String>? edgeVoiceByLanguage,
    ReaderLanguageFilter? languageFilter,
    Duration? segmentInterval,
    PlaybackSleepTimer? sleepTimer,
    bool? continuousChapter,
  }) {
    return ReaderTtsPreferences(
      sourceMode: sourceMode ?? this.sourceMode,
      rate: (rate ?? this.rate).clamp(0.5, 3.0).toDouble(),
      systemEngineId:
          clearSystemEngineId ? null : (systemEngineId ?? this.systemEngineId),
      systemVoiceId:
          clearSystemVoiceId ? null : (systemVoiceId ?? this.systemVoiceId),
      systemVoiceByLanguage: systemVoiceByLanguage != null
          ? Map<String, String>.unmodifiable(systemVoiceByLanguage)
          : this.systemVoiceByLanguage,
      edgeVoiceByLanguage: edgeVoiceByLanguage != null
          ? Map<String, String>.unmodifiable(edgeVoiceByLanguage)
          : this.edgeVoiceByLanguage,
      languageFilter: languageFilter ?? this.languageFilter,
      segmentInterval: segmentInterval ?? this.segmentInterval,
      sleepTimer: sleepTimer ?? this.sleepTimer,
      continuousChapter: continuousChapter ?? this.continuousChapter,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'source': sourceMode,
        'rate': rate,
        'systemVoice': systemVoiceId,
        'systemEngine': systemEngineId,
        'voiceByLanguage': systemVoiceByLanguage,
        'edgeVoiceByLanguage': edgeVoiceByLanguage,
        'languageFilter': languageFilter.name,
        'segmentIntervalMs': segmentInterval.inMilliseconds,
        'sleepTimer': sleepTimer.name,
        'continuousChapter': continuousChapter,
      };

  static ReaderTtsPreferences fromJson(Map<Object?, Object?> values) {
    final source = values['source'];
    final filter = values['languageFilter'];
    final sleep = values['sleepTimer'];
    final voiceMap = values['voiceByLanguage'];
    final edgeMap = values['edgeVoiceByLanguage'];

    final systemVoices = <String, String>{};
    if (voiceMap is Map) {
      for (final entry in voiceMap.entries) {
        if (entry.key is String && entry.value is String) {
          systemVoices[entry.key as String] = entry.value as String;
        }
      }
    }

    final edgeVoices = <String, String>{};
    if (edgeMap is Map) {
      for (final entry in edgeMap.entries) {
        if (entry.key is String &&
            entry.value is String &&
            edgeVoiceById(entry.value as String)?.language == entry.key) {
          edgeVoices[entry.key as String] = entry.value as String;
        }
      }
    }

    final rawSource = source == 'gpt_sovits'
        ? 'online'
        : source is String &&
                const {'system', 'online', 'custom'}.contains(source)
            ? source
            : 'online';

    return ReaderTtsPreferences(
      sourceMode: rawSource,
      rate: ((values['rate'] as num?)?.toDouble() ?? 1.0)
          .clamp(0.5, 3.0)
          .toDouble(),
      systemEngineId: values['systemEngine'] as String?,
      systemVoiceId: values['systemVoice'] as String?,
      systemVoiceByLanguage: Map<String, String>.unmodifiable(systemVoices),
      edgeVoiceByLanguage: Map<String, String>.unmodifiable(edgeVoices),
      languageFilter: ReaderLanguageFilter.values.firstWhere(
        (value) => value.name == filter,
        orElse: () => ReaderLanguageFilter.automatic,
      ),
      segmentInterval: Duration(
        milliseconds: (values['segmentIntervalMs'] as num?)?.toInt() ?? 0,
      ),
      sleepTimer: PlaybackSleepTimer.values.firstWhere(
        (value) => value.name == sleep,
        orElse: () => PlaybackSleepTimer.none,
      ),
      continuousChapter: values['continuousChapter'] == true,
    );
  }

  static Future<ReaderTtsPreferences?> loadOrNull([String? accountKey]) async {
    final key = accountKey ?? currentAccountKey();
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(preferencesKey(key));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  static Future<ReaderTtsPreferences> load([String? accountKey]) async {
    return (await loadOrNull(accountKey)) ?? defaults;
  }

  static Future<void> save(
    ReaderTtsPreferences value, {
    String? accountKey,
  }) async {
    final key = accountKey ?? currentAccountKey();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      preferencesKey(key),
      jsonEncode(value.toJson()),
    );
    revision.value++;
  }
}
