import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/custom_ssml_tts.dart';
import '../services/reader_audio_handler.dart';

/// The page owns and disposes the injected preview player.
abstract interface class CustomTtsPreviewPlayer {
  Future<void> play(Uint8List mp3Bytes);
  Future<void> stop();
  Future<void> dispose();
}

typedef CustomTtsPreviewPlayerFactory = CustomTtsPreviewPlayer Function();

enum _EndpointMode { azureRegion, fullUrl }

class CustomTtsSettingsPage extends StatefulWidget {
  const CustomTtsSettingsPage({
    super.key,
    required this.tts,
    required this.preferences,
    required this.createPlayer,
    this.initialConfig,
    this.previewText = '这是一段语音试听。',
    this.metadataStorageKey = 'custom_ssml_tts_metadata',
  });

  final CustomSsmlTts tts;
  final SharedPreferences preferences;
  final CustomTtsPreviewPlayerFactory createPlayer;
  final CustomSsmlTtsConfig? initialConfig;
  final String previewText;
  final String metadataStorageKey;

  @override
  State<CustomTtsSettingsPage> createState() => _CustomTtsSettingsPageState();
}

class _CustomTtsSettingsPageState extends State<CustomTtsSettingsPage> {
  late final TextEditingController _endpoint;
  late final TextEditingController _region;
  late final TextEditingController _voice;
  late final TextEditingController _name;
  late final TextEditingController _locale;
  late final TextEditingController _zhVoice;
  late final TextEditingController _jaVoice;
  late final TextEditingController _koVoice;
  late final TextEditingController _credential;
  late final CustomSsmlTtsConfig? _originalConfig;
  late CustomTtsAuthMode _authMode;
  late _EndpointMode _endpointMode;
  final Map<String, String> _fieldErrors = {};
  CustomTtsPreviewPlayer? _player;
  Completer<void>? _abort;
  Future<void> _previewCleanup = Future<void>.value();
  int _previewGeneration = 0;
  int _voicesGeneration = 0;
  bool _previewBusy = false;
  bool _saving = false;
  bool _voicesLoading = false;
  bool _hideCredential = true;
  List<AzureSpeechVoice> _azureVoices = const [];
  String? _saveMessage;
  String? _previewMessage;
  String? _voicesMessage;
  bool _saveError = false;
  bool _previewError = false;
  bool _voicesError = false;

  @override
  void initState() {
    super.initState();
    final metadata = widget.preferences.getString(widget.metadataStorageKey);
    CustomSsmlTtsConfig? config = widget.initialConfig;
    if (config == null && metadata != null) {
      try {
        config =
            CustomSsmlTtsConfig.fromMetadata(decodeCustomTtsMetadata(metadata));
      } catch (_) {
        _saveError = true;
        _saveMessage = '旧语音配置格式无效，请重新填写并保存。';
      }
    }
    _originalConfig = config;
    // Existing URLs remain verbatim in full-URL mode, including custom paths.
    _endpointMode =
        config == null ? _EndpointMode.azureRegion : _EndpointMode.fullUrl;
    _endpoint = TextEditingController(text: config?.endpoint ?? '');
    _region = TextEditingController(text: 'eastasia');
    _voice = TextEditingController(text: config?.voiceId ?? '');
    _name = TextEditingController(text: config?.displayName ?? '');
    _locale = TextEditingController(text: config?.locale ?? '');
    _zhVoice =
        TextEditingController(text: config?.voiceByLanguage['chinese'] ?? '');
    _jaVoice =
        TextEditingController(text: config?.voiceByLanguage['japanese'] ?? '');
    _koVoice =
        TextEditingController(text: config?.voiceByLanguage['korean'] ?? '');
    _credential = TextEditingController();
    _authMode = config?.authMode ?? CustomTtsAuthMode.azureKey;
    for (final controller in [
      _endpoint,
      _region,
      _locale,
      _credential,
    ]) {
      controller.addListener(_invalidateVoiceCatalog);
    }
  }

