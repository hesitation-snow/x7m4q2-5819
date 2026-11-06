import 'dart:convert';

/// Display classification, not a grant to read protected content.
/// Missing fields and non-positive booleans are unknown, not proof of public.
enum BookAccessStatus { unknown, public, brave }

bool _positive(Object? value) =>
    value == true ||
    value == 1 ||
    value is String && const {'1', 'true'}.contains(value.trim().toLowerCase());
String _text(Object? value) =>
    value is String ? value.trim().toLowerCase() : '';

Map<String, dynamic>? _metadata(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.fromEntries(value.entries
        .where((entry) => entry.key is String)
        .map((entry) => MapEntry(entry.key as String, entry.value)));
  }
  // Some stored/imported metadata is JSON encoded. Do not scan arbitrary
  // nested profile/user payloads or unbounded JSON strings for access flags.
  if (value is String && value.length <= 65536) {
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? _metadata(decoded) : null;
    } on FormatException {
      return null;
    }
  }
  return null;
}

bool _braveScope(Object? value) =>
    const {'brave', 'brave_only', 'brave_required'}.contains(_text(value));

BookAccessStatus _access(Map<String, dynamic> json, {required bool book}) {
  // OR aliases independently: an old false alias must not mask a positive one.
  final brave = const [
    'is_brave',
    'isBrave',
    'brave_required',
    'braveRequired',
    'brave_only',
    'braveOnly'
  ].any((key) => _positive(json[key]));
  final types = [json['access_type'], json['accessType']];
  final metadata = [_metadata(json['meta_json']), _metadata(json['metaJson'])];
  if (brave ||
      types.any(_braveScope) ||
      metadata.any((map) =>
          map != null &&
          (_braveScope(map['brave_scope']) ||
              _braveScope(map['braveScope'])))) {
    return BookAccessStatus.brave;
  }
  if (book) {
    final tags = json['tags'];
    if (tags is List &&
        tags.any((tag) {
          final value = tag is Map ? (tag['name'] ?? tag['tag_name']) : tag;
          return const {'勇者', '勇者可读'}
              .contains(value is String ? value.trim() : '');
        })) {
      return BookAccessStatus.brave;
    }
    // A substring such as "not_brave" is not affirmative evidence.
    if (const {'brave', 'brave_only', 'brave_required', 'brave_readable'}
        .contains(_text(json['display_badge_code']))) {
      return BookAccessStatus.brave;
    }
    if (_text(json['book_access_state']) == 'brave') {
      return BookAccessStatus.brave;
    }
  }
  // A book's entry/default access being public says nothing about later
  // chapters. Public is a chapter-level fact, not a whole-book verdict.
  if (!book &&
      (types.any((value) => _text(value) == 'public') ||
          metadata.any((map) =>
              map != null &&
              (_text(map['brave_scope']) == 'public' ||
                  _text(map['braveScope']) == 'public')))) {
    return BookAccessStatus.public;
  }
  return BookAccessStatus.unknown;
}

/// Call with a book object, never a user/profile object containing is_brave.
BookAccessStatus classifyBookAccess(Map<String, dynamic> json) =>
    _access(json, book: true);

/// Only classifies this chapter. A public chapter does not prove the book public.
BookAccessStatus classifyChapterAccess(Map<String, dynamic> json) =>
    _access(json, book: false);

int bookIdentityFromJson(Map<String, dynamic> json) {
  for (final key in const ['book_id', 'bookId', 'article_id', 'aid', 'id']) {
    final raw = json[key];
    final id =
        raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;
    if (id > 0) return id;
  }
  return 0;
}
