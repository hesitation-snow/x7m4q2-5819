import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/structured_content.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('flutter_open_chinese_convert'),
    (MethodCall methodCall) async {
      if (methodCall.method == 'convert') {
        final args = methodCall.arguments;
        final text = args is List ? args[0] as String : (args as Map)['text'] as String;
        return text
            .replaceAll('这里', '這裡')
            .replaceAll('简体', '簡體')
            .replaceAll('链接', '連結')
            .replaceAll('汉字', '漢字')
            .replaceAll('注音', '註音');
      }
      return null;
    },
  );

  group('StructuredContentParser HTML parsing', () {
    test('parses basic formatting (b, i, u, s, font color)', () {
      const html =
          '<p>Hello <b>bold</b> <i>italic</i> <u>underline</u> <s>strike</s> '
          '<font color="#ff0000">red text</font></p>';
      final blocks = StructuredContentParser.parseHtml(html);
      expect(blocks.length, 1);
      final b = blocks.first;
      expect(b.type, StructuredBlockType.paragraph);
      expect(b.text,
          'Hello bold italic underline strike red text');

      final boldRun = b.runs.firstWhere((r) => r.text == 'bold');
      expect(boldRun.isBold, isTrue);
      expect(boldRun.isItalic, isFalse);

      final italicRun = b.runs.firstWhere((r) => r.text == 'italic');
      expect(italicRun.isItalic, isTrue);

      final underlineRun = b.runs.firstWhere((r) => r.text == 'underline');
      expect(underlineRun.isUnderline, isTrue);

      final strikeRun = b.runs.firstWhere((r) => r.text == 'strike');
      expect(strikeRun.isStrikethrough, isTrue);

      final redRun = b.runs.firstWhere((r) => r.text == 'red text');
      expect(redRun.color, const Color(0xFFFF0000));
    });

    test('parses headings (h1..h6)', () {
      const html = '<h1>Title 1</h1><h2>Title 2</h2><p>Normal text</p>';
      final blocks = StructuredContentParser.parseHtml(html);
      expect(blocks.length, 3);
      expect(blocks[0].type, StructuredBlockType.heading);
      expect(blocks[0].headingLevel, 1);
      expect(blocks[0].text, 'Title 1');

      expect(blocks[1].type, StructuredBlockType.heading);
      expect(blocks[1].headingLevel, 2);
      expect(blocks[1].text, 'Title 2');

      expect(blocks[2].type, StructuredBlockType.paragraph);
      expect(blocks[2].text, 'Normal text');
    });

    test('parses blockquote and alignment', () {
      const html =
          '<blockquote style="text-align: center;"><p>Quote content</p></blockquote>';
      final blocks = StructuredContentParser.parseHtml(html);
      expect(blocks.length, 1);
      final b = blocks.first;
      expect(b.type, StructuredBlockType.blockquote);
      expect(b.isBlockquote, isTrue);
      expect(b.align, TextAlign.center);
      expect(b.indent, greaterThan(0));
      expect(b.text, 'Quote content');
    });

    test('parses horizontal divider <hr>', () {
      const html = '<p>Before</p><hr><p>After</p>';
      final blocks = StructuredContentParser.parseHtml(html);
      expect(blocks.length, 3);
      expect(blocks[0].text, 'Before');
      expect(blocks[1].isDivider, isTrue);
      expect(blocks[2].text, 'After');
    });

    test('parses images with aspect ratio', () {
      const html =
          '<p>Intro</p><img src="https://api.lightnovel.fun/image1.jpg" width="400" height="800"><p>Outro</p>';
      final blocks = StructuredContentParser.parseHtml(html);
      expect(blocks.length, 3);
      expect(blocks[0].text, 'Intro');
      expect(blocks[1].isImage, isTrue);
      expect(blocks[1].imageUrl, 'https://api.lightnovel.fun/image1.jpg');
      expect(blocks[1].imageAspect, closeTo(0.5, 0.001));
      expect(blocks[2].text, 'Outro');
    });

    test('parses ruby tags into annotated run', () {
      const html = '<p>主角是<ruby>勇者<rt>ゆうしゃ</rt></ruby>。</p>';
      final blocks = StructuredContentParser.parseHtml(html);
      expect(blocks.length, 1);
      final b = blocks.first;
      expect(b.text, '主角是勇者(ゆうしゃ)。');
      final rubyRun = b.runs.firstWhere((r) => r.rubyText != null);
      expect(rubyRun.rubyText, 'ゆうしゃ');
      expect(rubyRun.text, '勇者(ゆうしゃ)');
    });

    test('parses hyperlinks correctly', () {
      const html = '<p>点击 <a href="https://example.com/item">这里</a> 查看</p>';
      final blocks = StructuredContentParser.parseHtml(html);
      expect(blocks.length, 1);
      final b = blocks.first;
      expect(b.text, '点击 这里 查看');
      final links = b.extractLinks();
      expect(links.length, 1);
      expect(links.first.$3, 'https://example.com/item');
      expect(b.text.substring(links.first.$1, links.first.$2), '这里');
    });

    test('ignores script, style, and strips [res] tags', () {
      const html =
          '<script>alert("xss")</script><style>.bad{color:red}</style><p>[res]0,12345[/res]Safe text</p>';
      final blocks = StructuredContentParser.parseHtml(html);
      expect(blocks.length, 1);
      expect(blocks.first.text, 'Safe text');
    });
  });

  group('StructuredBlock slicing and TextSpan building', () {
    test('slice preserves run styles and character boundaries', () {
      const block = StructuredBlock(
        type: StructuredBlockType.paragraph,
        text: 'ABCDEFGHIJ',
        runs: [
          StructuredInlineRun(text: 'ABC', isBold: true),
          StructuredInlineRun(text: 'DEF', isItalic: true),
          StructuredInlineRun(text: 'GHIJ', isUnderline: true),
        ],
      );

      // Slice 'CDE' (index 2 to 5)
      final slice1 = block.slice(2, 5);
      expect(slice1.text, 'CDE');
      expect(slice1.runs.length, 2);
      expect(slice1.runs[0].text, 'C');
      expect(slice1.runs[0].isBold, isTrue);
      expect(slice1.runs[1].text, 'DE');
      expect(slice1.runs[1].isItalic, isTrue);

      // Slice 'FG' (index 5 to 7)
      final slice2 = block.slice(5, 7);
      expect(slice2.text, 'FG');
      expect(slice2.runs.length, 2);
      expect(slice2.runs[0].text, 'F');
      expect(slice2.runs[0].isItalic, isTrue);
      expect(slice2.runs[1].text, 'G');
      expect(slice2.runs[1].isUnderline, isTrue);
    });

    test('ensureLegibleColor boosts dark color on dark background', () {
      const darkColor = Color(0xFF111111);
      const darkBg = Color(0xFF1A1A1A);
      final adjusted = StructuredBlock.ensureLegibleColor(darkColor, darkBg);
      expect(adjusted.computeLuminance(), greaterThan(0.3));
    });

    test('ensureLegibleColor darkens light color on light background', () {
      const lightColor = Color(0xFFEEEEEE);
      const lightBg = Color(0xFFFFFFFF);
      final adjusted = StructuredBlock.ensureLegibleColor(lightColor, lightBg);
      expect(adjusted.computeLuminance(), lessThan(0.4));
    });

    test('buildTextSpan creates matching spans for measurement and display', () {
      const block = StructuredBlock(
        type: StructuredBlockType.heading,
        headingLevel: 2,
        text: '大标题',
        runs: [
          StructuredInlineRun(text: '大标题', isBold: true),
        ],
      );

      final spanForMeasure = block.buildTextSpan(
        baseStyle: const TextStyle(fontSize: 16),
        linkColor: Colors.blue,
        backgroundColor: Colors.white,
        forMeasurement: true,
      );

      expect(spanForMeasure.style?.fontSize, closeTo(16 * 1.28, 0.01));
      expect(spanForMeasure.style?.fontWeight, FontWeight.bold);

      final spanForDisplay = block.buildTextSpan(
        baseStyle: const TextStyle(fontSize: 16),
        linkColor: Colors.blue,
        backgroundColor: Colors.white,
        forMeasurement: false,
      );
      expect(spanForDisplay.style?.fontSize, spanForMeasure.style?.fontSize);
    });

    test('convertBlocks converts only text and ruby without altering structure or URLs', () async {
      const html =
          '<p>这里是<a href="https://example.com/link">简体链接</a>与<ruby>汉字<rt>注音</rt></ruby></p>';
      final blocks = StructuredContentParser.parseHtml(html);
      final converted = await StructuredContentParser.convertBlocks(blocks, 1); // S2T
      expect(converted.length, 1);
      final b = converted.first;
      expect(b.text, contains('這裡是'));
      expect(b.text, contains('簡體連結'));
      expect(b.text, contains('漢字(註音)'));
      // Link URL is intact
      expect(b.runs.firstWhere((r) => r.linkUrl != null).linkUrl,
          'https://example.com/link');
    });
  });
}
