import 'dart:io';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/linked_books.dart';
import 'package:path/path.dart' as p;

/// Directory libraries and WebDAV read caches register files as linked books:
/// the file stays where it is, while the existing Book row carries reading
/// progress, status, covers and history.
class LinkedBookRegistry {
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
    if (known != null) return known;

    final key = await LinkedBooks.linkPath(absolute);
    // The link may already exist even when restoreLinks skipped it (for
    // example an unreadable cache before it was downloaded again). Reuse the
    // row so reading progress is never replaced by a duplicate.
    final existing = await bookDao.selectBookByFilePath(key);
    if (existing != null) {
      knownBooks?[absolute] = existing;
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
    return book;
  }
}
