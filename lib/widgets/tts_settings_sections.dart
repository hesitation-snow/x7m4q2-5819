import 'package:flutter/material.dart';

import '../reader/reader_language_segments.dart';
import '../services/app_motion.dart';
import '../services/custom_ssml_tts.dart';
import '../services/edge_speech.dart';
import '../services/system_tts.dart';
import 'm3_controls.dart';
import 'm3_menu_sheet.dart';

class TtsPickerOption<T> {
  const TtsPickerOption({
    required this.value,
    required this.title,
    required this.icon,
    this.subtitle,
  });

  final T value;
  final String title;
  final String? subtitle;
  final IconData icon;
}

Future<T?> showTtsOptionSheet<T>({
  required BuildContext context,
  required String title,
  required IconData icon,
  required List<TtsPickerOption<T>> options,
  required T selected,
  String? description,
}) {
  return showModalBottomSheet<T>(
    sheetAnimationStyle: AppMotion.style(context),
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) => M3MenuSheet(
      title: title,
      icon: icon,
      description: description,
      children: [
        for (final option in options)
          M3OptionTile(
            title: option.title,
            subtitle: option.subtitle,
            icon: option.icon,
            selected: option.value == selected,
            onTap: () => Navigator.pop(sheetCtx, option.value),
          ),
      ],
    ),
  );
}

class TtsOnlineVoicesSection extends StatelessWidget {
  const TtsOnlineVoicesSection({
    super.key,
    required this.edgeVoiceByLanguage,
    required this.onVoiceChanged,
  });

  final Map<String, String> edgeVoiceByLanguage;
  final void Function(String language, String? voiceId) onVoiceChanged;

  static const _languages = [
    ('chinese', '中文音色', Icons.record_voice_over_outlined),
    ('japanese', '日文音色', Icons.record_voice_over_outlined),
    ('korean', '韩文音色', Icons.record_voice_over_outlined),
  ];

