import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class BookImageTestPaths extends PathProviderPlatform {
  BookImageTestPaths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// File-backed image caching needs paths even though these tests mock HTTP.
/// Use one sandbox per test file so the shared image cache has a full lifecycle.
class BookImageTestSandbox {
  late final Directory directory;
  late final PathProviderPlatform previous;
  Future<void> open() async {
    previous = PathProviderPlatform.instance;
    directory =
        await Directory.systemTemp.createTemp('yomiru-book-image-tests-');
    PathProviderPlatform.instance = BookImageTestPaths(directory.path);
    // Await repository initialization before any widget/fake-async zone or close.
    await DefaultCacheManager().getFileFromCache('book-test-sandbox:init');
  }

  Future<void> close() async {
    await DefaultCacheManager().dispose();
    PathProviderPlatform.instance = previous;
    for (var attempt = 0;; attempt++) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
        return;
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode != 32 || attempt >= 5) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
  }
}
