import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/lk_client.dart';
import '../services/app_motion.dart';
import '../services/custom_ssml_tts.dart';
import '../services/listening_now.dart';
import '../services/reader_audio_bootstrap.dart';
import '../services/reader_audio_handler.dart';
import '../services/reader_tts_preferences.dart';
import '../services/system_tts.dart';
import '../widgets/m3_controls.dart';
import '../widgets/reader_listening_sheet.dart';
import '../widgets/tts_settings_sections.dart';
import 'custom_tts_settings_page.dart';

class TtsSettingsPage extends StatefulWidget {
  const TtsSettingsPage({
    super.key,
    this.systemTts,
  });

  final SystemTts? systemTts;

  @override
  State<TtsSettingsPage> createState() => _TtsSettingsPageState();
}

class _TtsSettingsPageState extends State<TtsSettingsPage> {
  late final SystemTts _systemTts;
  late final bool _ownsSystemTts;

  ReaderTtsPreferences _prefs = ReaderTtsPreferences.defaults;
  bool _loading = true;
  bool _changingSource = false;

  List<SystemTtsEngine> _engines = const [];
  bool _enginesLoading = false;
  String? _engineError;

  List<SystemTtsVoice> _voices = const [];
  bool _voicesLoading = false;
  String? _voiceError;

  CustomSsmlTtsConfig? _customProfile;
  String? _customProfileError;

  int _accountLoadSerial = 0;

  @override
  void initState() {
    super.initState();
    _ownsSystemTts = widget.systemTts == null;
    _systemTts = widget.systemTts ?? SystemTts();
    LKClient.sessionRev.addListener(_onAccountChanged);
    unawaited(_loadAll());
  }

  @override
  void dispose() {
    LKClient.sessionRev.removeListener(_onAccountChanged);
    if (_ownsSystemTts) {
      unawaited(_systemTts.dispose());
    }
    super.dispose();
  }

  void _onAccountChanged() {
    if (!mounted) return;
    unawaited(_loadAll());
  }

  Future<void> _loadAll() async {
    final serial = ++_accountLoadSerial;
    final accountKey = ReaderTtsPreferences.currentAccountKey();
    final loaded = await ReaderTtsPreferences.load(accountKey);
    if (!mounted || serial != _accountLoadSerial) return;
    setState(() {
      _prefs = loaded;
      _loading = false;
    });
    await _loadCustomProfile(accountKey, serial: serial);
    if (!mounted || serial != _accountLoadSerial) return;
    if (_prefs.sourceMode == 'system' &&
        defaultTargetPlatform == TargetPlatform.android) {
      await _prepareSystemSpeechOptions();
    }
  }

