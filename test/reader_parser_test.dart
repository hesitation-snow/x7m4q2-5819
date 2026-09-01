import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/pages/reader_page.dart';

void main() {
  test('long chapter HTML parses off the UI isolate', () async {
    final longParagraph = List.filled(7000, '正文').join();
    final blocks = await parseReaderHtmlForTesting(
      '<p>$longParagraph</p>'
      "<img src='https://example.com/illustration.webp' width='600' height='300'>"
      '<p>结尾</p>',
    );

    expect(blocks.first.text, contains('正文'));
    expect(
      blocks,
      contains(
        const (
          image: 'https://example.com/illustration.webp',
          text: '',
          aspect: 2.0,
        ),
      ),
    );
    expect(blocks.last.text, '结尾');
  });
}
