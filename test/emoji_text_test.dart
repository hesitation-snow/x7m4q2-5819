import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/widgets/emoji_text.dart';

void main() {
  test('dynamic body splits known emoji codes into image segments', () {
    final segments = parseLkEmojiText(
      '正文 {:neko3:} 中间 [s:1] 未知 {:missing:}',
      {
        '{:neko3:}': 'https://example.com/neko3.png',
        '[s:1]': 'https://example.com/s1.png',
      },
    );

    expect(segments.where((segment) => segment.isImage), hasLength(2));
    expect(
      segments
          .where((segment) => segment.isImage)
          .map((segment) => segment.text),
      ['{:neko3:}', '[s:1]'],
    );
    expect(
      segments.where((segment) => !segment.isImage).last.text,
      contains('{:missing:}'),
    );
  });
}
