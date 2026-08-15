import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/store.dart';
import '../widgets/common.dart';

/// 正文块:文本或插画
class _BodyBlock {
  final String? text;
  final String? image;
  _BodyBlock.text(this.text) : image = null;
  _BodyBlock.image(this.image) : text = null;
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

class _ReaderPageState extends State<ReaderPage> {
  String _title = '';
  List<_BodyBlock> _blocks = [_BodyBlock.text('加载中…')];
  int? _prevId;
  String? _prevTitle;
  int? _nextId;
  String? _nextTitle;
  bool _locked = false;
  bool _unlocked = false;
  bool _loading = true;
  bool _chrome = true;

  // 偏好
  double _fontSize = 17;
  double _lineHeight = 1.7;
  int _bg = 0;
  bool _bgChosen = false;
  bool _keepOn = false;
  bool _hideBar = false;
  bool _tapTurn = false;
  bool _volTurn = false;
  bool _autoMargin = true;
  double _mt = 56, _mb = 70, _ml = 20, _mr = 20;
  bool _indicators = true;

  final _sc = ScrollController();
  double _progress = 0;

  static const _presets = [
    (Color(0xFFFFFFFF), Color(0xFF333333), '白'),
    (Color(0xFFF7F1E3), Color(0xFF3D362A), '米黄'),
    (Color(0xFF2A2D34), Color(0xFFC9CDD6), '深灰'),
    (Color(0xFF000000), Color(0xFF9AA0A6), '纯黑'),
  ];

  Color get _bgColor => _presets[_bg].$1;
  Color get _textColor => _presets[_bg].$2;
  bool get _isDarkBg => _bg >= 2;

  @override
  void initState() {
    super.initState();
    _title = widget.chapterTitle;
    _sc.addListener(() {
      final max = _sc.position.maxScrollExtent;
      _progress = max <= 0 ? 1 : (_sc.offset / max).clamp(0.0, 1.0);
    });
    _load();
    _loadPrefs();
  }

  @override
  void dispose() {
    _sc.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final bg = await ReaderPrefs.bgPreset();
    final fontSize = await ReaderPrefs.fontSize();
    final lineHeight = await ReaderPrefs.lineHeight();
    final keepOn = await ReaderPrefs.keepScreenOn();
    final hideBar = await ReaderPrefs.hideStatusBar();
    final tapTurn = await ReaderPrefs.tapTurnPage();
    final volTurn = await ReaderPrefs.volumeTurnPage();
    final autoMargin = await ReaderPrefs.autoMargin();
    final mt = await ReaderPrefs.marginTop();
    final mb = await ReaderPrefs.marginBottom();
    final ml = await ReaderPrefs.marginLeft();
    final mr = await ReaderPrefs.marginRight();
    final ind = await ReaderPrefs.showIndicators();
    if (!mounted) return;
    setState(() {
      _fontSize = fontSize;
      _lineHeight = lineHeight;
      if (bg >= 0) {
        _bg = bg;
        _bgChosen = true;
      }
      _keepOn = keepOn;
      _hideBar = hideBar;
      _tapTurn = tapTurn;
      _volTurn = volTurn;
      _autoMargin = autoMargin;
      _mt = mt;
      _mb = mb;
      _ml = ml;
      _mr = mr;
      _indicators = ind;
    });
    WakelockPlus.toggle(enable: _keepOn);
    _applyImmersive();
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

  // ==================== 加载与解析 ====================

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await LKApi.chapterDetail(widget.bookId, widget.chapterId);
      if (!mounted) return;
      setState(() {
        _title = d.title.isEmpty ? _title : d.title;
        _blocks = _parseBlocks(d);
        _locked = d.locked;
        _unlocked = d.unlocked;
        _prevId = d.prevChapterId;
        _prevTitle = d.prevTitle;
        _nextId = d.nextChapterId;
        _nextTitle = d.nextTitle;
      });
      if (LKClient.shared.session.isLoggedIn && !d.locked) {
        try {
          await LKApi.saveHistory(
              widget.bookId, widget.volumeId, widget.chapterId, 5);
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) {
        setState(() => _blocks = [_BodyBlock.text('加载失败: $e')]);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<_BodyBlock> _parseBlocks(dynamic d) {
    final html = d.bodyHtml as String?;
    if (html != null && html.isNotEmpty) {
      final blocks = <_BodyBlock>[];
      final imgRe = RegExp(r'<img[^>]*src="([^"]+)"[^>]*>');
      var pos = 0;
      for (final m in imgRe.allMatches(html)) {
        _addTextBlocks(blocks, html.substring(pos, m.start));
        blocks.add(_BodyBlock.image(m.group(1)!));
        pos = m.end;
      }
      _addTextBlocks(blocks, html.substring(pos));
      if (blocks.isNotEmpty) return blocks;
    }
    return [_BodyBlock.text(d.bodyText ?? '')];
  }

  void _addTextBlocks(List<_BodyBlock> blocks, String seg) {
    var t = seg
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    final paras = t
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    blocks.addAll(paras.map((p) => _BodyBlock.text(p)));
  }

  void _open(int chapterId, String title) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
          builder: (_) => ReaderPage(
                bookId: widget.bookId,
                bookTitle: widget.bookTitle,
                chapterId: chapterId,
                chapterTitle: title,
                volumeId: widget.volumeId,
              )),
    );
  }

