import 'dart:io';

import 'package:flutter/services.dart';

/// Books that stay in their original location instead of being copied into the
/// private library.
///
/// iOS persists security-scoped bookmarks; Android persists absolute paths
/// backed by the "All files access" grant. Device-local book access is never
/// stored in the synced database.
class LinkedBooks {
  static const channel = MethodChannel('com.modu.reader/book_folder');
  static const extensions = ['epub', 'pdf', 'mobi', 'azw3', 'fb2'];

  static const _iosPrefix = 'file/ios-linked-';
  static const _androidPrefix = 'file/android-linked-';

  static final Map<String, String> _paths = {};

  /// Whether this platform can read a book without owning a copy of it.
  static bool get supported => Platform.isIOS || Platform.isAndroid;

  static bool isLinked(String path) =>
      path.startsWith(_iosPrefix) || path.startsWith(_androidPrefix);

  static String? resolve(String path) => _paths[path];

  static Future<void> restore() async {
    final paths = await channel.invokeMapMethod<String, String>('restoreLinks');
    _paths
      ..clear()
      ..addAll(paths ?? {});
  }

  static Future<String> link(String selectionId) async {
    final link = await channel.invokeMapMethod<String, String>('link', {
      'id': selectionId,
    });
    final key = link?['key'];
    final path = link?['path'];
    if (key == null ||
        !isLinked(key) ||
        path == null ||
        !File(path).isAbsolute) {
      throw const FileSystemException('Unable to retain book access');
    }
    _paths[key] = path;
    return key;
  }

  /// Registers an absolute path that is already readable (directory scan or
  /// WebDAV cache) without copying the file into the private library.
  static Future<String> linkPath(String path) async {
    final link = await channel.invokeMapMethod<String, String>('linkPath', {
      'path': path,
    });
    final key = link?['key'];
    final resolved = link?['path'];
    if (key == null ||
        !isLinked(key) ||
        resolved == null ||
        !File(resolved).isAbsolute) {
      throw const FileSystemException('Unable to retain book access');
    }
    _paths[key] = resolved;
    return key;
  }

  static Future<void> forget(String key) async {
    if (!isLinked(key)) return;
    try {
      await channel.invokeMethod<void>('forgetLink', {'key': key});
    } on MissingPluginException {
      // Desktop builds can receive synced linked rows but store no link state.
    }
    _paths.remove(key);
  }

  /// Android 11+ only grants raw paths outside the app sandbox to apps with the
  /// special "All files access" permission. Other platforms need no extra grant.
  static Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    return await channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
  }

  static Future<void> requestAllFilesAccess() =>
      channel.invokeMethod<void>('requestAllFilesAccess');

  static Future<int> androidSdkInt() async =>
      await channel.invokeMethod<int>('sdkInt') ?? 0;
}
