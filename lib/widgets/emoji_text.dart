import '../services/app_motion.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'common.dart';

class LkEmojiTextSegment {
  final String text;
  final String? imageUrl;

  const LkEmojiTextSegment.text(this.text) : imageUrl = null;
  const LkEmojiTextSegment.image(this.text, this.imageUrl);

  bool get isImage => imageUrl != null;
}

final RegExp _lkEmojiCodePattern = RegExp(r'\{:[^:]+:\}|\[[a-zA-Z]+:\d+\]');

/// 将站点表情代码切分为普通文本和图片片段；未知代码保留原文。
List<LkEmojiTextSegment> parseLkEmojiText(
    String text, Map<String, String> emojiUrls) {
  final segments = <LkEmojiTextSegment>[];
  var position = 0;
  for (final match in _lkEmojiCodePattern.allMatches(text)) {
    if (match.start > position) {
      segments
          .add(LkEmojiTextSegment.text(text.substring(position, match.start)));
    }
    final code = match.group(0)!;
    final imageUrl = emojiUrls[code];
    segments.add(imageUrl == null
        ? LkEmojiTextSegment.text(code)
        : LkEmojiTextSegment.image(code, imageUrl));
    position = match.end;
  }
  if (position < text.length) {
    segments.add(LkEmojiTextSegment.text(text.substring(position)));
  }
  return segments;
}

class LkEmojiText extends StatelessWidget {
  final String text;
  final Map<String, String> emojiUrls;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow overflow;
  final double emojiSize;

  const LkEmojiText({
    super.key,
    required this.text,
    required this.emojiUrls,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.emojiSize = 24,
  });

  @override
  Widget build(BuildContext context) {
    final segments = parseLkEmojiText(text, emojiUrls);
    return Text.rich(
      TextSpan(
        children: [
          for (final segment in segments)
            if (!segment.isImage)
              TextSpan(text: segment.text)
            else
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: CachedNetworkImage(
                    fadeOutDuration: AppMotion.duration(context, 1000),
                    fadeInDuration: AppMotion.duration(context, 500),
                    imageUrl: segment.imageUrl!,
                    width: emojiSize,
                    height: emojiSize,
                    memCacheWidth: imageCacheDimension(context, emojiSize),
                    fit: BoxFit.contain,
                    errorWidget: (_, __, ___) => Text(
                      segment.text,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
        ],
      ),
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
