import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'reading_position.dart';

/// Per-account, per-book, per-chapter TTS resume position. These keys remain
/// separate from the reader's general reading position so separate logins do
/// not overwrite one another's listening progress.
class ReaderTtsResumeStore {
  const ReaderTtsResumeStore._();

  static String _key(String accountId, int bookId, int chapterId) =>
      'reader_tts_resume_v1_${Uri.encodeComponent(accountId)}_${bookId}_$chapterId';

  static String _prefix(String accountId) =>
      'reader_tts_resume_v1_${Uri.encodeComponent(accountId)}_';

  static Future<ReadingPosition?> read({
    required String accountId,
    required int bookId,
    required int chapterId,
  }) async {
    final raw = (await SharedPreferences.getInstance())
        .getString(_key(accountId, bookId, chapterId));
    if (raw == null || raw.isEmpty) return null;
    try {
      return ReadingPosition.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save({
    required String accountId,
    required int bookId,
    required int chapterId,
    required ReadingPosition position,
  }) async {
    if (accountId.isEmpty) return;
    await (await SharedPreferences.getInstance()).setString(
      _key(accountId, bookId, chapterId),
      jsonEncode(position.toJson()),
    );
  }

  static Future<void> clearAccount(String accountId) async {
    if (accountId.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    final prefix = _prefix(accountId);
    for (final key
        in preferences.getKeys().where((key) => key.startsWith(prefix))) {
      await preferences.remove(key);
    }
  }
}
