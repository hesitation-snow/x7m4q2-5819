import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
h1, h2, h3 {
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
p {
  margin: 0.5em 0;
  text-indent: 2em;
  text-align: justify;
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

  static final RegExp _imageTagRe = RegExp(
      r'''<img[^>]*\bsrc\s*=\s*["']?([^"'>\s]+)["']?[^>]*>''',
      caseSensitive: false);
  static final RegExp _scriptTagRe = RegExp(
      r'''<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>''',
      caseSensitive: false);
  static final RegExp _styleTagRe = RegExp(
      r'''<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>''',
      caseSensitive: false);
  static final RegExp _paragraphSplitRe =
      RegExp(r'</p>|<br\s*/?>', caseSensitive: false);
  static final RegExp _stripTagsRe = RegExp(r'<[^>]+>');
  static final RegExp _resourceTagRe = RegExp(r'\[res\][^[]+\[/res\]');

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
    // 1. 移除 script 与 style 危险标签
    var cleaned = html.replaceAll(_scriptTagRe, '').replaceAll(_styleTagRe, '');

    // 2. 将段落和断行按顺序解析，同时查找插画标签
    final initialLength = buffer.length;
    var pos = 0;
    for (final match in _imageTagRe.allMatches(cleaned)) {
      final textBefore = cleaned.substring(pos, match.start);
      _emitTextParagraphs(textBefore, buffer);

      final src = match.group(1)?.trim() ?? '';
      final localRel = _resolveImageLocalPath(src, imageUrlToLocalPath);
      if (localRel != null && localRel.isNotEmpty) {
        buffer.writeln('    <div class="illustration">');
        buffer.writeln('      <img src="$localRel" alt=""/>');
        buffer.writeln('    </div>');
      }
      pos = match.end;
    }
    final remainingText = cleaned.substring(pos);
    _emitTextParagraphs(remainingText, buffer);

    if (buffer.length == initialLength) {
      buffer.writeln('    <p>(本章暂无内容)</p>');
    }
  }

  static void _emitTextParagraphs(String seg, StringBuffer buffer) {
    if (seg.trim().isEmpty) return;
    var decoded = seg
        .replaceAll(_resourceTagRe, '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');

    final lines = decoded.split(_paragraphSplitRe);
    for (var line in lines) {
      // 剔除遗留的 HTML 标签，如 <span>, <div>, <a> 等，保留文字
      line = line.replaceAll(_stripTagsRe, '').trim();
      if (line.isNotEmpty) {
        buffer.writeln('    <p>${xmlEscape(line)}</p>');
      }
    }
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
      if (await coverFile.exists()) {
        hasCover = true;
        await writer.addFile('EPUB/images/cover.jpg', coverFile, compress: false);
        imagesManifest.add((
          id: 'cover-image',
          href: 'images/cover.jpg',
          mime: 'image/jpeg',
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

  static String _buildContentOpf({
    required EpubBuildContext ctx,
    required bool hasCover,
    required List<({String id, String href, String mime, bool isCover})> imagesManifest,
    required List<({String id, String href, String title, int volumeId, String volumeTitle})> chaptersManifest,
  }) {
    final title = ctx.exportIncomplete ? '${ctx.bookTitle} [不完整版]' : ctx.bookTitle;
    final nowIso = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'\.\d+'), '');

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
    buffer.writeln('    <dc:publisher>轻之国度 (Yomiru)</dc:publisher>');
    buffer.writeln('    <meta property="dcterms:modified">$nowIso</meta>');
    buffer.writeln('    <meta name="generator" content="Yomiru EPUB Engine"/>');
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
