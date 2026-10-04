import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/reader_indent.dart';
import 'package:yomiru/reader/structured_content.dart';

const _style =
    TextStyle(inherit: false, fontFamily: 'Ahem', fontSize: 20, height: 1.5);
final _body = List.filled(8, '这是足够长的正文段落。').join();

TextPainter _measure(TextSpan span, TextAlign align, TextScaler scaler) {
  final painter = TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    textAlign: align,
    textScaler: scaler,
  );
  setReaderIndentDimensions(painter);
  return painter..layout(maxWidth: 213);
}

TextSpan _span(StructuredBlock block) => block.buildTextSpan(
      baseStyle: _style,
      linkColor: Colors.blue,
      backgroundColor: Colors.white,
      forMeasurement: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final align in [TextAlign.start, TextAlign.justify]) {
    for (final scale in [1.0, 1.5]) {
      for (final structured in [false, true]) {
        test('fixed first-line indent: $align, scale $scale, rich $structured',
            () {
          final span = structured
              ? _span(StructuredContentParser.parseHtml('<p>$_body</p>',
                      firstLineIndent: true)
                  .single)
              : withReaderIndent(
                  TextSpan(text: '\u3000\u3000$_body', style: _style), _style);
          final painter = _measure(span, align, TextScaler.linear(scale));
          final first = painter
              .getBoxesForSelection(
                  const TextSelection(baseOffset: 2, extentOffset: 3))
              .first;
          expect(first.left, closeTo(40 * scale, 0.1));
          final lines = painter.computeLineMetrics();
          expect(lines.length, greaterThan(2));
          final secondLine =
              painter.getPositionForOffset(Offset(0, lines[1].baseline));
          final second = painter
              .getBoxesForSelection(TextSelection(
                  baseOffset: secondLine.offset,
                  extentOffset: secondLine.offset + 1))
              .first;
          expect(second.left, closeTo(0, 0.1));
          expect(span.toPlainText(), '\u3000\u3000$_body');
          painter.dispose();
        });
      }
    }
  }
  test('normalizes whitespace without absorbing first-word ruby styles', () {
    for (final prefix in [
      '',
      ' ',
      '  ',
      '\u3000',
      '\u3000\u3000',
      '&nbsp;&nbsp;',
      '<span> </span> '
    ]) {
      final block = StructuredContentParser.parseHtml(
              '<p>$prefix<ruby>汉字<rt>注音</rt></ruby>正文</p>',
              firstLineIndent: true)
          .single;
      expect(block.text, '\u3000\u3000汉字(注音)正文');
      expect(block.runs.first.rubyText, isNull);
      final ruby = block
          .rubyAnnotations(
              baseStyle: _style,
              linkColor: Colors.blue,
              backgroundColor: Colors.white)
          .single;
      expect(ruby.start, 2);
      expect(ruby.end, 4);
    }
  });
  test('continuations do not gain indentation; disabling removes it', () {
    final block =
        StructuredContentParser.parseText(_body, firstLineIndent: true).single;
    final continuation = block.slice(12, block.text.length);
    final painter =
        _measure(_span(continuation), TextAlign.justify, TextScaler.noScaling);
    expect(
        painter
            .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 1))
            .first
            .left,
        0);
    painter.dispose();
    final disabled =
        StructuredContentParser.parseHtml('<p>　　$_body</p>').single;
    expect(_span(disabled).toPlainText(), _body);
  });
  test('headings, quotes and lists do not receive paragraph indentation', () {
    final blocks = StructuredContentParser.parseHtml(
      '<h1>标题</h1><blockquote>引用</blockquote><ul><li>列表</li></ul>',
      firstLineIndent: true,
    );
    expect(blocks, isNotEmpty);
    for (final block in blocks) {
      expect(block.text.startsWith('\u3000\u3000'), isFalse);
    }
  });
  test('short paragraphs and styled links keep their text and indentation', () {
    final block = StructuredContentParser.parseHtml(
            '<p><a href="https://example.com">短句</a></p>',
            firstLineIndent: true)
        .single;
    final span = _span(block);
    final painter = _measure(span, TextAlign.justify, TextScaler.noScaling);
    expect(painter.computeLineMetrics(), hasLength(1));
    expect(
        painter
            .getBoxesForSelection(
                const TextSelection(baseOffset: 2, extentOffset: 3))
            .first
            .left,
        40);
    expect(block.extractLinks().single, (2, 4, 'https://example.com'));
    expect(span.toPlainText(), block.text);
    expect(withReaderIndent(span, _style).toPlainText(), block.text);
    painter.dispose();
  });
  testWidgets(
      'ruby and clickable footnotes still lay out after fixed indentation',
      (tester) async {
    final block = StructuredContentParser.parseHtml(
      '<p><ruby>正文<rt>注音</rt></ruby><sup>[1]</sup>$_body</p>',
      firstLineIndent: true,
    ).single;
    String? tapped;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
          width: 300,
          child: SelectionArea(
              child: StructuredRubyText(
            block: block,
            span: _span(block),
            baseStyle: _style,
            linkColor: Colors.blue,
            backgroundColor: Colors.white,
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.noScaling,
            locale: null,
            textAlign: TextAlign.justify,
            onFootnoteTap: (value) => tapped = value,
          ))),
    ))));
    expect(tester.takeException(), isNull);
    final hits = find.descendant(
        of: find.byType(StructuredRubyText),
        matching: find.byType(GestureDetector));
    expect(hits, findsOneWidget);
    await tester.tap(hits);
    expect(tapped, '1');
    expect(tester.takeException(), isNull);
  });
  testWidgets('rendering and measurement agree with system font scaling',
      (tester) async {
    final block = StructuredContentParser.parseHtml('<p>$_body</p>',
            firstLineIndent: true)
        .single;
    final span = _span(block);
    const scaler = TextScaler.linear(1.5);
    final painter = _measure(span, TextAlign.justify, scaler);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
          width: 213,
          child: StructuredRubyText(
            block: block,
            span: span,
            baseStyle: _style,
            linkColor: Colors.blue,
            backgroundColor: Colors.white,
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            locale: null,
            textAlign: TextAlign.justify,
          )),
    ))));
    final rich = find
        .descendant(
            of: find.byType(StructuredRubyText),
            matching: find.byType(RichText))
        .first;
    final render = tester.renderObject<RenderParagraph>(rich);
    expect(render.size.height, closeTo(painter.height, 0.1));
    final first = render
        .getBoxesForSelection(
            const TextSelection(baseOffset: 2, extentOffset: 3))
        .first;
    expect(first.left, closeTo(60, 0.1));
    expect(tester.takeException(), isNull);
    painter.dispose();
  });
}
