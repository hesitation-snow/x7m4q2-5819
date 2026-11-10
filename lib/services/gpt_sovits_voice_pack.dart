import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Represents a reference audio entry inside a voice pack.
class GptSoVitsReference {
  const GptSoVitsReference({
    required this.id,
    required this.tag,
    required this.text,
    required this.lang,
    required this.wavPath,
    required this.specPath,
    required this.svPath,
    required this.sslPath,
  });

  final String id;
  final String tag;
  final String text;
  final String lang;
  final String wavPath;
  final String specPath;
  final String svPath;
  final String sslPath;

  factory GptSoVitsReference.fromJson(
      Map<String, dynamic> json, String baseDir) {
    return GptSoVitsReference(
      id: json['id'] as String? ?? 'default',
      tag: json['tag'] as String? ?? '默认',
      text: json['text'] as String? ?? '',
      lang: json['lang'] as String? ?? 'ja',
      wavPath: p.join(baseDir, json['wav'] as String? ?? ''),
      specPath: p.join(baseDir, json['spec'] as String? ?? ''),
      svPath: p.join(baseDir, json['sv'] as String? ?? ''),
      sslPath: p.join(baseDir, json['ssl'] as String? ?? ''),
    );
  }
}

/// Represents an installed or loaded Yomiru Voice Pack.
class GptSoVitsVoicePack {
  const GptSoVitsVoicePack({
    required this.voiceId,
    required this.name,
    required this.modelVersion,
    required this.folderPath,
    required this.topK,
    required this.topP,
    required this.temperature,
    required this.speed,
    required this.sampleRate,
    required this.references,
  });

  final String voiceId;
  final String name;
  final String modelVersion;
  final String folderPath;
  final int topK;
  final double topP;
  final double temperature;
  final double speed;
  final int sampleRate;
  final List<GptSoVitsReference> references;

  String get encoderOnnxPath =>
      p.join(folderPath, 'models', 't2s_encoder.onnx');
  String get fsdecOnnxPath => p.join(folderPath, 'models', 't2s_fsdec.onnx');
  String get sdecOnnxPath => p.join(folderPath, 'models', 't2s_sdec.onnx');
  String get vitsOnnxPath => p.join(folderPath, 'models', 'vits.onnx');

  bool get isValid {
    return File(encoderOnnxPath).existsSync() &&
        File(fsdecOnnxPath).existsSync() &&
        File(sdecOnnxPath).existsSync() &&
        File(vitsOnnxPath).existsSync() &&
        references.isNotEmpty;
  }

  factory GptSoVitsVoicePack.fromFolder(String folderPath) {
    final metaFile = File(p.join(folderPath, 'voice.json'));
    if (!metaFile.existsSync()) {
      throw FileSystemException('voice.json not found', metaFile.path);
    }
    final json =
        jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
    final defaults = json['defaults'] as Map<String, dynamic>? ?? {};
    final rawRefs = (json['references'] as List<dynamic>?) ?? [];

    final refs = rawRefs
        .whereType<Map<String, dynamic>>()
        .map((m) => GptSoVitsReference.fromJson(m, folderPath))
        .toList(growable: false);

    return GptSoVitsVoicePack(
      voiceId: json['voice_id'] as String? ?? p.basename(folderPath),
      name: json['name'] as String? ?? p.basename(folderPath),
      modelVersion: json['model_version'] as String? ?? 'v2Pro',
      folderPath: folderPath,
      topK: (defaults['top_k'] as num?)?.toInt() ?? 10,
      topP: (defaults['top_p'] as num?)?.toDouble() ?? 0.75,
      temperature: (defaults['temperature'] as num?)?.toDouble() ?? 0.65,
      speed: (defaults['speed'] as num?)?.toDouble() ?? 1.0,
      sampleRate: (defaults['sample_rate'] as num?)?.toInt() ?? 32000,
      references: refs,
    );
  }
}

/// Manages installation, deletion and discovery of local voice packs.
class GptSoVitsVoicePackStore {
  const GptSoVitsVoicePackStore({this.directoryProvider});

  final Future<Directory> Function()? directoryProvider;

  Future<Directory> getBaseDir() async {
    final root = directoryProvider != null
        ? await directoryProvider!()
        : await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'yomiru_voice_packs'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<List<GptSoVitsVoicePack>> listVoicePacks() async {
    final base = await getBaseDir();
    if (!base.existsSync()) return const [];
    final results = <GptSoVitsVoicePack>[];
    for (final entity in base.listSync()) {
      if (entity is Directory) {
        try {
          final pack = GptSoVitsVoicePack.fromFolder(entity.path);
          if (pack.isValid) results.add(pack);
        } catch (_) {
          // Ignore invalid or incomplete folders
        }
      }
    }
    return results;
  }

  Future<GptSoVitsVoicePack?> findVoicePack(String voiceId) async {
    final packs = await listVoicePacks();
    return packs.where((p) => p.voiceId == voiceId).firstOrNull;
  }

  Future<void> deleteVoicePack(String voiceId) async {
    final base = await getBaseDir();
    final target = Directory(p.join(base.path, voiceId));
    if (target.existsSync()) {
      target.deleteSync(recursive: true);
    }
  }
}
