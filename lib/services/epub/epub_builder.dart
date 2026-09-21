import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../reader/structured_content.dart';
import 'epub_models.dart';
import 'epub_zip_writer.dart';

/// XML 实体字符转义工具
String xmlEscape(String text) {
  if (text.isEmpty) return '';
  return text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

/// 将十进制 UID 转为 UTF-8 + 标准 Base64 编码
String encodeUidToBase64(int uid) {
  return base64.encode(utf8.encode(uid.toString()));
}

/// 从标准 Base64 还原十进制 UID
int decodeUidFromBase64(String b64) {
  return int.parse(utf8.decode(base64.decode(b64.trim())));
}

/// 过滤或推断文件的 MIME 类型
String mimeTypeForFile(String pathOrUrl) {
  final clean = pathOrUrl.toLowerCase();
  if (clean.endsWith('.jpg') || clean.endsWith('.jpeg')) return 'image/jpeg';
  if (clean.endsWith('.png')) return 'image/png';
  if (clean.endsWith('.gif')) return 'image/gif';
  if (clean.endsWith('.webp')) return 'image/webp';
  if (clean.endsWith('.svg')) return 'image/svg+xml';
  return 'image/jpeg';
}

/// 构建上下文参数（跨 Isolate 传递的数据）
class EpubBuildContext {
  final String taskDir;
  final String outputPath;
  final int bookId;
  final String bookTitle;
  final String authorName;
  final String summary;
  final int publisherUid;
  final int exporterUid;
  final bool includeIllustrations;
  final bool exportIncomplete;
  final List<EpubChapterItem> chapters;
  final List<int> completedChapterIds;
  final String? coverImagePath; // 相对或绝对图片路径

  const EpubBuildContext({
    required this.taskDir,
    required this.outputPath,
    required this.bookId,
    required this.bookTitle,
    required this.authorName,
    required this.summary,
    this.publisherUid = 0,
    this.exporterUid = 0,
    required this.includeIllustrations,
    required this.exportIncomplete,
    required this.chapters,
    required this.completedChapterIds,
    this.coverImagePath,
  });
}

/// EPUB 3.3 规范构建器
class EpubBuilder {
  static const String cssContent = '''@charset "utf-8";
body {
  margin: 5% 5%;
  padding: 0;
  line-height: 1.75;
  font-size: 1em;
}
h1, h2, h3, h4, h5, h6 {
  margin: 1.4em 0 0.8em 0;
  font-weight: bold;
  text-align: center;
  line-height: 1.3;
}
h1 {
  font-size: 1.5em;
}
h2 {
  font-size: 1.3em;
}
h3 {
  font-size: 1.15em;
}
h4 {
  font-size: 1.05em;
}
p {
  margin: 0.5em 0;
  text-indent: 2em;
  text-align: justify;
}
blockquote {
  margin: 1em 0;
  padding: 0.5em 1em;
  border-left: 3px solid gray;
  opacity: 0.9;
}
blockquote p {
  text-indent: 0;
}
ul, ol {
  margin: 0.5em 0;
  padding-left: 2em;
}
li {
  margin: 0.25em 0;
}
ruby rt {
  font-size: 0.6em;
}
sup {
  font-size: 0.75em;
  line-height: 0;
  vertical-align: super;
}
hr {
  border: none;
  border-top: 1px solid gray;
  margin: 1.5em 0;
}
.illustration {
  text-align: center;
  margin: 1.5em 0;
  page-break-inside: avoid;
}
.illustration img {
  max-width: 100%;
  height: auto;
  margin: 0 auto;
  display: block;
}
.cover {
  text-align: center;
  padding: 0;
  margin: 0;
}
.cover img {
  max-width: 100%;
  max-height: 100%;
  height: auto;
  margin: 0 auto;
  display: block;
}
nav#toc ol {
  list-style-type: none;
  padding-left: 1em;
}
nav#toc li {
  margin: 0.5em 0;
}
''';

  /// 正文 HTML 清洗为符合严格 XML 规范的 XHTML
  static String sanitizeToXHtml({
    required String title,
    required String? rawHtml,
    required String rawText,
    required Map<String, String> imageUrlToLocalPath,
    bool isCover = false,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln(
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh-CN" lang="zh-CN">');
    buffer.writeln('<head>');
    buffer.writeln('  <meta charset="utf-8"/>');
    buffer.writeln('  <title>${xmlEscape(title)}</title>');
    buffer.writeln(
        '  <link rel="stylesheet" type="text/css" href="../styles/style.css"/>');
    buffer.writeln('</head>');
    buffer.writeln('<body>');

    if (isCover) {
      final coverRel = imageUrlToLocalPath['cover'] ?? '../images/cover.jpg';
      buffer.writeln('  <div class="cover">');
      buffer.writeln('    <img src="$coverRel" alt="${xmlEscape(title)}"/>');
      buffer.writeln('  </div>');
    } else {
      buffer.writeln('  <section class="chapter" epub:type="chapter">');
      buffer.writeln('    <h2>${xmlEscape(title)}</h2>');

      if (rawHtml != null && rawHtml.trim().isNotEmpty) {
        _convertHtmlToXHtml(rawHtml, buffer, imageUrlToLocalPath);
      } else if (rawText.trim().isNotEmpty) {
        _convertTextToXHtml(rawText, buffer);
      } else {
        buffer.writeln('    <p>(本章暂无内容)</p>');
      }

      buffer.writeln('  </section>');
    }

    buffer.writeln('</body>');
    buffer.writeln('</html>');
    return buffer.toString();
  }


  /// 多级检索插画的本地相对路径（支持原始 URL、去实体 URL、安全文件名与基名）
  static String? _resolveImageLocalPath(
    String rawSrc,
    Map<String, String> map,
  ) {
    if (rawSrc.isEmpty) return null;
    if (map.containsKey(rawSrc)) return map[rawSrc];
    final unescaped = rawSrc.replaceAll('&amp;', '&').trim();
    if (map.containsKey(unescaped)) return map[unescaped];
    final fileName = getIllustrationFileName(unescaped);
    if (map.containsKey(fileName)) return map[fileName];
    final withoutQuery = unescaped.replaceAll(RegExp(r'\?.*$'), '');
    if (map.containsKey(withoutQuery)) return map[withoutQuery];
    final uri = Uri.tryParse(unescaped);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      final last = uri.pathSegments.last;
      if (map.containsKey(last)) return map[last];
    }
    return null;
  }

  static void _convertHtmlToXHtml(
    String html,
    StringBuffer buffer,
    Map<String, String> imageUrlToLocalPath,
  ) {
    final blocks =
        StructuredContentParser.parseHtml(html, firstLineIndent: false);
    if (blocks.isEmpty) {
      _convertTextToXHtml(html, buffer);
      return;
    }

    final initialLength = buffer.length;
    var inList = false;
    var isOrderedList = false;

    for (final block in blocks) {
      if (block.isListItem) {
        final currentIsOrdered = block.listNumber != null;
        if (!inList) {
          inList = true;
          isOrderedList = currentIsOrdered;
          buffer.writeln(isOrderedList ? '    <ol>' : '    <ul>');
        } else if (isOrderedList != currentIsOrdered) {
          buffer.writeln(isOrderedList ? '    </ol>' : '    </ul>');
          isOrderedList = currentIsOrdered;
          buffer.writeln(isOrderedList ? '    <ol>' : '    <ul>');
        }
        final itemContent = _renderRunsToXHtml(block.runs, isListItem: true);
        if (itemContent.isNotEmpty) {
          buffer.writeln('      <li>$itemContent</li>');
        }
        continue;
      }

      if (inList) {
        buffer.writeln(isOrderedList ? '    </ol>' : '    </ul>');
        inList = false;
      }

      if (block.isImage) {
        if (block.imageUrl != null) {
          final localRel =
              _resolveImageLocalPath(block.imageUrl!, imageUrlToLocalPath);
          if (localRel != null && localRel.isNotEmpty) {
            buffer.writeln('    <div class="illustration">');
            buffer.writeln('      <img src="$localRel" alt=""/>');
            buffer.writeln('    </div>');
          }
        }
      } else if (block.isDivider) {
        buffer.writeln('    <hr/>');
      } else if (block.isHeading) {
        final lvl = math.min(6, math.max(3, block.headingLevel + 2));
        final alignStyle = _alignStyleAttr(block.align);
        final content = _renderRunsToXHtml(block.runs);
        if (content.isNotEmpty) {
          buffer.writeln('    <h$lvl$alignStyle>$content</h$lvl>');
        }
      } else if (block.isBlockquote) {
        final alignStyle = _alignStyleAttr(block.align);
        final content = _renderRunsToXHtml(block.runs);
        if (content.isNotEmpty) {
          buffer.writeln(
              '    <blockquote><p$alignStyle>$content</p></blockquote>');
        }
      } else {
        // 段落
        final alignStyle = _alignStyleAttr(block.align);
        final content = _renderRunsToXHtml(block.runs);
        if (content.isNotEmpty) {
          buffer.writeln('    <p$alignStyle>$content</p>');
        }
      }
    }

    if (inList) {
      buffer.writeln(isOrderedList ? '    </ol>' : '    </ul>');
    }

    if (buffer.length == initialLength) {
      buffer.writeln('    <p>(本章暂无内容)</p>');
    }
  }

  static String _alignStyleAttr(TextAlign? align) {
    if (align == TextAlign.center) {
      return ' style="text-align: center; text-indent: 0;"';
    } else if (align == TextAlign.right) {
      return ' style="text-align: right; text-indent: 0;"';
    } else if (align == TextAlign.left) {
      return ' style="text-align: left;"';
    } else if (align == TextAlign.justify) {
      return ' style="text-align: justify;"';
    }
    return '';
  }

  static String _renderRunsToXHtml(List<StructuredInlineRun> runs,
      {bool isListItem = false}) {
    if (runs.isEmpty) return '';
    final sb = StringBuffer();
    var startIndex = 0;
    if (isListItem && runs.isNotEmpty) {
      final firstText = runs.first.text.trim();
      if (firstText == '•' || RegExp(r'^\d+\.?$').hasMatch(firstText)) {
        startIndex = 1;
      }
    }

    for (var i = startIndex; i < runs.length; i++) {
      final run = runs[i];
      String textHtml;
      if (run.rubyText != null && run.rubyText!.isNotEmpty) {
        final paren = '(${run.rubyText!})';
        var baseText = run.text;
        if (baseText.endsWith(paren)) {
          baseText = baseText.substring(0, baseText.length - paren.length);
        }
        textHtml =
            '<ruby>${xmlEscape(baseText)}<rp>(</rp><rt>${xmlEscape(run.rubyText!)}</rt><rp>)</rp></ruby>';
      } else {
        textHtml = xmlEscape(run.text);
      }

      if (run.isFootnote) {
        textHtml = '<sup>$textHtml</sup>';
      }

      if (run.fontSizeMultiplier != null && run.fontSizeMultiplier != 1.0) {
        final em = run.fontSizeMultiplier!.toStringAsFixed(2);
        textHtml = '<span style="font-size: ${em}em;">$textHtml</span>';
      }

      if (run.isBold) {
        textHtml = '<strong>$textHtml</strong>';
      }

      if (run.isItalic) {
        textHtml = '<em>$textHtml</em>';
      }

      if (run.isUnderline && run.isStrikethrough) {
        textHtml =
            '<span style="text-decoration: underline line-through;">$textHtml</span>';
      } else if (run.isUnderline) {
        textHtml = '<span style="text-decoration: underline;">$textHtml</span>';
      } else if (run.isStrikethrough) {
        textHtml = '<del>$textHtml</del>';
      }

      if (run.color != null) {
        final hex = (run.color!.toARGB32() & 0x00FFFFFF)
            .toRadixString(16)
            .padLeft(6, '0');
        textHtml = '<span style="color: #$hex;">$textHtml</span>';
      }

      if (run.linkUrl != null && run.linkUrl!.isNotEmpty) {
        textHtml = '<a href="${xmlEscape(run.linkUrl!)}">$textHtml</a>';
      }

      sb.write(textHtml);
    }
    return sb.toString();
  }

  static void _convertTextToXHtml(String text, StringBuffer buffer) {
    final lines = text.split('\n');
    for (var line in lines) {
      line = line.trim();
      if (line.isNotEmpty) {
        buffer.writeln('    <p>${xmlEscape(line)}</p>');
      }
    }
  }

  /// 在独立 Isolate 中执行打包操作，完全不卡顿主线程 UI
  static Future<int> packageInIsolate(EpubBuildContext context) async {
    return await Isolate.run(() => _buildEpubSync(context));
  }

  static Future<int> _buildEpubSync(EpubBuildContext ctx) async {
    final outputFile = File(ctx.outputPath);
    final writer = await EpubZipWriter.open(outputFile);

    try {
      // 1. META-INF/container.xml
      const containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="EPUB/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
      await writer.addBytes('META-INF/container.xml', utf8.encode(containerXml));

      // 2. EPUB/styles/style.css
      await writer.addBytes('EPUB/styles/style.css', utf8.encode(cssContent));

      // 3. 收集并写入图片资源
      final taskDir = Directory(ctx.taskDir);
      final imagesDir = Directory('${taskDir.path}/images');
      final imagesManifest = <({String id, String href, String mime, bool isCover})>[];
      final urlToRelMap = <String, String>{};

      // 处理封面
      var hasCover = false;
      final coverFile = File('${taskDir.path}/cover.jpg');
      if (ctx.coverImagePath != null && ctx.coverImagePath!.isNotEmpty) {
        final customCover = File(ctx.coverImagePath!);
        if (await customCover.exists() && customCover.path != coverFile.path) {
          try {
            await customCover.copy(coverFile.path);
          } catch (_) {}
        }
      }
      if (await coverFile.exists()) {
        hasCover = true;
        await writer.addFile('EPUB/images/cover.jpg', coverFile, compress: false);
        imagesManifest.add((
          id: 'cover-image',
          href: 'images/cover.jpg',
          mime: mimeTypeForFile(coverFile.path),
          isCover: true,
        ));
        urlToRelMap['cover'] = '../images/cover.jpg';
      }

      // 处理插画
      if (ctx.includeIllustrations && await imagesDir.exists()) {
        final imageEntries = imagesDir.listSync().whereType<File>();
        var imgIndex = 1;
        for (final imgFile in imageEntries) {
          final fileName = imgFile.uri.pathSegments.last;
          final entryPath = 'EPUB/images/$fileName';
          final mime = mimeTypeForFile(fileName);
          await writer.addFile(entryPath, imgFile, compress: false);
          final imgId = 'img_$imgIndex';
          imagesManifest.add((
            id: imgId,
            href: 'images/$fileName',
            mime: mime,
            isCover: false,
          ));
          // 映射规则：原 URL/hash 映射到 relative path
          final rawKey = Uri.decodeComponent(fileName);
          urlToRelMap[rawKey] = '../images/$fileName';
          urlToRelMap[fileName] = '../images/$fileName';
          imgIndex++;
        }
      }

      // 如果有插画元数据映射表
      final imageMetaFile = File('${taskDir.path}/image_map.json');
      if (await imageMetaFile.exists()) {
        try {
          final map = jsonDecode(await imageMetaFile.readAsString()) as Map<String, dynamic>;
          for (final entry in map.entries) {
            urlToRelMap[entry.key] = '../images/${entry.value}';
          }
        } catch (_) {}
      }

      // 4. 写入封面页 XHTML（如果有封面）
      if (hasCover) {
        final coverXhtml = sanitizeToXHtml(
          title: '封面',
          rawHtml: null,
          rawText: '',
          imageUrlToLocalPath: urlToRelMap,
          isCover: true,
        );
        await writer.addBytes('EPUB/text/cover.xhtml', utf8.encode(coverXhtml));
      }

      // 5. 逐章读取并写入章节 XHTML
      final chaptersManifest = <({String id, String href, String title, int volumeId, String volumeTitle})>[];
      final completedSet = ctx.completedChapterIds.toSet();

      var chOrder = 1;
      for (final ch in ctx.chapters) {
        if (!completedSet.contains(ch.chapterId)) {
          // 未完成章节且未允许导出不完整内容则跳过
          if (!ctx.exportIncomplete) continue;
        }

        final chFile = File('${taskDir.path}/chapters/${ch.chapterId}.json');
        String bodyText = '';
        String? bodyHtml;

        if (await chFile.exists()) {
          try {
            final json = jsonDecode(await chFile.readAsString()) as Map<String, dynamic>;
            bodyText = (json['body_text'] ?? '').toString();
            bodyHtml = json['body_html'] as String?;
          } catch (_) {}
        }

        final xhtmlName = 'ch_${chOrder.toString().padLeft(4, '0')}.xhtml';
        final xhtmlContent = sanitizeToXHtml(
          title: ch.title,
          rawHtml: bodyHtml,
          rawText: bodyText,
          imageUrlToLocalPath: urlToRelMap,
        );

        await writer.addBytes('EPUB/text/$xhtmlName', utf8.encode(xhtmlContent));
        chaptersManifest.add((
          id: 'chapter_$chOrder',
          href: 'text/$xhtmlName',
          title: ch.title,
          volumeId: ch.volumeId,
          volumeTitle: ch.volumeTitle,
        ));
        chOrder++;
      }

      // 6. 编写 EPUB 3 nav.xhtml 与 EPUB 2 toc.ncx
      final navXhtml = _buildNavXhtml(ctx.bookTitle, chaptersManifest);
      await writer.addBytes('EPUB/nav.xhtml', utf8.encode(navXhtml));

      final tocNcx = _buildTocNcx(ctx.bookId, ctx.bookTitle, chaptersManifest);
      await writer.addBytes('EPUB/toc.ncx', utf8.encode(tocNcx));

      // 7. 编写 EPUB/content.opf
      final contentOpf = _buildContentOpf(
        ctx: ctx,
        hasCover: hasCover,
        imagesManifest: imagesManifest,
        chaptersManifest: chaptersManifest,
      );
      await writer.addBytes('EPUB/content.opf', utf8.encode(contentOpf));

      // 8. 关闭并刷盘
      await writer.close();
      return await outputFile.length();
    } catch (e) {
      await writer.close();
      rethrow;
    }
  }

  static String _buildNavXhtml(
    String bookTitle,
    List<({String id, String href, String title, int volumeId, String volumeTitle})> chapters,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln(
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh-CN" lang="zh-CN">');
    buffer.writeln('<head>');
    buffer.writeln('  <meta charset="utf-8"/>');
    buffer.writeln('  <title>目录</title>');
    buffer.writeln('  <link rel="stylesheet" type="text/css" href="styles/style.css"/>');
    buffer.writeln('</head>');
    buffer.writeln('<body>');
    buffer.writeln('  <nav epub:type="toc" id="toc">');
    buffer.writeln('    <h1>目录</h1>');
    buffer.writeln('    <ol>');

    int? currentVolId;
    var openVolLi = false;

    for (final ch in chapters) {
      if (ch.volumeId > 0 && ch.volumeId != currentVolId) {
        if (openVolLi) {
          buffer.writeln('        </ol>');
          buffer.writeln('      </li>');
        }
        currentVolId = ch.volumeId;
        openVolLi = true;
        buffer.writeln('      <li>');
        buffer.writeln('        <span>${xmlEscape(ch.volumeTitle.isEmpty ? "正文" : ch.volumeTitle)}</span>');
        buffer.writeln('        <ol>');
      }

      buffer.writeln('          <li><a href="${ch.href}">${xmlEscape(ch.title)}</a></li>');
    }

    if (openVolLi) {
      buffer.writeln('        </ol>');
      buffer.writeln('      </li>');
    }

    buffer.writeln('    </ol>');
    buffer.writeln('  </nav>');
    buffer.writeln('</body>');
    buffer.writeln('</html>');
    return buffer.toString();
  }

  static String _buildTocNcx(
    int bookId,
    String bookTitle,
    List<({String id, String href, String title, int volumeId, String volumeTitle})> chapters,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">');
    buffer.writeln('  <head>');
    buffer.writeln('    <meta name="dtb:uid" content="urn:lk:book:$bookId"/>');
    buffer.writeln('    <meta name="dtb:depth" content="2"/>');
    buffer.writeln('    <meta name="dtb:totalPageCount" content="0"/>');
    buffer.writeln('    <meta name="dtb:maxPageNumber" content="0"/>');
    buffer.writeln('  </head>');
    buffer.writeln('  <docTitle><text>${xmlEscape(bookTitle)}</text></docTitle>');
    buffer.writeln('  <navMap>');

    var playOrder = 1;
    for (final ch in chapters) {
      buffer.writeln('    <navPoint id="np_$playOrder" playOrder="$playOrder">');
      buffer.writeln('      <navLabel><text>${xmlEscape(ch.title)}</text></navLabel>');
      buffer.writeln('      <content src="${ch.href}"/>');
      buffer.writeln('    </navPoint>');
      playOrder++;
    }

    buffer.writeln('  </navMap>');
    buffer.writeln('</ncx>');
    return buffer.toString();
  }

  @visibleForTesting
  static String buildContentOpf({
    required EpubBuildContext ctx,
    required bool hasCover,
    required List<({String id, String href, String mime, bool isCover})> imagesManifest,
    required List<({String id, String href, String title, int volumeId, String volumeTitle})> chaptersManifest,
  }) =>
      _buildContentOpf(
        ctx: ctx,
        hasCover: hasCover,
        imagesManifest: imagesManifest,
        chaptersManifest: chaptersManifest,
      );

  static String _buildContentOpf({
    required EpubBuildContext ctx,
    required bool hasCover,
    required List<({String id, String href, String mime, bool isCover})> imagesManifest,
    required List<({String id, String href, String title, int volumeId, String volumeTitle})> chaptersManifest,
  }) {
    final title = ctx.exportIncomplete ? '${ctx.bookTitle} [不完整版]' : ctx.bookTitle;
    final nowIso = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'\.\d+'), '');

    final pubB64 = encodeUidToBase64(ctx.publisherUid);
    final expB64 = encodeUidToBase64(ctx.exporterUid);
    final generatorContent =
        'Yomiru EPUB; publisher_=$pubB64; exporter_=$expB64';

    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="pub-id" version="3.0">');
    buffer.writeln('  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">');
    buffer.writeln('    <dc:identifier id="pub-id">urn:lk:book:${ctx.bookId}</dc:identifier>');
    buffer.writeln('    <dc:title>${xmlEscape(title)}</dc:title>');
    buffer.writeln('    <dc:language>zh-CN</dc:language>');
    if (ctx.authorName.isNotEmpty) {
      buffer.writeln('    <dc:creator>${xmlEscape(ctx.authorName)}</dc:creator>');
    }
    if (ctx.summary.isNotEmpty) {
      buffer.writeln('    <dc:description>${xmlEscape(ctx.summary)}</dc:description>');
    }
    buffer.writeln('    <meta property="dcterms:modified">$nowIso</meta>');
    buffer.writeln('    <meta name="generator" content="${xmlEscape(generatorContent)}" />');
    if (hasCover) {
      buffer.writeln('    <meta name="cover" content="cover-image"/>');
    }
    buffer.writeln('  </metadata>');

    buffer.writeln('  <manifest>');
    buffer.writeln('    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>');
    buffer.writeln('    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>');
    buffer.writeln('    <item id="style" href="styles/style.css" media-type="text/css"/>');

    if (hasCover) {
      buffer.writeln('    <item id="cover-page" href="text/cover.xhtml" media-type="application/xhtml+xml"/>');
    }

    for (final img in imagesManifest) {
      final props = img.isCover ? ' properties="cover-image"' : '';
      buffer.writeln('    <item id="${img.id}" href="${img.href}" media-type="${img.mime}"$props/>');
    }

    for (final ch in chaptersManifest) {
      buffer.writeln('    <item id="${ch.id}" href="${ch.href}" media-type="application/xhtml+xml"/>');
    }
    buffer.writeln('  </manifest>');

    buffer.writeln('  <spine toc="ncx">');
    if (hasCover) {
      buffer.writeln('    <itemref idref="cover-page"/>');
    }
    for (final ch in chaptersManifest) {
      buffer.writeln('    <itemref idref="${ch.id}"/>');
    }
    buffer.writeln('  </spine>');
    buffer.writeln('</package>');
    return buffer.toString();
  }
}
