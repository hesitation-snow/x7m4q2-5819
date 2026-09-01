import '../api/models.dart';

const int largeCatalogChapterThreshold = 200;
const int expandAllVolumeLimit = 50;
const double catalogPrefetchExtent = 700;

bool shouldUsePagedCatalog(int chapterCount) =>
    chapterCount > largeCatalogChapterThreshold;

int effectiveVolumeChapterCount(
  LKVolume volume, {
  required int loadedVolumeCount,
  required int bookChapterCount,
}) {
  if (volume.chapterCount > 0) return volume.chapterCount;
  if (volume.firstChapterId > 0 &&
      volume.firstChapterId == volume.lastChapterId) {
    return 1;
  }
  return loadedVolumeCount == 1 ? bookChapterCount : 0;
}

bool shouldUsePagedCatalogForVolumes(
  List<LKVolume> volumes, {
  required int bookChapterCount,
}) {
  if (volumes.isEmpty) return shouldUsePagedCatalog(bookChapterCount);
  var largest = 0;
  for (final volume in volumes) {
    if (volume.chapterCount > largest) largest = volume.chapterCount;
  }
  if (largest <= 0 && volumes.length == 1) largest = bookChapterCount;
  return shouldUsePagedCatalog(largest);
}

bool shouldOfferExpandAllVolumes(
  List<LKVolume> volumes, {
  required int bookChapterCount,
}) {
  if (volumes.isEmpty || volumes.length > expandAllVolumeLimit) return false;
  final loadedChapterCount =
      volumes.fold<int>(0, (total, volume) => total + volume.chapterCount);
  final totalChapterCount = loadedChapterCount > bookChapterCount
      ? loadedChapterCount
      : bookChapterCount;
  return totalChapterCount <= largeCatalogChapterThreshold;
}

bool shouldLoadNextCatalogPage({
  required double extentAfter,
  required bool hasMore,
  required bool loading,
  required bool hasError,
}) =>
    hasMore && !loading && !hasError && extentAfter < catalogPrefetchExtent;

bool isCatalogMetadataVolume(LKVolume volume) {
  if (volume.chapterCount > 1) return false;
  final title = volume.title.trim().replaceAll(' ', '');
  return const {'作品信息', '作品资料', '作品简介', '小说信息'}.contains(title);
}

LKVolume? selectCatalogStartVolume(
  List<LKVolume> volumes, {
  int preferredVolumeId = 0,
}) {
  if (volumes.isEmpty) return null;
  LKVolume? preferred;
  for (final volume in volumes) {
    if (volume.volumeId == preferredVolumeId) {
      preferred = volume;
      break;
    }
  }
  if (preferred != null && !isCatalogMetadataVolume(preferred)) {
    return preferred;
  }
  for (final volume in volumes) {
    if (!isCatalogMetadataVolume(volume)) return volume;
  }
  return preferred ?? volumes.first;
}

int catalogPageCount(int total, int pageSize) {
  if (total <= 0 || pageSize <= 0) return 0;
  return (total + pageSize - 1) ~/ pageSize;
}

int catalogPageForChapter({
  required int chapterNo,
  required int total,
  required int pageSize,
}) {
  if (chapterNo <= 0 || pageSize <= 0) return 1;
  final requested = ((chapterNo - 1) ~/ pageSize) + 1;
  final pageCount = catalogPageCount(total, pageSize);
  return pageCount > 0 ? requested.clamp(1, pageCount) : requested;
}

int catalogSourcePage({
  required int logicalPage,
  required int total,
  required int pageSize,
  required bool descending,
}) {
  if (!descending) return logicalPage < 1 ? 1 : logicalPage;
  final pageCount = catalogPageCount(total, pageSize);
  if (pageCount <= 0) return 1;
  final sourcePage = pageCount - logicalPage + 1;
  return sourcePage.clamp(1, pageCount);
}