  String get _effectiveEndpoint => _endpointMode == _EndpointMode.azureRegion
      ? 'https://${_region.text.trim()}.tts.speech.microsoft.com/cognitiveservices/v1'
      : _endpoint.text.trim();

  String? get _draftCredential {
    final draft = _credential.text.trim();
    return draft.isEmpty ? null : draft;
  }

  CustomSsmlTtsConfig _config() => CustomSsmlTtsConfig(
        endpoint: _effectiveEndpoint,
        voiceId: _voice.text.trim(),
        displayName: _name.text.trim(),
        locale: _locale.text.trim(),
        authMode: _authMode,
        audioFormat:
            _originalConfig?.audioFormat ?? defaultCustomTtsAudioFormat,
        timeout: _originalConfig?.timeout ?? defaultCustomTtsTimeout,
        localeByLanguage: _originalConfig?.localeByLanguage ?? const {},
        voiceByLanguage: <String, String>{
          ...?_originalConfig?.voiceByLanguage,
          if (_zhVoice.text.trim().isNotEmpty) 'chinese': _zhVoice.text.trim(),
          if (_jaVoice.text.trim().isNotEmpty) 'japanese': _jaVoice.text.trim(),
          if (_koVoice.text.trim().isNotEmpty) 'korean': _koVoice.text.trim(),
        }..removeWhere((key, _) => switch (key) {
              'chinese' => _zhVoice.text.trim().isEmpty,
              'japanese' => _jaVoice.text.trim().isEmpty,
              'korean' => _koVoice.text.trim().isEmpty,
              _ => false,
            }),
      );

  void _invalidateVoiceCatalog() {
    _voicesGeneration++;
    if (!mounted) return;
    setState(() {
      _voicesLoading = false;
      _azureVoices = const [];
      _voicesMessage = null;
    });
  }

