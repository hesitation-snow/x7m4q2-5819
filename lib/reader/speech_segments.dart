/// Minimal immutable view of one rendered reader block.
///
/// Offsets in [SpeechSegment] are UTF-16 code-unit offsets into [text], matching
/// Dart's [String.length] and [String.substring].
class SpeechTextBlock {
  const SpeechTextBlock({
    required this.text,
    this.image,
    this.blockIndex = 0,
  });

  final String text;
  final String? image;
  final int blockIndex;
}

/// A speakable slice of an original reader block (end-exclusive UTF-16 range).
class SpeechSegment {
  const SpeechSegment({
    required this.blockIndex,
    required this.startOffset,
    required this.endOffset,
    required this.text,
  });

  final int blockIndex;
  final int startOffset;
  final int endOffset;
  final String text;
}

/// Splits text blocks into TTS-sized sentences while preserving source offsets.
///
/// Image blocks, whitespace, and punctuation/symbol-only ranges are omitted.
/// Input strings are never normalized or otherwise modified. Segment boundaries
/// prefer sentence punctuation, then commas/whitespace when a segment exceeds
/// [maxCodeUnits].
List<SpeechSegment> splitSpeechSegments(
  Iterable<SpeechTextBlock> blocks, {
  int maxCodeUnits = 240,
}) {
  if (maxCodeUnits < 1) {
    throw ArgumentError.value(maxCodeUnits, 'maxCodeUnits');
  }
  final output = <SpeechSegment>[];
  for (final block in blocks) {
    if (block.image != null || block.text.isEmpty) continue;
    final text = block.text;
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (_isSentencePunctuation(text.codeUnitAt(i))) {
        _appendSpeakableRange(output, block, start, i + 1, maxCodeUnits);
        start = i + 1;
      }
    }
    _appendSpeakableRange(output, block, start, text.length, maxCodeUnits);
  }
  return List.unmodifiable(output);
}

bool _isSentencePunctuation(int unit) =>
    unit == 0x3002 || // 。
    unit == 0xff01 || // ！
    unit == 0xff1f || // ？
    unit == 0x0021 || // !
    unit == 0x003f || // ?
    unit == 0x002e || // .
    unit == 0x2026; // …

bool _isPreferredBoundary(int unit) =>
    _isSentencePunctuation(unit) ||
    unit == 0x3001 || // 、
    unit == 0xff0c || // ，
    unit == 0x002c || // ,
    unit == 0x003b || // ;
    unit == 0xff1b || // ；
    _isWhitespaceUnit(unit);

bool _isWhitespaceUnit(int unit) =>
    unit <= 0x20 || unit == 0x3000 || (unit >= 0x2000 && unit <= 0x200a);

bool _isSurrogateHigh(int unit) => unit >= 0xd800 && unit <= 0xdbff;
bool _isSurrogateLow(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

bool _isSpeakable(int unit) {
  if (_isWhitespaceUnit(unit) || (unit >= 0x7f && unit <= 0x9f)) return false;
  // Fullwidth Latin letters and digits are content, not punctuation.
  if ((unit >= 0xff10 && unit <= 0xff19) ||
      (unit >= 0xff21 && unit <= 0xff3a) ||
      (unit >= 0xff41 && unit <= 0xff5a)) {
    return true;
  }
  return !_isPunctuationOrSymbol(unit) ||
      _isSentencePunctuation(unit) ||
      unit == 0x3001 || // 、
      unit == 0xff0c || // ，
      unit == 0x002c || // ,
      unit == 0x003b || // ;
      unit == 0xff1b; // ；
}

bool _isPunctuationOrSymbol(int unit) =>
    // ASCII punctuation and symbols.
    (unit >= 0x21 && unit <= 0x2f) ||
    (unit >= 0x3a && unit <= 0x40) ||
    (unit >= 0x5b && unit <= 0x60) ||
    (unit >= 0x7b && unit <= 0x7e) ||
    // Common Unicode punctuation/symbol blocks, including CJK and fullwidth.
    (unit >= 0x2000 && unit <= 0x206f) ||
    (unit >= 0x20a0 && unit <= 0x20cf) ||
    (unit >= 0x2190 && unit <= 0x2bff) ||
    (unit >= 0x3001 && unit <= 0x303f) ||
    (unit >= 0xfe10 && unit <= 0xfe1f) ||
    (unit >= 0xfe30 && unit <= 0xfe6f) ||
    (unit >= 0xff01 && unit <= 0xff0f) ||
    (unit >= 0xff1a && unit <= 0xff20) ||
    (unit >= 0xff3b && unit <= 0xff40) ||
    (unit >= 0xff5b && unit <= 0xff65) ||
    (unit >= 0x1f000 && unit <= 0x1faff);

void _appendSpeakableRange(
  List<SpeechSegment> output,
  SpeechTextBlock block,
  int from,
  int to,
  int maxCodeUnits,
) {
  final text = block.text;
  while (from < to && !_isSpeakable(text.codeUnitAt(from))) {
    from++;
  }
  while (to > from && !_isSpeakable(text.codeUnitAt(to - 1))) {
    to--;
  }
  if (from >= to) return;

  var cursor = from;
  while (cursor < to) {
    var end = (cursor + maxCodeUnits).clamp(cursor + 1, to);
    if (end < to &&
        _isSurrogateHigh(text.codeUnitAt(end - 1)) &&
        _isSurrogateLow(text.codeUnitAt(end))) {
      // If the limit falls inside a surrogate pair, keep the pair together.
      // With a one-unit limit the pair itself is the smallest valid chunk.
      if (end - 1 > cursor) {
        end--;
      } else {
        end++;
      }
    }
    if (end < to) {
      final floor = cursor + (maxCodeUnits ~/ 2);
      for (var candidate = end; candidate > floor; candidate--) {
        if (_isPreferredBoundary(text.codeUnitAt(candidate - 1))) {
          end = candidate;
          break;
        }
      }
    }
    // Include boundary whitespace in the next range's offset gap, not in TTS.
    var visibleEnd = end;
    while (visibleEnd > cursor &&
        _isWhitespaceUnit(text.codeUnitAt(visibleEnd - 1))) {
      visibleEnd--;
    }
    if (visibleEnd > cursor && _containsSpeakable(text, cursor, visibleEnd)) {
      output.add(SpeechSegment(
        blockIndex: block.blockIndex,
        startOffset: cursor,
        endOffset: visibleEnd,
        text: text.substring(cursor, visibleEnd),
      ));
    }
    cursor = end;
    while (cursor < to && _isWhitespaceUnit(text.codeUnitAt(cursor))) {
      cursor++;
    }
  }
}

bool _containsSpeakable(String text, int from, int to) {
  for (var i = from; i < to; i++) {
    final unit = text.codeUnitAt(i);
    if (_isSpeakable(unit) && !_isPunctuationOrSymbol(unit)) return true;
  }
  return false;
}