  String _voiceLabel(String language) {
    final id = edgeVoiceByLanguage[language];
    final voice = edgeVoiceById(id);
    if (voice != null && voice.language == language) {
      return voice.label;
    }
    return '自动';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionTitle('在线音色'),
        AppSettingsGroup(
          children: [
            for (final language in _languages)
              ListTile(
                key: ValueKey('tts-online-voice-${language.$1}'),
                leading: AppSettingIcon(language.$3),
                title: Text(language.$2),
                subtitle: Text(_voiceLabel(language.$1)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final currentId = edgeVoiceByLanguage[language.$1];
                  final currentValid =
                      edgeVoiceById(currentId)?.language == language.$1
                          ? currentId!
                          : '';
                  final picked = await showTtsOptionSheet<String>(
                    context: context,
                    title: language.$2,
                    icon: Icons.cloud_outlined,
                    description: '选择自动时将按段落语言自动匹配默认自然音色。',
                    selected: currentValid,
                    options: [
                      const TtsPickerOption(
                        value: '',
                        title: '自动',
                        subtitle: '使用该语言的默认自然音色',
                        icon: Icons.auto_awesome_outlined,
                      ),
                      for (final voice in builtInEdgeVoices
                          .where((item) => item.language == language.$1))
                        TtsPickerOption(
                          value: voice.id,
                          title: voice.label,
                          subtitle: voice.id,
                          icon: Icons.graphic_eq_rounded,
                        ),
                    ],
                  );
                  if (picked == null) return;
                  onVoiceChanged(language.$1, picked.isEmpty ? null : picked);
                },
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
          child: Text(
            '无需密钥；语速仅调节播放速度，正文会发送至在线语音服务。',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class TtsSystemVoicesSection extends StatelessWidget {
  const TtsSystemVoicesSection({
    super.key,
    required this.isAndroid,
    this.isSupported,
    this.showEnginePicker,
    required this.engines,
    required this.enginesLoading,
    required this.engineError,
    required this.selectedEngineId,
    required this.onRetryEngines,
    required this.onEngineSelected,
    required this.voices,
    required this.voicesLoading,
    required this.voiceError,
    required this.selectedVoiceId,
    required this.onRetryVoices,
    required this.onVoiceSelected,
    required this.voiceByLanguage,
    required this.onLanguageVoiceChanged,
    this.perLanguageEnabled = true,
  });

  final bool isAndroid;
  final bool? isSupported;
  final bool? showEnginePicker;
  final List<SystemTtsEngine> engines;
  final bool enginesLoading;
  final String? engineError;
  final String? selectedEngineId;
  final VoidCallback onRetryEngines;
  final ValueChanged<String> onEngineSelected;

  final List<SystemTtsVoice> voices;
  final bool voicesLoading;
  final String? voiceError;
  final String? selectedVoiceId;
  final VoidCallback onRetryVoices;
  final ValueChanged<SystemTtsVoice> onVoiceSelected;

  final Map<String, String> voiceByLanguage;
  final void Function(String language, String? voiceId) onLanguageVoiceChanged;
  final bool perLanguageEnabled;

  String _engineSubtitle() {
    if (selectedEngineId == null || selectedEngineId == 'default') {
      return '系统默认引擎';
    }
    final match =
        engines.where((item) => item.id == selectedEngineId).firstOrNull;
    return match != null ? match.label : selectedEngineId!;
  }

  String _voiceSubtitle() {
    final match =
        voices.where((item) => item.id == selectedVoiceId).firstOrNull;
    if (match == null) return '未选择语音';
    final locale = match.locale ?? '未知语言';
    final net = match.networkRequired == true ? ' · 需联网' : '';
    return '${match.name} · $locale$net';
  }

  String _perLanguageSubtitle() {
    if (!perLanguageEnabled) return '连接媒体服务后可用';
    final configured = <String>[];
    const labels = [
      ('chinese', '中文', 'zh'),
      ('japanese', '日语', 'ja'),
      ('korean', '韩语', 'ko'),
    ];
    for (final lang in labels) {
      final id = voiceByLanguage[lang.$1];
      if (id != null &&
          voices.any((v) =>
              v.id == id &&
              v.locale?.toLowerCase().startsWith(lang.$3) == true)) {
        configured.add(lang.$2);
      }
    }
    if (configured.isEmpty) return '全部自动匹配';
    return '已指定：${configured.join('、')}';
  }

  Future<void> _showPerLanguageSheet(BuildContext context) async {
    const languages = [
      ('chinese', '中文语音', 'zh'),
      ('japanese', '日语语音', 'ja'),
      ('korean', '韩语语音', 'ko'),
    ];
    final currentMap = Map<String, String>.from(voiceByLanguage);
    await showModalBottomSheet<void>(
      sheetAnimationStyle: AppMotion.style(context),
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => M3MenuSheet(
          title: '分语言音色',
          icon: Icons.language_rounded,
          description: '为中、日、韩正文分别指定系统音色，留空则自动匹配。',
          children: [
            for (final lang in languages)
              Builder(builder: (_) {
                final candidates = voices
                    .where((item) =>
                        item.locale?.toLowerCase().startsWith(lang.$3) == true)
                    .toList(growable: false);
                final currentId = currentMap[lang.$1];
                final currentVoice = candidates
                    .where((item) => item.id == currentId)
                    .firstOrNull;
                return M3OptionTile(
                  title: lang.$2,
                  subtitle: candidates.isEmpty
                      ? '当前引擎无可用${lang.$2}'
                      : (currentVoice?.name ?? '自动'),
                  icon: Icons.record_voice_over_outlined,
                  onTap: candidates.isEmpty
                      ? null
                      : () async {
                          final picked = await showTtsOptionSheet<String>(
                            context: ctx,
                            title: lang.$2,
                            icon: Icons.record_voice_over_outlined,
                            selected: currentVoice?.id ?? '',
                            options: [
                              const TtsPickerOption(
                                value: '',
                                title: '自动',
                                subtitle: '跟随系统默认匹配',
                                icon: Icons.auto_awesome_outlined,
                              ),
                              for (final voice in candidates)
                                TtsPickerOption(
                                  value: voice.id,
                                  title: voice.name,
                                  subtitle: voice.locale ?? '未知语言',
                                  icon: Icons.graphic_eq_rounded,
                                ),
                            ],
                          );
                          if (picked == null) return;
                          setSheet(() {
                            if (picked.isEmpty) {
                              currentMap.remove(lang.$1);
                            } else {
                              currentMap[lang.$1] = picked;
                            }
                          });
                          onLanguageVoiceChanged(
                            lang.$1,
                            picked.isEmpty ? null : picked,
                          );
                        },
                );
              }),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final supported = isSupported ?? isAndroid;
    final enginePickerVisible = showEnginePicker ?? isAndroid;
    if (!supported) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionTitle('系统语音'),
          AppSettingsGroup(
            children: [
              ListTile(
                leading: AppSettingIcon(Icons.phone_android_rounded),
                title: Text('系统语音引擎仅在 Android 与 iOS 上可用'),
                subtitle: Text('可在 Android 或 iOS 设备上选择系统离线音色'),
              ),
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionTitle('系统语音'),
        AppSettingsGroup(
          children: [
            if (enginePickerVisible) ...[
              if (enginesLoading)
                const ListTile(
                  leading: AppSettingIcon(Icons.memory_rounded),
                  title: Text('系统朗读引擎'),
                  subtitle: Text('正在检测已安装的语音引擎…'),
                  trailing: SizedBox.square(
                    dimension: 20,
                    child: MotionProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (engineError != null)
                ListTile(
                  leading: const AppSettingIcon(
                    Icons.error_outline_rounded,
                    danger: true,
                  ),
                  title: const Text('系统朗读引擎'),
                  subtitle: Text(engineError!),
                  trailing: IconButton(
                    tooltip: '重新检测引擎',
                    onPressed: onRetryEngines,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                )
              else
                ListTile(
                  key: const ValueKey('tts-system-engine-tile'),
                  leading: const AppSettingIcon(Icons.memory_rounded),
                  title: const Text('系统朗读引擎'),
                  subtitle: Text(_engineSubtitle()),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    final picked = await showTtsOptionSheet<String>(
                      context: context,
                      title: '系统朗读引擎',
                      icon: Icons.memory_rounded,
                      selected: selectedEngineId ?? 'default',
                      options: [
                        const TtsPickerOption(
                          value: 'default',
                          title: '系统默认引擎',
                          subtitle: '跟随设备系统语音设置',
                          icon: Icons.phone_android_rounded,
                        ),
                        for (final engine in engines)
                          TtsPickerOption(
                            value: engine.id,
                            title: engine.label,
                            subtitle: engine.id,
                            icon: Icons.memory_rounded,
                          ),
                      ],
                    );
                    if (picked == null) return;
                    onEngineSelected(picked);
                  },
                ),
            ],
            if (voicesLoading)
              const ListTile(
                leading: AppSettingIcon(Icons.record_voice_over_outlined),
                title: Text('系统语音'),
                subtitle: Text('正在加载可用音色…'),
                trailing: SizedBox.square(
                  dimension: 20,
                  child: MotionProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (voiceError != null)
              ListTile(
                leading: const AppSettingIcon(
                  Icons.error_outline_rounded,
                  danger: true,
                ),
                title: const Text('系统语音'),
                subtitle: Text(voiceError!),
                trailing: IconButton(
                  tooltip: '重新检测语音',
                  onPressed: onRetryVoices,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              )
            else if (voices.isEmpty)
              ListTile(
                leading: const AppSettingIcon(Icons.warning_amber_rounded),
                title: const Text('系统语音'),
                subtitle: const Text('系统未提供可用语音，请检查设备语音设置'),
                trailing: IconButton(
                  tooltip: '重新检测语音',
                  onPressed: onRetryVoices,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              )
            else
              ListTile(
                key: const ValueKey('tts-system-voice-tile'),
                leading: const AppSettingIcon(Icons.record_voice_over_outlined),
                title: const Text('系统语音'),
                subtitle: Text(_voiceSubtitle()),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final picked = await showTtsOptionSheet<String>(
                    context: context,
                    title: '系统语音',
                    icon: Icons.record_voice_over_outlined,
                    selected: selectedVoiceId ?? '',
                    options: [
                      for (final voice in voices)
                        TtsPickerOption(
                          value: voice.id,
                          title: voice.name,
                          subtitle:
                              '${voice.locale ?? '未知语言'}${voice.networkRequired == true ? ' · 需联网' : ''}',
                          icon: Icons.graphic_eq_rounded,
                        ),
                    ],
                  );
                  if (picked == null) return;
                  final match =
                      voices.where((item) => item.id == picked).firstOrNull;
                  if (match != null) onVoiceSelected(match);
                },
              ),
            if (!voicesLoading && voiceError == null && voices.isNotEmpty)
              ListTile(
                key: const ValueKey('tts-system-lang-voices-tile'),
                enabled: perLanguageEnabled,
                leading: const AppSettingIcon(Icons.language_rounded),
                title: const Text('分语言音色'),
                subtitle: Text(_perLanguageSubtitle()),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: perLanguageEnabled
                    ? () => _showPerLanguageSheet(context)
                    : null,
              ),
          ],
        ),
      ],
    );
  }
}

class TtsCustomVoiceSection extends StatelessWidget {
  const TtsCustomVoiceSection({
    super.key,
    required this.profile,
    required this.profileError,
    required this.onConfigure,
  });

  final CustomSsmlTtsConfig? profile;
  final String? profileError;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final configured = profile != null;
    final host = configured
        ? (Uri.tryParse(profile!.endpoint)?.host ?? profile!.endpoint)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionTitle('自定义语音服务'),
        AppSettingsGroup(
          children: [
            ListTile(
              key: const ValueKey('tts-custom-config-tile'),
              leading: const AppSettingIcon(Icons.settings_voice_rounded),
              title: Text(
                configured && profile!.displayName.isNotEmpty
                    ? profile!.displayName
                    : '配置在线 / 自定义 SSML 语音',
              ),
              subtitle: Text(
                configured
                    ? '$host · ${profile!.locale} · 点击修改或试听'
                    : (profileError ?? '填写服务地址与音色；Azure 需填写区域密钥'),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onConfigure,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
          child: Text(
            '自定义 SSML 会将朗读正文发送至你配置的 HTTPS 接口，Azure 语音也在此配置。',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class TtsPlaybackSettingsSection extends StatelessWidget {
  const TtsPlaybackSettingsSection({
    super.key,
    required this.languageFilter,
    required this.onLanguageFilterChanged,
    required this.segmentInterval,
    required this.onSegmentIntervalChanged,
    required this.sleepTimer,
    required this.onSleepTimerChanged,
    required this.continuousChapter,
    required this.onContinuousChapterChanged,
    this.mediaControlsEnabled = true,
  });

  final ReaderLanguageFilter languageFilter;
  final ValueChanged<ReaderLanguageFilter> onLanguageFilterChanged;
  final Duration segmentInterval;
  final ValueChanged<Duration> onSegmentIntervalChanged;
  final PlaybackSleepTimer sleepTimer;
  final ValueChanged<PlaybackSleepTimer> onSleepTimerChanged;
  final bool continuousChapter;
  final ValueChanged<bool> onContinuousChapterChanged;
  final bool mediaControlsEnabled;

  static String languageFilterLabel(ReaderLanguageFilter value) =>
      switch (value) {
        ReaderLanguageFilter.automatic => '自动识别',
        ReaderLanguageFilter.chineseOnly => '仅中文',
        ReaderLanguageFilter.japaneseOnly => '仅日文',
      };

  static String intervalLabel(Duration value) => switch (value.inMilliseconds) {
        <= 0 => '无间隔',
        500 => '0.5 秒',
        1000 => '1 秒',
        2000 => '2 秒',
        final ms => '${(ms / 1000).toStringAsFixed(1)} 秒',
      };

  static String sleepTimerLabel(PlaybackSleepTimer value) => switch (value) {
        PlaybackSleepTimer.none => '关闭',
        PlaybackSleepTimer.minutes15 => '15 分钟',
        PlaybackSleepTimer.minutes30 => '30 分钟',
        PlaybackSleepTimer.minutes60 => '60 分钟',
        PlaybackSleepTimer.chapterEnd => '本章结束时停止',
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionTitle('播放设置'),
        AppSettingsGroup(
          children: [
            ListTile(
              key: const ValueKey('tts-playback-language-tile'),
              leading: const AppSettingIcon(Icons.translate_rounded),
              title: const Text('朗读语言'),
              subtitle: Text(languageFilterLabel(languageFilter)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                final picked = await showTtsOptionSheet<ReaderLanguageFilter>(
                  context: context,
                  title: '朗读语言',
                  icon: Icons.translate_rounded,
                  selected: languageFilter,
                  options: const [
                    TtsPickerOption(
                      value: ReaderLanguageFilter.automatic,
                      title: '自动识别',
                      subtitle: '朗读全部正文并自动切换对应语言',
                      icon: Icons.auto_awesome_outlined,
                    ),
                    TtsPickerOption(
                      value: ReaderLanguageFilter.chineseOnly,
                      title: '仅中文',
                      subtitle: '跳过纯日文段落',
                      icon: Icons.translate_rounded,
                    ),
                    TtsPickerOption(
                      value: ReaderLanguageFilter.japaneseOnly,
                      title: '仅日文',
                      subtitle: '仅朗读日文内容',
                      icon: Icons.translate_rounded,
                    ),
                  ],
                );
                if (picked != null) onLanguageFilterChanged(picked);
              },
            ),
            ListTile(
              key: const ValueKey('tts-playback-interval-tile'),
              enabled: mediaControlsEnabled,
              leading: const AppSettingIcon(Icons.hourglass_bottom_rounded),
              title: const Text('语段间隔'),
              subtitle: Text(
                mediaControlsEnabled
                    ? intervalLabel(segmentInterval)
                    : '连接媒体服务后可用',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: !mediaControlsEnabled
                  ? null
                  : () async {
                      final picked = await showTtsOptionSheet<int>(
                        context: context,
                        title: '语段间隔',
                        icon: Icons.hourglass_bottom_rounded,
                        description: '控制句段之间的停顿时长。',
                        selected: segmentInterval.inMilliseconds,
                        options: const [
                          TtsPickerOption(
                            value: 0,
                            title: '无间隔',
                            icon: Icons.flash_on_outlined,
                          ),
                          TtsPickerOption(
                            value: 500,
                            title: '0.5 秒',
                            icon: Icons.hourglass_bottom_rounded,
                          ),
                          TtsPickerOption(
                            value: 1000,
                            title: '1 秒',
                            icon: Icons.hourglass_bottom_rounded,
                          ),
                          TtsPickerOption(
                            value: 2000,
                            title: '2 秒',
                            icon: Icons.hourglass_bottom_rounded,
                          ),
                        ],
                      );
                      if (picked != null) {
                        onSegmentIntervalChanged(
                          Duration(milliseconds: picked),
                        );
                      }
                    },
            ),
            ListTile(
              key: const ValueKey('tts-playback-sleep-tile'),
              enabled: mediaControlsEnabled,
              leading: const AppSettingIcon(Icons.bedtime_outlined),
              title: const Text('睡眠定时'),
              subtitle: Text(
                mediaControlsEnabled
                    ? sleepTimerLabel(sleepTimer)
                    : '连接媒体服务后可用',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: !mediaControlsEnabled
                  ? null
                  : () async {
                      final picked =
                          await showTtsOptionSheet<PlaybackSleepTimer>(
                        context: context,
                        title: '睡眠定时',
                        icon: Icons.bedtime_outlined,
                        selected: sleepTimer,
                        options: const [
                          TtsPickerOption(
                            value: PlaybackSleepTimer.none,
                            title: '关闭',
                            icon: Icons.do_not_disturb_on_outlined,
                          ),
                          TtsPickerOption(
                            value: PlaybackSleepTimer.minutes15,
                            title: '15 分钟',
                            icon: Icons.bedtime_outlined,
                          ),
                          TtsPickerOption(
                            value: PlaybackSleepTimer.minutes30,
                            title: '30 分钟',
                            icon: Icons.bedtime_outlined,
                          ),
                          TtsPickerOption(
                            value: PlaybackSleepTimer.minutes60,
                            title: '60 分钟',
                            icon: Icons.bedtime_outlined,
                          ),
                          TtsPickerOption(
                            value: PlaybackSleepTimer.chapterEnd,
                            title: '本章结束时停止',
                            icon: Icons.menu_book_outlined,
                          ),
                        ],
                      );
                      if (picked != null) onSleepTimerChanged(picked);
                    },
            ),
            SwitchListTile(
              key: const ValueKey('tts-settings-continuous-switch'),
              secondary: const AppSettingIcon(Icons.playlist_play_rounded),
              title: const Text('连续朗读下一章'),
              subtitle: Text(
                mediaControlsEnabled
                    ? '当前章节播完后自动续读下一章'
                    : '连接媒体服务后可用',
              ),
              value: continuousChapter,
              onChanged:
                  mediaControlsEnabled ? onContinuousChapterChanged : null,
            ),
          ],
        ),
      ],
    );
  }
}
