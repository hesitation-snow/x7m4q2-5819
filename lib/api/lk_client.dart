import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 接口异常(code != 0 / HTTP 错误 / 网络错误)
class LKException implements Exception {
  final int code;
  final String message;
  LKException(this.code, this.message);
  @override
  String toString() => message.isEmpty ? '接口错误 code=$code' : '接口错误 code=$code $message';
}

/// 登录会话(持久化字段由上层保存)
class LKSession {
  String securityKey = '';
  int uid = 0;
  String nickname = '';
  String avatar = '';
  bool get isLoggedIn => securityKey.isNotEmpty;
}

/// lightnovel.fun 正式服 API 客户端
/// 统一走 pc-proxy 网关(服务端加签,客户端免签),全部 POST + JSON。
class LKClient {
  LKClient._();
  static final LKClient shared = LKClient._();

  final String base = 'https://www.lightnovel.fun/api/pc-proxy';
  final LKSession session = LKSession();

  static const Map<String, String> _headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36 LKFlutter/0.1',
    'Origin': 'https://www.lightnovel.fun',
    'Referer': 'https://www.lightnovel.fun/',
    // iOS 上避免复用可能挂起的 keep-alive 连接
    'Connection': 'close',
  };

  /// 自动附加 security_key(登录态接口用)
  Map<String, dynamic> authed([Map<String, dynamic> extra = const {}]) {
    final b = Map<String, dynamic>.from(extra);
    if (session.securityKey.isNotEmpty) b['security_key'] = session.securityKey;
    return b;
  }

  /// POST → 校验 code==0 → 返回 data
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) async {
    late final http.Response resp;
    try {
      resp = await http
          .post(Uri.parse('$base$path'), headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw LKException(-1, '网络错误: $e');
    }
    if (resp.statusCode >= 400) {
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final snippet = body.length > 300 ? body.substring(0, 300) : body;
      debugPrint('LKHTTP status=${resp.statusCode} url=$base$path body=$snippet');
      throw LKException(resp.statusCode, 'HTTP ${resp.statusCode}');
    }
    final Object? obj;
    try {
      obj = jsonDecode(utf8.decode(resp.bodyBytes));
    } catch (_) {
      throw LKException(-1, '响应解析失败');
    }
    if (obj is! Map<String, dynamic>) throw LKException(-1, '响应格式错误');
    final code = (obj['code'] as num?)?.toInt() ?? -1;
    if (code != 0) throw LKException(code, _extractMessage(obj['data']));
    return (obj['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  }

  /// POST → 返回 data(不做模型转换)
  Future<void> postVoid(String path, Map<String, dynamic> body) async {
    await post(path, body);
  }

  static String _extractMessage(dynamic data) {
    if (data is Map<String, dynamic>) {
      final m = data['message'];
      if (m is String && m.isNotEmpty) return m;
      for (final v in data.values) {
        if (v is List && v.isNotEmpty && v.first is String) return v.first as String;
        if (v is String && v.isNotEmpty) return v;
      }
    }
    return '';
  }

  /// pageSize 服务端上限 50
  static int clampPageSize(int n) => n < 1 ? 1 : (n > 50 ? 50 : n);

  /// multipart 头像上传,返回新头像 URL
  Future<String> uploadAvatar(String filePath, String md5Hex) async {
    final key = session.securityKey;
    if (key.isEmpty) throw LKException(8, '未登录');
    final req = http.MultipartRequest(
        'POST', Uri.parse('$base/api/bff/upload-my-avatar-v1'));
    req.headers.addAll({
      'User-Agent': _headers['User-Agent']!,
      'Origin': _headers['Origin']!,
      'Referer': _headers['Referer']!,
    });
    req.fields['security_key'] = key;
    req.fields['scene'] = 'user_avatar';
    req.fields['md5'] = md5Hex;
    req.files.add(await http.MultipartFile.fromPath('file', filePath));
    final resp = await req.send().timeout(const Duration(seconds: 40));
    final bytes = await resp.stream.toBytes();
    final obj = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final code = (obj['code'] as num?)?.toInt() ?? -1;
    if (code != 0) throw LKException(code, _extractMessage(obj['data']));
    final d = (obj['data'] as Map<String, dynamic>?) ?? {};
    return (d['url'] as String?) ?? (d['avatar'] as String?) ?? '';
  }
}
