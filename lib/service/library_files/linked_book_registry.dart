import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/book.dart' show resetBookCover;
import 'package:anx_reader/service/linked_books.dart';
import 'package:anx_reader/utils/lightweight_cover_extractor.dart'
    show LightweightCoverExtractor;
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
  static Timer? _notifyTimer;

  /// Titles/authors read from an EPUB OPF after the Book row was created.
  /// Widgets holding an old Book snapshot read these through [titleFor] /
  /// [authorFor], so a background backfill shows up on the next rebuild.
  static final Map<int, String> _backfilledTitles = <int, String>{};
  static final Map<int, String> _backfilledAuthors = <int, String>{};
  static final Queue<Book> _metadataQueue = Queue<Book>();
  static final Set<int> _metadataInFlight = <int>{};
  static bool _metadataWorkerRunning = false;

  static String? titleFor(Book book) => _backfilledTitles[book.id];
  static String? authorFor(Book book) => _backfilledAuthors[book.id];

  /// Queue a cover for a linked book that has no usable cover yet. Called both
  /// from registration and from the cover widget's build, so it must be cheap,
  /// idempotent, and must never run two extractions for the same row.
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

  /// Schedule an OPF title/author backfill for linked EPUBs that were imported
  /// before metadata parsing existed. A user-edited title is never replaced.
  static void requestMetadata(Book book) {
    if (book.id <= 0 || !LinkedBooks.isLinked(book.filePath)) return;
    final path = book.fileFullPath;
    if (p.extension(path).toLowerCase() != '.epub') return;
    if (!_looksLikeFilenameTitle(book.title, path)) return;
    if (!File(path).existsSync()) return;
    if (_metadataQueue.length >= 30 || !_metadataInFlight.add(book.id)) return;
    _metadataQueue.add(book);
    unawaited(_drainMetadata());
  }

  /// A title equal to the file name (with or without extension) means the row
  /// never received a real metadata title. Empty titles count as missing too.
  static bool _looksLikeFilenameTitle(String title, String path) {
    final value = title.trim();
    return value.isEmpty ||
        value == p.basenameWithoutExtension(path) ||
        value == p.basename(path);
  }

  /// Strictly serial, like cover extraction: one zip directory at a time.
  static Future<void> _drainMetadata() async {
    if (_metadataWorkerRunning) return;
    _metadataWorkerRunning = true;
    try {
      while (_metadataQueue.isNotEmpty) {
        final book = _metadataQueue.removeFirst();
        try {
          final meta = await LightweightCoverExtractor.readEpubMetadata(
            book.fileFullPath,
          );
          final title = meta?.title;
          if (title == null || title.isEmpty) continue;
          // Re-read the row: progress sync may have written a newer snapshot.
          final fresh = await bookDao.selectBookById(book.id);
          if (!_looksLikeFilenameTitle(fresh.title, fresh.fileFullPath)) {
            continue;
          }
          final author = fresh.author.trim().isEmpty
              ? (meta?.author ?? '')
              : fresh.author;
          if (fresh.title != title || fresh.author != author) {
            await bookDao.updateBook(
              fresh.copyWith(title: title, author: author),
            );
          }
          _backfilledTitles[book.id] = title;
          _backfilledAuthors[book.id] = author;
          _scheduleCoverNotify();
        } catch (_) {
          // Unreadable / malformed book: keep the file-name title as-is.
        } finally {
          _metadataInFlight.remove(book.id);
        }
      }
    } finally {
      _metadataWorkerRunning = false;
    }
  }

  static void _scheduleCoverNotify() {
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 400), () {
      _notifyTimer = null;
      coverVersion.value++;
    });
  }

  /// Strictly serial: extracting a cover opens and inflates a book file, and
  /// the native PDF first-page renderer allocates a full-size bitmap. Running
  /// one at a time keeps a bulk directory scan from exhausting memory. No
  /// WebView or loopback server is involved any more, so there is no warmup
  /// delay before the first book.
  static Future<void> _drainCovers() async {
    if (_coverWorkerRunning) return;
    _coverWorkerRunning = true;
    try {
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
      // Older builds registered file-browser books without parsing metadata.
      requestCover(known);
      requestMetadata(known);
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
      requestMetadata(existing);
      return existing;
    }

    // One cheap zip-directory read; no WebView and no whole-book Blob. Keep
    // the caller-supplied name (e.g. a WebDAV entry name) as the fallback.
    final meta = await LightweightCoverExtractor.readEpubMetadata(absolute);
    final effectiveTitle =
        meta?.title ?? title ?? p.basenameWithoutExtension(absolute);
    final now = DateTime.now();
    final book = Book(
      id: -1,
      title: effectiveTitle,
      coverPath: '',
      filePath: key,
      lastReadPosition: '',
      readingPercentage: 0.0,
      author: meta?.author ?? '',
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
