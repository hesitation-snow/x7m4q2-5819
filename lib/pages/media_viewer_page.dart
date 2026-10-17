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
import '../widgets/content_state_view.dart';

/// 社交内容图片查看器:预览图保持紧凑,详情页支持缩放和保存。
class MediaViewerPage extends StatefulWidget {
  final String url;
  final List<String>? urls;
  final BaseCacheManager? cacheManager;

  const MediaViewerPage({
    super.key,
    required this.url,
    this.urls,
    this.cacheManager,
  });

  @override
  State<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<MediaViewerPage> {
  bool _saving = false;
  late final List<String> _urls;
  late final PageController _pages;
  final Map<int, TransformationController> _transforms = {};
  int _index = 0;
  bool _zoomed = false;
  int _retry = 0;

  @override
  void initState() {
    super.initState();
    _urls = List.unmodifiable(
        widget.urls?.isNotEmpty == true ? widget.urls! : [widget.url]);
    _index = _urls.indexOf(widget.url).clamp(0, _urls.length - 1);
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    for (final controller in _transforms.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _image(int index) {
    final url = _urls[index];
    final controller =
        _transforms.putIfAbsent(index, TransformationController.new);
    Offset tap = Offset.zero;
    return GestureDetector(
      onDoubleTapDown: (details) => tap = details.localPosition,
      onDoubleTap: () {
        final zoom = controller.value.getMaxScaleOnAxis() > 1.01;
        controller.value = zoom
            ? Matrix4.identity()
            : (Matrix4.identity()
              ..translateByDouble(-tap.dx * 1.5, -tap.dy * 1.5, 0, 1)
              ..scaleByDouble(2.5, 2.5, 1, 1));
        setState(() => _zoomed = !zoom);
      },
      child: InteractiveViewer(
        transformationController: controller,
        minScale: 1,
        maxScale: 6,
        onInteractionEnd: (_) => setState(
            () => _zoomed = controller.value.getMaxScaleOnAxis() > 1.01),
        child: Center(
            child: CachedNetworkImage(
          key: ValueKey('$url:$_retry'),
          fadeOutDuration: AppMotion.duration(context, 150),
          fadeInDuration: AppMotion.duration(context, 150),
          cacheManager: widget.cacheManager,
          cacheKey: widget.cacheManager is IllustrationCacheManager
              ? illustrationCacheKey(url)
              : null,
          imageUrl: url,
          fit: BoxFit.contain,
          progressIndicatorBuilder: (_, __, ___) => const ContentStateView(
              message: '正在加载图片…', loading: true, color: Colors.white70),
          errorWidget: (_, __, ___) => ContentStateView(
              message: '图片加载失败',
              color: Colors.white70,
              icon: Icons.broken_image_outlined,
              onRetry: () async {
                await CachedNetworkImage.evictFromCache(url,
                    cacheManager: widget.cacheManager,
                    cacheKey: widget.cacheManager is IllustrationCacheManager
                        ? illustrationCacheKey(url)
                        : null);
                if (mounted) setState(() => _retry++);
              }),
        )),
      ),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final url = _urls[_index];
    try {
      List<int>? bytes;
      if (widget.cacheManager is IllustrationCacheManager) {
        // 保存与当前大图展示共用同一请求，不能另开 http.get 绕过插画队列。
        final file = await widget.cacheManager!.getSingleFile(url);
        bytes = await file.readAsBytes();
      } else if (widget.cacheManager != null) {
        final fileInfo = await widget.cacheManager!.getFileFromCache(url);
        if (fileInfo != null && fileInfo.file.existsSync()) {
          bytes = await fileInfo.file.readAsBytes();
        }
      }
      if (bytes == null) {
        final response = await http.get(Uri.parse(url), headers: const {
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
            child: PageView.builder(
                controller: _pages,
                itemCount: _urls.length,
                physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
                onPageChanged: (index) => setState(() {
                      for (final controller in _transforms.values) {
                        controller.value = Matrix4.identity();
                      }
                      _index = index;
                      _zoomed = false;
                    }),
                itemBuilder: (_, index) => _image(index)),
          ),
          Positioned(
              top: top + 20,
              left: 70,
              right: 70,
              child: IgnorePointer(
                  child: Text('${_index + 1} / ${_urls.length}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70)))),
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