  bool _validate({bool saving = false, bool voicesOnly = false}) {
    final errors = <String, String>{};
    if (_endpointMode == _EndpointMode.azureRegion) {
      if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9-]*$').hasMatch(_region.text.trim())) {
        errors['region'] = '请输入 Azure 区域名称，例如 eastasia。';
      }
    } else if (!isValidCustomTtsEndpoint(_effectiveEndpoint)) {
      errors['endpoint'] = '请输入有效 HTTPS endpoint（默认端口 443，不含账号密码）。';
    }
    if (!voicesOnly) {
      if (_voice.text.trim().isEmpty) errors['voice'] = '请填写音色 ID。';
      if (_locale.text.trim().isEmpty) errors['locale'] = '请填写语言，例如 zh-CN。';
      if (saving && _name.text.trim().isEmpty) {
        errors['name'] = '请填写便于识别的显示名称。';
      }
    }
    if (_authMode != CustomTtsAuthMode.none &&
        (_credential.text.contains('\r') || _credential.text.contains('\n'))) {
      errors['credential'] = '密钥 / Token 应为单行文本。';
    }
    setState(() {
      _fieldErrors
        ..clear()
        ..addAll(errors);
    });
    return errors.isEmpty;
  }

  Future<void> _loadAzureVoices() async {
    if (_saving || _voicesLoading) return;
    if (!_validate(voicesOnly: true)) {
      setState(() {
        _voicesError = true;
        _voicesMessage = '请检查连接与认证输入。';
      });
      return;
    }
    final source = Uri.tryParse(_effectiveEndpoint);
    if (_authMode != CustomTtsAuthMode.azureKey ||
        source == null ||
        !source.host.toLowerCase().endsWith('.tts.speech.microsoft.com')) {
      setState(() {
        _voicesError = true;
        _voicesMessage = '音色目录需要 Azure Key 和 Azure 区域 HTTPS endpoint。';
      });
      return;
    }
    final generation = ++_voicesGeneration;
    setState(() {
      _voicesLoading = true;
      _voicesError = false;
      _voicesMessage = '正在获取 Azure 音色目录…';
    });
    try {
      final voices = await widget.tts.listAzureVoices(
        endpoint: _effectiveEndpoint,
        locale: _locale.text.trim(),
        credentialOverride: _draftCredential,
      );
      if (!mounted || generation != _voicesGeneration) return;
      setState(() {
        _azureVoices = voices;
        _voicesMessage =
            voices.isEmpty ? '此语言没有返回可用音色。' : '已获取 ${voices.length} 个音色。';
      });
    } catch (error) {
      if (!mounted || generation != _voicesGeneration) return;
      setState(() {
        _voicesError = true;
        _voicesMessage = error is CustomTtsError
            ? _friendlyError(error)
            : '获取音色失败，请检查网络、区域与密钥后重试。';
      });
    } finally {
      if (mounted && generation == _voicesGeneration) {
        setState(() => _voicesLoading = false);
      }
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    if (!_validate(saving: true)) {
      setState(() {
        _saveError = true;
        _saveMessage = '请检查标记的输入项后再保存。';
      });
      return;
    }
    final config = _config();
    final credential = _draftCredential;
    setState(() {
      _saving = true;
      _saveError = false;
      _saveMessage = null;
    });
    try {
      if (config.authMode == CustomTtsAuthMode.none) {
        await widget.tts.clearCredential();
      } else if (credential != null) {
        await widget.tts.saveCredential(credential);
      }
      final saved = await widget.preferences.setString(
          widget.metadataStorageKey, encodeCustomTtsMetadata(config));
      if (!saved) throw StateError('Metadata was not saved.');
      if (!mounted) return;
      _credential.clear();
      setState(() {
        _saveMessage = '设置已保存；密钥仅保存在安全存储中。';
      });
    } catch (_) {
      if (!mounted) return;
      // Storage exceptions may contain secret values; never display raw details.
      setState(() {
        _saveError = true;
        _saveMessage = '保存失败，请检查设备存储后重试。草稿已保留。';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _isCurrentPreview(int generation, Completer<void> abort) =>
      mounted && generation == _previewGeneration && !abort.isCompleted;

  Future<void> _preview() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    final generation = ++_previewGeneration;
    final cleanup = _releasePreview();
    if (!_validate()) {
      setState(() {
        _previewBusy = false;
        _previewError = true;
        _previewMessage = '请检查连接、音色与认证输入后再试听。';
      });
      await cleanup;
      return;
    }
    final config = _config();
    final credential = _draftCredential;
    final abort = createCustomTtsAbortTrigger();
    _abort = abort;
    setState(() {
      _previewBusy = true;
      _previewError = false;
      _previewMessage = '正在生成试听…';
    });
    try {
      // Queue cleanup so a slow previous stop cannot stop a newer playback.
      await cleanup;
      if (!_isCurrentPreview(generation, abort)) return;
      final player = widget.createPlayer();
      _player = player;
      final result = await widget.tts.synthesize(
        config: config,
        text: widget.previewText,
        abortTrigger: abort,
        credentialOverride: credential,
      );
      if (!_isCurrentPreview(generation, abort)) return;
      if (!result.isSuccess) {
        setState(() {
          _previewError = true;
          _previewMessage =
              result.error == null ? '试听生成失败。' : _friendlyError(result.error!);
          _previewBusy = false;
        });
        await _releasePreview();
        return;
      }
      setState(() => _previewMessage = '试听音频已生成，正在播放。');
      await player.play(result.audio!);
      if (_isCurrentPreview(generation, abort)) {
        setState(() => _previewBusy = false);
      }
    } catch (_) {
      if (!_isCurrentPreview(generation, abort)) return;
      setState(() {
        _previewError = true;
        _previewMessage = '试听播放失败，请检查音频服务与输出格式。';
        _previewBusy = false;
      });
      await _releasePreview();
    }
  }

  Future<void> _releasePreview() {
    final abort = _abort;
    _abort = null;
    if (abort != null && !abort.isCompleted) abort.complete();
    final player = _player;
    _player = null;
    _previewCleanup = _previewCleanup.then((_) async {
      if (player == null) return;
      try {
        await player.stop();
      } catch (_) {}
      try {
        await player.dispose();
      } catch (_) {}
    });
    return _previewCleanup;
  }

  Future<void> _stopPreview() {
    _previewGeneration++;
    final cleanup = _releasePreview();
    setState(() {
      _previewBusy = false;
      _previewError = false;
      _previewMessage = '试听已取消。';
    });
    return cleanup;
  }

  String _friendlyError(CustomTtsError error) => switch (error.code) {
        CustomTtsErrorCode.missingCredential =>
          '请填写密钥 / Token，或使用已安全保存的密钥；试听无需先保存。',
        CustomTtsErrorCode.invalidEndpoint => '请检查 HTTPS endpoint 与 Azure 区域。',
        CustomTtsErrorCode.timeout => '请求超时，请检查网络后重试。',
        CustomTtsErrorCode.network => '请求失败，请检查网络、区域与服务地址。',
        CustomTtsErrorCode.cancelled => '试听已取消。',
        _ => error.message,
      };

  @override
  void dispose() {
    _previewGeneration++;
    _voicesGeneration++;
    unawaited(_releasePreview());
    for (final controller in [
      _endpoint,
      _region,
      _locale,
      _credential,
    ]) {
      controller.removeListener(_invalidateVoiceCatalog);
    }
    for (final controller in [
      _endpoint,
      _region,
      _voice,
      _name,
      _locale,
      _zhVoice,
      _jaVoice,
      _koVoice,
      _credential,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _field(String label, TextEditingController controller,
          {String? id,
          String? hint,
          String? helper,
          TextInputType? keyboardType,
          bool secret = false,
          TextInputAction action = TextInputAction.next}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: TextField(
          key: id == null ? null : ValueKey('custom-tts-$id'),
          controller: controller,
          enabled: !_saving,
          keyboardType: keyboardType,
          textInputAction: action,
          obscureText: secret && _hideCredential,
          enableSuggestions: false,
          autocorrect: false,
          onChanged: (_) {
            if (_fieldErrors.containsKey(id)) {
              setState(() => _fieldErrors.remove(id));
            }
          },
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            helperText: helper,
            helperMaxLines: 5,
            errorText: _fieldErrors[id],
            errorMaxLines: 5,
            border: const OutlineInputBorder(),
            suffixIcon: secret
                ? IconButton(
                    tooltip: _hideCredential ? '显示密钥' : '隐藏密钥',
                    onPressed: () =>
                        setState(() => _hideCredential = !_hideCredential),
                    icon: Icon(_hideCredential
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                  )
                : null,
          ),
        ),
      );

  Widget _section(String title, IconData icon, List<Widget> children) =>
      Card.filled(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Icon(icon, color: Theme.of(context).colorScheme.primary),
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 20),
              ...children,
            ],
          ),
        ),
      );

  Widget _status(String? message, bool error, String id) {
    if (message == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        liveRegion: true,
        child: Text(
          message,
          key: ValueKey(id),
          style:
              TextStyle(color: error ? colors.error : colors.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _progress() => const SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('自定义语音服务')),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _section('连接', Icons.cloud_outlined, [
                    DropdownButtonFormField<_EndpointMode>(
                      initialValue: _endpointMode,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '服务地址方式',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: _EndpointMode.azureRegion,
                          child: Text('Azure 区域'),
                        ),
                        DropdownMenuItem(
                          value: _EndpointMode.fullUrl,
                          child: Text('完整 HTTPS endpoint'),
                        ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value == null) return;
                              if (value == _EndpointMode.fullUrl &&
                                  _endpoint.text.isEmpty) {
                                _endpoint.text = _effectiveEndpoint;
                              }
                              setState(() {
                                _endpointMode = value;
                                _fieldErrors.clear();
                              });
                              _invalidateVoiceCatalog();
                            },
                    ),
                    const SizedBox(height: 16),
                    if (_endpointMode == _EndpointMode.azureRegion)
                      _field('Azure 区域', _region,
                          id: 'region',
                          hint: '例如 eastasia、eastus',
                          helper: '填写 Azure Speech 资源所在区域，自动生成标准 HTTPS 地址。')
                    else
                      _field('完整 HTTPS endpoint', _endpoint,
                          id: 'endpoint',
                          hint: defaultMicrosoftSpeechEndpoint,
                          keyboardType: TextInputType.url,
                          helper: '保留完整路径；支持 Microsoft Speech REST 兼容服务。'),
                  ]),
                  _section('音色', Icons.record_voice_over_outlined, [
                    _field('音色 ID', _voice,
                        id: 'voice', hint: '例如 zh-CN-XiaoxiaoNeural'),
                    _field('显示名称', _name,
                        id: 'name', helper: '用于识别此配置；仅保存时必填。'),
                    _field('语言', _locale,
                        id: 'locale', hint: '例如 zh-CN、ja-JP、en-US'),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('分语言音色（可选）'),
                      subtitle: const Text('留空时使用上方默认音色'),
                      children: [
                        _field('中文音色 ID', _zhVoice,
                            hint: '例如 zh-CN-XiaoxiaoNeural'),
                        _field('日语音色 ID', _jaVoice,
                            hint: '例如 ja-JP-NanamiNeural'),
                        _field('韩语音色 ID', _koVoice,
                            hint: '例如 ko-KR-SunHiNeural'),
                      ],
                    ),
                    if (_authMode == CustomTtsAuthMode.azureKey) ...[
                      const SizedBox(height: 12),
                      Wrap(children: [
                        OutlinedButton.icon(
                          key: const ValueKey('custom-tts-load-voices'),
                          onPressed: _voicesLoading || _saving
                              ? null
                              : _loadAzureVoices,
                          icon: _voicesLoading
                              ? _progress()
                              : const Icon(Icons.refresh_rounded),
                          label: Text(
                              _voicesLoading ? '正在获取音色…' : '获取 Azure 音色列表'),
                        ),
                      ]),
                      if (_azureVoices.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          key: ValueKey(_azureVoices),
                          initialValue: _azureVoices
                                  .any((voice) => voice.id == _voice.text)
                              ? _voice.text
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '选择 Azure 音色',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final voice in _azureVoices)
                              DropdownMenuItem(
                                value: voice.id,
                                child: Text(
                                  '${voice.name} · ${voice.locale}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _saving
                              ? null
                              : (id) {
                                  if (id == null) return;
                                  final voice = _azureVoices.firstWhere(
                                      (candidate) => candidate.id == id);
                                  setState(() {
                                    _voice.text = voice.id;
                                    _name.text = voice.name;
                                    _locale.text = voice.locale;
                                    _fieldErrors.remove('voice');
                                    _fieldErrors.remove('name');
                                    _fieldErrors.remove('locale');
                                  });
                                },
                        ),
                      ],
                      _status(_voicesMessage, _voicesError,
                          'custom-tts-voices-status'),
                    ],
                  ]),
                  _section('认证', Icons.key_outlined, [
                    DropdownButtonFormField<CustomTtsAuthMode>(
                      initialValue: _authMode,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '认证方式',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                            value: CustomTtsAuthMode.none, child: Text('无认证')),
                        DropdownMenuItem(
                            value: CustomTtsAuthMode.azureKey,
                            child: Text('Azure Key')),
                        DropdownMenuItem(
                            value: CustomTtsAuthMode.bearer,
                            child: Text('Bearer Token')),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) {
                              setState(() {
                                _authMode = value ?? CustomTtsAuthMode.none;
                                _fieldErrors.remove('credential');
                              });
                              _invalidateVoiceCatalog();
                            },
                    ),
                    const SizedBox(height: 16),
                    if (_authMode != CustomTtsAuthMode.none)
                      _field('密钥 / Token（单独安全保存）', _credential,
                          id: 'credential',
                          hint: '留空使用已保存密钥',
                          helper: '草稿可直接用于试听和获取音色，无需先保存；保存成功后清空此处。',
                          secret: true,
                          action: TextInputAction.done)
                    else
                      const Text('当前不发送认证信息；保存时将清除已有密钥。'),
                  ]),
                  _section('试听', Icons.headphones_outlined, [
                    Text(widget.previewText,
                        style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.secondaryContainer.withValues(alpha: .55),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Text(
                          '计费提示：试听及正文朗读会调用所配置的服务，可能按字符或请求计费。正文发送提示：使用此服务朗读时，正文文本会发送至该 endpoint。'),
                    ),
                    const SizedBox(height: 16),
                    Wrap(spacing: 10, runSpacing: 8, children: [
                      OutlinedButton.icon(
                        key: const ValueKey('custom-tts-preview'),
                        onPressed: _saving ? null : _preview,
                        icon: _previewBusy
                            ? _progress()
                            : const Icon(Icons.play_arrow_rounded),
                        label: Text(_previewBusy ? '再次试听' : '试听'),
                      ),
                      if (_previewBusy || _player != null)
                        OutlinedButton.icon(
                          onPressed: _stopPreview,
                          icon: const Icon(Icons.stop_rounded),
                          label: const Text('取消试听'),
                        ),
                    ]),
                    _status(_previewMessage, _previewError,
                        'custom-tts-preview-status'),
                  ]),
                  FilledButton.icon(
                    key: const ValueKey('custom-tts-save'),
                    onPressed: _saving ? null : _save,
                    icon:
                        _saving ? _progress() : const Icon(Icons.save_outlined),
                    label: Text(_saving ? '正在保存…' : '保存'),
                  ),
                  _status(_saveMessage, _saveError, 'custom-tts-status'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An adapter can feed bytes through a temporary source while keeping
/// playback lifecycle ownership explicit at the page boundary.
abstract interface class CustomTtsAudioHandlerAdapter {
  Future<void> playMp3(Uint8List bytes);
  Future<void> stop();
  Future<void> dispose();
}

class AudioHandlerCustomTtsPreviewPlayer implements CustomTtsPreviewPlayer {
  AudioHandlerCustomTtsPreviewPlayer(this.handler);
  final CustomTtsAudioHandlerAdapter handler;
  @override
  Future<void> play(Uint8List mp3Bytes) => handler.playMp3(mp3Bytes);
  @override
  Future<void> stop() => handler.stop();
  @override
  Future<void> dispose() => handler.dispose();
}

/// The shared media handler remains owned by AudioService/main.dart.
class ReaderAudioHandlerTtsAdapter implements CustomTtsAudioHandlerAdapter {
  ReaderAudioHandlerTtsAdapter(this.handler);
  final ReaderAudioHandler handler;
  static int _nextSourceId = 0;
  final String _sourceId =
      'custom-preview:${DateTime.now().microsecondsSinceEpoch}:${_nextSourceId++}';
  int _revision = 0;

  @override
  Future<void> playMp3(Uint8List bytes) async {
    final revision = ++_revision;
    if (handler.ttsOwnerKey != null || handler.speechSessionOwnerKey != null) {
      await handler.stop();
    }
    if (revision != _revision) return;
    final isWav = bytes.length >= 12 &&
        String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
        String.fromCharCodes(bytes.skip(8).take(4)) == 'WAVE';
    await handler.playBytes(bytes,
        title: '自定义语音试听',
        id: _sourceId,
        contentType: isWav ? 'audio/wav' : 'audio/mpeg');
  }

  @override
  Future<void> stop() async {
    ++_revision;
    // A closing settings page must not stop a newer reader/preview source.
    if (handler.mediaItem.valueOrNull?.id == _sourceId) await handler.stop();
  }

  @override
  Future<void> dispose() async {
    // The shared media handler remains owned by AudioService/main.dart.
  }
}