  Future<void> _unlock() async {
    try {
      await LKApi.unlockChapter(widget.chapterId);
      _load();
    } catch (e) {
      if (mounted) showLkError(context, e);
    }
  }

  Future<void> _pickParagraph() async {
    try {
      final paras = await LKApi.paragraphs(widget.bookId, widget.chapterId);
      if (!mounted) return;
      if (paras.isEmpty) {
        showLkError(context, '本章没有段落数据');
        return;
      }
      final p = await showModalBottomSheet<dynamic>(
        context: context,
        builder: (_) => ListView(
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('选择段落看段评',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ...paras.take(30).map((e) => ListTile(
                  dense: true,
                  title: Text('¶${e.paragraphNo} ${e.text}',
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, e),
                )),
          ],
        ),
      );
      if (p == null || !mounted) return;
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _ParagraphCommentsSheet(
            bookId: widget.bookId, chapterId: widget.chapterId, para: p),
      );
    } catch (e) {
      if (mounted) showLkError(context, e);
    }
  }

  void _addBookmark() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('添加书签 · $_title'),
        content: const TextField(
          decoration: InputDecoration(hintText: '书签名称(可选)'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  // ==================== 翻页 ====================

  void _pageUp() {
    final h = MediaQuery.of(context).size.height;
    _sc.animateTo(
        (_sc.offset - h * 0.85).clamp(0.0, _sc.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut);
  }

  void _pageDown() {
    final h = MediaQuery.of(context).size.height;
    _sc.animateTo(
        (_sc.offset + h * 0.85).clamp(0.0, _sc.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && _volTurn) {
      if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
        _pageUp();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
        _pageDown();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
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
                    Tab(icon: Icon(Icons.palette_outlined, size: 20), text: '外观'),
                    Tab(icon: Icon(Icons.touch_app_outlined, size: 20), text: '操作'),
                    Tab(icon: Icon(Icons.aspect_ratio_rounded, size: 20), text: '边距'),
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
                        _switchTile(scheme, Icons.info_outline, '正文指示器',
                            _indicators, (v) {
                          setSheet(() {});
                          setState(() => _indicators = v);
                          ReaderPrefs.setShowIndicators(v);
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
                                    });
                                    ReaderPrefs.setBgPreset(i);
                                  },
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: _presets[i].$1,
                                      borderRadius: BorderRadius.circular(22),
                                      border: Border.all(
                                        color: _bg == i
                                            ? scheme.primary
                                            : (isDark
                                                ? Colors.grey.shade700
                                                : Colors.grey.shade300),
                                        width: _bg == i ? 2.5 : 1,
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
                        _switchTile(scheme, Icons.volume_up_outlined,
                            '音量键翻页', _volTurn, (v) {
                          setSheet(() {});
                          setState(() => _volTurn = v);
                          ReaderPrefs.setVolumeTurnPage(v);
                        }),
                        _aaTile(scheme, Icons.menu_rounded, '目录', () {}),
                        _aaTile(scheme, Icons.format_quote_rounded, '段评',
                            () {
                          Navigator.pop(sheetCtx);
                          _pickParagraph();
                        }),
                        _aaTile(scheme, Icons.bookmark_border_rounded, '书签',
                            () {
                          Navigator.pop(sheetCtx);
                          _addBookmark();
                        }),
                        _aaTile(scheme, Icons.chevron_left_rounded, '上一章',
                            () {
                          Navigator.pop(sheetCtx);
                          if (_prevId != null) {
                            _open(_prevId!, _prevTitle ?? '');
                          }
                        }),
                        _aaTile(scheme, Icons.chevron_right_rounded, '下一章',
                            () {
                          Navigator.pop(sheetCtx);
                          if (_nextId != null) {
                            _open(_nextId!, _nextTitle ?? '');
                          }
                        }),
                        if (_locked && !_unlocked)
                          _aaTile(scheme, Icons.lock_open_rounded, '解锁本章',
                              () {
                            Navigator.pop(sheetCtx);
                            _unlock();
                          }),
                        _aaTile(scheme, Icons.arrow_upward_rounded, '回顶部',
                            () {
                          Navigator.pop(sheetCtx);
                          _sc.jumpTo(0);
                        }),
                      ],
                    ),
                    // ---- 边距 ----
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _switchTile(scheme, Icons.fit_screen_outlined,
                            '自动边距', _autoMargin, (v) {
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

  Widget _marginSlider(
      String label, double value, Function(double) onChanged) {
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

  // ==================== 界面 ====================

  EdgeInsets get _bodyPadding {
    if (_autoMargin) {
      return const EdgeInsets.fromLTRB(20, 56, 20, 70);
    }
    return EdgeInsets.fromLTRB(_ml, _mt, _mr, _mb);
  }

  @override
  Widget build(BuildContext context) {
    final lockedBody = _locked && !_unlocked && _blocks.length == 1;
    final barColor = _bgColor.withValues(alpha: 0.96);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            _isDarkBg ? Brightness.light : Brightness.dark,
        statusBarBrightness: _isDarkBg ? Brightness.dark : Brightness.light,
      ),
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: _bgColor,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              if (_tapTurn) {
                final w = MediaQuery.of(context).size.width;
                if (d.globalPosition.dx < w / 3) {
                  _pageUp();
                  return;
                }
                if (d.globalPosition.dx > w * 2 / 3) {
                  _pageDown();
                  return;
                }
              }
              setState(() => _chrome = !_chrome);
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: _loading
                      ? Center(
                          child:
                              CircularProgressIndicator(color: _textColor))
                      : NotificationListener<ScrollNotification>(
                          onNotification: (n) {
                            if (n is ScrollUpdateNotification && _chrome) {
                              setState(() => _chrome = false);
                            }
                            return false;
                          },
                          child: ListView.builder(
                            controller: _sc,
                            padding: _bodyPadding,
                            itemCount: _blocks.length,
                            itemBuilder: (_, i) {
                              final b = _blocks[i];
                              if (b.image != null) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 10),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: CachedNetworkImage(
                                      imageUrl: b.image!,
                                      width: double.infinity,
                                      fit: BoxFit.fitWidth,
                                      placeholder: (_, __) => Container(
                                        height: 180,
                                        color: _isDarkBg
                                            ? Colors.white10
                                            : Colors.black
                                                .withValues(alpha: 0.05),
                                        child: const Center(
                                            child:
                                                CircularProgressIndicator(
                                                    strokeWidth: 2)),
                                      ),
                                      errorWidget: (_, __, ___) =>
                                          Container(
                                        height: 120,
                                        alignment: Alignment.center,
                                        child: Icon(
                                            Icons.broken_image_outlined,
                                            color: _textColor
                                                .withValues(alpha: 0.5)),
                                      ),
                                    ),
                                  ),
                                );
                              }
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  lockedBody
                                      ? '本章需要解锁后阅读\n\n点击屏幕,在设置面板中解锁'
                                      : (b.text ?? ''),
                                  style: TextStyle(
                                    fontSize: _fontSize,
                                    height: _lineHeight,
                                    color: _textColor,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
                if (_indicators && !_chrome && !_loading)
                  Positioned(
                    top: 6,
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
                    child: Text(
                      '${(_progress * 100).toStringAsFixed(1)}%',
                      style: TextStyle(
                          fontSize: 11,
                          color: _textColor.withValues(alpha: 0.45)),
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
                          const SizedBox(width: 48),
                        ],
                      ),
                    ),
                  ),
                ),
                // 底栏:小齿轮
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  bottom: _chrome ? 0 : -90,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: barColor,
                    child: SafeArea(
                      top: false,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_locked && !_unlocked)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(Icons.lock_outline_rounded,
                                  size: 16, color: _textColor),
                            ),
                          IconButton(
                            tooltip: '阅读设置',
                            icon: Icon(Icons.settings_rounded,
                                size: 22, color: _textColor),
                            onPressed: _showSettings,
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

/// 段评底部弹层
class _ParagraphCommentsSheet extends StatefulWidget {
  final int bookId;
  final int chapterId;
  final dynamic para;
  const _ParagraphCommentsSheet(
      {required this.bookId, required this.chapterId, required this.para});

  @override
  State<_ParagraphCommentsSheet> createState() =>
      _ParagraphCommentsSheetState();
}

class _ParagraphCommentsSheetState extends State<_ParagraphCommentsSheet> {
  List<dynamic> _comments = [];
  String? _error;
  final _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cs = await LKApi.paragraphComments(
          widget.bookId, widget.chapterId, widget.para);
      if (!mounted) return;
      setState(() => _comments = cs);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _publish() async {
    final content = _input.text.trim();
    if (content.isEmpty) return;
    try {
      await LKApi.publishParagraphComment(
          widget.bookId, widget.chapterId, widget.para, content);
      _input.clear();
      _load();
    } catch (e) {
      if (mounted) showLkError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: 420,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('¶${widget.para.paragraphNo} ${widget.para.text}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.grey.shade600)),
          ),
          Expanded(
            child: _comments.isEmpty
                ? Center(
                    child: Text(_error ?? '这段还没有段评',
                        style: const TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: _comments.length,
                    itemBuilder: (_, i) {
                      final c = _comments[i];
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                            backgroundImage: c.avatar.isNotEmpty
                                ? NetworkImage(c.avatar)
                                : null),
                        title: Text(c.nickname,
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.indigo.shade400)),
                        subtitle: Text(c.content),
                      );
                    },
                  ),
          ),
          Row(children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextField(
                  controller: _input,
                  decoration: const InputDecoration(
                      hintText: '写段评…',
                      isDense: true,
                      border: OutlineInputBorder()),
                ),
              ),
            ),
            FilledButton(onPressed: _publish, child: const Text('发布')),
          ]),
        ]),
      ),
    );
  }
}
