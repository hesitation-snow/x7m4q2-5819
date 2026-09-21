import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/services/epub/epub_builder.dart';
import 'package:yomiru/services/epub/epub_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EpubBuilder XHTML Sanitization & XML validity', () {
    test('xmlEscape handles all reserved XML characters properly', () {
      expect(xmlEscape(''), equals(''));
      expect(xmlEscape('Rock & Roll <5> "quote" \'single\''),
          equals('Rock &amp; Roll &lt;5&gt; &quot;quote&quot; &apos;single&apos;'));
    });

    test('sanitizeToXHtml cleans raw HTML and outputs valid XML', () {
      const rawHtml = '''
        <p>第一段文本包含特殊符号 &lt;测试&gt; &amp; 符号。</p>
        <script>alert("hack");</script>
        <style>.hide { display: none; }</style>
        <p>这是第二段。<br/>这是换行后的内容。</p>
        <img src="https://example.com/art.jpg" width="800" height="600"/>
        <p>第三段结尾。</p>
      ''';

      final imageUrlMap = {
        'https://example.com/art.jpg': '../images/art_01.jpg',
      };

      final xhtml = EpubBuilder.sanitizeToXHtml(
        title: '第一章 测试',
        rawHtml: rawHtml,
        rawText: '',
        imageUrlToLocalPath: imageUrlMap,
      );

      // 验证未包含任何 <script> 或 <style> 标签
      expect(xhtml.contains('<script>'), isFalse);
      expect(xhtml.contains('alert'), isFalse);
      expect(xhtml.contains('<style>'), isFalse);

      // 验证插画被正确转换为标准结构与相对路径
      expect(xhtml.contains('<div class="illustration">'), isTrue);
      expect(xhtml.contains('<img src="../images/art_01.jpg" alt=""/>'), isTrue);

      // 验证文档为严格合法的 XHTML
      expect(xhtml.startsWith('<?xml version="1.0" encoding="UTF-8"?>'), isTrue);
      expect(xhtml.contains('<html xmlns="http://www.w3.org/1999/xhtml"'), isTrue);
      expect(xhtml.contains('</html>'), isTrue);
      expect(RegExp(r'<p>.*?</p>').allMatches(xhtml).length, greaterThanOrEqualTo(3));
    });

    test('sanitizeToXHtml converts rich text typography into standard EPUB 3 XHTML', () {
      const richHtml = '''
        <h3>章节副标题</h3>
        <p>这是<b>加粗文本</b>、<i>斜体文本</i>、<u>下划线文本</u>与<s>删除线文本</s>。</p>
        <p>日文注音测试：<ruby>漢子<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>以及注解<sup>[1]</sup>。</p>
        <p align="center">居中对齐文本</p>
        <p align="right">居右对齐文本</p>
        <p><font color="#ff5500">彩色文本</font>与<a href="https://lightnovel.fun">参考链接</a>。</p>
        <blockquote>这是一段重要引用内容。</blockquote>
        <ul>
          <li>无序列表项一</li>
          <li>无序列表项二</li>
        </ul>
        <ol>
          <li>有序列表项一</li>
          <li>有序列表项二</li>
        </ol>
        <hr/>
      ''';

      final xhtml = EpubBuilder.sanitizeToXHtml(
        title: '样式增强章节',
        rawHtml: richHtml,
        rawText: '',
        imageUrlToLocalPath: const {},
      );

      // 验证副标题
      expect(xhtml.contains('<h'), isTrue);
      expect(xhtml.contains('章节副标题'), isTrue);
      // 验证加粗、斜体、下划线、删除线
      expect(xhtml.contains('<strong>加粗文本</strong>'), isTrue);
      expect(xhtml.contains('<em>斜体文本</em>'), isTrue);
      expect(xhtml.contains('text-decoration: underline'), isTrue);
      expect(xhtml.contains('<del>删除线文本</del>'), isTrue);
      // 验证注音与脚注
      expect(xhtml.contains('<ruby>漢子<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>'), isTrue);
      expect(xhtml.contains('<sup>[1]</sup>'), isTrue);
      // 验证对齐方式
      expect(xhtml.contains('text-align: center'), isTrue);
      expect(xhtml.contains('text-align: right'), isTrue);
      // 验证颜色与链接
      expect(xhtml.contains('color: #ff5500'), isTrue);
      expect(xhtml.contains('<a href="https://lightnovel.fun">参考链接</a>'), isTrue);
      // 验证引用
      expect(xhtml.contains('<blockquote>'), isTrue);
      expect(xhtml.contains('这是一段重要引用内容。'), isTrue);
      // 验证列表
      expect(xhtml.contains('<ul>'), isTrue);
      expect(xhtml.contains('<li>无序列表项一</li>'), isTrue);
      expect(xhtml.contains('<ol>'), isTrue);
      expect(xhtml.contains('<li>有序列表项一</li>'), isTrue);
      // 验证分割线
      expect(xhtml.contains('<hr/>'), isTrue);
      // 验证标准 XML 闭合
      expect(xhtml.startsWith('<?xml version="1.0" encoding="UTF-8"?>'), isTrue);
      expect(xhtml.contains('</html>'), isTrue);
    });

    test('sanitizeToXHtml converts plain text into legal XHTML paragraphs', () {
      const plainText = '第一行内容。\n\n第二行内容含有 < 与 >。\n第三行。';
      final xhtml = EpubBuilder.sanitizeToXHtml(
        title: '纯文本章节',
        rawHtml: null,
        rawText: plainText,
        imageUrlToLocalPath: const {},
      );

      expect(xhtml.startsWith('<?xml version="1.0" encoding="UTF-8"?>'), isTrue);
      expect(xhtml.contains('<p>第一行内容。</p>'), isTrue);
      expect(xhtml.contains('<p>第二行内容含有 &lt; 与 &gt;。</p>'), isTrue);
      expect(xhtml.contains('<p>第三行。</p>'), isTrue);
      expect(RegExp(r'<p>.*?</p>').allMatches(xhtml).length, equals(3));
    });

    test('cssContent does NOT hardcode theme background or text colors', () {
      const css = EpubBuilder.cssContent;
      expect(css.contains('@charset "utf-8";'), isTrue);
      // 不能写死背景色或字体颜色，确保读者自定义背景与深色模式正常
      expect(css.toLowerCase().contains('background-color:'), isFalse);
      expect(css.toLowerCase().contains('color: #'), isFalse);
      expect(css.toLowerCase().contains('color: black'), isFalse);
      expect(css.toLowerCase().contains('color: white'), isFalse);
    });

    test('getIllustrationFileName produces safe and consistent file names without url characters', () {
      const lkUrl = 'https://api.lightnovel.fun/upload-files/images/260731/6bda583f9cf992ba5ab8b0e6f2773cf0.jpg?m=abc&t=1700000000';
      final fileName = getIllustrationFileName(lkUrl);
      expect(fileName, equals('6bda583f9cf992ba5ab8b0e6f2773cf0.jpg'));
      expect(fileName.contains(':'), isFalse);
      expect(fileName.contains('/'), isFalse);
      expect(fileName.contains('?'), isFalse);

      const htmlEscapedUrl = 'https://api.lightnovel.fun/upload-files/images/260731/6bda583f9cf992ba5ab8b0e6f2773cf0.jpg?m=abc&amp;t=1700000000';
      expect(getIllustrationFileName(htmlEscapedUrl), equals('6bda583f9cf992ba5ab8b0e6f2773cf0.jpg'));

      const pngUrl = 'https://example.com/images/chapter_art.png?v=2';
      final pngFileName = getIllustrationFileName(pngUrl);
      expect(pngFileName.endsWith('.png'), isTrue);
      expect(pngFileName.contains('/'), isFalse);
      expect(pngFileName.contains(':'), isFalse);
    });

    test('sanitizeToXHtml resolves image with query parameters and &amp; properly', () {
      const rawHtml = '''
        <p>正文段落前文。</p>
        <img src="https://api.lightnovel.fun/upload-files/images/260731/6bda583f9cf992ba5ab8b0e6f2773cf0.jpg?m=xyz&amp;t=9999" width="600" height="800" />
        <p>正文段落后文包含&nbsp;空格与&amp;符号。</p>
      ''';

      // 映射表无论以何种形态存储，均能正确命中
      final map = {
        '6bda583f9cf992ba5ab8b0e6f2773cf0.jpg': '../images/6bda583f9cf992ba5ab8b0e6f2773cf0.jpg',
      };

      final xhtml = EpubBuilder.sanitizeToXHtml(
        title: '插画章节',
        rawHtml: rawHtml,
        rawText: '',
        imageUrlToLocalPath: map,
      );

      expect(xhtml.contains('<div class="illustration">'), isTrue);
      expect(xhtml.contains('<img src="../images/6bda583f9cf992ba5ab8b0e6f2773cf0.jpg" alt=""/>'), isTrue);
      expect(xhtml.contains('&amp;nbsp;'), isFalse); // &nbsp; 已被正确转为普通空格，不产生非法 XML 实体
    });
  });

  group('EpubBuilder Full Package Integration', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('epub_build_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('packageInIsolate builds standard EPUB package with cover and chapters', () async {
      final taskDir = Directory('${tempDir.path}/task_1');
      await taskDir.create(recursive: true);
      final chaptersDir = Directory('${taskDir.path}/chapters');
      await chaptersDir.create(recursive: true);
      final imagesDir = Directory('${taskDir.path}/images');
      await imagesDir.create(recursive: true);

      // 创建虚拟封面与插画
      final coverFile = File('${taskDir.path}/cover.jpg');
      await coverFile.writeAsBytes(List.filled(64, 0xFF));

      final imgFile = File('${imagesDir.path}/art_01.jpg');
      await imgFile.writeAsBytes(List.filled(128, 0xEE));

      // 写入两章虚拟正文
      final ch1 = File('${chaptersDir.path}/101.json');
      await ch1.writeAsString(jsonEncode({
        'body_text': '第 1 章正文内容。',
        'body_html': '<p>第 1 章正文内容。</p><img src="https://img.test/art_01.jpg"/>',
      }));

      final ch2 = File('${chaptersDir.path}/102.json');
      await ch2.writeAsString(jsonEncode({
        'body_text': '第 2 章纯正文内容。',
        'body_html': null,
      }));

      // 图片映射
      final mapFile = File('${taskDir.path}/image_map.json');
      await mapFile.writeAsString(jsonEncode({
        'https://img.test/art_01.jpg': 'art_01.jpg',
      }));

      final outputPath = '${tempDir.path}/output_book.epub';
      final ctx = EpubBuildContext(
        taskDir: taskDir.path,
        outputPath: outputPath,
        bookId: 12345,
        bookTitle: '测试书名',
        authorName: '测试作者',
        summary: '这是测试书籍简介',
        publisherUid: 123456,
        exporterUid: 654321,
        includeIllustrations: true,
        exportIncomplete: false,
        chapters: const [
          EpubChapterItem(
            chapterId: 101,
            chapterNo: 1,
            title: '序章 开启',
            volumeId: 1,
            volumeTitle: '第 1 卷',
          ),
          EpubChapterItem(
            chapterId: 102,
            chapterNo: 2,
            title: '第一章 启程',
            volumeId: 1,
            volumeTitle: '第 1 卷',
          ),
        ],
        completedChapterIds: const [101, 102],
      );

      final size = await EpubBuilder.packageInIsolate(ctx);
      expect(size, greaterThan(200));

      final outFile = File(outputPath);
      expect(await outFile.exists(), isTrue);

      final bytes = await outFile.readAsBytes();
      // 验证首 entry 是 mimetype
      final name = ascii.decode(bytes.sublist(30, 38));
      expect(name, equals('mimetype'));

      // 验证生成的 EPUB 内部 content.opf
      final opfContent = _extractFileFromZip(bytes, 'EPUB/content.opf');

      // 1. 验证 generator 标签仅有一个且格式严格匹配
      final generatorMatches =
          RegExp(r'<meta\s+name="generator"[^>]*/>').allMatches(opfContent);
      expect(generatorMatches.length, equals(1));

      expect(
        opfContent.contains(
          '<meta name="generator" content="Yomiru EPUB; publisher_uid_b64=MTIzNDU2; exporter_uid_b64=NjU0MzIx" />',
        ),
        isTrue,
      );

      // 2. 验证两组 UID 可正确解码还原为十进制整数
      final match = RegExp(
        r'content="Yomiru EPUB;\s*publisher_uid_b64=([^;]+);\s*exporter_uid_b64=([^"]+)"',
      ).firstMatch(opfContent);
      expect(match, isNotNull);
      expect(decodeUidFromBase64(match!.group(1)!), equals(123456));
      expect(decodeUidFromBase64(match.group(2)!), equals(654321));

      // 3. 验证 dc:publisher 不再写入
      expect(opfContent.contains('dc:publisher'), isFalse);

      // 4. 验证 dc:creator 保持原状未被覆盖或新增
      expect(opfContent.contains('<dc:creator>测试作者</dc:creator>'), isTrue);
      final creatorMatches =
          RegExp(r'<dc:creator>.*?</dc:creator>').allMatches(opfContent);
      expect(creatorMatches.length, equals(1));
    });

    test('UID base64 conversion and generator OPF metadata format', () {
      expect(encodeUidToBase64(123456), equals('MTIzNDU2'));
      expect(decodeUidFromBase64('MTIzNDU2'), equals(123456));

      expect(encodeUidToBase64(654321), equals('NjU0MzIx'));
      expect(decodeUidFromBase64('NjU0MzIx'), equals(654321));

      expect(encodeUidToBase64(0), equals('MA=='));
      expect(decodeUidFromBase64('MA=='), equals(0));

      const ctx = EpubBuildContext(
        taskDir: '',
        outputPath: '',
        bookId: 888,
        bookTitle: '测试书名',
        authorName: '伏濑',
        summary: '书本简介',
        publisherUid: 123456,
        exporterUid: 654321,
        includeIllustrations: false,
        exportIncomplete: false,
        chapters: [],
        completedChapterIds: [],
      );

      final opf = EpubBuilder.buildContentOpf(
        ctx: ctx,
        hasCover: false,
        imagesManifest: [],
        chaptersManifest: [],
      );

      // 验证 generator 仅存在一个
      final generatorMatches =
          RegExp(r'<meta\s+name="generator"[^>]*/>').allMatches(opf);
      expect(generatorMatches.length, equals(1));

      // 验证格式完全符合规范
      expect(
        opf.contains(
          '<meta name="generator" content="Yomiru EPUB; publisher_uid_b64=MTIzNDU2; exporter_uid_b64=NjU0MzIx" />',
        ),
        isTrue,
      );

      // 验证 dc:publisher 不存在
      expect(opf.contains('dc:publisher'), isFalse);

      // 验证 dc:creator 保持原作者
      expect(opf.contains('<dc:creator>伏濑</dc:creator>'), isTrue);
    });
  });
}

String _extractFileFromZip(Uint8List bytes, String targetName) {
  var offset = 0;
  final byteData = ByteData.sublistView(bytes);
  while (offset < bytes.length - 30) {
    final sig = byteData.getUint32(offset, Endian.little);
    if (sig == 0x04034b50) {
      final method = byteData.getUint16(offset + 8, Endian.little);
      final compSize = byteData.getUint32(offset + 18, Endian.little);
      final nameLen = byteData.getUint16(offset + 26, Endian.little);
      final extraLen = byteData.getUint16(offset + 28, Endian.little);
      final name = utf8.decode(bytes.sublist(offset + 30, offset + 30 + nameLen));
      final payloadOffset = offset + 30 + nameLen + extraLen;
      if (name == targetName) {
        final payload = bytes.sublist(payloadOffset, payloadOffset + compSize);
        if (method == 0) {
          return utf8.decode(payload);
        } else if (method == 8) {
          return utf8.decode(ZLibDecoder(raw: true).convert(payload));
        }
      }
      offset = (payloadOffset + compSize).toInt();
    } else {
      offset++;
    }
  }
  throw StateError('File $targetName not found in zip');
}
