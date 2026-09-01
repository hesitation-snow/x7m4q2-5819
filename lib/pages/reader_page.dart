import 'dart:async';
import 'dart:collection';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_open_chinese_convert/flutter_open_chinese_convert.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../api/reader_cache.dart';
import '../api/reading_session.dart';
import '../api/store.dart';
import '../widgets/common.dart';
import '../reader/scroll_layout_index.dart';
import 'catalog_paging.dart';
import 'login_page.dart';
import '../reader/reading_position.dart';
import 'search_page.dart';

/// 正文块:文本(可含链接区间)或插画
class _BodyBlock {
  final String? image;
  final double? aspect; // 插画宽高比(width/height),用于翻页模式精确命中区域
  final String text;

  /// 链接区间 (start, end, url),相对于 [text] 的下标
  final List<(int, int, String)> links;
  _BodyBlock.text(this.text, [this.links = const []])
      : image = null,
        aspect = null;
  _BodyBlock.image(this.image, {this.aspect})
      : text = '',
        links = const [];
}

@visibleForTesting
Future<List<({String? image, String text, double? aspect})>>
    parseReaderHtmlForTesting(String html) async {
  final blocks = await _ReaderPageState._parseHtmlOffMainIsolate(html);
  return blocks
      .map((block) =>
          (image: block.image, text: block.text, aspect: block.aspect))
      .toList(growable: false);
}

/// 翻页模式:一页内的条目(切分后的文本/插画)
class _PageItem {
  final String? image;
  final double? aspect;
  final String text;
  final List<(int, int, String)> links;
  final int blockIndex;
  final int startOffset;
  final int endOffset;
  _PageItem.text(this.text, this.links,
      {required this.blockIndex,
      required this.startOffset,
      required this.endOffset})
      : image = null,
        aspect = null;
  _PageItem.image(this.image, {this.aspect, required this.blockIndex})
      : text = '',
        startOffset = 0,
        endOffset = 0,
        links = const [];
}

/// 保留内部名称，避免把正文分页代码和 UI 细节耦合到具体模型名称。
typedef _ReadingAnchor = ReadingPosition;

/// 翻页模式:一页
class _Page {
  final List<_PageItem> items;
  final bool chapterEnd; // 章末导航页
  final bool unlockCard; // 付费解锁卡片页
  _Page(this.items, {this.chapterEnd = false, this.unlockCard = false});
}

/// 阅读器(LightNovelReader + Apple Books 风格):
/// - 全屏沉浸,点击唤出,滑动隐藏,小齿轮设置
/// - 设置面板三页签:外观/操作/边距
/// - 点击翻页 / 音量键翻页 / 保持常亮 / 隐藏状态栏 / 指示器
class ReaderPage extends StatefulWidget {
  final int bookId;
  final String bookTitle;
  final int chapterId;
  final String chapterTitle;
  final int volumeId;
  const ReaderPage(
      {super.key,
      required this.bookId,
      required this.bookTitle,
      required this.chapterId,
      required this.chapterTitle,
      required this.volumeId});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  static const int _parsedChapterCacheLimit = 8;
  static final LinkedHashMap<String, List<_BodyBlock>> _parsedChapterCache =
      LinkedHashMap<String, List<_BodyBlock>>();
  static int _parsedCacheGeneration = ReaderContentCache.generation;
  String _title = '';
  List<_BodyBlock> _blocks = [_BodyBlock.text('加载中…')];
  int? _prevId;
  String? _prevTitle;
  int? _prevVolumeId;
  int? _nextId;
  String? _nextTitle;
  int? _nextVolumeId;
  bool _locked = false;
  bool _unlocked = false;
  bool _loading = true;
  String? _loadError;
  bool _chrome = true;

  /// 章节真实所在卷(详情接口返回,入口传的 volumeId 可能是默认卷,不可靠)
  int _effectiveVolumeId = 0;
  bool _unlocking = false;
  int _coinPrice = 0;
  int _coins = -1; // -1 表示余额未知
  bool _paged = false;
  final PageController _pageController = PageController();
  List<_Page> _pages = [_Page(const [], chapterEnd: true)];
  int _pageIndex = 0;
  bool _chapterSwitching = false;
  _ReadingAnchor? _pendingPagedAnchor;
  int? _pendingPositionTransitionId;
  bool _restoringPagedProgress = false;

  /// 翻页模式分页缓存键(内容/尺寸变化时重建分页)
  String _pagedKey = '';

  /// 已参与分页的正文块(内容变化检测)
  List<_BodyBlock> _pagesSource = const [];

  // 偏好
  double _fontSize = 17;
  double _lineHeight = 1.7;
  int _bg = 0;
  bool _bgChosen = false;

  /// 外观:跟随系统深浅色
  bool _bgFollowSystem = true;
  bool _keepOn = false;
  bool _hideBar = false;
  bool _tapTurn = false;
  bool _autoMargin = true;
  double _mt = 56, _mb = 70, _ml = 20, _mr = 20;
  bool _indicators = true;
  bool _traditional = false;
  bool _simplified = false;

  /// 缓存的章节详情(切换简繁时本地重解析,不重新请求)
  LKChapterDetail? _detail;
  LKChapterDetail? _parsedDetail;
  int _parsedMode = -1;
  List<_BodyBlock>? _parsedBlocks;
  late final Future<void> _prefsReady;

  Future<void>? _adjacentResolutionFuture;
  final Set<int> _prefetchingChapterIds = <int>{};
  Future<void>? _catalogWarmFuture;
  Future<List<LKVolume>>? _volumesFuture;
  List<LKVolume>? _volumesCache;
  final Map<String, Future<LKChapterPage>> _chapterPageFutures = {};
  final Map<String, LKChapterPage> _chapterPageCache = {};

  final _sc = ScrollController();
  final _shareButtonKey = GlobalKey();
  List<GlobalKey> _scrollTextKeys = const [];
  List<double> _blockProgressOffsets = const [0, 1];
  ReaderScrollLayoutIndex? _scrollLayoutIndex;
  String _scrollLayoutIndexKey = '';
  final ReadingPositionController _positionController =
      ReadingPositionController();
  int _positionRestoreSerial = 0;
  int _scrollProgressGeneration = 0;
  bool _restoringScrollAnchor = false;
  bool _progressUpdateScheduled = false;
  Timer? _positionPersistTimer;
  double _scrollLayoutWidth = 0;
  bool _scrollLayoutLockedBody = false;

  /// 正文文字区域的指针跟踪。
  /// SelectionArea 会优先处理文字手势，这里用 Listener 旁路记录短按，
  /// 让点到文字时仍按翻页规则工作，同时保留长按选择复制。
  Offset? _textPointerStart;
  DateTime? _textPointerDownAt;
  bool _textPointerMoved = false;
  bool _textPointerHandled = false;
  bool _suppressNextTextTap = false;
  int _textTapSerial = 0;

  /// 滚动进度通知(正文指示器实时刷新,无需整页重建)
  final ValueNotifier<double> _progressN = ValueNotifier<double>(0);
  Timer? _readingReportTimer;
  Future<void>? _readingReportFuture;
  int _reportedReadingSeconds = 0;
  bool _finishingReadingSession = false;

  static const _presets = [
    (Color(0xFFFFFFFF), Color(0xFF333333), '白'),
    (Color(0xFFF7F1E3), Color(0xFF3D362A), '米黄'),
    (Color(0xFF2A2D34), Color(0xFFC9CDD6), '深灰'),
    (Color(0xFF000000), Color(0xFF9AA0A6), '纯黑'),
  ];

  bool get _sysDark => Theme.of(context).brightness == Brightness.dark;
  int get _bgEff => _bgFollowSystem ? (_sysDark ? 2 : 0) : _bg;
  Color get _bgColor => _presets[_bgEff].$1;
  Color get _textColor => _presets[_bgEff].$2;
  bool get _isDarkBg => _bgEff >= 2;

  _ReadingAnchor? get _logicalAnchor => _positionController.value;

  /// 进度始终从正文锚点推导，避免“百分比”和真实位置分别维护后漂移。
  double get _progress {
    final anchor = _positionController.value;
    return anchor == null ? 0 : _progressForAnchor(anchor);
  }

  void _syncProgressUi(_ReadingAnchor anchor, {bool updateSession = true}) {
    final progress = _progressForAnchor(anchor);
    _progressN.value = progress;
    if (updateSession) {
      LKReadingSession.shared
          .update(volumeId: _effectiveVolumeId, progress: progress);
    }
  }

  bool _publishPosition(_ReadingAnchor anchor,
      {int? transitionId,
      bool updateSession = true,
      bool persist = true,
      bool syncUi = true}) {
    final normalized = _normalizeAnchor(anchor);
    final accepted =
        _positionController.update(normalized, transitionId: transitionId);
    if (!accepted) return false;
    if (syncUi) {
      _syncProgressUi(normalized, updateSession: updateSession);
    }
    if (persist) _schedulePositionPersist();
    return true;
  }

  bool _completePositionTransition(int transitionId, _ReadingAnchor anchor) {
    final normalized = _normalizeAnchor(anchor);
    final accepted =
        _positionController.completeTransition(transitionId, normalized);
    if (!accepted) return false;
    _syncProgressUi(normalized);
    _schedulePositionPersist();
    return true;
  }

  void _schedulePositionPersist() {
    _positionPersistTimer?.cancel();
    _positionPersistTimer = Timer(const Duration(milliseconds: 300), _savePos);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _title = widget.chapterTitle;
    _effectiveVolumeId = widget.volumeId;
    _sc.addListener(_onScroll);
    _prefsReady = _loadPrefs();
    _load();
  }

