/// 首页可浏览的频道。列表顺序也是首次安装时首页标签的默认顺序。
class HomeChannel {
  const HomeChannel(this.code, this.label, this.path);

  final String code;
  final String label;
  final String path;
}

const homePrimaryChannelCount = 3;

const homeChannels = <HomeChannel>[
  HomeChannel('hot', '热度', '/api/bff/home-feed-v1'),
  HomeChannel('recent', '最近更新', '/api/bff/home-recent-updates-feed-v1'),
  HomeChannel('rank', '排行', 'rank'),
  HomeChannel('lightnovel', '轻小说', '/api/bff/home-lightnovel-feed-v1'),
  HomeChannel('original', '原创', '/api/bff/home-original-feed-v1'),
  HomeChannel('fanfic', '同人', '/api/bff/home-fanfic-feed-v1'),
  HomeChannel('epub', 'EPUB', '/api/bff/home-epub-feed-v1'),
];

final defaultHomeChannelOrder = List<String>.unmodifiable(
  homeChannels.map((channel) => channel.code),
);

/// 忽略旧版或损坏的频道代码，并把新版本新增的频道补在末尾。
List<String> normalizeHomeChannelOrder(Iterable<String>? saved) {
  final known = defaultHomeChannelOrder.toSet();
  final order = <String>[];
  for (final code in saved ?? defaultHomeChannelOrder) {
    if (known.contains(code) && !order.contains(code)) order.add(code);
  }
  for (final code in defaultHomeChannelOrder) {
    if (!order.contains(code)) order.add(code);
  }
  return List<String>.unmodifiable(order);
}

HomeChannel homeChannelByCode(String code) =>
    homeChannels.firstWhere((channel) => channel.code == code);
