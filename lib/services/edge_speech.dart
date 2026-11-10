import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../reader/reader_language_segments.dart';
import '../reader/reader_speech_session.dart';
import '../reader/reader_tts_core.dart';
import 'edge_protocol.dart';

/// A built-in Edge neural voice. Playback speed is not part of this identity.
class EdgeVoice {
  const EdgeVoice({
    required this.id,
    required this.label,
    required this.locale,
    required this.language,
  });

  final String id;
  final String label;
  final String locale;
  final String language;
}

const defaultEdgeVoice = EdgeVoice(
  id: 'zh-CN-XiaoxiaoNeural',
  label: '晓晓 · 中文女声',
  locale: 'zh-CN',
  language: 'chinese',
);

/// Voices that work without an account. The first entry of each language is
/// the automatic choice.
const builtInEdgeVoices = <EdgeVoice>[
  defaultEdgeVoice,
  EdgeVoice(
    id: 'zh-CN-YunxiNeural',
    label: '云希 · 中文男声',
    locale: 'zh-CN',
    language: 'chinese',
  ),
  EdgeVoice(
    id: 'ja-JP-NanamiNeural',
    label: '七海 · 日文女声',
    locale: 'ja-JP',
    language: 'japanese',
  ),
  EdgeVoice(
    id: 'ja-JP-KeitaNeural',
    label: '圭太 · 日文男声',
    locale: 'ja-JP',
    language: 'japanese',
  ),
  EdgeVoice(
    id: 'ko-KR-SunHiNeural',
    label: '善熙 · 韩文女声',
    locale: 'ko-KR',
    language: 'korean',
  ),
  EdgeVoice(
    id: 'ko-KR-InJoonNeural',
    label: '仁俊 · 韩文男声',
    locale: 'ko-KR',
    language: 'korean',
  ),
  EdgeVoice(
    id: 'en-US-AriaNeural',
    label: 'Aria · 英文女声',
    locale: 'en-US',
    language: 'other',
  ),
];

EdgeVoice? edgeVoiceById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final voice in builtInEdgeVoices) {
    if (voice.id == id) return voice;
  }
  return null;
}

/// Cache identity for Edge audio. [rate] is intentionally fixed: speed is a
/// player setting, so changing it must not resynthesize the chapter.
SpeechSynthesisConfig edgeSpeechConfig({
  String voice = 'zh-CN-XiaoxiaoNeural',
  Map<String, String> voiceByLanguage = const {},
}) {
  final selected = edgeVoiceById(voice) ?? defaultEdgeVoice;
  return SpeechSynthesisConfig(
    source: 'edge',
    voice: selected.id,
    language: selected.locale,
    rate: 1,
    fileExtension: 'mp3',
    options: <String, Object?>{
      'voiceByLanguage': Map<String, String>.unmodifiable(voiceByLanguage),
    },
  );
}

/// Same provider, different language. A missing override stays on that
/// language's default instead of reading Japanese with a Chinese voice.
EdgeVoice edgeVoiceForText(
  String text,
  SpeechSynthesisConfig config,
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
  final overrides = config.options['voiceByLanguage'];
  if (overrides is Map && overrides[language] is String) {
    final chosen = edgeVoiceById(overrides[language] as String);
    if (chosen != null && chosen.language == language) return chosen;
  }
  for (final voice in builtInEdgeVoices) {
    if (voice.language == language) return voice;
  }
  return edgeVoiceById(config.voice) ?? defaultEdgeVoice;
}

class EdgeSpeechException implements Exception {
  const EdgeSpeechException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Microsoft Edge read-aloud client. No subscription key.
class EdgeSpeechClient {
  EdgeSpeechClient({this.clock});

  final DateTime Function()? clock;
  static const host = 'speech.platform.bing.com';
  static const route = '/consumer/speech/synthesize/readaloud';

  static String connectionId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static String escapeXml(String source) => source
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String timestamp(DateTime date) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final d = date.toUtc();
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${days[d.weekday - 1]} ${months[d.month - 1]} ${pad(d.day)} ${d.year} '
        '${pad(d.hour)}:${pad(d.minute)}:${pad(d.second)} GMT+0000 (Coordinated Universal Time)';
  }

  static Map<String, String> headers() => {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
        'Accept-Language': 'en-US,en;q=0.9',
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
        'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
        'Cookie': 'muid=${connectionId().toUpperCase()};',
      };

  static ({String path, Uint8List audio}) binaryAudio(List<int> data) {
    if (data.length < 2) {
      throw const EdgeSpeechException('在线语音返回了不完整的数据');
    }
    final length = (data[0] << 8) | data[1];
    if (length <= 0 || length + 2 > data.length) {
      throw const EdgeSpeechException('在线语音数据头无效');
    }
    final header = utf8.decode(data.sublist(2, length + 2));
    final path =
        RegExp(r'(?:^|\r\n)Path:([^\r\n]+)').firstMatch(header)?.group(1) ??
            '';
    return (path: path, audio: Uint8List.fromList(data.sublist(length + 2)));
  }

  Future<Uint8List> synthesize(String text, EdgeVoice voice) async {
    final spoken = text.trim();
    if (spoken.isEmpty) {
      throw const EdgeSpeechException('这一段没有可朗读的文本');
    }
    final client = HttpClient()
      ..userAgent = null
      ..connectionTimeout = const Duration(seconds: 10);
    WebSocket? socket;
    try {
      final now = (clock?.call() ?? DateTime.now()).toUtc();
      final uri = Uri(
        scheme: 'wss',
        host: host,
        port: 443,
        path: '$route/edge/v1',
        queryParameters: {
          'TrustedClientToken': EdgeProtocol.clientIdentifier,
          'ConnectionId': connectionId(),
          'Sec-MS-GEC': EdgeProtocol.timeProof(now),
          'Sec-MS-GEC-Version': EdgeProtocol.version,
        },
      );
      socket = await WebSocket.connect(
        uri.toString(),
        headers: headers(),
        customClient: client,
      ).timeout(const Duration(seconds: 12));
      socket.add(
        'X-Timestamp:${timestamp(now)}\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n',
      );
      final ssml =
          '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="${voice.locale}">'
          '<voice name="${voice.id}"><prosody pitch="+0Hz" rate="+0%" volume="+0%">${escapeXml(spoken)}</prosody></voice></speak>';
      socket.add(
        'X-RequestId:${connectionId()}\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:${timestamp(now)}Z\r\nPath:ssml\r\n\r\n$ssml',
      );
      final audio = BytesBuilder(copy: false);
      var ended = false;
      await for (final event in socket.timeout(const Duration(seconds: 25))) {
        if (event is List<int>) {
          final frame = binaryAudio(event);
          if (frame.path != 'audio') {
            throw const EdgeSpeechException('在线语音返回了未知的数据类型');
          }
          audio.add(frame.audio);
          if (audio.length > 8 * 1024 * 1024) {
            throw const EdgeSpeechException('单段语音超过缓存上限');
          }
        } else if (event is String &&
            RegExp(r'(?:^|\r\n)Path:turn.end(?:\r\n|$)').hasMatch(event)) {
          ended = true;
          break;
        }
      }
      if (!ended || audio.length < 100) {
        throw const EdgeSpeechException('在线音源没有读完这一段，请检查网络后重试');
      }
      return audio.takeBytes();
    } on EdgeSpeechException {
      rethrow;
    } catch (_) {
      throw const EdgeSpeechException('在线音源连接失败，请检查网络后重试');
    } finally {
      client.close(force: true);
      try {
        await socket?.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }
}