  void _onScroll() {
    if (!_sc.hasClients) return;
    if (_paged || _restoringScrollAnchor || _progressUpdateScheduled) return;
    final generation = _scrollProgressGeneration;
    _progressUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _progressUpdateScheduled = false;
      if (!mounted ||
          _paged ||
          _restoringScrollAnchor ||
          generation != _scrollProgressGeneration) {
        return;
      }
      final anchor = _captureScrollAnchor();
      if (anchor == null) return;
      final next = _progressForAnchor(anchor);
      if ((next - _progress).abs() < 0.0005) return;
      _publishPosition(anchor);
    });
  }

  double _blockProgressWeight(_BodyBlock block) {
    if (block.image != null) return 400;
    return block.text.isEmpty ? 1 : block.text.length.toDouble();
  }

  double _scrollContentWidth([double? viewportWidth]) {
    final width = viewportWidth ??
        (_scrollLayoutWidth > 0
            ? _scrollLayoutWidth
            : MediaQuery.sizeOf(context).width);
    return (width - _bodyPadding.left - _bodyPadding.right)
        .clamp(1.0, 2000.0)
        .toDouble();
  }

  bool _isLockedText(_BodyBlock block, bool lockedBody) {
    return lockedBody && block.links.isEmpty && block.text == '(本章暂无内容)';
  }

  String _scrollTextContent(_BodyBlock block, {required bool lockedBody}) {
    return _isLockedText(block, lockedBody) ? '本章需要轻币解锁' : block.text;
  }

  TextSpan _scrollTextSpan(_BodyBlock block, {required bool lockedBody}) {
    final hint = _isLockedText(block, lockedBody);
    return TextSpan(
      style: _bodyTextStyle,
      children: hint ? const [TextSpan(text: '本章需要轻币解锁')] : _spansFor(block),
    );
  }

  TextPainter _scrollTextPainter(int index,
      {double? viewportWidth, bool? lockedBody}) {
    final block = _blocks[index];
    final displayText = _scrollTextContent(
      block,
      lockedBody: lockedBody ?? _scrollLayoutLockedBody,
    );
    return TextPainter(
      // 链接只改变颜色和下划线，不改变排版尺寸；不在测量阶段创建
      // TapGestureRecognizer，避免每次 Sliver 布局都产生不可回收对象。
      text: TextSpan(style: _bodyTextStyle, text: displayText),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout(maxWidth: _scrollContentWidth(viewportWidth));
  }

  double _scrollImageHeight(_BodyBlock block, double contentWidth) {
    final aspect = block.aspect;
    if (aspect != null && aspect > 0) {
      return (contentWidth / aspect).clamp(1.0, 10000.0).toDouble();
    }
    // 未提供原图比例时保留一个稳定的竖向插画区域，并使用 contain
    // 展示完整图片。固定布局尺寸可避免图片解码后改变全文滚动坐标。
    return (contentWidth * 1.35).clamp(180.0, 720.0).toDouble();
  }

  String _scrollLayoutKey(double viewportWidth, bool lockedBody) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    return '${identityHashCode(_blocks)}|${viewportWidth.round()}|'
        '${_fontSize.toStringAsFixed(2)}|${_lineHeight.toStringAsFixed(2)}|'
        '${_bodyPadding.left}|${_bodyPadding.top}|${_bodyPadding.right}|'
        '${_bodyPadding.bottom}|$lockedBody|'
        '${scale.toStringAsFixed(3)}';
  }

  void _ensureScrollLayoutIndex(double viewportWidth, bool lockedBody) {
    final key = _scrollLayoutKey(viewportWidth, lockedBody);
    if (_scrollLayoutIndexKey == key &&
        _scrollLayoutIndex?.length == _blocks.length) {
      return;
    }

    final contentWidth = _scrollContentWidth(viewportWidth);
    final extents = <double>[];
    for (var index = 0; index < _blocks.length; index++) {
      final block = _blocks[index];
      if (block.image != null) {
        extents.add(_scrollImageHeight(block, contentWidth) + 20);
        continue;
      }
      final painter = _scrollTextPainter(
        index,
        viewportWidth: viewportWidth,
        lockedBody: lockedBody,
      );
      extents.add(painter.height.clamp(1.0, 100000.0).toDouble() + 12);
      painter.dispose();
    }
    _scrollLayoutIndexKey = key;
    _scrollLayoutIndex = ReaderScrollLayoutIndex(
      itemExtents: extents,
      leadingPadding: _bodyPadding.top,
    );
  }

  double _scrollTextCaretOffset(int index, int textOffset,
      {double? viewportWidth, bool? lockedBody}) {
    final painter = _scrollTextPainter(
      index,
      viewportWidth: viewportWidth,
      lockedBody: lockedBody,
    );
    final displayLength = _scrollTextContent(
      _blocks[index],
      lockedBody: lockedBody ?? _scrollLayoutLockedBody,
    ).length;
    final safeOffset = textOffset.clamp(0, displayLength);
    final result = painter
        .getOffsetForCaret(TextPosition(offset: safeOffset), Rect.zero)
        .dy;
    painter.dispose();
    return result;
  }

  _ReadingAnchor _snapAnchorToScrollLine(_ReadingAnchor rawAnchor) {
    final anchor = _normalizeAnchor(rawAnchor);
    if (_blocks.isEmpty || _blocks[anchor.blockIndex].image != null) {
      return anchor;
    }
    final block = _blocks[anchor.blockIndex];
    final offset = (anchor.textOffset ??
            (block.text.length * anchor.blockFraction).round())
        .clamp(0, block.text.length);
    final painter = _scrollTextPainter(anchor.blockIndex);
    final line = painter.getLineBoundary(TextPosition(offset: offset));
    painter.dispose();
    return ReadingPosition.text(
      blockIndex: anchor.blockIndex,
      offset: line.start.clamp(0, block.text.length),
    );
  }

  /// 精确布局索引是滚动位置的唯一像素来源，不读取 maxScrollExtent 的
  /// 中间估值，也不依赖目标子项是否已经挂载。
  double? _scrollOffsetForAnchor(_ReadingAnchor rawAnchor) {
    final layout = _scrollLayoutIndex;
    if (layout == null || layout.length != _blocks.length || _blocks.isEmpty) {
      return null;
    }
    final anchor = _normalizeAnchor(rawAnchor);
    final index = anchor.blockIndex.clamp(0, _blocks.length - 1);
    final contentWidth = _scrollContentWidth();
    final block = _blocks[index];
    double localOffset;
    if (block.image != null) {
      localOffset = 10 +
          _scrollImageHeight(block, contentWidth) *
              anchor.blockFraction.clamp(0.0, 1.0).toDouble();
    } else {
      final text = _scrollTextContent(
        block,
        lockedBody: _scrollLayoutLockedBody,
      );
      final textOffset = anchor.textOffset == null
          ? (text.length * anchor.blockFraction.clamp(0.0, 1.0)).round()
          : anchor.textOffset!.clamp(0, text.length);
      localOffset = _scrollTextCaretOffset(index, textOffset);
    }
    return layout.scrollOffsetForItem(index, localOffset: localOffset);
  }

  void _applyBlocks(List<_BodyBlock> blocks) {
    _blocks = blocks;
    _scrollLayoutIndexKey = '';
    _scrollLayoutIndex = null;
    _scrollTextKeys = List<GlobalKey>.generate(
      blocks.length,
      (i) => GlobalKey(debugLabel: 'reader-text-$i'),
      growable: false,
    );
    final offsets = <double>[0];
    for (final block in blocks) {
      offsets.add(offsets.last + _blockProgressWeight(block));
    }
    if (offsets.last <= 0) offsets[offsets.length - 1] = 1;
    _blockProgressOffsets = offsets;
  }

  /// 将旧百分比/旧布局产生的锚点限制到当前正文，并把文本位置统一成
  /// Flutter 使用的 UTF-16 偏移。这样字体、窗口尺寸变化后仍能指向同一字。
  _ReadingAnchor _normalizeAnchor(_ReadingAnchor anchor) {
    if (_blocks.isEmpty) return const _ReadingAnchor(0, 0);
    final index = anchor.blockIndex.clamp(0, _blocks.length - 1);
    final block = _blocks[index];
    if (block.image != null) {
      return ReadingPosition.image(
        blockIndex: index,
        fraction: anchor.blockFraction.clamp(0.0, 1.0).toDouble(),
      );
    }
    final length = block.text.length;
    if (length == 0) return ReadingPosition.text(blockIndex: index, offset: 0);
    final offset = anchor.textOffset == null
        ? (length * anchor.blockFraction.clamp(0.0, 1.0)).round()
        : anchor.textOffset!.clamp(0, length);
    return ReadingPosition.text(blockIndex: index, offset: offset);
  }

  double _progressForAnchor(_ReadingAnchor anchor) {
    if (_blocks.isEmpty || _blockProgressOffsets.length != _blocks.length + 1) {
      return 0;
    }
    final index = anchor.blockIndex.clamp(0, _blocks.length - 1);
    final start = _blockProgressOffsets[index];
    final end = _blockProgressOffsets[index + 1];
    final block = _blocks[index];
    final fraction = anchor.textOffset == null || block.text.isEmpty
        ? anchor.blockFraction
        : anchor.textOffset!.clamp(0, block.text.length).toDouble() /
            block.text.length;
    final position =
        start + (end - start) * fraction.clamp(0.0, 1.0).toDouble();
    return (position / _blockProgressOffsets.last).clamp(0.0, 1.0);
  }

  _ReadingAnchor _anchorForProgress(double rawProgress) {
    if (_blocks.isEmpty || _blockProgressOffsets.length != _blocks.length + 1) {
      return const _ReadingAnchor(0, 0);
    }
    final progress = rawProgress.clamp(0.0, 1.0).toDouble();
    final target = _blockProgressOffsets.last * progress;
    var low = 0;
    var high = _blocks.length - 1;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_blockProgressOffsets[mid + 1] < target) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final start = _blockProgressOffsets[low];
    final end = _blockProgressOffsets[low + 1];
    final fraction = end <= start ? 0.0 : (target - start) / (end - start);
    final block = _blocks[low];
    final normalizedFraction = fraction.clamp(0.0, 1.0).toDouble();
    if (block.image != null || block.text.isEmpty) {
      return _ReadingAnchor(low, normalizedFraction);
    }
    return ReadingPosition.text(
      blockIndex: low,
      offset: (block.text.length * normalizedFraction).round(),
    );
  }

  _ReadingAnchor? _captureScrollAnchor() {
    try {
      return _captureScrollAnchorUnsafe();
    } catch (_) {
      // 渲染树在滚动/切换模式的同一帧内可能正在拆装，位置采样失败
      // 不应把一个内部 RenderObject 异常升级成阅读器崩溃。
      return null;
    }
  }

  _ReadingAnchor? _captureScrollAnchorUnsafe() {
    final layout = _scrollLayoutIndex;
    if (_blocks.isEmpty ||
        layout == null ||
        layout.length != _blocks.length ||
        !_sc.hasClients) {
      return null;
    }
    if ((_sc.position.maxScrollExtent > 0 &&
            _sc.offset >= _sc.position.maxScrollExtent - 1) ||
        _sc.offset >= layout.scrollContentEnd - 1) {
      return _ReadingAnchor(_blocks.length - 1, 1);
    }
    final location = layout.locate(_sc.offset);
    final index = location.index.clamp(0, _blocks.length - 1);
    final block = _blocks[index];
    if (block.image != null) {
      final imageHeight = _scrollImageHeight(block, _scrollContentWidth());
      final imageOffset =
          (location.localOffset - 10).clamp(0.0, imageHeight).toDouble();
      return ReadingPosition.image(
        blockIndex: index,
        fraction: imageHeight <= 0 ? 0 : imageOffset / imageHeight,
      );
    }

    final textObject =
        _scrollTextKeys[index].currentContext?.findRenderObject();
    final textRender = textObject is RenderParagraph ? textObject : null;
    final localY = location.localOffset.clamp(
      0.0,
      textRender != null && textRender.attached && textRender.hasSize
          ? textRender.size.height
          : layout.itemExtents[index],
    );
    int offset;
    if (textRender != null && textRender.attached && textRender.hasSize) {
      offset = textRender.getPositionForOffset(Offset(0.5, localY)).offset;
    } else {
      final painter = _scrollTextPainter(index);
      offset = painter.getPositionForOffset(Offset(0.5, localY)).offset;
      painter.dispose();
    }
    return ReadingPosition.text(
      blockIndex: index,
      offset: offset.clamp(0, block.text.length),
    );
  }

  _ReadingAnchor? _anchorForPage(int rawPageIndex) {
    if (_blocks.isEmpty || _pages.isEmpty) return null;
    final pageIndex = rawPageIndex.clamp(0, _pages.length - 1);
    final page = _pages[pageIndex];
    if (page.items.isNotEmpty) {
      final item = page.items.first;
      final blockIndex = item.blockIndex.clamp(0, _blocks.length - 1);
      if (item.image != null) {
        return ReadingPosition.imagePage(blockIndex: blockIndex);
      }
      final length = _blocks[blockIndex].text.length;
      return length <= 0
          ? _ReadingAnchor(blockIndex, 0)
          : ReadingPosition.text(
              blockIndex: blockIndex, offset: item.startOffset);
    }
    if (page.chapterEnd || pageIndex >= _pages.length - 1) {
      final last = _blocks.length - 1;
      return _blocks[last].image != null
          ? ReadingPosition.image(blockIndex: last, fraction: 1)
          : ReadingPosition.text(
              blockIndex: last, offset: _blocks[last].text.length);
    }
    for (var i = pageIndex - 1; i >= 0; i--) {
      if (_pages[i].items.isEmpty) continue;
      final item = _pages[i].items.last;
      final blockIndex = item.blockIndex.clamp(0, _blocks.length - 1);
      final length = _blocks[blockIndex].text.length;
      if (item.image != null) {
        return ReadingPosition.image(blockIndex: blockIndex, fraction: 1);
      }
      return length <= 0
          ? _ReadingAnchor(blockIndex, 1)
          : ReadingPosition.text(
              blockIndex: blockIndex, offset: item.endOffset);
    }
    return const _ReadingAnchor(0, 0);
  }

  int? _pageForAnchor(_ReadingAnchor anchor, [List<_Page>? source]) {
    final pages = source ?? _pages;
    if (_blocks.isEmpty || pages.isEmpty) return null;
    final blockIndex = anchor.blockIndex.clamp(0, _blocks.length - 1);
    final block = _blocks[blockIndex];
    final offset = anchor.textOffset == null
        ? (block.text.length * anchor.blockFraction.clamp(0.0, 1.0)).round()
        : anchor.textOffset!.clamp(0, block.text.length);
    int? nearestPage;
    for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      for (final item in pages[pageIndex].items) {
        if (item.blockIndex < blockIndex) continue;
        nearestPage ??= pageIndex;
        if (item.blockIndex > blockIndex) return nearestPage;
        if (item.image != null ||
            (offset >= item.startOffset && offset < item.endOffset) ||
            (offset == block.text.length && item.endOffset == offset)) {
          return pageIndex;
        }
      }
    }
    return nearestPage ?? (pages.length - 1);
  }

  bool _anchorsClose(_ReadingAnchor first, _ReadingAnchor second) {
    final a = _normalizeAnchor(first);
    final b = _normalizeAnchor(second);
    if (a.blockIndex != b.blockIndex) return false;
    final block = _blocks[a.blockIndex];
    if (block.image != null) {
      return (a.blockFraction - b.blockFraction).abs() <= 0.01;
    }
    return ((a.textOffset ?? 0) - (b.textOffset ?? 0)).abs() <= 2;
  }

  Future<void> _restoreScrollAnchor(_ReadingAnchor anchor,
      {bool animate = false,
      bool retainAnchor = false,
      int? transitionId}) async {
    final targetAnchor = _snapAnchorToScrollLine(anchor);
    final targetProgress = _progressForAnchor(targetAnchor);
    final serial = ++_positionRestoreSerial;
    final generation = ++_scrollProgressGeneration;
    _restoringScrollAnchor = true;
    var confirmed = false;
    _ReadingAnchor? actual;
    double? pendingOffset;
    try {
      for (var attempt = 0; attempt < 6; attempt++) {
        if (!mounted ||
            _paged ||
            serial != _positionRestoreSerial ||
            generation != _scrollProgressGeneration) {
          return;
        }
        final layout = _scrollLayoutIndex;
        if (!_sc.hasClients ||
            layout == null ||
            layout.length != _blocks.length) {
          await WidgetsBinding.instance.endOfFrame;
          continue;
        }

        final exactOffset =
            pendingOffset ?? _scrollOffsetForAnchor(targetAnchor);
        pendingOffset = null;
        if (exactOffset == null) {
          await WidgetsBinding.instance.endOfFrame;
          continue;
        }
        final target = exactOffset
            .clamp(_sc.position.minScrollExtent, _sc.position.maxScrollExtent)
            .toDouble();
        if (animate && attempt == 0) {
          await _sc.animateTo(
            target,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
          );
        } else {
          _sc.jumpTo(target);
        }
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || serial != _positionRestoreSerial) return;

        actual = _captureScrollAnchor();
        if (actual == null) continue;
        if (_anchorsClose(actual, targetAnchor) ||
            (_progressForAnchor(actual) - targetProgress).abs() <= 0.0005) {
          confirmed = true;
          return;
        }

        // 理论上精确索引一次即可落位；系统字体的字形取整若产生亚像素
        // 差异，再根据实际字符进度作一次闭环校正。
        final correction = (targetProgress - _progressForAnchor(actual)) *
            layout.contentExtent;
        final corrected = (_sc.offset + correction)
            .clamp(_sc.position.minScrollExtent, _sc.position.maxScrollExtent)
            .toDouble();
        if ((corrected - _sc.offset).abs() < 0.5) break;
        pendingOffset = corrected;
      }
    } catch (_) {
      // 页面关闭或滚动手势接管时停止恢复，不向用户显示内部定位错误。
    } finally {
      if (mounted && serial == _positionRestoreSerial) {
        _restoringScrollAnchor = false;
        actual = _captureScrollAnchor() ?? actual;
        // 只有闭环验证通过后才提交目标锚点；失败时提交真实落点，UI、
        // 阅读记录和持久化位置始终来自同一份事实。
        final effectiveAnchor = confirmed && retainAnchor
            ? targetAnchor
            : (actual ??
                (confirmed
                    ? targetAnchor
                    : _positionController.value ?? targetAnchor));
        if (transitionId == null) {
          _publishPosition(effectiveAnchor);
        } else {
          _completePositionTransition(transitionId, effectiveAnchor);
        }
      }
    }
  }

  @override
  void dispose() {
    // 让所有未完成的异步恢复回调失效，避免在 PositionController 已经
    // dispose 后仍然提交位置。
    _positionRestoreSerial++;
    _scrollProgressGeneration++;
    _readingReportTimer?.cancel();
    LKReadingSession.shared.pause();
    unawaited(_reportReadingProgress(force: true));
    WidgetsBinding.instance.removeObserver(this);
    _positionPersistTimer?.cancel();
    _savePos();
    _sc.dispose();
    _pageController.dispose();
    _progressN.dispose();
    _positionController.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        LKReadingSession.shared.resume();
        _startReadingReportTimer();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        LKReadingSession.shared.pause();
        unawaited(_reportReadingProgress(force: true));
      case AppLifecycleState.hidden:
        LKReadingSession.shared.pause();
        unawaited(_reportReadingProgress(force: true));
    }
  }

  void _startReadingReportTimer() {
    if (_readingReportTimer != null || !LKClient.shared.session.isLoggedIn) {
      assert(() {
        debugPrint(
            '[Yomiru reading] report timer not started: not logged in or already running');
        return true;
      }());
      return;
    }
    assert(() {
      debugPrint('[Yomiru reading] report timer started');
      return true;
    }());
    _readingReportTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      unawaited(_reportReadingProgress());
    });
  }

  Future<void> _finishReadingSession() async {
    if (_finishingReadingSession) return;
    _finishingReadingSession = true;
    _readingReportTimer?.cancel();
    _readingReportTimer = null;
    LKReadingSession.shared.pause();
    await _reportReadingProgress(force: true);
  }

  Future<void> _reportReadingProgress({bool force = false}) async {
    final existing = _readingReportFuture;
    if (existing != null) {
      await existing;
      return;
    }
    final future = _performReadingReport(force: force);
    _readingReportFuture = future;
    try {
      await future;
    } finally {
      if (identical(_readingReportFuture, future)) {
        _readingReportFuture = null;
      }
    }
  }

  Future<void> _performReadingReport({required bool force}) async {
    if (!LKClient.shared.session.isLoggedIn) return;
    final snapshot = LKReadingSession.shared.snapshot();
    if (snapshot == null) {
      assert(() {
        debugPrint('[Yomiru reading] report skipped: no active session');
        return true;
      }());
      return;
    }
    final unreported = snapshot.readDurationSeconds - _reportedReadingSeconds;
    if (unreported < (force ? 1 : 15)) {
      assert(() {
        debugPrint(
            '[Yomiru reading] report skipped: ${snapshot.readDurationSeconds}s total, $_reportedReadingSeconds s reported');
        return true;
      }());
      return;
    }
    final activeSecondsDelta = unreported > 300 ? 300 : unreported;
    try {
      assert(() {
        debugPrint(
            '[Yomiru reading] report start: total=${snapshot.readDurationSeconds}s delta=${activeSecondsDelta}s progress=${snapshot.progressPercent}%');
        return true;
      }());
      await LKApi.reportReadingProgress(
        bookId: snapshot.bookId,
        volumeId: snapshot.volumeId,
        chapterId: snapshot.chapterId,
        progressPercent: snapshot.progressPercent,
        readDurationSeconds: snapshot.readDurationSeconds,
        activeSecondsDelta: activeSecondsDelta,
      );
      _reportedReadingSeconds += activeSecondsDelta;
      assert(() {
        debugPrint('[Yomiru reading] report accepted');
        return true;
      }());
    } catch (_) {
      // 阅读上报失败不打断阅读；下一次心跳或离开阅读器时重试。
      assert(() {
        debugPrint('[Yomiru reading] report failed: $_');
        return true;
      }());
    }
  }

  Future<bool> _handleWillPop() async {
    await _finishReadingSession();
    return true;
  }

  /// 保存与排版无关的正文进度，切换滚动/翻页模式仍指向同一段内容。
  void _savePos() {
    final anchor = _positionController.value;
    final frac = _progress;
    if (anchor != null && frac > 0.005) {
      unawaited(ReaderPrefs.setReadPosFrac(widget.chapterId, frac));
      unawaited(ReaderPrefs.setPosition(widget.chapterId, anchor));
    }
  }

  Future<void> _loadPrefs() async {
    final prefs = await ReaderPrefs.loadAll();
    final tradChanged =
        _traditional != prefs.traditional || _simplified != prefs.simplified;
    if (!mounted) return;
    setState(() {
      _fontSize = prefs.fontSize;
      _lineHeight = prefs.lineHeight;
      if (prefs.bgPreset >= 0) {
        _bg = prefs.bgPreset;
        _bgChosen = true;
        // 选过具体预设的老用户保持固定;新用户默认跟随系统
        _bgFollowSystem = prefs.bgFollowSystem;
      }
      _keepOn = prefs.keepScreenOn;
      _hideBar = prefs.hideStatusBar;
      _tapTurn = prefs.tapTurnPage;
      _autoMargin = prefs.autoMargin;
      _mt = prefs.marginTop;
      _mb = prefs.marginBottom;
      _ml = prefs.marginLeft;
      _mr = prefs.marginRight;
      _indicators = prefs.showIndicators;
      _traditional = prefs.traditional;
      _simplified = prefs.simplified;
      _paged = prefs.pagedMode;
    });
    // 偏好到达后,若章节已加载且简繁状态有变化,则本地重解析
    if (tradChanged && _detail != null) {
      await _reparseCurrentDetail();
    }
    WakelockPlus.toggle(enable: _keepOn);
    _applyImmersive();
  }

  Future<void> _reparseCurrentDetail() async {
    final detail = _detail;
    if (detail == null) return;
    final blocks = await _parseBlocks(detail);
    if (!mounted || _detail?.hasSameContent(detail) != true) return;
    final anchor = _positionController.value;
    setState(() => _applyBlocks(blocks));
    if (!_paged && anchor != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_paged) {
          unawaited(_restoreScrollAnchor(_normalizeAnchor(anchor),
              retainAnchor: true));
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_bgChosen) {
      _bg = Theme.of(context).brightness == Brightness.dark ? 2 : 0;
    }
  }

  void _applyImmersive() {
    SystemChrome.setEnabledSystemUIMode(
        _hideBar ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  /// UID 0 is the anonymous/public cache scope. A logged-in session without a
  /// valid UID must not fall back to that shared scope.
  int? get _readerCacheOwnerUid {
    final session = LKClient.shared.session;
    if (!session.isLoggedIn) return 0;
    return session.uid > 0 ? session.uid : null;
  }

  // ==================== 加载与解析 ====================

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final cacheOwnerUid = _readerCacheOwnerUid;
    final cacheGeneration = ReaderContentCache.generation;
    // 阅读位置和正文缓存互不依赖，并行读取可以缩短命中缓存时的首屏等待。
    final localStateFuture = Future.wait<Object?>([
      ReaderPrefs.readPosition(widget.chapterId),
      ReaderPrefs.readPosFrac(widget.chapterId),
      cacheOwnerUid == null
          ? Future<LKChapterDetail?>.value(null)
          : ReaderContentCache.read(widget.bookId, widget.chapterId,
              ownerUid: cacheOwnerUid),
    ]);
    // Preferences and local content are read concurrently, but parsing waits
    // for the selected script mode so a cached chapter is rendered only once.
    await _prefsReady;
    final localState = await localStateFuture;
    final savedPosition = localState[0] as ReadingPosition?;
    final savedFrac = localState[1] as double;
    final restore = (savedFrac > 0.02 && savedFrac < 0.98) ? savedFrac : 0.0;

    // 先展示本机已经读过的正文,避免每次打开都等待网络。
    final cached = localState[2] as LKChapterDetail?;
    if (!mounted) return;
    if (_readerCacheOwnerUid != cacheOwnerUid ||
        ReaderContentCache.generation != cacheGeneration) {
      unawaited(_load());
      return;
    }
    if (cached != null) {
      await _renderDetail(cached,
          restore: restore,
          restorePosition: true,
          savedPosition: savedPosition);
      if (!mounted) return;
      if (_readerCacheOwnerUid != cacheOwnerUid ||
          ReaderContentCache.generation != cacheGeneration) {
        unawaited(_load());
        return;
      }
      setState(() => _loading = false);
      _resolveAdjacentOrPrefetch();
      // 缓存只负责快速展示,仍在后台向服务端刷新,防止正文过期。
      unawaited(_refreshFromNetwork(restore,
          cacheOwnerUid: cacheOwnerUid,
          cacheGeneration: cacheGeneration,
          savedPosition: savedPosition));
      return;
    }

    // 没有缓存时保持原来的在线加载流程。
    await _refreshFromNetwork(restore,
        initialLoad: true,
        cacheOwnerUid: cacheOwnerUid,
        cacheGeneration: cacheGeneration,
        savedPosition: savedPosition);
  }

  Future<void> _refreshFromNetwork(double restore,
      {bool initialLoad = false,
      required int? cacheOwnerUid,
      required int cacheGeneration,
      ReadingPosition? savedPosition}) async {
    try {
      final d = await LKApi.chapterDetail(widget.bookId, widget.chapterId);
      if (!mounted) return;
      if (_readerCacheOwnerUid != cacheOwnerUid ||
          ReaderContentCache.generation != cacheGeneration) {
        unawaited(_load());
        return;
      }
      final old = _detail;
      if (old == null || !old.hasSameContent(d)) {
        // 首次在线加载恢复上次进度;缓存刷新时不打断用户当前阅读位置。
        await _renderDetail(d,
            restore: restore,
            restorePosition: initialLoad && old == null,
            savedPosition: savedPosition);
      } else {
        // 正文没有变化时只刷新锁定状态、标题和前后章信息,避免重排版。
        _updateDetailState(d);
      }
      if (!mounted) return;
      setState(() => _loading = false);

      // 只缓存公开正文或当前账号已解锁的付费正文。
      if (cacheOwnerUid != null) {
        unawaited(ReaderContentCache.write(widget.bookId, d,
            ownerUid: cacheOwnerUid, expectedGeneration: cacheGeneration));
      }
      if (d.locked && !d.unlocked) _refreshCoins();
      if (LKClient.shared.session.isLoggedIn && !d.locked) {
        unawaited(() async {
          try {
            await LKApi.saveHistory(
                widget.bookId,
                _effectiveVolumeId,
                widget.chapterId,
                (initialLoad ? restore : _progress * 100)
                    .round()
                    .clamp(0, 100));
          } catch (_) {}
        }());
      }
      _resolveAdjacentOrPrefetch();
    } catch (e) {
      // 有缓存时网络失败不覆盖正文;只有首次加载失败才显示错误。
      if (initialLoad && mounted) {
        final accessError = e is LKException && e.accessRestricted;
        setState(() {
          if (accessError) {
            _loadError = e.message;
            _applyBlocks(const []);
          } else {
            _applyBlocks([_BodyBlock.text('加载失败: $e')]);
          }
          _loading = false;
        });
      }
    }
  }

  Future<void> _renderDetail(LKChapterDetail d,
      {required double restore,
      required bool restorePosition,
      ReadingPosition? savedPosition}) async {
    final blocks = await _parseBlocks(d);
    if (!mounted) return;
    _updateDetailState(d, blocks: blocks);
    if (LKClient.shared.session.isLoggedIn && (!d.locked || d.unlocked)) {
      LKReadingSession.shared.begin(
        bookId: widget.bookId,
        volumeId: d.volumeId > 0 ? d.volumeId : widget.volumeId,
        chapterId: widget.chapterId,
      );
      assert(() {
        debugPrint(
            '[Yomiru reading] session started: book=${widget.bookId} chapter=${widget.chapterId}');
        return true;
      }());
      _startReadingReportTimer();
    }
    if (restorePosition) {
      final anchor =
          _normalizeAnchor(savedPosition ?? _anchorForProgress(restore));
      _publishPosition(anchor, persist: false);
      // 保存值对应正文逻辑位置，不直接换算尚未稳定的滚动总高度。
      if (_paged) {
        _pendingPagedAnchor = anchor;
        _restoringPagedProgress = true;
      } else if (_progress > 0) {
        _scheduleRestoreJumps(anchor);
      }
    }
  }

  void _updateDetailState(LKChapterDetail d, {List<_BodyBlock>? blocks}) {
    _detail = d;
    if (!mounted) return;
    setState(() {
      _title = d.title.isEmpty ? _title : d.title;
      if (blocks != null) _applyBlocks(blocks);
      _locked = d.locked;
      _unlocked = d.unlocked;
      _coinPrice = d.coinPrice;
      _effectiveVolumeId = d.volumeId > 0 ? d.volumeId : widget.volumeId;
      _prevId = d.prevChapterId;
      _prevTitle = d.prevTitle;
      _prevVolumeId = d.prevVolumeId;
      _nextId = d.nextChapterId;
      _nextTitle = d.nextTitle;
      _nextVolumeId = d.nextVolumeId;
    });
  }

  void _resolveAdjacentOrPrefetch() {
    if (_prevId == null || _nextId == null) {
      if (_adjacentResolutionFuture != null) return;
      final task = _resolveAdjacent();
      _adjacentResolutionFuture = task;
      unawaited(task.whenComplete(() {
        if (identical(_adjacentResolutionFuture, task)) {
          _adjacentResolutionFuture = null;
        }
        if (mounted) {
          unawaited(_prefetchAdjacentChapters());
          unawaited(_warmCatalogContext());
        }
      }));
    } else {
      unawaited(_prefetchAdjacentChapters());
      unawaited(_warmCatalogContext());
    }
  }

  /// Cache both adjacent chapters. Forward navigation is requested first, and
  /// the in-flight API guard prevents a rapid page switch from duplicating it.
  Future<void> _prefetchAdjacentChapters() async {
    final ids = <int>[
      if (_nextId != null) _nextId!,
      if (_prevId != null && _prevId != _nextId) _prevId!,
    ].where((id) => id != widget.chapterId).toList(growable: false);
    await Future.wait(ids.map(_prefetchChapter));
  }

  Future<void> _prefetchChapter(int chapterId) async {
    if (!_prefetchingChapterIds.add(chapterId)) return;
    try {
      final cacheOwnerUid = _readerCacheOwnerUid;
      if (cacheOwnerUid == null) return;
      final cacheGeneration = ReaderContentCache.generation;
      if (await ReaderContentCache.contains(widget.bookId, chapterId,
          ownerUid: cacheOwnerUid)) {
        return;
      }
      final d = await LKApi.chapterDetail(widget.bookId, chapterId);
      if (!mounted ||
          _readerCacheOwnerUid != cacheOwnerUid ||
          ReaderContentCache.generation != cacheGeneration) {
        return;
      }
      await ReaderContentCache.write(widget.bookId, d,
          ownerUid: cacheOwnerUid, expectedGeneration: cacheGeneration);
    } catch (_) {
      // 预取失败不影响当前章节阅读。
    } finally {
      _prefetchingChapterIds.remove(chapterId);
    }
  }

  /// Warm the exact catalog page used by the current chapter. The catalog
  /// sheet then reuses LKApi's in-flight/persistent response cache on first open.
  Future<void> _warmCatalogContext() {
    final existing = _catalogWarmFuture;
    if (existing != null) return existing;
    final task = () async {
      try {
        final detail = _detail;
        if (detail == null || _effectiveVolumeId <= 0) return;
        final page = detail.chapterNo > 0
            ? catalogPageForChapter(
                chapterNo: detail.chapterNo,
                // 章节序号足以定位服务端分页，不必为取得卷总数先拉完整目录。
                total: 0,
                pageSize: 50,
              )
            : 1;
        await _chapterPageAt(_effectiveVolumeId, page);
      } catch (_) {
        // Catalog warming is opportunistic and never blocks the reader.
      }
    }();
    _catalogWarmFuture = task;
    return task.whenComplete(() {
      if (identical(_catalogWarmFuture, task)) _catalogWarmFuture = null;
    });
  }

  /// 按正文锚点恢复滚动位置，不依赖仍会变化的懒加载总高度。
  void _scheduleRestoreJumps(_ReadingAnchor anchor) {
    final normalized = _normalizeAnchor(anchor);
    unawaited(_restoreScrollAnchor(normalized, retainAnchor: true));
  }

  /// 拉取轻币余额(失败静默,余额显示保持未知)
  Future<void> _refreshCoins() async {
    try {
      final c = await LKApi.myCoins();
      if (mounted && _locked && !_unlocked) setState(() => _coins = c);
    } catch (_) {}
  }

  Future<LKChapterPage> _chapterPageAt(int volumeId, int page) async {
    final normalizedPage = page < 1 ? 1 : page;
    final key = '$volumeId:$normalizedPage';
    final cached = _chapterPageCache[key];
    if (cached != null) return cached;
    final existing = _chapterPageFutures[key];
    if (existing != null) return existing;
    final future = LKApi.chapterPage(widget.bookId, volumeId, normalizedPage);
    _chapterPageFutures[key] = future;
    try {
      final result = await future;
      _chapterPageCache[key] = result;
      return result;
    } finally {
      if (identical(_chapterPageFutures[key], future)) {
        _chapterPageFutures.remove(key);
      }
    }
  }

  /// 拉取全书全部卷
  Future<List<LKVolume>> _allVolumes() async {
    final cached = _volumesCache;
    if (cached != null) return cached;
    final existing = _volumesFuture;
    if (existing != null) return existing;
    final future = LKApi.allVolumes(widget.bookId);
    _volumesFuture = future;
    try {
      final volumes = await future;
      _volumesCache = volumes;
      return volumes;
    } finally {
      if (identical(_volumesFuture, future)) _volumesFuture = null;
    }
  }

  void _usePreviousChapter(LKChapter chapter, int volumeId) {
    _prevId = chapter.chapterId;
    _prevTitle = chapter.title;
    _prevVolumeId = volumeId;
  }

  void _useNextChapter(LKChapter chapter, int volumeId) {
    _nextId = chapter.chapterId;
    _nextTitle = chapter.title;
    _nextVolumeId = volumeId;
  }

  Future<LKChapter?> _firstChapter(LKVolume volume) async {
    final page = await _chapterPageAt(volume.volumeId, 1);
    return page.items.isEmpty ? null : page.items.first;
  }

  Future<LKChapter?> _lastChapter(LKVolume volume) async {
    final pageCount = catalogPageCount(volume.chapterCount, 50);
    final page =
        await _chapterPageAt(volume.volumeId, pageCount > 0 ? pageCount : 1);
    return page.items.isEmpty ? null : page.items.last;
  }

  /// 服务端缺少 navigation 时，只请求当前章节附近的分页来补齐前后章。
  /// 即使单卷包含上千章，也不会为了两个相邻章节下载完整目录。
  Future<void> _resolveAdjacent() async {
    try {
      final detail = _detail;
      final chapterNo = detail?.chapterNo ?? 0;
      if (chapterNo <= 0) return;
      final volumes = await _allVolumes();
      if (!mounted) return;
      final volumeIndex =
          volumes.indexWhere((v) => v.volumeId == _effectiveVolumeId);
      if (volumeIndex < 0) return;
      final volume = volumes[volumeIndex];
      final sourcePage = catalogPageForChapter(
        chapterNo: chapterNo,
        total: volume.chapterCount,
        pageSize: 50,
      );
      final page = await _chapterPageAt(volume.volumeId, sourcePage);
      if (!mounted) return;
      final chapterIndex =
          page.items.indexWhere((c) => c.chapterId == widget.chapterId);
      if (chapterIndex < 0) return;

      if (_prevId == null) {
        if (chapterIndex > 0) {
          _usePreviousChapter(page.items[chapterIndex - 1], volume.volumeId);
        } else if (sourcePage > 1) {
          final previousPage =
              await _chapterPageAt(volume.volumeId, sourcePage - 1);
          if (previousPage.items.isNotEmpty) {
            _usePreviousChapter(previousPage.items.last, volume.volumeId);
          }
        } else if (volumeIndex > 0) {
          final previous = await _lastChapter(volumes[volumeIndex - 1]);
          if (previous != null) {
            _usePreviousChapter(previous, volumes[volumeIndex - 1].volumeId);
          }
        }
      }

      if (_nextId == null) {
        if (chapterIndex < page.items.length - 1) {
          _useNextChapter(page.items[chapterIndex + 1], volume.volumeId);
        } else {
          final pageCount = catalogPageCount(
              page.total > 0 ? page.total : volume.chapterCount, 50);
          if (page.hasMore || sourcePage < pageCount) {
            final nextPage =
                await _chapterPageAt(volume.volumeId, sourcePage + 1);
            if (nextPage.items.isNotEmpty) {
              _useNextChapter(nextPage.items.first, volume.volumeId);
            }
          } else if (volumeIndex < volumes.length - 1) {
            final next = await _firstChapter(volumes[volumeIndex + 1]);
            if (next != null) {
              _useNextChapter(next, volumes[volumeIndex + 1].volumeId);
            }
          }
        }
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  int get _scriptMode => _traditional
      ? 1
      : _simplified
          ? 2
          : 0;

  Future<List<_BodyBlock>> _parseBlocks(LKChapterDetail d) async {
    final mode = _scriptMode;
    if (_parsedMode == mode &&
        _parsedDetail?.hasSameContent(d) == true &&
        _parsedBlocks != null) {
      return _parsedBlocks!;
    }

    if (_parsedCacheGeneration != ReaderContentCache.generation) {
      _parsedChapterCache.clear();
      _parsedCacheGeneration = ReaderContentCache.generation;
    }
    final source = d.bodyHtml?.isNotEmpty == true ? d.bodyHtml! : d.bodyText;
    final cacheKey = '${d.chapterId}:$mode:${source.length}:${source.hashCode}';
    final shared = _parsedChapterCache.remove(cacheKey);
    if (shared != null) {
      _parsedChapterCache[cacheKey] = shared;
      _parsedDetail = d;
      _parsedMode = mode;
      _parsedBlocks = shared;
      return shared;
    }

    var html = d.bodyHtml;
    List<_BodyBlock> blocks = const [];
    if (html != null && html.isNotEmpty) {
      // 简繁转换(整章一次转换;OpenCC 不影响 HTML 标签/实体)
      if (mode == 1) {
        html = await ChineseConverter.convert(html, S2T());
      } else if (mode == 2) {
        html = await ChineseConverter.convert(html, T2S());
      }
      blocks = await _parseHtmlOffMainIsolate(html);
    }
    if (blocks.isEmpty) {
      var text = d.bodyText;
      if (mode == 1) {
        text = await ChineseConverter.convert(text, S2T());
      } else if (mode == 2) {
        text = await ChineseConverter.convert(text, T2S());
      }
      blocks = await _parseTextOffMainIsolate(text);
    }

    // A rapid script-mode change supersedes this parse instead of briefly
    // showing content produced for the previous selection.
    if (mode != _scriptMode) return _parseBlocks(d);
    final result = List<_BodyBlock>.unmodifiable(
        blocks.isEmpty ? [_BodyBlock.text('(本章暂无内容)')] : blocks);
    _parsedDetail = d;
    _parsedMode = mode;
    _parsedBlocks = result;
    _parsedChapterCache[cacheKey] = result;
    while (_parsedChapterCache.length > _parsedChapterCacheLimit) {
      _parsedChapterCache.remove(_parsedChapterCache.keys.first);
    }
    return result;
  }

  static Future<List<_BodyBlock>> _parseHtmlOffMainIsolate(String html) =>
      html.length < 12000
          ? Future.value(_parseHtmlBlocks(html))
          : compute(_parseHtmlBlocks, html,
              debugLabel: 'Yomiru chapter HTML parser');

  static Future<List<_BodyBlock>> _parseTextOffMainIsolate(String text) =>
      text.length < 12000
          ? Future.value(_parseTextBlocks(text))
          : compute(_parseTextBlocks, text,
              debugLabel: 'Yomiru chapter text parser');

  static List<_BodyBlock> _parseHtmlBlocks(String html) {
    final blocks = <_BodyBlock>[];
    var pos = 0;
    for (final m in _imageTagRe.allMatches(html)) {
      _addTextBlocks(blocks, html.substring(pos, m.start));
      final tag = m.group(0)!;
      final w = _imageWidthRe.firstMatch(tag)?.group(1);
      final h = _imageHeightRe.firstMatch(tag)?.group(1);
      final wi = int.tryParse(w ?? '') ?? 0;
      final hi = int.tryParse(h ?? '') ?? 0;
      final imageUrl = m.group(1)!.trim();
      final imageUri = Uri.tryParse(imageUrl);
      if (imageUri != null &&
          imageUri.scheme == 'https' &&
          imageUri.host.isNotEmpty) {
        blocks.add(_BodyBlock.image(imageUrl,
            aspect: (wi > 0 && hi > 0) ? wi / hi : null));
      }
      pos = m.end;
    }
    _addTextBlocks(blocks, html.substring(pos));
    return blocks;
  }

  static List<_BodyBlock> _parseTextBlocks(String text) {
    final blocks = <_BodyBlock>[];
    _addTextBlocks(blocks, text);
    return blocks;
  }

  static final RegExp _aTagRe = RegExp(
      r'''<a\s+[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>''',
      caseSensitive: false, dotAll: true);
  static final RegExp _imageTagRe = RegExp(
      r'''<img[^>]*src\s*=\s*["']([^"']+)["'][^>]*>''',
      caseSensitive: false);
  static final RegExp _imageWidthRe = RegExp(
      r'''(?:img-width|width)\s*=\s*["'](\d+)["']''',
      caseSensitive: false);
  static final RegExp _imageHeightRe = RegExp(
      r'''(?:img-height|height)\s*=\s*["'](\d+)["']''',
      caseSensitive: false);
  static final RegExp _resourceTagRe = RegExp(r'\[res\][^[]+\[/res\]');
  static final RegExp _lineBreakTagRe =
      RegExp(r'<br\s*/?>', caseSensitive: false);
  static final RegExp _paragraphEndTagRe =
      RegExp(r'</p>', caseSensitive: false);
  static final RegExp _htmlTagRe = RegExp(r'<[^>]+>');
  static final RegExp _trailingUrlPunctuationRe =
      RegExp(r'[。，！？；、,;:!?)）】』」]+$');
  static final RegExp _urlRe = RegExp(r"(?:https?://|www\.)[^\s<>"
      "'（）()\[\]「」『』]+"); // ignore: unnecessary_string_escapes

  static void _addTextBlocks(List<_BodyBlock> blocks, String seg) {
    var t = seg
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        // 正文里的资源占位符(如 [res]0,369356[/res])不展示
        .replaceAll(_resourceTagRe, '')
        .replaceAll(_lineBreakTagRe, '\n')
        .replaceAll(_paragraphEndTagRe, '\n');
    final paras =
        t.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    for (final p in paras) {
      final blk = _paraBlock(p);
      // 纯标签段落(<p> 等)去掉标签后为空,跳过,否则翻页模式会出现空白页
      if (blk.text.isNotEmpty) _appendTextBlockChunks(blocks, blk);
    }
  }

  static const int _maxTextBlockLength = 8000;

  /// 极少数页面会把整章正文放在一个超长段落里。拆成有限大小的块后，
  /// 滚动模式仍可懒加载，翻页模式也不会为一整段几十万字一次性排版。
  static void _appendTextBlockChunks(
      List<_BodyBlock> blocks, _BodyBlock block) {
    if (block.text.length <= _maxTextBlockLength) {
      blocks.add(block);
      return;
    }
    var start = 0;
    while (start < block.text.length) {
      var end =
          (start + _maxTextBlockLength).clamp(0, block.text.length).toInt();
      if (end < block.text.length) {
        // 英文段落尽量在空白处分割；中文没有空白时直接按 UTF-16
        // 边界分割，并确保不把 surrogate pair 拆开。
        for (var i = end; i > start + (_maxTextBlockLength ~/ 2); i--) {
          final code = block.text.codeUnitAt(i - 1);
          if (code == 0x20 || code == 0x09) {
            end = i;
            break;
          }
        }
        if (end < block.text.length &&
            end > 0 &&
            block.text.codeUnitAt(end - 1) >= 0xD800 &&
            block.text.codeUnitAt(end - 1) <= 0xDBFF &&
            block.text.codeUnitAt(end) >= 0xDC00 &&
            block.text.codeUnitAt(end) <= 0xDFFF) {
          end++;
        }
      }
      final chunkLinks = <(int, int, String)>[];
      for (final (linkStart, linkEnd, url) in block.links) {
        if (linkEnd <= start || linkStart >= end) continue;
        final localStart = (linkStart < start ? start : linkStart) - start;
        final localEnd = (linkEnd > end ? end : linkEnd) - start;
        if (localEnd > localStart) {
          chunkLinks.add((localStart, localEnd, url));
        }
      }
      blocks.add(_BodyBlock.text(
          block.text.substring(start, end), List.unmodifiable(chunkLinks)));
      start = end;
    }
  }

  /// 把一段(可能含 <a> 与裸 URL 的)文本解析成带链接区间的正文块
  static _BodyBlock _paraBlock(String raw) {
    final buf = StringBuffer();
    final links = <(int, int, String)>[];
    var pos = 0;
    for (final m in _aTagRe.allMatches(raw)) {
      _appendScanningUrls(buf, links, raw.substring(pos, m.start));
      final label = m.group(2)!.replaceAll(_htmlTagRe, '').trim();
      final url = (m.group(1) ?? '').trim();
      if (label.isNotEmpty && url.isNotEmpty) {
        links.add((buf.length, buf.length + label.length, url));
        buf.write(label);
      }
      pos = m.end;
    }
    _appendScanningUrls(buf, links, raw.substring(pos));
    return _BodyBlock.text(buf.toString(), links);
  }

  /// 去标签后,扫描裸 URL(www./http/https),附加为链接区间
  static void _appendScanningUrls(
      StringBuffer buf, List<(int, int, String)> links, String seg) {
    final clean = seg.replaceAll(_htmlTagRe, '');
    var pos = 0;
    for (final m in _urlRe.allMatches(clean)) {
      if (m.start > pos) buf.write(clean.substring(pos, m.start));
      var u = m.group(0)!;
      // 去掉结尾误吞的中文标点
      u = u.replaceFirst(_trailingUrlPunctuationRe, '');
      links.add((buf.length, buf.length + u.length, u));
      buf.write(u);
      pos = m.end;
    }
    if (pos < clean.length) buf.write(clean.substring(pos));
  }

  Future<void> _open(int chapterId, String title, {int? volumeId}) async {
    await _finishReadingSession();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
          builder: (_) => ReaderPage(
                bookId: widget.bookId,
                bookTitle: widget.bookTitle,
                chapterId: chapterId,
                chapterTitle: title,
                volumeId: volumeId ?? _effectiveVolumeId,
              )),
    );
  }

  /// 付费解锁:试读内容下方的解锁卡片直接调用,不再弹窗确认
  Future<void> _unlock() async {
    if (_unlocking) return;
    setState(() => _unlocking = true);
    try {
      await LKApi.unlockChapter(widget.chapterId);
      if (!mounted) return;
      showLkError(context, '解锁成功');
      await _load();
    } catch (e) {
      if (mounted) showLkError(context, e);
    } finally {
      if (mounted) setState(() => _unlocking = false);
    }
  }

  Color get _linkColor =>
      _isDarkBg ? const Color(0xFF7EB6FF) : const Color(0xFF2F6FBF);

  /// 正文内链接:系统浏览器打开
  Future<void> _openLink(String url) async {
    var u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    try {
      final uri = Uri.tryParse(u);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        if (mounted) showLkError(context, '链接协议不受支持');
        return;
      }
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) showLkError(context, '无法打开链接');
    } catch (e) {
      if (mounted) showLkError(context, '无法打开链接: $e');
    }
  }

  /// 全屏查看插画(可缩放、可保存到相册)
  void _showImageViewer(String url) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _ImageViewer(url: url)),
    );
  }

  // ==================== 翻页 ====================

  void _pageUp() {
    if (_paged) {
      _turnPrev();
      return;
    }
    final h = MediaQuery.of(context).size.height;
    _sc.animateTo(
        (_sc.offset - h * 0.85).clamp(0.0, _sc.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut);
  }

  void _pageDown() {
    if (_paged) {
      _turnNext();
      return;
    }
    final h = MediaQuery.of(context).size.height;
    _sc.animateTo(
        (_sc.offset + h * 0.85).clamp(0.0, _sc.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut);
  }

  /// 从底部阅读进度条跳转到本章指定位置。
  Future<void> _seekToProgress(double rawValue) async {
    final value = rawValue.clamp(0.0, 1.0).toDouble();
    final requestedAnchor = _anchorForProgress(value);
    unawaited(HapticFeedback.selectionClick());

    if (_paged) {
      final target = _pageForAnchor(requestedAnchor);
      if (target == null) return;
      final transitionId = _positionController.beginTransition();
      _restoringPagedProgress = true;
      try {
        // PageView 正在挂载时最多等待数帧。进度跳转只提交真实页，不能先
        // 显示目标百分比、随后再被异步 onPageChanged 覆盖。
        for (var attempt = 0;
            attempt < 6 && mounted && !_pageController.hasClients;
            attempt++) {
          await WidgetsBinding.instance.endOfFrame;
        }
        if (!mounted || !_paged || !_pageController.hasClients) {
          _positionController.cancelTransition(transitionId);
          return;
        }
        try {
          await _pageController.animateToPage(
            target,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
          );
        } catch (_) {
          // 页面在动画期间关闭时无需显示错误。
        }
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !_paged) {
          _positionController.cancelTransition(transitionId);
          return;
        }

        final actualPage = (_pageController.page ?? target.toDouble())
            .round()
            .clamp(0, _pages.length - 1)
            .toInt();
        final reachedTarget = actualPage == target;
        final effectiveAnchor = reachedTarget
            // 目标落在独占一页的插画内部时，保留滑块所选的块内比例；
            // 图片加载前后都不会再退回插画页起点。
            ? requestedAnchor
            : (_anchorForPage(actualPage) ?? requestedAnchor);
        if (_pageIndex != actualPage) {
          setState(() => _pageIndex = actualPage);
        }
        _completePositionTransition(transitionId, effectiveAnchor);
      } finally {
        if (mounted) _restoringPagedProgress = false;
      }
      return;
    }
    final anchor = _snapAnchorToScrollLine(requestedAnchor);
    final transitionId = _positionController.beginTransition();
    await _restoreScrollAnchor(
      anchor,
      animate: true,
      retainAnchor: true,
      transitionId: transitionId,
    );
  }

  /// 在滚动/翻页模式之间切换时保留同一章节进度。
  void _changeReadingMode(bool paged, StateSetter setSheet) {
    if (paged == _paged) return;
    final transitionId = _positionController.beginTransition();
    final capturedAnchor = _paged
        ? (_logicalAnchor ?? _anchorForPage(_pageIndex))
        : (_captureScrollAnchor() ?? _logicalAnchor);
    final anchor =
        _normalizeAnchor(capturedAnchor ?? _anchorForProgress(_progress));
    _publishPosition(anchor,
        transitionId: transitionId, persist: false, syncUi: false);
    // 取消仍在排队的旧滚动位置恢复，避免它在模式来回切换后覆盖新位置。
    _positionRestoreSerial++;
    _scrollProgressGeneration++;
    setState(() {
      _paged = paged;
      _pagedKey = '';
      _pendingPositionTransitionId = paged ? transitionId : null;
      _pendingPagedAnchor = paged ? anchor : null;
      _restoringPagedProgress = paged;
    });
    setSheet(() {});
    unawaited(ReaderPrefs.setPagedMode(paged));
    _schedulePositionPersist();

    if (!paged) {
      // 滚动布局索引要在下一帧按当前窗口与字体建立，之后精确定位。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_paged) {
          unawaited(_restoreScrollAnchor(anchor,
              retainAnchor: true, transitionId: transitionId));
        }
      });
    }
    // 切入翻页模式时由 _buildPages 使用正文锚点定位目标页。
  }

  // ==================== 设置面板(三页签) ====================

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1E2025)
          : Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) {
        final scheme = Theme.of(sheetCtx).colorScheme;
        final isDark = Theme.of(sheetCtx).brightness == Brightness.dark;
        return StatefulBuilder(
          builder: (_, setSheet) => DefaultTabController(
            length: 3,
            child: SizedBox(
              height: MediaQuery.of(sheetCtx).size.height * 0.55,
              child: Column(children: [
                const TabBar(
                  tabs: [
                    Tab(
                        icon: Icon(Icons.palette_outlined, size: 20),
                        text: '外观'),
                    Tab(
                        icon: Icon(Icons.touch_app_outlined, size: 20),
                        text: '操作'),
                    Tab(
                        icon: Icon(Icons.aspect_ratio_rounded, size: 20),
                        text: '边距'),
                  ],
                ),
                Expanded(
                  child: TabBarView(children: [
                    // ---- 外观 ----
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _switchTile(scheme, Icons.brightness_6_outlined,
                            '保持屏幕常亮', _keepOn, (v) async {
                          setSheet(() {});
                          setState(() => _keepOn = v);
                          ReaderPrefs.setKeepScreenOn(v);
                          WakelockPlus.toggle(enable: v);
                        }),
                        _switchTile(scheme, Icons.hide_image_outlined,
                            '隐藏系统状态栏', _hideBar, (v) {
                          setSheet(() {});
                          setState(() => _hideBar = v);
                          ReaderPrefs.setHideStatusBar(v);
                          _applyImmersive();
                        }),
                        _switchTile(
                            scheme, Icons.info_outline, '正文指示器', _indicators,
                            (v) {
                          setSheet(() {});
                          setState(() => _indicators = v);
                          ReaderPrefs.setShowIndicators(v);
                        }),
                        _switchTile(scheme, Icons.translate_rounded,
                            '繁体显示(简→繁)', _traditional, (v) async {
                          setSheet(() {});
                          setState(() {
                            _traditional = v;
                            if (v) _simplified = false;
                          });
                          ReaderPrefs.setTraditional(v);
                          if (v) ReaderPrefs.setSimplified(false);
                          await _reparseCurrentDetail();
                        }),
                        _switchTile(scheme, Icons.translate_rounded,
                            '简体显示(繁→简)', _simplified, (v) async {
                          setSheet(() {});
                          setState(() {
                            _simplified = v;
                            if (v) _traditional = false;
                          });
                          ReaderPrefs.setSimplified(v);
                          if (v) ReaderPrefs.setTraditional(false);
                          await _reparseCurrentDetail();
                        }),
                        const SizedBox(height: 6),
                        Text('字号',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade500)),
                        Slider(
                          value: _fontSize,
                          min: 12,
                          max: 28,
                          divisions: 16,
                          onChanged: (v) {
                            setSheet(() {});
                            setState(() => _fontSize = v);
                            ReaderPrefs.setFontSize(v);
                          },
                        ),
                        Text('行距',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade500)),
                        Slider(
                          value: _lineHeight,
                          min: 1.2,
                          max: 2.4,
                          divisions: 12,
                          onChanged: (v) {
                            setSheet(() {});
                            setState(() => _lineHeight = v);
                            ReaderPrefs.setLineHeight(v);
                          },
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            for (var i = 0; i < _presets.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: GestureDetector(
                                  onTap: () {
                                    setSheet(() {});
                                    setState(() {
                                      _bg = i;
                                      _bgChosen = true;
                                      _bgFollowSystem = false;
                                    });
                                    ReaderPrefs.setBgPreset(i);
                                    ReaderPrefs.setBgFollowSystem(false);
                                  },
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: _presets[i].$1,
                                      borderRadius: BorderRadius.circular(22),
                                      border: Border.all(
                                        color: !_bgFollowSystem && _bg == i
                                            ? scheme.primary
                                            : (isDark
                                                ? Colors.grey.shade700
                                                : Colors.grey.shade300),
                                        width: !_bgFollowSystem && _bg == i
                                            ? 2.5
                                            : 1,
                                      ),
                                    ),
                                    child: Center(
                                      child: Text(_presets[i].$3,
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: _presets[i].$2)),
                                    ),
                                  ),
                                ),
                              ),
                            // 跟随系统
                            Padding(
                              padding: const EdgeInsets.only(right: 10),
                              child: GestureDetector(
                                onTap: () {
                                  setSheet(() {});
                                  setState(() {
                                    _bgFollowSystem = true;
                                    _bgChosen = true;
                                  });
                                  ReaderPrefs.setBgFollowSystem(true);
                                },
                                child: Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? const Color(0xFF2A2D34)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(22),
                                    border: Border.all(
                                      color: _bgFollowSystem
                                          ? scheme.primary
                                          : (isDark
                                              ? Colors.grey.shade700
                                              : Colors.grey.shade300),
                                      width: _bgFollowSystem ? 2.5 : 1,
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.brightness_auto_rounded,
                                    size: 20,
                                    color: _bgFollowSystem
                                        ? scheme.primary
                                        : Colors.grey,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    // ---- 操作 ----
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _switchTile(scheme, Icons.touch_app_outlined,
                            '点击翻页(左右 1/3 区域翻页)', _tapTurn, (v) {
                          setSheet(() {});
                          setState(() => _tapTurn = v);
                          ReaderPrefs.setTapTurnPage(v);
                        }),
                        _switchTile(scheme, Icons.auto_stories_rounded,
                            '翻页模式(整页左右翻)', _paged, (v) {
                          _changeReadingMode(v, setSheet);
                        }),
                        if (_locked && !_unlocked)
                          _aaTile(scheme, Icons.lock_open_rounded,
                              _coinPrice > 0 ? '解锁本章($_coinPrice 轻币)' : '解锁本章',
                              () {
                            Navigator.pop(sheetCtx);
                            _unlock();
                          }),
                        _aaTile(scheme, Icons.arrow_upward_rounded, '回顶部', () {
                          Navigator.pop(sheetCtx);
                          _sc.jumpTo(0);
                        }),
                      ],
                    ),
                    // ---- 边距 ----
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _switchTile(scheme, Icons.fit_screen_outlined, '自动边距',
                            _autoMargin, (v) {
                          setSheet(() {});
                          setState(() => _autoMargin = v);
                          ReaderPrefs.setAutoMargin(v);
                        }),
                        if (!_autoMargin) ...[
                          _marginSlider('上边距', _mt, (v) {
                            setSheet(() {});
                            setState(() => _mt = v);
                            ReaderPrefs.setMarginTop(v);
                          }),
                          _marginSlider('下边距', _mb, (v) {
                            setSheet(() {});
                            setState(() => _mb = v);
                            ReaderPrefs.setMarginBottom(v);
                          }),
                          _marginSlider('左边距', _ml, (v) {
                            setSheet(() {});
                            setState(() => _ml = v);
                            ReaderPrefs.setMarginLeft(v);
                          }),
                          _marginSlider('右边距', _mr, (v) {
                            setSheet(() {});
                            setState(() => _mr = v);
                            ReaderPrefs.setMarginRight(v);
                          }),
                        ],
                      ],
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _switchTile(ColorScheme scheme, IconData icon, String title,
      bool value, Function(bool) onChanged) {
    return SwitchListTile(
      dense: true,
      secondary: Icon(icon, color: scheme.primary),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      value: value,
      onChanged: (v) => onChanged(v),
    );
  }

  Widget _marginSlider(String label, double value, Function(double) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.toInt()}',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        Slider(
          value: value,
          min: 0,
          max: 128,
          onChanged: (v) => onChanged(v),
        ),
      ],
    );
  }

  Widget _aaTile(
      ColorScheme scheme, IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20, color: scheme.primary),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      onTap: onTap,
    );
  }

  /// 底栏左右角的 上一章/下一章 按钮
  Widget _cornerChapterBtn(
      IconData icon, String label, bool enabled, VoidCallback onTap) {
    final color = enabled ? _textColor : _textColor.withValues(alpha: 0.35);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: TextButton.icon(
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 18, color: color),
        label: Text(label, style: TextStyle(fontSize: 13, color: color)),
      ),
    );
  }

  /// Apple Books 风格的本章进度控制：细圆角轨道、小滑块、松手跳转。
  Widget _readerProgressBar() {
    final enabled = !_loading && _loadError == null;
    final muted = _textColor.withValues(alpha: 0.5);
    return ValueListenableBuilder<double>(
      valueListenable: _progressN,
      builder: (_, rawValue, __) {
        final value = rawValue.clamp(0.0, 1.0).toDouble();
        final percent = (value * 100).round();
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
          child: Row(
            children: [
              Text('本章',
                  style: TextStyle(
                      color: muted, fontSize: 11, fontWeight: FontWeight.w500)),
              const SizedBox(width: 10),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3.5,
                    trackShape: const RoundedRectSliderTrackShape(),
                    activeTrackColor:
                        _textColor.withValues(alpha: _isDarkBg ? 0.82 : 0.7),
                    inactiveTrackColor:
                        _textColor.withValues(alpha: _isDarkBg ? 0.18 : 0.13),
                    disabledActiveTrackColor:
                        _textColor.withValues(alpha: 0.28),
                    disabledInactiveTrackColor:
                        _textColor.withValues(alpha: 0.09),
                    thumbColor: _textColor.withValues(alpha: 0.96),
                    disabledThumbColor: _textColor.withValues(alpha: 0.4),
                    overlayColor: _textColor.withValues(alpha: 0.1),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5.5,
                      disabledThumbRadius: 5.5,
                      elevation: 0,
                      pressedElevation: 1,
                    ),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 15),
                    showValueIndicator: ShowValueIndicator.never,
                  ),
                  child: Semantics(
                    label: '本章阅读进度',
                    value: '$percent%',
                    child: Slider(
                      value: value,
                      onChanged: enabled ? (v) => _progressN.value = v : null,
                      onChangeEnd:
                          enabled ? (v) => unawaited(_seekToProgress(v)) : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 38,
                child: Text(
                  '$percent%',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: muted,
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _scrollBlockWidget(int index, {required bool lockedBody}) {
    final block = _blocks[index];
    if (block.image != null) {
      final imageHeight = _scrollImageHeight(block, _scrollContentWidth());
      return SizedBox(
        height: imageHeight + 20,
        child: GestureDetector(
          onTap: () => _showImageViewer(block.image!),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: double.infinity,
                height: imageHeight,
                child: CachedNetworkImage(
                  imageUrl: block.image!,
                  width: double.infinity,
                  height: imageHeight,
                  memCacheWidth:
                      imageCacheDimension(context, _scrollContentWidth()),
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                  placeholder: (_, __) => Container(
                    color: _isDarkBg
                        ? Colors.white10
                        : Colors.black.withValues(alpha: 0.05),
                    child: const Center(
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                  errorWidget: (_, __, ___) => Center(
                    child: Icon(Icons.broken_image_outlined,
                        color: _textColor.withValues(alpha: 0.5)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _textPointerDown,
        onPointerMove: _textPointerMove,
        onPointerUp: _textPointerUp,
        onPointerCancel: _textPointerCancel,
        child: SelectionArea(
          child: Text.rich(
            key: _scrollTextKeys[index],
            _scrollTextSpan(block, lockedBody: lockedBody),
          ),
        ),
      ),
    );
  }

  /// 滚动模式正文(整章连续滚动)
  Widget _scrollBody(double viewportWidth, double viewTop, double viewBottom,
      bool locked, bool lockedBody) {
    // 所有滚动读写共用同一份精确布局索引。正文仍按需构建，文字高度
    // 只在字体/宽度/内容变化时测量一次。
    _scrollLayoutWidth = viewportWidth;
    _scrollLayoutLockedBody = lockedBody;
    _ensureScrollLayoutIndex(viewportWidth, lockedBody);
    final layout = _scrollLayoutIndex!;
    final horizontal = EdgeInsets.only(
      left: _bodyPadding.left,
      right: _bodyPadding.right,
    );
    final bodyPadding = EdgeInsets.fromLTRB(
      _bodyPadding.left,
      _bodyPadding.top,
      _bodyPadding.right,
      0,
    );
    final endPadding = EdgeInsets.fromLTRB(
      _bodyPadding.left,
      0,
      _bodyPadding.right,
      _bodyPadding.bottom,
    );
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollUpdateNotification &&
            _chrome &&
            !_restoringScrollAnchor) {
          setState(() => _chrome = false);
        }
        return false;
      },
      // 视口整体避开系统栏:未隐藏时文本/章末按钮都不会进入状态栏与手势条区域
      child: Padding(
        padding: EdgeInsets.only(top: viewTop, bottom: viewBottom),
        child: CustomScrollView(
          controller: _sc,
          slivers: [
            SliverPadding(
              padding: bodyPadding,
              sliver: SliverVariedExtentList(
                delegate: SliverChildBuilderDelegate(
                  (_, index) =>
                      _scrollBlockWidget(index, lockedBody: lockedBody),
                  childCount: _blocks.length,
                  addAutomaticKeepAlives: false,
                  addSemanticIndexes: false,
                ),
                itemExtentBuilder: (index, _) => layout.itemExtents[index],
              ),
            ),
            if (locked)
              SliverPadding(
                padding: horizontal,
                sliver: SliverToBoxAdapter(child: _unlockCard()),
              ),
            SliverPadding(
              padding: endPadding,
              sliver: SliverToBoxAdapter(
                child: _loading ? const SizedBox.shrink() : _chapterEndNav(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _loadErrorView() {
    final loggedIn = LKClient.shared.session.isLoggedIn;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline_rounded,
                  size: 42, color: _textColor.withValues(alpha: 0.65)),
              const SizedBox(height: 14),
              Text(_loadError ?? '正文暂时无法加载',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: _textColor, fontSize: 15, height: 1.6)),
              const SizedBox(height: 18),
              if (!loggedIn)
                FilledButton.icon(
                  onPressed: () async {
                    await Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const LoginPage()));
                    if (mounted && LKClient.shared.session.isLoggedIn) {
                      _load();
                    }
                  },
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text('去登录'),
                ),
              if (!loggedIn) const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重新加载'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 翻页模式正文(整页左右翻,末页/首页超滑切章)
  Widget _pagedBody(
      double vh, double viewTop, double viewBottom, bool lockedBody) {
    final contentH =
        (vh - viewTop - viewBottom - _bodyPadding.top - _bodyPadding.bottom)
            .clamp(120.0, 4000.0);
    return Padding(
      padding: EdgeInsets.only(top: viewTop, bottom: viewBottom),
      child: NotificationListener<OverscrollNotification>(
        onNotification: (n) {
          if (n.overscroll > 0) {
            if (_pageIndex >= _pages.length - 1 &&
                _nextId != null &&
                !_chapterSwitching) {
              _chapterSwitching = true;
              _open(_nextId!, _nextTitle ?? '', volumeId: _nextVolumeId);
            }
          } else if (n.overscroll < 0) {
            if (_pageIndex <= 0 && _prevId != null && !_chapterSwitching) {
              _chapterSwitching = true;
              _open(_prevId!, _prevTitle ?? '', volumeId: _prevVolumeId);
            }
          }
          return false;
        },
        child: PageView.builder(
          controller: _pageController,
          itemCount: _pages.length,
          physics: const ClampingScrollPhysics(),
          onPageChanged: (i) {
            if (_restoringPagedProgress) return;
            // 切入翻页模式时 PageView 可能异步回调一次目标页。该回调
            // 只代表恢复完成，不应把“页内原始锚点”降级成页首锚点。
            final pendingAnchor = _pendingPagedAnchor;
            if (pendingAnchor != null && i == _pageIndex) {
              _pendingPagedAnchor = null;
              final transitionId = _pendingPositionTransitionId;
              _pendingPositionTransitionId = null;
              if (transitionId != null) {
                _completePositionTransition(transitionId, pendingAnchor);
              }
              return;
            }
            _pendingPagedAnchor = null;
            _pendingPositionTransitionId = null;
            final anchor = _anchorForPage(i);
            final progress = anchor == null
                ? (_pages.length <= 1
                    ? 1.0
                    : (i / (_pages.length - 1)).clamp(0.0, 1.0))
                : _progressForAnchor(anchor);
            setState(() {
              _pageIndex = i;
            });
            if (anchor != null) {
              _publishPosition(anchor);
            } else {
              _progressN.value = progress;
              LKReadingSession.shared
                  .update(volumeId: _effectiveVolumeId, progress: progress);
            }
          },
          itemBuilder: (_, i) {
            final page = _pages[i];
            if (page.unlockCard) {
              return Padding(
                padding: _bodyPadding,
                child:
                    Align(alignment: Alignment.topCenter, child: _unlockCard()),
              );
            }
            if (page.chapterEnd) {
              return Padding(
                padding: _bodyPadding,
                child: SizedBox(
                    height: contentH, child: Center(child: _chapterEndNav())),
              );
            }
            return Padding(
              padding: _bodyPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final it in page.items)
                    if (it.image != null)
                      // 展示层铺满页面的 contain,但只有插画实际区域可点
                      // (无宽高信息时取中央 72% 作为命中区),空白处点击
                      // 走翻页/工具栏逻辑
                      Builder(builder: (_) {
                        final pad = _bodyPadding;
                        final contentW = MediaQuery.of(context).size.width -
                            pad.left -
                            pad.right;
                        final availH = contentH - 12;
                        double hitW, hitH;
                        final aspect = it.aspect;
                        if (aspect != null && aspect > 0) {
                          hitH = availH;
                          hitW = hitH * aspect;
                          if (hitW > contentW) {
                            hitW = contentW;
                            hitH = hitW / aspect;
                          }
                        } else {
                          hitW = contentW * 0.72;
                          hitH = availH * 0.72;
                        }
                        return Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: contentW,
                              height: availH,
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8)),
                              child: CachedNetworkImage(
                                imageUrl: it.image!,
                                width: contentW,
                                height: availH,
                                memCacheWidth:
                                    imageCacheDimension(context, contentW),
                                fit: BoxFit.contain,
                                placeholder: (_, __) => Container(
                                  color: _isDarkBg
                                      ? Colors.white10
                                      : Colors.black.withValues(alpha: 0.05),
                                  child: const Center(
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                                ),
                                errorWidget: (_, __, ___) => Container(
                                  alignment: Alignment.center,
                                  child: Icon(Icons.broken_image_outlined,
                                      color: _textColor.withValues(alpha: 0.5)),
                                ),
                              ),
                            ),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _showImageViewer(it.image!),
                              child: SizedBox(width: hitW, height: hitH),
                            ),
                          ],
                        );
                      })
                    else
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: _textPointerDown,
                          onPointerMove: _textPointerMove,
                          onPointerUp: _textPointerUp,
                          onPointerCancel: _textPointerCancel,
                          child: SelectionArea(
                            child: Text.rich(
                              TextSpan(
                                style: _bodyTextStyle,
                                children: (lockedBody &&
                                        it.links.isEmpty &&
                                        it.text == '(本章暂无内容)')
                                    ? const [TextSpan(text: '本章需要轻币解锁')]
                                    : _spans(it.text, it.links),
                              ),
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // ==================== 章末导航 / 目录 / 本卷评论 ====================

  /// 付费章节:试读内容下方的解锁卡片(轻币价格 + 余额,免弹窗直接解锁)
  Widget _unlockCard() {
    final accent = _linkColor;
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        decoration: BoxDecoration(
          color: _isDarkBg
              ? Colors.white.withValues(alpha: 0.05)
              : _textColor.withValues(alpha: 0.045),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.55)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.lock_rounded, size: 18, color: accent),
            const SizedBox(width: 8),
            Text('本章需要轻币解锁',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _textColor)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Icon(Icons.monetization_on_outlined, size: 18, color: accent),
            const SizedBox(width: 6),
            Text('$_coinPrice 轻币',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold, color: accent)),
            if (_coins >= 0) ...[
              const SizedBox(width: 12),
              Text('余额 $_coins',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: _textColor.withValues(alpha: 0.55))),
            ],
          ]),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12)),
              onPressed: _unlocking ? null : _unlock,
              icon: _unlocking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.lock_open_rounded, size: 18),
              label: Text(_unlocking ? '解锁中…' : '解锁本章($_coinPrice 轻币)'),
            ),
          ),
        ]),
      ),
    );
  }

  /// 章末的 上一章/下一章(首章只显下一章,末章只显上一章)
  Widget _chapterEndNav() {
    final style = OutlinedButton.styleFrom(
      foregroundColor: _textColor,
      side: BorderSide(color: _textColor.withValues(alpha: 0.35), width: 1),
      padding: const EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
    Widget btn(IconData icon, String label, String? title, VoidCallback onTap) {
      return Expanded(
        child: OutlinedButton.icon(
          style: style,
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(
            title == null || title.isEmpty ? label : '$label\n$title',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 24),
      child: Row(children: [
        if (_prevId != null)
          btn(Icons.chevron_left_rounded, '上一章', _prevTitle,
              () => _open(_prevId!, _prevTitle ?? '', volumeId: _prevVolumeId)),
        if (_prevId != null && _nextId != null) const SizedBox(width: 12),
        if (_nextId != null)
          btn(Icons.chevron_right_rounded, '下一章', _nextTitle,
              () => _open(_nextId!, _nextTitle ?? '', volumeId: _nextVolumeId)),
      ]),
    );
  }

  void _openVolumeComments() {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => CommentsPage(
                bookId: widget.bookId,
                bookTitle: widget.bookTitle,
                volumeId: _effectiveVolumeId,
              )),
    );
  }

  void _showCatalog() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1E2025)
          : Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: _CatalogSheet(
          bookId: widget.bookId,
          volumeId: _effectiveVolumeId,
          currentChapterId: widget.chapterId,
          currentChapterNo: _detail?.chapterNo ?? 0,
          onPick: (chapterId, title, volumeId) {
            Navigator.pop(context);
            _open(chapterId, title, volumeId: volumeId);
          },
        ),
      ),
    );
  }

  // ==================== 界面 ====================

  EdgeInsets get _bodyPadding {
    if (_autoMargin) {
      return const EdgeInsets.fromLTRB(20, 56, 20, 70);
    }
    return EdgeInsets.fromLTRB(_ml, _mt, _mr, _mb);
  }

  /// 正文链接区间 → InlineSpan(链接用主题色+下划线,点击系统浏览器打开)
  List<InlineSpan> _spansFor(_BodyBlock b) => _spans(b.text, b.links);

  List<InlineSpan> _spans(String text, List<(int, int, String)> links) {
    if (links.isEmpty) return [TextSpan(text: text)];
    final out = <InlineSpan>[];
    final linkStyle = TextStyle(
        color: _linkColor,
        decoration: TextDecoration.underline,
        decorationColor: _linkColor);
    var pos = 0;
    for (final (s, e, url) in links) {
      if (s > pos) out.add(TextSpan(text: text.substring(pos, s)));
      out.add(TextSpan(
          text: text.substring(s, e),
          style: linkStyle,
          // 翻页模式短按优先翻页；滚动模式仍可直接打开正文链接。
          recognizer: _paged
              ? null
              : (TapGestureRecognizer()
                ..onTap = () {
                  _suppressNextTextTap = true;
                  _openLink(url);
                })));
      pos = e;
    }
    if (pos < text.length) out.add(TextSpan(text: text.substring(pos)));
    return out;
  }

  // ==================== 翻页模式 ====================

  TextStyle get _bodyTextStyle => TextStyle(
      fontSize: _fontSize,
      height: _lineHeight,
      color: _textColor,
      letterSpacing: 0.3);

  /// 把整章正文切分成翻页页面
  void _buildPages(double viewW, double viewH) {
    final pad = _bodyPadding;
    final contentW = (viewW - pad.left - pad.right).clamp(80.0, 2000.0);
    final contentH = (viewH - pad.top - pad.bottom).clamp(120.0, 4000.0);
    final pages = <_Page>[];
    var cur = <_PageItem>[];
    var used = 0.0;
    void flush() {
      if (cur.isNotEmpty) {
        pages.add(_Page(cur));
        cur = [];
        used = 0;
      }
    }

    // 渲染时每个文本条目底部有 12px 段间距,分页高度计算必须计入,否则 BOTTOM OVERFLOW
    const gap = 12.0;
    final maxTextHeight = (contentH - gap).clamp(1.0, contentH).toDouble();
    for (var blockIndex = 0; blockIndex < _blocks.length; blockIndex++) {
      final b = _blocks[blockIndex];
      if (b.image != null) {
        // 插画是原子页面：网络图片加载前后始终只占这一页，原图比例只
        // 影响 contain 后的可见区域，不参与分页数量或阅读进度重排。
        flush();
        pages.add(_Page([
          _PageItem.image(b.image!, aspect: b.aspect, blockIndex: blockIndex)
        ]));
        continue;
      }
      if (b.text.trim().isEmpty) continue; // 空文本块不占页
      for (final (chunk, measuredHeight)
          in _splitTextBlock(b, blockIndex, contentW, maxTextHeight)) {
        if (chunk.text.isEmpty) continue;
        final h = measuredHeight + gap;
        if (used + h > contentH && used > 0) flush();
        cur.add(chunk);
        used += h;
      }
    }
    flush();
    if (_locked && !_unlocked) pages.add(_Page(const [], unlockCard: true));
    pages.add(_Page(const [], chapterEnd: true));
    _pages = pages;
    // 只使用正文锚点定位，不再把旧页码/百分比当作第二个位置来源。
    final currentAnchor = _positionController.value;
    final restoreAnchor = _normalizeAnchor(
        _pendingPagedAnchor ?? currentAnchor ?? _anchorForProgress(_progress));
    final restoreProgress = _progressForAnchor(restoreAnchor);
    final transitionId = _pendingPositionTransitionId;
    final total = pages.length - 1;
    final target = _pageForAnchor(restoreAnchor, pages) ??
        (total <= 0 ? 0 : (restoreProgress * total).round().clamp(0, total));
    _pageIndex = target;
    _publishPosition(restoreAnchor,
        transitionId: transitionId,
        persist: false,
        syncUi: transitionId == null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(target);
      }
      if (_restoringPagedProgress) {
        // PageView 首次挂载会先发出第 0 页回调；等目标页落位后再恢复
        // 正常的翻页进度更新，避免模式切换覆盖保存的百分比。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (transitionId != null) {
            _completePositionTransition(transitionId, restoreAnchor);
            if (_pendingPositionTransitionId == transitionId) {
              _pendingPositionTransitionId = null;
            }
          }
          _pendingPagedAnchor = null;
          _restoringPagedProgress = false;
        });
      }
    });
  }

  /// 文本段按行切分(每页高度 contentH),链接区间随之重映射
  List<(_PageItem, double)> _splitTextBlock(
      _BodyBlock b, int blockIndex, double w, double h) {
    final tp = TextPainter(
      text: TextSpan(text: b.text, style: _bodyTextStyle),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: w);
    final lms = tp.computeLineMetrics();
    if (lms.isEmpty) {
      return [
        (
          _PageItem.text(b.text, b.links,
              blockIndex: blockIndex, startOffset: 0, endOffset: b.text.length),
          tp.height
        )
      ];
    }
    int lineEnd(int idx) {
      final pos = tp.getPositionForOffset(Offset(0, lms[idx].baseline));
      return tp.getLineBoundary(pos).end;
    }

    final out = <(_PageItem, double)>[];
    var lineIdx = 0;
    var start = 0;
    var usedH = 0.0;
    while (lineIdx < lms.length) {
      final lh = lms[lineIdx].height;
      if (usedH + lh > h && usedH > 0) {
        final end = lineEnd(lineIdx - 1);
        if (end > start) {
          out.add((
            _PageItem.text(
              b.text.substring(start, end),
              _remapLinks(b.links, start, end),
              blockIndex: blockIndex,
              startOffset: start,
              endOffset: end,
            ),
            usedH,
          ));
        }
        start = end;
        usedH = 0;
      } else {
        usedH += lh;
        lineIdx++;
      }
    }
    final end = lineEnd(lms.length - 1);
    if (end > start) {
      out.add((
        _PageItem.text(
          b.text.substring(start, end),
          _remapLinks(b.links, start, end),
          blockIndex: blockIndex,
          startOffset: start,
          endOffset: end,
        ),
        usedH,
      ));
    }
    if (end < b.text.length) {
      final tail = b.text.substring(end);
      out.add((
        _PageItem.text(tail, const [],
            blockIndex: blockIndex, startOffset: end, endOffset: b.text.length),
        _measureText(tail, w)
      ));
    }
    return out;
  }

  /// 链接区间裁剪重映射到子串坐标
  List<(int, int, String)> _remapLinks(
      List<(int, int, String)> links, int start, int end) {
    final out = <(int, int, String)>[];
    for (final (s, e, url) in links) {
      if (e <= start || s >= end) continue;
      final ns = (s - start).clamp(0, end - start);
      final ne = (e - start).clamp(ns, end - start);
      if (ne > ns) out.add((ns, ne, url));
    }
    return out;
  }

  double _measureText(String text, double w) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: _bodyTextStyle),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: w);
    return tp.height;
  }

  /// 分享本章:系统分享菜单,内容为小说链接
  Future<void> _share() async {
    final url =
        'https://www.lightnovel.fun/reader/${widget.bookId}/${widget.chapterId}';
    try {
      // iPad 的 UIActivityViewController 使用 popover,必须传入分享按钮
      // 自身在 controller.view 坐标系中的有效矩形,不能使用页面根 context。
      final renderObject = _shareButtonKey.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) {
        if (mounted) showLkError(context, '分享按钮暂不可用,请稍后重试');
        return;
      }
      final sharePositionOrigin =
          renderObject.localToGlobal(Offset.zero) & renderObject.size;
      if (sharePositionOrigin.isEmpty) {
        if (mounted) showLkError(context, '分享按钮暂不可用,请稍后重试');
        return;
      }
      await Share.share(
        url,
        subject: _title,
        sharePositionOrigin: sharePositionOrigin,
      );
    } catch (e) {
      if (mounted) showLkError(context, '分享失败: $e');
    }
  }

  void _turnPrev() {
    if (_pageIndex <= 0) return; // 边界交给超滑/底栏按钮
    _pageController.previousPage(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic);
  }

  void _turnNext() {
    if (_pageIndex >= _pages.length - 1) return;
    _pageController.nextPage(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic);
  }

  void _textPointerDown(PointerDownEvent event) {
    _textPointerStart = event.position;
    _textPointerDownAt = DateTime.now();
    _textPointerMoved = false;
    _textPointerHandled = false;
  }

  void _textPointerMove(PointerMoveEvent event) {
    final down = _textPointerStart;
    if (down != null && (event.position - down).distance > 12) {
      _textPointerMoved = true;
    }
  }

  void _textPointerCancel(PointerCancelEvent event) {
    _textPointerStart = null;
    _textPointerDownAt = null;
    _textPointerMoved = false;
    _textPointerHandled = false;
  }

  void _textPointerUp(PointerUpEvent event) {
    final startedAt = _textPointerDownAt;
    final moved = _textPointerMoved;
    _textPointerStart = null;
    _textPointerDownAt = null;
    _textPointerMoved = false;
    if (startedAt == null || moved) return;
    // 长按交给 SelectionArea，避免破坏正文复制。
    if (DateTime.now().difference(startedAt) >
        const Duration(milliseconds: 350)) {
      return;
    }

    _textPointerHandled = true;
    final tapSerial = ++_textTapSerial;
    final position = event.position;
    // 等手势竞技场和链接识别器处理完本次事件，再执行阅读器手势。
    scheduleMicrotask(() {
      if (!mounted || tapSerial != _textTapSerial) return;
      _textPointerHandled = false;
      if (_suppressNextTextTap) {
        _suppressNextTextTap = false;
        return;
      }
      _handleBodyTap(position);
    });
  }

  void _handleBodyTap(Offset position) {
    final width = MediaQuery.of(context).size.width;
    if (_paged) {
      if (position.dx < width / 3) {
        _turnPrev();
        return;
      }
      if (position.dx > width * 2 / 3) {
        _turnNext();
        return;
      }
    } else if (_tapTurn) {
      if (position.dx < width / 3) {
        _pageUp();
        return;
      }
      if (position.dx > width * 2 / 3) {
        _pageDown();
        return;
      }
    }
    if (mounted) setState(() => _chrome = !_chrome);
  }

  @override
  Widget build(BuildContext context) {
    final locked = _locked && !_unlocked;
    final lockedBody = locked && _blocks.length == 1;
    final barColor = _bgColor.withValues(alpha: 0.96);
    final padTop = MediaQuery.of(context).padding.top;
    // 未隐藏系统栏时:顶部避开状态栏、底部避开手势导航条
    final viewTopPadding = _hideBar ? 0.0 : padTop;
    final viewBottomPadding =
        _hideBar ? 0.0 : MediaQuery.of(context).padding.bottom;
    // WillPopScope is used so the final reading report can complete before
    // the reader route is removed.
    // ignore: deprecated_member_use
    return WillPopScope(
      onWillPop: _handleWillPop,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              _isDarkBg ? Brightness.light : Brightness.dark,
          statusBarBrightness: _isDarkBg ? Brightness.dark : Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: _bgColor,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              if (_textPointerHandled) {
                return;
              }
              _handleBodyTap(d.globalPosition);
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: _loading
                      ? LkLoadingIndicator(color: _textColor)
                      : _loadError != null
                          ? _loadErrorView()
                          : LayoutBuilder(builder: (ctx, cons) {
                              final vw = cons.maxWidth;
                              final vh = cons.maxHeight;
                              // 翻页模式:内容/排版/尺寸变化时重建分页
                              if (_paged) {
                                final key = '$_fontSize|$_lineHeight|$_mt|$_mb|'
                                    '$_ml|$_mr|$_autoMargin|${vw.round()}|${vh.round()}|'
                                    '${viewTopPadding.round()}|${viewBottomPadding.round()}|'
                                    '$_locked|$_unlocked|${identical(_blocks, _pagesSource)}';
                                if (key != _pagedKey) {
                                  _pagedKey = key;
                                  _pagesSource = _blocks;
                                  WidgetsBinding.instance
                                      .addPostFrameCallback((_) {
                                    if (mounted &&
                                        _paged &&
                                        _pagedKey == key &&
                                        identical(_blocks, _pagesSource)) {
                                      _buildPages(
                                          vw,
                                          vh -
                                              viewTopPadding -
                                              viewBottomPadding);
                                      setState(() {});
                                    }
                                  });
                                }
                                return _pagedBody(vh, viewTopPadding,
                                    viewBottomPadding, lockedBody);
                              }
                              return _scrollBody(vw, viewTopPadding,
                                  viewBottomPadding, locked, lockedBody);
                            }),
                ),
                if (_indicators && !_chrome && !_loading)
                  Positioned(
                    top: _hideBar ? 6.0 : padTop + 6,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: _textColor.withValues(alpha: 0.45)),
                      ),
                    ),
                  ),
                if (_indicators && !_chrome && !_loading)
                  Positioned(
                    bottom: 8,
                    right: 16,
                    child: _paged
                        ? Text(
                            '第 ${_pageIndex + 1}/${_pages.length} 页',
                            style: TextStyle(
                                fontSize: 11,
                                color: _textColor.withValues(alpha: 0.45)),
                          )
                        : ValueListenableBuilder<double>(
                            valueListenable: _progressN,
                            builder: (_, v, __) => Text(
                              '${(v * 100).toStringAsFixed(1)}%',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: _textColor.withValues(alpha: 0.45)),
                            ),
                          ),
                  ),
                // 顶栏
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  top: _chrome ? 0 : -90,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: barColor,
                    child: SafeArea(
                      bottom: false,
                      child: Row(
                        children: [
                          IconButton(
                            icon: Icon(Icons.chevron_left_rounded,
                                color: _textColor),
                            onPressed: () => Navigator.pop(context),
                          ),
                          Expanded(
                            child: Text(
                              _title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: _textColor),
                            ),
                          ),
                          IconButton(
                            key: _shareButtonKey,
                            tooltip: '分享',
                            icon: Icon(Icons.ios_share_rounded,
                                size: 22, color: _textColor),
                            onPressed: _share,
                          ),
                          IconButton(
                            tooltip: '本卷评论',
                            icon: Icon(Icons.chat_bubble_outline_rounded,
                                size: 22, color: _textColor),
                            onPressed: _openVolumeComments,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 底栏:上一章 / 设置+目录 / 下一章
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  bottom: _chrome ? 0 : -170,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: barColor,
                    child: SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _readerProgressBar(),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                _cornerChapterBtn(Icons.chevron_left_rounded,
                                    '上一章', _prevId != null, () {
                                  if (_prevId != null) {
                                    _open(_prevId!, _prevTitle ?? '',
                                        volumeId: _prevVolumeId);
                                  }
                                }),
                                Expanded(
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      if (_locked && !_unlocked)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(right: 4),
                                          child: Icon(
                                              Icons.lock_outline_rounded,
                                              size: 16,
                                              color: _textColor),
                                        ),
                                      IconButton(
                                        tooltip: '阅读设置',
                                        icon: Icon(Icons.settings_rounded,
                                            size: 22, color: _textColor),
                                        onPressed: _showSettings,
                                      ),
                                      TextButton.icon(
                                        onPressed: _showCatalog,
                                        icon: Icon(Icons.menu_book_rounded,
                                            size: 18, color: _textColor),
                                        label: Text('目录',
                                            style: TextStyle(
                                                fontSize: 13,
                                                color: _textColor)),
                                      ),
                                    ],
                                  ),
                                ),
                                _cornerChapterBtn(Icons.chevron_right_rounded,
                                    '下一章', _nextId != null, () {
                                  if (_nextId != null) {
                                    _open(_nextId!, _nextTitle ?? '',
                                        volumeId: _nextVolumeId);
                                  }
                                }),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 阅读器目录弹层:卷就地展开章节,点章节跳转;打开时自动定位当前卷/章