  Future<void> _loadCustomProfile(String accountKey, {int? serial}) async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted ||
        (serial != null && serial != _accountLoadSerial) ||
        accountKey != ReaderTtsPreferences.currentAccountKey()) {
      return;
    }
    final raw = preferences.getString(
      ReaderTtsPreferences.customMetadataKey(accountKey),
    );
    try {
      final parsed = raw == null || raw.isEmpty
          ? null
          : CustomSsmlTtsConfig.fromMetadata(decodeCustomTtsMetadata(raw));
      setState(() {
        _customProfile = parsed;
        _customProfileError = null;
      });
    } catch (_) {
      setState(() {
        _customProfile = null;
        _customProfileError = '已保存的服务配置无效，请重新配置。';
      });
    }
  }

  Future<void> _savePrefs(ReaderTtsPreferences next) async {
    setState(() => _prefs = next);
    await ReaderTtsPreferences.save(next);
  }

  Future<void> _prepareSystemSpeechOptions() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_engines.isEmpty) await _loadEngines();
    if (!mounted) return;
    if (_prefs.systemEngineId != null) {
      try {
        await _systemTts.setEngine(_prefs.systemEngineId!);
      } catch (error) {
        if (mounted) setState(() => _engineError = error.toString());
        return;
      }
    }
    if (_voices.isEmpty) await _loadVoices();
  }

  Future<void> _loadEngines() async {
    if (_enginesLoading) return;
    setState(() {
      _enginesLoading = true;
      _engineError = null;
    });
    try {
      final engines = await _systemTts.getEngines();
      if (!mounted) return;
      final selectedExists = _prefs.systemEngineId == null ||
          engines.any((item) => item.id == _prefs.systemEngineId);
      setState(() {
        _engines = engines;
        _enginesLoading = false;
      });
      if (!selectedExists) {
        await _savePrefs(_prefs.copyWith(clearSystemEngineId: true));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _enginesLoading = false;
        _engineError = error.toString();
      });
    }
  }

  Future<void> _loadVoices() async {
    if (_voicesLoading) return;
    setState(() {
      _voicesLoading = true;
      _voiceError = null;
    });
    try {
      final voices = await _systemTts.getVoices();
      if (!mounted) return;
      final preferredId = _prefs.systemVoiceId;
      final hasPreferred =
          preferredId != null && voices.any((voice) => voice.id == preferredId);
      SystemTtsVoice? fallback;
      if (!hasPreferred && voices.isNotEmpty) {
        fallback = voices.firstWhere(
          (voice) => voice.locale?.toLowerCase().startsWith('zh') == true,
          orElse: () => voices.first,
        );
      }
      setState(() {
        _voices = voices;
        _voicesLoading = false;
      });
      if (!hasPreferred && fallback != null) {
        await _savePrefs(_prefs.copyWith(systemVoiceId: fallback.id));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _voicesLoading = false;
        _voiceError = error.toString();
      });
    }
  }

  Future<void> _onSourceChanged(String source) async {
    if (_changingSource || source == _prefs.sourceMode) return;
    setState(() => _changingSource = true);
    try {
      if (ListeningNow.instance.active) {
        await ListeningNow.instance.stop();
      }
      await _savePrefs(_prefs.copyWith(sourceMode: source));
      if (!mounted) return;
      if (source == 'system') {
        await _prepareSystemSpeechOptions();
      }
    } finally {
      if (mounted) setState(() => _changingSource = false);
    }
  }

  Future<void> _onEngineChanged(String id) async {
    if (id == (_prefs.systemEngineId ?? 'default')) return;
    if (ListeningNow.instance.active) {
      await ListeningNow.instance.stop();
    }
    try {
      await _systemTts.setEngine(id);
      if (!mounted) return;
      setState(() {
        _voices = const [];
        _engineError = null;
      });
      await _savePrefs(_prefs.copyWith(
        systemEngineId: id == 'default' ? null : id,
        clearSystemEngineId: id == 'default',
        clearSystemVoiceId: true,
        systemVoiceByLanguage: const <String, String>{},
      ));
      if (!mounted) return;
      await _loadVoices();
    } catch (error) {
      if (mounted) setState(() => _engineError = error.toString());
    }
  }

  Future<void> _openCustomTtsSettings() async {
    if (ListeningNow.instance.active) {
      await ListeningNow.instance.stop();
    }
    if (!mounted) return;
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    var mediaHandler = activeReaderAudioHandler;
    if (mediaHandler == null &&
        defaultTargetPlatform == TargetPlatform.android) {
      try {
        mediaHandler =
            await ensureReaderAudioHandler().timeout(const Duration(seconds: 3));
      } catch (_) {
        mediaHandler = activeReaderAudioHandler;
      }
    }
    if (!mounted) return;
    final accountKey = ReaderTtsPreferences.currentAccountKey();
    final service = CustomSsmlTts(
      credentialStorageKey: ReaderTtsPreferences.customCredentialKey(accountKey),
    );
    try {
      await Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (_) => CustomTtsSettingsPage(
          tts: service,
          preferences: preferences,
          metadataStorageKey:
              ReaderTtsPreferences.customMetadataKey(accountKey),
          createPlayer: () {
            final currentHandler = activeReaderAudioHandler ?? mediaHandler;
            if (currentHandler != null) {
              return AudioHandlerCustomTtsPreviewPlayer(
                ReaderAudioHandlerTtsAdapter(currentHandler),
              );
            }
            return _UnavailableCustomPreviewPlayer();
          },
        ),
      ));
    } finally {
      service.close();
      if (mounted) {
        await _loadCustomProfile(ReaderTtsPreferences.currentAccountKey());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    return Scaffold(
      appBar: AppBar(title: const Text('听书与 TTS')),
      body: _loading
          ? const Center(child: MotionProgressIndicator())
          : ListView(
              key: const ValueKey('tts-settings-list'),
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                MediaQuery.of(context).padding.bottom + 24,
              ),
              children: [
                if (!isAndroid) ...[
                  const AppSettingsGroup(
                    children: [
                      ListTile(
                        leading: AppSettingIcon(Icons.info_outline_rounded),
                        title: Text('当前平台仅支持保存偏好'),
                        subtitle: Text('阅读器朗读播放目前支持 Android 设备，这里保存的配置会自动同步。'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
                const AppSectionTitle('语音来源'),
                ListeningSourcePicker(
                  value: _prefs.sourceMode,
                  enabled: !_changingSource,
                  onChanged: _onSourceChanged,
                ),
                if (_changingSource) ...[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(minHeight: 2),
                ],
                const SizedBox(height: 20),
                const AppSectionTitle('语速'),
                ListeningRateControl(
                  rate: _prefs.rate,
                  onChanged: (value) =>
                      setState(() => _prefs = _prefs.copyWith(rate: value)),
                  onChangeEnd: (value) async {
                    await _savePrefs(_prefs.copyWith(rate: value));
                    if (_prefs.sourceMode == 'online' &&
                        ListeningNow.instance.active) {
                      try {
                        await activeReaderAudioHandler?.setPlaybackRate(value);
                      } catch (_) {}
                    }
                  },
                ),
                const SizedBox(height: 20),
                if (_prefs.sourceMode == 'online')
                  TtsOnlineVoicesSection(
                    edgeVoiceByLanguage: _prefs.edgeVoiceByLanguage,
                    onVoiceChanged: (language, voiceId) async {
                      final nextMap =
                          Map<String, String>.from(_prefs.edgeVoiceByLanguage);
                      if (voiceId == null || voiceId.isEmpty) {
                        nextMap.remove(language);
                      } else {
                        nextMap[language] = voiceId;
                      }
                      await _savePrefs(_prefs.copyWith(
                        edgeVoiceByLanguage: nextMap,
                      ));
                    },
                  ),
                if (_prefs.sourceMode == 'system')
                  TtsSystemVoicesSection(
                    isAndroid: isAndroid,
                    engines: _engines,
                    enginesLoading: _enginesLoading,
                    engineError: _engineError,
                    selectedEngineId: _prefs.systemEngineId,
                    onRetryEngines: () => unawaited(_loadEngines()),
                    onEngineSelected: (id) => unawaited(_onEngineChanged(id)),
                    voices: _voices,
                    voicesLoading: _voicesLoading,
                    voiceError: _voiceError,
                    selectedVoiceId: _prefs.systemVoiceId,
                    onRetryVoices: () => unawaited(_loadVoices()),
                    onVoiceSelected: (voice) =>
                        unawaited(_savePrefs(_prefs.copyWith(
                      systemVoiceId: voice.id,
                    ))),
                    voiceByLanguage: _prefs.systemVoiceByLanguage,
                    onLanguageVoiceChanged: (language, voiceId) {
                      final nextMap = Map<String, String>.from(
                        _prefs.systemVoiceByLanguage,
                      );
                      if (voiceId == null || voiceId.isEmpty) {
                        nextMap.remove(language);
                      } else {
                        nextMap[language] = voiceId;
                      }
                      unawaited(_savePrefs(_prefs.copyWith(
                        systemVoiceByLanguage: nextMap,
                      )));
                    },
                  ),
                if (_prefs.sourceMode == 'custom')
                  TtsCustomVoiceSection(
                    profile: _customProfile,
                    profileError: _customProfileError,
                    onConfigure: () => unawaited(_openCustomTtsSettings()),
                  ),
                const SizedBox(height: 20),
                TtsPlaybackSettingsSection(
                  languageFilter: _prefs.languageFilter,
                  onLanguageFilterChanged: (value) async {
                    if (ListeningNow.instance.active) {
                      await ListeningNow.instance.stop();
                    }
                    await _savePrefs(_prefs.copyWith(languageFilter: value));
                  },
                  segmentInterval: _prefs.segmentInterval,
                  onSegmentIntervalChanged: (interval) async {
                    ListeningNow.instance.session?.setSegmentInterval(interval);
                    await _savePrefs(
                        _prefs.copyWith(segmentInterval: interval));
                  },
                  sleepTimer: _prefs.sleepTimer,
                  onSleepTimerChanged: (timer) async {
                    ListeningNow.instance.session?.setSleepTimer(timer);
                    await _savePrefs(_prefs.copyWith(sleepTimer: timer));
                  },
                  continuousChapter: _prefs.continuousChapter,
                  onContinuousChapterChanged: (value) async {
                    await _savePrefs(
                        _prefs.copyWith(continuousChapter: value));
                  },
                ),
                const SizedBox(height: 20),
                const AppSettingsGroup(
                  children: [
                    ListTile(
                      leading: AppSettingIcon(Icons.sync_rounded),
                      title: Text('与阅读器听书面板同步'),
                      subtitle: Text(
                        '设置按当前账号自动保存；进入阅读器双击正文或打开听书面板时即刻生效。',
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _UnavailableCustomPreviewPlayer implements CustomTtsPreviewPlayer {
  @override
  Future<void> dispose() async {}

  @override
  Future<void> play(Uint8List mp3Bytes) async {
    throw const CustomTtsError(
      CustomTtsErrorCode.invalidConfiguration,
      '音频服务尚未初始化，配置保存后可在阅读器中试听',
    );
  }

  @override
  Future<void> stop() async {}
}
