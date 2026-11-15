import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/book.dart' show resetBookCover;
import 'package:anx_reader/service/linked_books.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Directory libraries and WebDAV read caches register files as linked books:
/// the file stays where it is, while the existing Book row carries reading
/// progress, status, covers and history.
class LinkedBookRegistry {
  /// Bumped after a background cover extraction lands. Cover widgets listen to
  /// this so the placeholder is replaced without a full bookshelf reload.
  static final ValueNotifier<int> coverVersion = ValueNotifier<int>(0);

  /// Covers generated during this session, keyed by book id. The Book held by
  /// a widget is a snapshot taken before the cover existed, so its coverPath
  /// stays empty until the bookshelf is reloaded from the database.
  static final Map<int, String> _coverFiles = <int, String>{};

  static String? coverFileFor(int bookId) => _coverFiles[bookId];

  static final Queue<Book> _coverQueue = Queue<Book>();
  static final Set<int> _coverInFlight = <int>{};
  static final Map<int, int> _coverAttempts = <int, int>{};
  static const int _maxQueuedCovers = 30;
  static const int _maxCoverAttempts = 3;
  static bool _coverWorkerRunning = false;
  static bool _needsWarmup = true;
  static Timer? _notifyTimer;

  /// Queue a cover for a linked book that has no usable cover yet. Called both
  /// from registration and from the cover widget's build, so it must be cheap,
  /// idempotent, and must never open two WebViews for the same row.
  static void requestCover(Book book) {
    if (book.id <= 0 || !LinkedBooks.isLinked(book.filePath)) return;
    if (book.coverPath.isNotEmpty && File(book.coverFullPath).existsSync()) {
      return;
    }
    if ((_coverAttempts[book.id] ?? 0) >= _maxCoverAttempts) return;
    if (_coverQueue.length >= _maxQueuedCovers ||
        !_coverInFlight.add(book.id)) {
      return;
    }
    _coverQueue.add(book);
    unawaited(_drainCovers());
  }

  static void _scheduleCoverNotify() {
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 400), () {
      _notifyTimer = null;
      coverVersion.value++;
    });
  }

  /// Strictly serial: cover extraction runs in a headless WebView, which can
  /// only be driven from the main isolate and is expensive for large PDFs.
  /// The image encoding itself already runs in a compute isolate.
  static Future<void> _drainCovers() async {
    if (_coverWorkerRunning) return;
    _coverWorkerRunning = true;
    try {
      if (_needsWarmup) {
        _needsWarmup = false;
        // The loopback book server starts just after the first runApp. Cover
        // extraction needs its port and the WebView environment to be ready.
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      while (_coverQueue.isNotEmpty) {
        final book = _coverQueue.removeFirst();
        try {
          if (!await File(book.fileFullPath).exists()) {
            _coverAttempts[book.id] = (_coverAttempts[book.id] ?? 0) + 1;
            continue;
          }
          // Re-read the row: resetBookCover writes a whole Book snapshot, and
          // a stale one would overwrite progress synced from another device.
          final fresh = await bookDao.selectBookById(book.id);
          await resetBookCover(fresh);
          final updated = await bookDao.selectBookById(book.id);
          if (updated.coverPath.isNotEmpty) {
            _coverFiles[book.id] = updated.coverFullPath;
            _coverAttempts.remove(book.id);
            _scheduleCoverNotify();
          } else {
            _coverAttempts[book.id] = (_coverAttempts[book.id] ?? 0) + 1;
          }
        } catch (_) {
          // Books without an embedded cover throw FormatException. Keep the
          // placeholder and cap retries so a failing file cannot spin forever.
          _coverAttempts[book.id] = (_coverAttempts[book.id] ?? 0) + 1;
          AnxLog.warning('Linked book cover unavailable: ${book.id}');
        } finally {
          _coverInFlight.remove(book.id);
        }
      }
    } finally {
      _coverWorkerRunning = false;
    }
  }

  static Future<Map<String, Book>> booksByPath() async {
    final books = await bookDao.selectNotDeleteBooks();
    final result = <String, Book>{};
    for (final book in books) {
      try {
        final path = book.fileFullPath;
        if (path.isEmpty) continue;
        result[File(path).absolute.path] = book;
      } catch (_) {
        // A stale/missing link must not hide the rest of the library.
      }
    }
    return result;
  }

  static Future<Book> ensurePath(
    String path, {
    Map<String, Book>? knownBooks,
    String? title,
  }) async {
    final absolute = File(path).absolute.path;
    final known = knownBooks?[absolute];
    if (known != null) {
      // Covers books added by an older build that skipped metadata parsing.
      requestCover(known);
      return known;
    }

    final key = await LinkedBooks.linkPath(absolute);
    // The link may already exist even when restoreLinks skipped it (for
    // example an unreadable cache before it was downloaded again). Reuse the
    // row so reading progress is never replaced by a duplicate.
    final existing = await bookDao.selectBookByFilePath(key);
    if (existing != null) {
      knownBooks?[absolute] = existing;
      requestCover(existing);
      return existing;
    }

    final now = DateTime.now();
    final book = Book(
      id: -1,
      title: title ?? p.basenameWithoutExtension(absolute),
      coverPath: '',
      filePath: key,
      lastReadPosition: '',
      readingPercentage: 0.0,
      author: '',
      isDeleted: false,
      rating: 0.0,
      createTime: now,
      updateTime: now,
    );
    book.id = await bookDao.insertBook(book);
    knownBooks?[absolute] = book;
    requestCover(book);
    return book;
  }
}