class _CatalogSheet extends StatefulWidget {
  final int bookId;
  final int volumeId;
  final int currentChapterId;
  final int currentChapterNo;
  final void Function(int chapterId, String title, int volumeId) onPick;
  const _CatalogSheet(
      {required this.bookId,
      required this.volumeId,
      required this.currentChapterId,
      required this.currentChapterNo,
      required this.onPick});

  @override
  State<_CatalogSheet> createState() => _CatalogSheetState();
}

class _CatalogSheetState extends State<_CatalogSheet> {
  static const int _pageSize = 50;
  static const int _volumePageSize = 50;

  List<LKVolume> _volumes = const [];
  String? _error;
  int _volumesPage = 0;
  bool _volumesHasMore = true;
  bool _volumePageLoading = false;
  int? _expanded;
  final Map<int, List<LKChapter>> _chapters = {};
  final Set<int> _loadingVolumes = <int>{};
  final Set<int> _openingSingleVolumes = <int>{};
  final Map<int, String> _chapterErrors = <int, String>{};
  final Map<int, int> _failedChapterPages = <int, int>{};
  final Map<int, Set<int>> _loadedChapterPages = <int, Set<int>>{};
  final Map<int, int> _chapterTotals = <int, int>{};
  final Map<int, bool> _maxPageHasMore = <int, bool>{};
  final ScrollController _sc = ScrollController();
  final Map<int, GlobalKey> _volKeys = {};
  final GlobalKey _curChapterKey = GlobalKey();
  bool _located = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.volumeId; // 打开即展开当前卷
    unawaited(_loadVolumes());
    // 当前卷与卷列表互不依赖，先加载当前章节所在分页即可立即使用目录。
    if (widget.volumeId > 0) unawaited(_loadChapters(widget.volumeId));
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  Future<void> _loadVolumes({bool append = false}) async {
    if (_volumePageLoading || (append && !_volumesHasMore)) return;
    final page = append ? _volumesPage + 1 : 1;
    setState(() {
      _volumePageLoading = true;
      _error = null;
    });
    try {
      final pageItems = await LKApi.volumes(
        widget.bookId,
        page,
        pageSize: _volumePageSize,
      );
      if (!mounted) return;
      final seen =
          append ? _volumes.map((volume) => volume.volumeId).toSet() : <int>{};
      final merged = [
        if (append) ..._volumes,
        ...pageItems.where((volume) => seen.add(volume.volumeId)),
      ];
      setState(() {
        _volumes = merged;
        _volumesPage = page;
        _volumesHasMore = pageItems.length >= _volumePageSize;
        _error = null;
      });
      if (widget.volumeId > 0 &&
          _displayVolumes.any((volume) => volume.volumeId == widget.volumeId)) {
        _revealCurrent();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = append ? '更多目录加载失败，点击重试' : '目录加载失败，请检查网络后重试');
      }
    } finally {
      if (mounted) setState(() => _volumePageLoading = false);
    }
  }

  /// 保留服务端返回的卷顺序，当前卷只通过“当前”标记突出显示。
  /// 当前卷不再被强行挪到列表顶部，避免目录顺序与网站不一致。
  List<LKVolume> get _displayVolumes => _volumes;

  LKVolume? _volumeFor(int volumeId) {
    for (final volume in _volumes) {
      if (volume.volumeId == volumeId) return volume;
    }
    return null;
  }

  int _initialPageFor(int volumeId) {
    if (volumeId != widget.volumeId || widget.currentChapterNo <= 0) return 1;
    return catalogPageForChapter(
      chapterNo: widget.currentChapterNo,
      total: _volumeFor(volumeId)?.chapterCount ?? 0,
      pageSize: _pageSize,
    );
  }

  int _totalFor(int volumeId) =>
      _chapterTotals[volumeId] ?? _volumeFor(volumeId)?.chapterCount ?? 0;

  int _pageCountFor(int volumeId) =>
      catalogPageCount(_totalFor(volumeId), _pageSize);

  bool _hasPreviousPage(int volumeId) {
    final pages = _loadedChapterPages[volumeId];
    return pages != null &&
        pages.isNotEmpty &&
        pages.reduce((a, b) => a < b ? a : b) > 1;
  }

  bool _hasNextPage(int volumeId) {
    final pages = _loadedChapterPages[volumeId];
    if (pages == null || pages.isEmpty) return false;
    final maxPage = pages.reduce((a, b) => a > b ? a : b);
    final pageCount = _pageCountFor(volumeId);
    return pageCount > 0
        ? maxPage < pageCount
        : (_maxPageHasMore[volumeId] ?? false);
  }

  Future<void> _loadChapters(int vid, {int? page}) async {
    final targetPage = page ?? _initialPageFor(vid);
    if ((_loadedChapterPages[vid]?.contains(targetPage) ?? false) ||
        _loadingVolumes.contains(vid)) {
      return;
    }
    setState(() {
      _loadingVolumes.add(vid);
      _chapterErrors.remove(vid);
      _failedChapterPages.remove(vid);
    });
    try {
      var loadedPage = targetPage;
      var result = await LKApi.chapterPage(widget.bookId, vid, loadedPage,
          pageSize: _pageSize);
      final currentChapterMissing = vid == widget.volumeId &&
          widget.currentChapterId > 0 &&
          !result.items
              .any((chapter) => chapter.chapterId == widget.currentChapterId);
      // 少数响应的 chapter_no 是全书序号。若它把单章卷定位到了不存在
      // 的后续分页，退回第一页即可找到当前章。
      if (loadedPage > 1 &&
          currentChapterMissing &&
          (result.items.isEmpty || result.total <= _pageSize)) {
        loadedPage = 1;
        result = await LKApi.chapterPage(widget.bookId, vid, loadedPage,
            pageSize: _pageSize);
      }
      if (!mounted) return;
      final loadedPages = _loadedChapterPages[vid] ?? const <int>{};
      final existing = _chapters[vid] ?? const <LKChapter>[];
      final minLoadedPage = loadedPages.isEmpty
          ? loadedPage
          : loadedPages.reduce((a, b) => a < b ? a : b);
      final candidates = loadedPage < minLoadedPage
          ? [...result.items, ...existing]
          : [...existing, ...result.items];
      final seen = <int>{};
      final merged = candidates
          .where((chapter) => seen.add(chapter.chapterId))
          .toList(growable: false);
      final maxLoadedPage = loadedPages.isEmpty
          ? loadedPage
          : loadedPages.reduce((a, b) => a > b ? a : b);
      setState(() {
        _chapters[vid] = merged;
        _loadedChapterPages[vid] = {...loadedPages, loadedPage};
        _chapterTotals[vid] = result.total > 0
            ? result.total
            : (_volumeFor(vid)?.chapterCount ?? merged.length);
        if (loadedPage >= maxLoadedPage) {
          _maxPageHasMore[vid] = result.hasMore;
        }
      });
      if (vid == widget.volumeId) _revealCurrent();
    } catch (_) {
      if (mounted) {
        setState(() {
          _chapterErrors[vid] = '章节加载失败，请检查网络后重试';
          _failedChapterPages[vid] = targetPage;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingVolumes.remove(vid));
    }
  }

  Future<void> _loadPreviousPage(int volumeId) async {
    final pages = _loadedChapterPages[volumeId];
    if (pages == null || pages.isEmpty) return;
    final page = pages.reduce((a, b) => a < b ? a : b) - 1;
    if (page > 0) await _loadChapters(volumeId, page: page);
  }

  Future<void> _loadNextPage(int volumeId) async {
    final pages = _loadedChapterPages[volumeId];
    if (pages == null || pages.isEmpty) return;
    final page = pages.reduce((a, b) => a > b ? a : b) + 1;
    await _loadChapters(volumeId, page: page);
  }

  int _chapterCountFor(LKVolume volume) {
    final loadedTotal = _chapterTotals[volume.volumeId] ?? 0;
    if (loadedTotal > 0) return loadedTotal;
    if (volume.chapterCount > 0) return volume.chapterCount;
    if (volume.firstChapterId > 0 &&
        volume.firstChapterId == volume.lastChapterId) {
      return 1;
    }
    return 0;
  }

  Future<void> _toggle(LKVolume volume) async {
    final vid = volume.volumeId;
    if (_chapterCountFor(volume) == 1) {
      await _openSingleChapterVolume(volume);
      return;
    }
    if (_expanded == vid) {
      setState(() => _expanded = null);
      return;
    }
    setState(() => _expanded = vid);
    unawaited(_loadChapters(vid));
  }

  Future<void> _openSingleChapterVolume(LKVolume volume) async {
    final vid = volume.volumeId;
    if (vid <= 0 || !_openingSingleVolumes.add(vid)) return;
    if (mounted) setState(() {});
    try {
      final cached = _chapters[vid];
      var chapterId = cached?.isNotEmpty == true
          ? cached!.first.chapterId
          : volume.firstChapterId > 0
              ? volume.firstChapterId
              : volume.lastChapterId;
      var chapterTitle =
          cached?.isNotEmpty == true ? cached!.first.title : volume.title;
      if (chapterId <= 0) {
        final page = await LKApi.chapterPage(
          widget.bookId,
          vid,
          1,
          pageSize: 1,
        );
        if (!mounted) return;
        if (page.items.isEmpty) {
          showLkError(context, '该卷暂时没有可阅读章节');
          return;
        }
        final chapter = page.items.first;
        chapterId = chapter.chapterId;
        chapterTitle = chapter.title;
      }
      if (mounted) widget.onPick(chapterId, chapterTitle, vid);
    } catch (_) {
      if (mounted) showLkError(context, '章节加载失败，请检查网络后重试');
    } finally {
      _openingSingleVolumes.remove(vid);
      if (mounted) setState(() {});
    }
  }

  /// 滚动定位到当前卷与当前章节
  void _revealCurrent() {
    if (_located) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final volumes = _displayVolumes;
      if (volumes.isEmpty) return;
      final vi = volumes.indexWhere((v) => v.volumeId == widget.volumeId);
      if (vi < 0) return;
      // 1) 当前卷:已构建则 ensureVisible,否则按估计偏移跳
      final vctx = _volKeys[widget.volumeId]?.currentContext;
      if (vctx != null) {
        Scrollable.ensureVisible(vctx,
            duration: const Duration(milliseconds: 250), alignment: 0.15);
      } else if (_sc.hasClients) {
        final est = (vi * 56.0).clamp(0.0, _sc.position.maxScrollExtent);
        _sc.jumpTo(est);
      }
      // 2) 当前章节(在展开的当前卷内):已构建则精确定位,否则按行高估计
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final cctx = _curChapterKey.currentContext;
        if (cctx != null) {
          _located = true;
          Scrollable.ensureVisible(cctx,
              duration: const Duration(milliseconds: 250), alignment: 0.45);
          return;
        }
        final chs = _chapters[widget.volumeId];
        if (_sc.hasClients && chs != null) {
          final ci =
              chs.indexWhere((c) => c.chapterId == widget.currentChapterId);
          if (ci > 0) {
            final est = (vi * 56.0 + ci * 42.0)
                .clamp(0.0, _sc.position.maxScrollExtent);
            _sc.jumpTo(est);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final ctx2 = _curChapterKey.currentContext;
              if (ctx2 != null) {
                _located = true;
                Scrollable.ensureVisible(ctx2,
                    duration: const Duration(milliseconds: 200),
                    alignment: 0.45);
              }
            });
          }
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final displayVolumes = _displayVolumes;
    final hasVolumeFooter =
        _volumePageLoading || _volumesHasMore || _error != null;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          const Text('目录',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const Spacer(),
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ]),
      ),
      Expanded(
        child: displayVolumes.isEmpty && _volumePageLoading
            ? const LkLoadingIndicator(minHeight: 120, size: 24)
            : displayVolumes.isEmpty && _error != null
                ? Center(
                    child: TextButton.icon(
                      onPressed: _volumePageLoading
                          ? null
                          : () => _loadVolumes(append: _volumesPage > 0),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(_error!),
                    ),
                  )
                : displayVolumes.isEmpty
                    ? const Center(child: Text('暂无目录'))
                    : ListView.builder(
                        controller: _sc,
                        padding: EdgeInsets.fromLTRB(12, 0, 12,
                            12 + MediaQuery.of(context).padding.bottom),
                        itemCount:
                            displayVolumes.length + (hasVolumeFooter ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i >= displayVolumes.length) {
                            if (_error != null) {
                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: TextButton.icon(
                                    onPressed: _volumePageLoading
                                        ? null
                                        : () => _loadVolumes(
                                            append: _volumesPage > 0),
                                    icon: const Icon(Icons.refresh_rounded,
                                        size: 18),
                                    label: Text(_error!),
                                  ),
                                ),
                              );
                            }
                            if (!_volumePageLoading && _volumesHasMore) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) {
                                  unawaited(_loadVolumes(append: true));
                                }
                              });
                            }
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 10),
                              child: LinearProgressIndicator(
                                minHeight: 2,
                              ),
                            );
                          }
                          final v = displayVolumes[i];
                          final vid = v.volumeId;
                          final expanded = _expanded == vid;
                          final chs = _chapters[vid];
                          final chapterError = _chapterErrors[vid];
                          final isCur = vid == widget.volumeId;
                          final chapterCount = _chapterCountFor(v);
                          final openingSingle =
                              _openingSingleVolumes.contains(vid);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Material(
                              key: _volKeys.putIfAbsent(vid, GlobalKey.new),
                              color: isDark
                                  ? const Color(0xFF2A2C33)
                                  : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(12),
                              clipBehavior: Clip.antiAlias,
                              child: Column(children: [
                                InkWell(
                                  onTap:
                                      openingSingle ? null : () => _toggle(v),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                                    child: Row(children: [
                                      Icon(
                                          chapterCount == 1
                                              ? Icons.play_arrow_rounded
                                              : expanded
                                                  ? Icons
                                                      .keyboard_arrow_down_rounded
                                                  : Icons.chevron_right_rounded,
                                          size: 20,
                                          color: Colors.grey.shade500),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(v.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w600,
                                                color: isCur
                                                    ? scheme.primary
                                                    : null)),
                                      ),
                                      if (chapterCount > 0)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(left: 6),
                                          child: Text('$chapterCount 章',
                                              style: TextStyle(
                                                  fontSize: 10.5,
                                                  color: Colors.grey.shade500)),
                                        ),
                                      if (isCur)
                                        Container(
                                          margin:
                                              const EdgeInsets.only(left: 6),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: scheme.primary
                                                .withValues(alpha: 0.12),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: Text('当前',
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  color: scheme.primary)),
                                        ),
                                    ]),
                                  ),
                                ),
                                if (expanded &&
                                    chs == null &&
                                    chapterError == null &&
                                    _loadingVolumes.contains(vid))
                                  const Padding(
                                    padding: EdgeInsets.only(bottom: 12),
                                    child: LinearProgressIndicator(
                                      minHeight: 2,
                                    ),
                                  ),
                                if (expanded &&
                                    chs == null &&
                                    chapterError != null)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: TextButton.icon(
                                      onPressed: () => _loadChapters(vid,
                                          page: _failedChapterPages[vid]),
                                      icon: const Icon(Icons.refresh_rounded,
                                          size: 18),
                                      label: Text(chapterError),
                                    ),
                                  ),
                                if (expanded && chs != null) ...[
                                  if (_hasPreviousPage(vid))
                                    TextButton.icon(
                                      onPressed: _loadingVolumes.contains(vid)
                                          ? null
                                          : () => _loadPreviousPage(vid),
                                      icon: const Icon(
                                          Icons.expand_less_rounded,
                                          size: 18),
                                      label: const Text('加载更早章节'),
                                    ),
                                  ...chs.map((c) => InkWell(
                                        onTap: () => widget.onPick(
                                            c.chapterId, c.title, vid),
                                        child: Container(
                                          key: c.chapterId ==
                                                  widget.currentChapterId
                                              ? _curChapterKey
                                              : null,
                                          width: double.infinity,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 10),
                                          color: c.chapterId ==
                                                  widget.currentChapterId
                                              ? scheme.primary
                                                  .withValues(alpha: 0.12)
                                              : Colors.transparent,
                                          child: Text(c.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  color: c.chapterId ==
                                                          widget
                                                              .currentChapterId
                                                      ? scheme.primary
                                                      : null)),
                                        ),
                                      )),
                                  if (chapterError != null)
                                    TextButton.icon(
                                      onPressed: _loadingVolumes.contains(vid)
                                          ? null
                                          : () => _loadChapters(vid,
                                              page: _failedChapterPages[vid]),
                                      icon: const Icon(Icons.refresh_rounded,
                                          size: 18),
                                      label: const Text('加载失败，点击重试'),
                                    ),
                                  if (_loadingVolumes.contains(vid))
                                    const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 10),
                                      child:
                                          LinearProgressIndicator(minHeight: 2),
                                    ),
                                  if (!_loadingVolumes.contains(vid) &&
                                      _hasNextPage(vid))
                                    TextButton.icon(
                                      onPressed: () => _loadNextPage(vid),
                                      icon: const Icon(
                                          Icons.expand_more_rounded,
                                          size: 18),
                                      label: const Text('加载后续章节'),
                                    ),
                                  if (_totalFor(vid) > 0)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 10),
                                      child: Text(
                                          '已加载 ${chs.length} / ${_totalFor(vid)}',
                                          style: TextStyle(
                                              fontSize: 10.5,
                                              color: Colors.grey.shade500)),
                                    ),
                                ],
                              ]),
                            ),
                          );
                        },
                      ),
      ),
    ]);
  }
}

