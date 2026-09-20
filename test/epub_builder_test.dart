import 'dart:convert';
import 'dart:io';

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
    });
  });
}
