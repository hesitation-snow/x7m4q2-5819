import 'dart:async';
import 'package:flutter/material.dart';
import '../api/lk_api.dart';
import '../api/models.dart';
import '../services/offline_library.dart';
import '../widgets/common.dart';
import '../widgets/content_state_view.dart';
import 'reader_page.dart';

class OfflineLibraryPage extends StatefulWidget {
  const OfflineLibraryPage({super.key, this.book});
  final LKBook? book;
  @override
  State<OfflineLibraryPage> createState() => _OfflineLibraryPageState();
}

class _OfflineLibraryPageState extends State<OfflineLibraryPage> {
  final library = OfflineLibrary.shared;
  final selected = <int>{};
  late Future<List<LKVolume>> volumes;
  @override
  void initState() {
    super.initState();
    volumes = widget.book == null
        ? Future.value([])
        : LKApi.allVolumes(widget.book!.bookId);
  }

  void _start(int bookId, String title, List<LKVolume> volumes,
      {List<int>? volumeOrder}) {
    unawaited(library
        .download(bookId, title, volumes, volumeOrder: volumeOrder)
        .catchError((Object e) {
      if (mounted) showFloatingPrompt(context, e.toString());
    }));
  }

  Future<void> _delete(int bookId) async {
    final owner = library.ownerUid;
    final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('删除离线正文？'),
              content: const Text('仅删除这本书主动下载的正文，不影响书架和阅读进度。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('删除'))
              ],
            ));
    if (confirm != true || owner != library.ownerUid) return;
    try {
      await library.remove(bookId);
    } catch (e) {
      if (mounted) showFloatingPrompt(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('离线下载')),
        body: ListenableBuilder(
            listenable: library,
            builder: (context, _) => FutureBuilder(
                  key: ValueKey('offline-list-${library.ownerUid}'),
                  future: library.books(),
                  builder: (context, snapshot) => ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      const Text(
                          '主动下载的正文不会被普通缓存清理删除。插画仍按需联网加载。关闭应用后下载可能暂停，可在这里继续。',
                          style: TextStyle(fontSize: 12)),
                      if (library.busy) ...[
                        const LinearProgressIndicator(),
                        TextButton(
                            onPressed: library.cancel,
                            child: const Text('暂停下载（当前请求结束后生效）')),
                      ],
                      if (library.error != null)
                        Text(library.error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      if (widget.book != null)
                        FutureBuilder<List<LKVolume>>(
                          future: volumes,
                          builder: (context, volumesSnapshot) {
                            if (volumesSnapshot.hasError) {
                              return ContentStateView(
                                  message: '目录加载失败',
                                  onRetry: () => setState(() => volumes =
                                      LKApi.allVolumes(widget.book!.bookId)));
                            }
                            if (!volumesSnapshot.hasData) {
                              return const Center(
                                  child: ContentStateView(
                                      message: '正在加载目录…', loading: true));
                            }
                            final items = volumesSnapshot.data!;
                            return Column(children: [
                              for (final volume in items)
                                CheckboxListTile(
                                  title: Text(volume.title),
                                  value: selected.contains(volume.volumeId),
                                  onChanged: library.busy
                                      ? null
                                      : (value) => setState(() {
                                            if (value == true) {
                                              selected.add(volume.volumeId);
                                            } else {
                                              selected.remove(volume.volumeId);
                                            }
                                          }),
                                ),
                              FilledButton.icon(
                                  onPressed: library.busy || selected.isEmpty
                                      ? null
                                      : () => _start(
                                          widget.book!.bookId,
                                          widget.book!.title,
                                          items
                                              .where((v) =>
                                                  selected.contains(v.volumeId))
                                              .toList(),
                                          volumeOrder: items
                                              .map((v) => v.volumeId)
                                              .toList()),
                                  icon: const Icon(Icons.download_outlined),
                                  label: const Text('下载所选卷正文')),
                              const SizedBox(height: 16),
                            ]);
                          },
                        ),
                      if (snapshot.hasError)
                        ContentStateView(
                            message: '离线列表读取失败',
                            onRetry: () => setState(() {})),
                      if (!snapshot.hasData)
                        const ContentStateView(
                            message: '正在读取离线书籍…', loading: true),
                      if (snapshot.hasData && snapshot.data!.isEmpty)
                        const ContentStateView(
                            message: '还没有离线书籍，可从书籍详情页「更多操作」下载。',
                            icon: Icons.download_for_offline_outlined),
                      for (final book
                          in snapshot.data ?? <Map<String, dynamic>>[])
                        _bookCard(book),
                    ],
                  ),
                )),
      );
  Widget _bookCard(Map<String, dynamic> book) {
    final chapters = (book['chapters'] as List).cast<Map<String, dynamic>>();
    final ready = chapters.where((c) => c['status'] == 'ready').length;
    final bytes = chapters.fold<int>(
        0, (total, c) => total + ((c['bytes'] as num?)?.toInt() ?? 0));
    return Card(
        child: ExpansionTile(
      key: ValueKey('offline-book-${library.ownerUid}-${book['book_id']}'),
      title: Text(book['title'] as String),
      subtitle: Text(
          '$ready / ${chapters.length} 章 · ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'),
      children: [
        Wrap(children: [
          TextButton(
              onPressed: library.busy
                  ? null
                  : () => _start(
                      book['book_id'] as int, book['title'] as String, []),
              child: const Text('继续／重试未完成章节')),
          TextButton(
              onPressed:
                  library.busy ? null : () => _delete(book['book_id'] as int),
              child: const Text('删除正文')),
        ]),
        SizedBox(
            height: chapters.isEmpty ? 0 : 360,
            child: ListView.builder(
                itemCount: chapters.length,
                itemBuilder: (context, index) {
                  final chapter = chapters[index];
                  return ListTile(
                    title: Text(chapter['title'] as String),
                    subtitle: chapter['error'] != null
                        ? Text(chapter['error'] as String)
                        : null,
                    trailing: Icon(chapter['status'] == 'ready'
                        ? Icons.offline_pin_outlined
                        : chapter['status'] == 'failed'
                            ? Icons.error_outline
                            : Icons.schedule),
                    onTap: chapter['status'] != 'ready'
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => ReaderPage(
                                    bookId: book['book_id'] as int,
                                    bookTitle: book['title'] as String,
                                    chapterId: chapter['id'] as int,
                                    chapterTitle: chapter['title'] as String,
                                    volumeId: chapter['volume'] as int,
                                    offlineOnly: true))),
                  );
                })),
      ],
    ));
  }
}
