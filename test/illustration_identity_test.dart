import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/services/illustration_identity.dart';

void main() {
  const path =
      '/upload-files/images/260731/6bda583f9cf992ba5ab8b0e6f2773cf0.jpg';
  const base = 'https://api.lightnovel.fun$path';

  test('only confirmed image m/t changes share identity', () {
    expect(illustrationCacheKey('$base?m=old&t=1700000000'), base);
    expect(illustrationCacheKey('$base?t=1700000002&m=new'), base);
    expect(illustrationCacheKey(base), base);
  });

  test('real variable-length hexadecimal filenames are recognized', () {
    for (final name in [
      '128defb50e4da4b6ed0e85d940292ae9',
      'c44ecc6d854642742676d5226c9cb343',
    ]) {
      final image =
          'https://api.lightnovel.fun/upload-files/images/260807/$name.jpg';
      expect(illustrationCacheKey('$image?m=token&t=1700000000'), image);
    }
  });

  test('all variant and unknown parameters retain their exact encoding', () {
    expect(
        illustrationCacheKey(
            '$base?m=old&width=900&t=1700000000&v=2&x=a%2Fb&x=c'),
        '$base?width=900&v=2&x=a%2Fb&x=c');
    expect(illustrationCacheKey('$base?m=old&t=1700000000&width=400'),
        isNot(illustrationCacheKey('$base?m=new&t=1700000002&width=900')));
  });

  test('other hosts paths protocols ports and credentials are never normalized',
      () {
    for (final url in [
      'https://example.invalid$path?m=old&t=1700000000',
      'https://api.lightnovel.fun/avatar.jpg?m=old&t=1700000000',
      'http://api.lightnovel.fun$path?m=old&t=1700000000',
      'https://api.lightnovel.fun:444$path?m=old&t=1700000000',
      'https://name@api.lightnovel.fun$path?m=old&t=1700000000',
      '$base?m=old&t=1700000000#different',
    ]) {
      expect(illustrationCacheKey(url), url);
    }
  });

  test('incomplete or ambiguous signing parameters keep the complete URL', () {
    for (final query in [
      'm=old',
      't=1700000000',
      'm=old&t=invalid',
      'm=old&m=new&t=1700000000',
      'm=&t=1700000000',
      'v=2'
    ]) {
      expect(illustrationCacheKey('$base?$query'), '$base?$query');
    }
  });
}
