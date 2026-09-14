import '../services/app_motion.dart';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;

import '../services/illustration_cache_manager.dart';
import '../services/illustration_identity.dart';
import '../widgets/common.dart';

/// 社交内容图片查看器:预览图保持紧凑,详情页支持缩放和保存。
class MediaViewerPage extends StatefulWidget {
  final String url;
  final BaseCacheManager? cacheManager;

  const MediaViewerPage({
    super.key,
    required this.url,
    this.cacheManager,
  });

  @override
  State<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<MediaViewerPage> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      List<int>? bytes;
      if (widget.cacheManager is IllustrationCacheManager) {
        // 保存与当前大图展示共用同一请求，不能另开 http.get 绕过插画队列。
        final file = await widget.cacheManager!.getSingleFile(widget.url);
        bytes = await file.readAsBytes();
      } else if (widget.cacheManager != null) {
        final fileInfo = await widget.cacheManager!.getFileFromCache(widget.url);
        if (fileInfo != null && fileInfo.file.existsSync()) {
          bytes = await fileInfo.file.readAsBytes();
        }
      }
      if (bytes == null) {
        final response = await http.get(Uri.parse(widget.url), headers: const {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 LKFlutter',
        }).timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          throw Exception('下载失败 HTTP ${response.statusCode}');
        }
        bytes = response.bodyBytes;
      }
      await Gal.putImageBytes(
        Uint8List.fromList(bytes),
        name: 'yomiru_${DateTime.now().millisecondsSinceEpoch}',
        album: 'Yomiru',
      );
      if (!mounted) return;
      showFloatingPrompt(context, '已保存到相册');
    } catch (e) {
      if (mounted) {
        showFloatingPrompt(context, '保存失败: $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 6,
              child: Center(
                child: CachedNetworkImage(
                  fadeOutDuration: AppMotion.duration(context, 1000),
                  fadeInDuration: AppMotion.duration(context, 500),
                  cacheManager: widget.cacheManager,
                  cacheKey: widget.cacheManager is IllustrationCacheManager
                      ? illustrationCacheKey(widget.url)
                      : null,
                  imageUrl: widget.url,
                  fit: BoxFit.contain,
                  progressIndicatorBuilder: (_, __, ___) =>
                      const MotionProgressIndicator(color: Colors.white70),
                  errorWidget: (_, __, ___) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                    size: 48,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: top + 4,
            left: 8,
            child: IconButton(
              tooltip: '关闭',
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: bottom + 20,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: MotionProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.download_rounded),
              label: Text(_saving ? '保存中' : '保存到相册'),
            ),
          ),
        ],
      ),
    );
  }
}
