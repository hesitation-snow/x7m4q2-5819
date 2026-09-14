// 仅用于本地缓存标识；联网请求始终使用服务器给出的完整 URL。
final _uploadedImagePath = RegExp(
    r'^/upload-files/images/\d{6}/[a-fA-F0-9]{24,64}\.(?:jpe?g|png|webp|gif|avif)$');
final _timestamp = RegExp(r'^\d+$');

bool isSiteIllustrationUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host == 'api.lightnovel.fun' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      !uri.hasFragment &&
      _uploadedImagePath.hasMatch(uri.path);
}

/// 已确认的站点插画 m/t 是临时访问参数，不是图片版本。
/// 未知域名/路径不处理，尺寸、格式、版本等其它参数原样保留。
String illustrationCacheKey(String url) {
  if (!isSiteIllustrationUrl(url)) return url;
  final uri = Uri.parse(url);
  final Map<String, List<String>> parameters;
  try {
    parameters = uri.queryParametersAll;
  } on FormatException {
    return url;
  }
  final signatures = parameters['m'];
  final timestamps = parameters['t'];
  if (signatures?.length != 1 ||
      signatures!.single.isEmpty ||
      timestamps?.length != 1 ||
      !_timestamp.hasMatch(timestamps!.single)) {
    return url;
  }
  // 保留其余参数的原始编码和顺序，不用 queryParameters 重组请求地址。
  final retained = uri.query.split('&').where((part) {
    final name = Uri.decodeQueryComponent(part.split('=').first);
    return name != 'm' && name != 't';
  }).join('&');
  final base = url.substring(0, url.indexOf('?'));
  return retained.isEmpty ? base : '$base?$retained';
}
