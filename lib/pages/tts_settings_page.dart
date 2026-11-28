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
import '../widgets/common.dart';
import '../widgets/m3_controls.dart';
import '../widgets/reader_listening_sheet.dart';
import '../widgets/scrollable_status.dart';
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
  int _engineLoadSerial = 0;
  int _voiceLoadSerial = 0;
  bool _openingCustom = false;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  bool get _isTtsSupported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

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
    ++_engineLoadSerial;
    ++_voiceLoadSerial;
    setState(() {
      _engines = const [];
      _voices = const [];
      _engineError = null;
      _voiceError = null;
      _enginesLoading = false;
      _voicesLoading = false;
    });
    unawaited(_loadAll());
  }

  (CustomSsmlTtsConfig?, String?) _parseCustomProfile(
    SharedPreferences preferences,
    String accountKey,
  ) {
    final raw = preferences.getString(
      ReaderTtsPreferences.customMetadataKey(accountKey),
    );
    try {
      final parsed = raw == null || raw.isEmpty
          ? null
          : CustomSsmlTtsConfig.fromMetadata(decodeCustomTtsMetadata(raw));
      return (parsed, null);
    } catch (_) {
      return (null, '已保存的服务配置无效，请重新配置。');
    }
  }

  bool _isActiveAccountContext(String accountKey, int accountSerial) =>
      mounted &&
      accountSerial == _accountLoadSerial &&
      accountKey == ReaderTtsPreferences.currentAccountKey();

  Future<void> _loadAll() async {
    final serial = ++_accountLoadSerial;
    ++_engineLoadSerial;
    ++_voiceLoadSerial;
    final accountKey = ReaderTtsPreferences.currentAccountKey();
    final results = await Future.wait<Object>([
      ReaderTtsPreferences.load(accountKey),
      SharedPreferences.getInstance(),
    ]);
    if (!_isActiveAccountContext(accountKey, serial)) return;
    final loaded = results[0] as ReaderTtsPreferences;
    final preferences = results[1] as SharedPreferences;
    final (customProfile, customProfileError) =
        _parseCustomProfile(preferences, accountKey);
    final systemMode = loaded.sourceMode == 'system' && _isTtsSupported;
    setState(() {
      _prefs = loaded;
      _customProfile = customProfile;
      _customProfileError = customProfileError;
      _enginesLoading = systemMode && _isAndroid;
      _voicesLoading = systemMode;
      _engineError = null;
      _voiceError = null;
      _loading = false;
    });
    if (systemMode) {
      await _prepareSystemSpeechOptions(
        accountKey: accountKey,
        accountSerial: serial,
      );
    }
  }

  Future<void> _loadCustomProfile(String accountKey, {int? serial}) async {
    final expectedSerial = serial ?? _accountLoadSerial;
    final preferences = await SharedPreferences.getInstance();
    if (!_isActiveAccountContext(accountKey, expectedSerial)) {
      return;
    }
    final (parsed, error) = _parseCustomProfile(preferences, accountKey);
    setState(() {
      _customProfile = parsed;
      _customProfileError = error;
    });
  }

  Future<void> _savePrefs(ReaderTtsPreferences next) async {
    setState(() => _prefs = next);
    await ReaderTtsPreferences.save(next);
  }

  Future<void> _prepareSystemSpeechOptions({
    String? accountKey,
    int? accountSerial,
  }) async {
    if (!_isTtsSupported) return;
    final activeKey = accountKey ?? ReaderTtsPreferences.currentAccountKey();
    final activeSerial = accountSerial ?? _accountLoadSerial;
    if (_isAndroid) {
      if (_engines.isEmpty) {
        await _loadEngines(
          accountKey: activeKey,
          accountSerial: activeSerial,
        );
      }
      if (!_isActiveAccountContext(activeKey, activeSerial)) return;
      if (_prefs.systemEngineId != null) {
        try {
          await _systemTts.setEngine(_prefs.systemEngineId!);
        } catch (error) {
          if (_isActiveAccountContext(activeKey, activeSerial)) {
            setState(() {
              _engineError = error.toString();
              _voicesLoading = false;
            });
          }
          return;
        }
      }
    }
    if (!_isActiveAccountContext(activeKey, activeSerial)) return;
    if (_voices.isEmpty) {
      await _loadVoices(
        accountKey: activeKey,
        accountSerial: activeSerial,
      );
    }
  }

  Future<void> _loadEngines({
    String? accountKey,
    int? accountSerial,
  }) async {
    final activeKey = accountKey ?? ReaderTtsPreferences.currentAccountKey();
    final activeSerial = accountSerial ?? _accountLoadSerial;
    final serial = ++_engineLoadSerial;
    if (!_enginesLoading || _engineError != null) {
      setState(() {
        _enginesLoading = true;
        _engineError = null;
      });
    }
    try {
      final engines = await _systemTts.getEngines();
      if (!_isActiveAccountContext(activeKey, activeSerial) ||
          serial != _engineLoadSerial) {
        return;
      }
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
      if (!_isActiveAccountContext(activeKey, activeSerial) ||
          serial != _engineLoadSerial) {
        return;
      }
      setState(() {
        _enginesLoading = false;
        _engineError = error.toString();
      });
    }
  }

  Future<void> _loadVoices({
    String? accountKey,
    int? accountSerial,
  }) async {
    final activeKey = accountKey ?? ReaderTtsPreferences.currentAccountKey();
    final activeSerial = accountSerial ?? _accountLoadSerial;
    final serial = ++_voiceLoadSerial;
    if (!_voicesLoading || _voiceError != null) {
      setState(() {
        _voicesLoading = true;
        _voiceError = null;
      });
    }
    try {
      final voices = await _systemTts.getVoices();
      if (!_isActiveAccountContext(activeKey, activeSerial) ||
          serial != _voiceLoadSerial) {
        return;
      }
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
      if (!_isActiveAccountContext(activeKey, activeSerial) ||
          serial != _voiceLoadSerial) {
        return;
      }
      setState(() {
        _voicesLoading = false;
        _voiceError = error.toString();
      });
    }
  }

  Future<void> _onSourceChanged(String source) async {
    if (_changingSource || source == _prefs.sourceMode) return;
    final accountKey = ReaderTtsPreferences.currentAccountKey();
    final accountSerial = _accountLoadSerial;
    final switchingToSystem = source == 'system' && _isTtsSupported;
    setState(() {
      _changingSource = true;
      if (switchingToSystem) {
        _enginesLoading = _isAndroid && _engines.isEmpty;
        _voicesLoading = _voices.isEmpty;
        _engineError = null;
        _voiceError = null;
      }
    });
    try {
      if (ListeningNow.instance.active) {
        await ListeningNow.instance.stop();
      }
      if (!_isActiveAccountContext(accountKey, accountSerial)) return;
      await _savePrefs(_prefs.copyWith(sourceMode: source));
      if (!_isActiveAccountContext(accountKey, accountSerial)) return;
      if (switchingToSystem) {
        await _prepareSystemSpeechOptions(
          accountKey: accountKey,
          accountSerial: accountSerial,
        );
      }
    } finally {
      if (mounted) setState(() => _changingSource = false);
    }
  }

  Future<void> _onEngineChanged(String id) async {
    if (id == (_prefs.systemEngineId ?? 'default')) return;
    final accountKey = ReaderTtsPreferences.currentAccountKey();
    final accountSerial = _accountLoadSerial;
    if (ListeningNow.instance.active) {
      await ListeningNow.instance.stop();
    }
    if (!_isActiveAccountContext(accountKey, accountSerial)) return;
    try {
      await _systemTts.setEngine(id);
      if (!_isActiveAccountContext(accountKey, accountSerial)) return;
      setState(() {
        _voices = const [];
        _voicesLoading = true;
        _engineError = null;
        _voiceError = null;
      });
      await _savePrefs(_prefs.copyWith(
        systemEngineId: id == 'default' ? null : id,
        clearSystemEngineId: id == 'default',
        clearSystemVoiceId: true,
        systemVoiceByLanguage: const <String, String>{},
      ));
      if (!_isActiveAccountContext(accountKey, accountSerial)) return;
      await _loadVoices(
        accountKey: accountKey,
        accountSerial: accountSerial,
      );
    } catch (error) {
      if (_isActiveAccountContext(accountKey, accountSerial)) {
        setState(() {
          _voicesLoading = false;
          _engineError = error.toString();
        });
      }
    }
  }

  Future<void> _openCustomTtsSettings() async {
    if (_openingCustom) return;
    _openingCustom = true;
    try {
      if (ListeningNow.instance.active) {
        await ListeningNow.instance.stop();
      }
      if (!mounted) return;
      final preferences = await SharedPreferences.getInstance();
      if (!mounted) return;
      var mediaHandler = activeReaderAudioHandler;
      if (mediaHandler == null && _isTtsSupported) {
        try {
          mediaHandler = await ensureReaderAudioHandler()
              .timeout(const Duration(seconds: 3));
        } catch (_) {
          mediaHandler = activeReaderAudioHandler;
        }
      }
      if (!mounted) return;
      final accountKey = ReaderTtsPreferences.currentAccountKey();
      final service = CustomSsmlTts(
        credentialStorageKey:
            ReaderTtsPreferences.customCredentialKey(accountKey),
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
    } finally {
      _openingCustom = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = _isAndroid;
    final isTtsSupported = _isTtsSupported;
    return Scaffold(
      appBar: AppBar(title: const Text('听书与 TTS')),
      body: _loading
          ? const ScrollableStatus(child: LkLoadingIndicator())
          : Stack(
              children: [
                ListView(
                  key: const ValueKey('tts-settings-list'),
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    MediaQuery.of(context).padding.bottom + 24,
                  ),
                  children: [
                    if (!isTtsSupported) ...[
                      const AppSettingsGroup(
                        children: [
                          ListTile(
                            leading: AppSettingIcon(Icons.info_outline_rounded),
                            title: Text('当前平台仅支持保存偏好'),
                            subtitle: Text('阅读器朗读播放目前支持 Android 与 iOS 设备。'),
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
                            await activeReaderAudioHandler
                                ?.setPlaybackRate(value);
                          } catch (_) {}
                        }
                      },
                    ),
                    const SizedBox(height: 20),
                    if (_prefs.sourceMode == 'online')
                      TtsOnlineVoicesSection(
                        edgeVoiceByLanguage: _prefs.edgeVoiceByLanguage,
                        onVoiceChanged: (language, voiceId) async {
                          final nextMap = Map<String, String>.from(
                              _prefs.edgeVoiceByLanguage);
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
                        isSupported: isTtsSupported,
                        showEnginePicker: isAndroid,
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
                        ListeningNow.instance.session
                            ?.setSegmentInterval(interval);
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
                  ],
                ),
                if (_changingSource)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: MotionLinearProgressIndicator(minHeight: 2),
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