/// 全屏插画查看:双指缩放、点击空白关闭、一键保存到相册
class _ImageViewer extends StatefulWidget {
  final String url;
  const _ImageViewer({required this.url});

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final resp = await http.get(Uri.parse(widget.url), headers: const {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 LKFlutter'
      }).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw Exception('下载失败 HTTP ${resp.statusCode}');
      }
      await Gal.putImageBytes(
        resp.bodyBytes,
        name: 'lk_${DateTime.now().millisecondsSinceEpoch}',
        album: 'Yomiru',
      );
      if (!mounted) return;
      showLkError(context, '已保存到相册');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showLkError(context, '保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: InteractiveViewer(
              maxScale: 5,
              child: Center(
                child: CachedNetworkImage(
                  imageUrl: widget.url,
                  fit: BoxFit.contain,
                  progressIndicatorBuilder: (_, __, ___) => const Center(
                      child: CircularProgressIndicator(color: Colors.white70)),
                  errorWidget: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: Colors.white38, size: 48)),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: MediaQuery.of(context).padding.top,
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
          bottom: 24 + MediaQuery.of(context).padding.bottom,
          child: SizedBox(
            height: 46,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_rounded, size: 20),
              label: Text(_saving ? '保存中…' : '保存图片到相册'),
            ),
          ),
        ),
      ]),
    );
  }
}
