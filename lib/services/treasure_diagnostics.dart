import 'dart:convert';

/// Opt-in, in-memory diagnostics. Never export raw responses, credentials,
/// account data or URLs. Only bounded task instructions are retained as text.
String treasureDiagnostics(Map<String, dynamic> response) {
  const numeric = {
    'campaignid',
    'campaignday',
    'boxid',
    'treasureboxid',
    'day',
    'rewardcoin',
    'rewardamount',
    'openedboxes',
    'claimablecount',
    'claimableboxes',
    'boxindex',
    'taskid',
    'todaytotalboxes',
    'prerequisitecompleted',
    'requirementvalue',
    'progress',
    'totalprogress',
  };
  const flags = {
    'claimable',
    'canclaim',
    'todayclaimable',
    'claimed',
    'isclaimed',
    'received',
    'opened'
  };
  const statuses = {
    'ready',
    'claimable',
    'claimed',
    'received',
    'locked',
    'pending',
    'waiting',
    'unavailable'
  };
  final sensitive = RegExp(
      'token|secret|password|cookie|authorization|security|session|email|avatar|nickname|username|userid|^uid\$|account|profile|phone',
      caseSensitive: false);
  var remaining = 160;
  dynamic inspect(dynamic value, String field, int depth) {
    if (--remaining < 0 || depth > 6) return '<truncated>';
    if (value == null) return null;
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries.take(40)) {
        if (remaining <= 0) {
          result['_truncated'] = true;
          break;
        }
        final key = '${entry.key}';
        if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,63}$').hasMatch(key)) continue;
        final normalized = key.replaceAll('_', '').toLowerCase();
        if (sensitive.hasMatch(normalized)) continue;
        result[key] = inspect(entry.value, normalized, depth + 1);
      }
      return result;
    }
    if (value is List) {
      return {
        'length': value.length,
        'sample':
            value.take(3).map((v) => inspect(v, field, depth + 1)).toList()
      };
    }
    if (numeric.contains(field) && RegExp(r'^\d{1,12}$').hasMatch('$value')) {
      return value;
    }
    if (flags.contains(field) &&
        [true, false, 0, 1, 'true', 'false', '0', '1'].contains(value)) {
      return value;
    }
    if ((field == 'status' || field == 'rewardstatus') &&
        (statuses.contains('$value'.toLowerCase()) ||
            RegExp(r'^\d{1,3}$').hasMatch('$value'))) {
      return value;
    }
    if ({'status', 'prerequisitetype', 'requirementtype', 'buttonaction'}
            .contains(field) &&
        value is String &&
        RegExp(r'^[a-z_]{1,40}$').hasMatch(value)) {
      return value;
    }
    if ({'prerequisitetext', 'requirementtext', 'buttontext'}.contains(field) &&
        value is String) {
      if (sensitive.hasMatch(value) ||
          value.contains('@') ||
          value.contains('://') ||
          RegExp(r'[A-Za-z0-9_\-]{24,}').hasMatch(value)) {
        return '<redacted>';
      }
      return value.length > 240 ? '${value.substring(0, 240)}…' : value;
    }
    return value is String
        ? '<string>'
        : value is num
            ? '<number>'
            : value is bool
                ? '<bool>'
                : '<value>';
  }

  return const JsonEncoder.withIndent('  ')
      .convert({'format': 2, 'response': inspect(response, '', 0)});
}
