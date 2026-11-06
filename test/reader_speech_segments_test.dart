import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/speech_segments.dart';

void main() {
  group('splitSpeechSegments', () {
    test('prefers Chinese sentence and comma punctuation', () {
      final segments = splitSpeechSegments([
        const SpeechTextBlock(text: '第一句，仍在句中。第二句！第三句？', blockIndex: 8),
      ]);
      expect(segments.map((segment) => segment.text),
          ['第一句，仍在句中。', '第二句！', '第三句？']);
      expect(segments.map((segment) => segment.blockIndex), [8, 8, 8]);
    });

    test('splits oversized text near punctuation and retains source mapping',
        () {
      final source = '${'甲' * 110}，${'乙' * 110}。末尾';
      final segments = splitSpeechSegments(
        [SpeechTextBlock(text: source, blockIndex: 3)],
        maxCodeUnits: 120,
      );
      expect(segments.length, greaterThan(1));
      expect(segments.every((segment) => segment.text.length <= 120), isTrue);
      for (final segment in segments) {
        expect(source.substring(segment.startOffset, segment.endOffset),
            segment.text);
      }
      expect(segments.map((segment) => segment.text).join(), source);
    });

    test('uses UTF-16 offsets around emoji', () {
      const source = '😀甲。乙';
      final segments = splitSpeechSegments([
        const SpeechTextBlock(text: source, blockIndex: 5),
      ]);
      expect(segments.map((segment) => segment.text), ['😀甲。', '乙']);
      expect(segments.first.endOffset, '😀甲。'.length);
      expect(
          source.substring(
              segments.first.startOffset, segments.first.endOffset),
          segments.first.text);
    });

    test('skips image, empty, whitespace, and symbol-only blocks', () {
      final segments = splitSpeechSegments([
        const SpeechTextBlock(text: '图片标题', image: 'cover.jpg'),
        const SpeechTextBlock(text: ''),
        const SpeechTextBlock(text: '　 \n\t'),
        const SpeechTextBlock(text: '！？……—…'),
        const SpeechTextBlock(text: '正文。', blockIndex: 9),
      ]);
      expect(segments.map((segment) => segment.text), ['正文。']);
      expect(segments.single.blockIndex, 9);
    });

    test(
        'one-unit limit makes progress without splitting emoji surrogate pairs',
        () {
      const source = '😀甲';
      final segments = splitSpeechSegments(
        [const SpeechTextBlock(text: source, blockIndex: 21)],
        maxCodeUnits: 1,
      );
      expect(segments.map((segment) => segment.text), ['😀', '甲']);
      for (final segment in segments) {
        expect(source.substring(segment.startOffset, segment.endOffset),
            segment.text);
        expect(segment.endOffset, greaterThan(segment.startOffset));
      }
    });

    test(
        'skips ASCII punctuation and symbols but retains fullwidth alphanumerics',
        () {
      final segments = splitSpeechSegments([
        const SpeechTextBlock(text: '---'),
        const SpeechTextBlock(text: '!!!'),
        const SpeechTextBlock(text: 'ＡＢＣ１２３', blockIndex: 4),
      ]);
      expect(segments.map((segment) => segment.text), ['ＡＢＣ１２３']);
    });

    test('maps each segment position to unchanged original text', () {
      const source = '  前文😀。\n 后文，继续。  ';
      final segments = splitSpeechSegments([
        const SpeechTextBlock(text: source, blockIndex: 12),
      ]);
      expect(segments.map((segment) => segment.text), ['前文😀。', '后文，继续。']);
      for (final segment in segments) {
        expect(segment.blockIndex, 12);
        expect(source.substring(segment.startOffset, segment.endOffset),
            segment.text);
      }
      expect(segments.first.startOffset, 2);
    });
  });
}
