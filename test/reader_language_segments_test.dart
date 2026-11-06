import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/reader_language_segments.dart';
import 'package:yomiru/reader/reader_tts_core.dart';

void main() {
  const classifier = ReaderLanguageSegments();
  const segments = [
    TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 4, text: '漢字本文。'),
    TtsSegment(blockIndex: 1, startOffset: 0, endOffset: 4, text: 'かなです。'),
    TtsSegment(blockIndex: 2, startOffset: 0, endOffset: 3, text: '한국어'),
    TtsSegment(blockIndex: 3, startOffset: 0, endOffset: 4, text: '汉字正文'),
  ];

  test('uses explicit locales and script signals; Han-only keeps default', () {
    final result = classifier.classify(segments,
        localeByBlock: const {0: 'ja-JP', 1: 'zh-CN'});
    expect(result.map((item) => item.language), [
      ReaderSpeechLanguage.japanese,
      ReaderSpeechLanguage.chinese,
      ReaderSpeechLanguage.korean,
      ReaderSpeechLanguage.chinese,
    ]);
    expect(result.first.explicitLocale, isTrue);
  });

  test('supports automatic, Chinese-only, and Japanese-only filtering', () {
    expect(classifier.filter(segments), segments);
    expect(classifier.filter(segments, filter: ReaderLanguageFilter.chineseOnly), [segments[0], segments[3]]);
    expect(classifier.filter(segments,
        filter: ReaderLanguageFilter.japaneseOnly,
        localeByBlock: const {0: 'ja-JP'}), [segments[0], segments[1]]);
  });
}