import 'package:flutter/material.dart';

/// Two fixed em boxes replace the two indentation spaces at render time.
/// The UTF-16 length is unchanged, so pagination, ruby and selection offsets
/// continue to refer to the original paragraph. Continuations have no prefix.
TextSpan withReaderIndent(TextSpan span, TextStyle baseStyle) {
  if (!span.toPlainText().startsWith('\u3000\u3000')) return span;
  var remaining = 2;
  final em = baseStyle.fontSize ?? 16;
  InlineSpan visit(InlineSpan node) {
    if (remaining == 0 || node is! TextSpan) return node;
    final text = node.text ?? '';
    var count = 0;
    while (count < text.length && remaining > 0 && text[count] == '\u3000') {
      count++;
      remaining--;
    }
    final children = <InlineSpan>[
      for (var i = 0; i < count; i++) ReaderIndentSpan(em),
      if (count > 0 && count < text.length)
        TextSpan(text: text.substring(count), recognizer: node.recognizer),
      for (final child in node.children ?? const <InlineSpan>[]) visit(child),
    ];
    return TextSpan(
      text: count == 0 ? node.text : null,
      style: node.style,
      children: children,
      recognizer: node.recognizer,
      mouseCursor: node.mouseCursor,
      onEnter: node.onEnter,
      onExit: node.onExit,
      semanticsLabel: count == 0 ? node.semanticsLabel : null,
      locale: node.locale,
      spellOut: node.spellOut,
    );
  }

  return visit(span) as TextSpan;
}

class ReaderIndentSpan extends WidgetSpan {
  ReaderIndentSpan(this.em)
      : super(
          style: TextStyle(fontSize: em),
          child: SizedBox(width: em, height: 0),
        );

  final double em;

  @override
  void computeToPlainText(StringBuffer buffer,
      {bool includeSemanticsLabels = true, bool includePlaceholders = true}) {
    // Keep copied text and character-based reader anchors free of U+FFFC.
    buffer.write('\u3000');
  }
}

/// Mirrors the size RichText gives the inline boxes, including system scaling.
/// Call before laying out any TextPainter used for reader body text.
void setReaderIndentDimensions(TextPainter painter) {
  final dimensions = <PlaceholderDimensions>[];
  painter.text?.visitChildren((span) {
    if (span is ReaderIndentSpan) {
      dimensions.add(PlaceholderDimensions(
        size: Size(painter.textScaler.scale(span.em), 0),
        alignment: span.alignment,
      ));
    }
    return true;
  });
  painter.setPlaceholderDimensions(dimensions);
}
