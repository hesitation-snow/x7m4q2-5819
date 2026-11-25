import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';
import '../services/app_motion.dart';
import '../services/emoji_catalog.dart';
import '../widgets/common.dart';

/// Shared keyboard-height cache for inline emoji panels so switching between the
/// system keyboard and the emoji grid avoids layout jumps.
abstract final class LkEmojiKeyboardHeight {
  static const String _prefsKey = 'last_keyboard_height';
  static double _cachedHeight = 0;

  static Future<void> warmUp() async {
    if (_cachedHeight > 150) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_prefsKey);
      if (saved != null && saved > 150) {
        _cachedHeight = saved;
      }
    } catch (_) {}
  }

  static void recordInset(double inset) {
    if (inset > 150 && inset > _cachedHeight) {
      _cachedHeight = inset;
      unawaited(
        SharedPreferences.getInstance().then((prefs) {
          prefs.setDouble(_prefsKey, inset);
        }).catchError((Object _) {}),
      );
    }
  }

  static double panelHeight(
    BuildContext context, {
    double reservedHeight = 200,
  }) {
    final media = MediaQuery.of(context);
    final isLandscape = media.size.width > media.size.height;
    final minH = isLandscape ? 160.0 : 260.0;
    final maxH = isLandscape ? 220.0 : 380.0;
    final available = math.max(
      120.0,
      media.size.height - media.viewPadding.vertical - reservedHeight,
    );
    final effectiveMin = math.min(minH, available);
    final effectiveMax = math.max(effectiveMin, math.min(maxH, available));

    if (_cachedHeight > 150 && !isLandscape) {
      return _cachedHeight.clamp(effectiveMin, effectiveMax).toDouble();
    }
    return (media.size.height * 0.40)
        .clamp(effectiveMin, effectiveMax)
        .toDouble();
  }
}

/// Shared inline emoji picker panel (category tabs + 8-column grid).
class LkEmojiPanel extends StatefulWidget {
  const LkEmojiPanel({
    super.key,
    required this.groups,
    required this.onPick,
  });

  final List<LKEmojiGroup> groups;
  final ValueChanged<String> onPick;

  @override
  State<LkEmojiPanel> createState() => _LkEmojiPanelState();
}

class _LkEmojiPanelState extends State<LkEmojiPanel> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.groups.isEmpty) return const SizedBox.shrink();
    final tab = _tab.clamp(0, widget.groups.length - 1);
    final group = widget.groups[tab];
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: widget.groups.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (_, index) {
              final selected = index == tab;
              return GestureDetector(
                onTap: () => setState(() => _tab = index),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primary
                        : scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    widget.groups[index].name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(10),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 8,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            itemCount: group.items.length,
            itemBuilder: (_, index) {
              final item = group.items[index];
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => widget.onPick(item.code),
                child: item.isImage
                    ? CachedNetworkImage(
                        fadeOutDuration: AppMotion.duration(context, 1000),
                        fadeInDuration: AppMotion.duration(context, 500),
                        imageUrl: YomiruEmojiCatalog.normalizeUrl(item.url),
                        width: 32,
                        height: 32,
                        memCacheWidth: imageCacheDimension(context, 32),
                        fit: BoxFit.contain,
                        errorWidget: (_, __, ___) => Icon(
                          Icons.broken_image_outlined,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    : Center(
                        child: Text(
                          item.code,
                          style: const TextStyle(fontSize: 22),
                        ),
                      ),
              );
            },
          ),
        ),
      ],
    );
  }
}
