import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/reader/reader_tts_resume.dart';
import 'package:yomiru/reader/reading_position.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('resume position is isolated by account, book and chapter', () async {
    const alice = ReadingPosition.text(blockIndex: 5, offset: 17);
    const bob = ReadingPosition.text(blockIndex: 2, offset: 3);
    await ReaderTtsResumeStore.save(
        accountId: 'uid:1', bookId: 10, chapterId: 20, position: alice);
    await ReaderTtsResumeStore.save(
        accountId: 'uid:2', bookId: 10, chapterId: 20, position: bob);

    expect(
        await ReaderTtsResumeStore.read(
            accountId: 'uid:1', bookId: 10, chapterId: 20),
        alice);
    expect(
        await ReaderTtsResumeStore.read(
            accountId: 'uid:2', bookId: 10, chapterId: 20),
        bob);
    expect(
        await ReaderTtsResumeStore.read(
            accountId: 'uid:1', bookId: 10, chapterId: 21),
        isNull);
  });

  test('clearAccount only clears that account resume keys', () async {
    const anchor = ReadingPosition.text(blockIndex: 1, offset: 9);
    await ReaderTtsResumeStore.save(
        accountId: 'uid:1', bookId: 10, chapterId: 20, position: anchor);
    await ReaderTtsResumeStore.save(
        accountId: 'uid:2', bookId: 10, chapterId: 20, position: anchor);
    await ReaderTtsResumeStore.clearAccount('uid:1');

    expect(
        await ReaderTtsResumeStore.read(
            accountId: 'uid:1', bookId: 10, chapterId: 20),
        isNull);
    expect(
        await ReaderTtsResumeStore.read(
            accountId: 'uid:2', bookId: 10, chapterId: 20),
        anchor);
  });
}
