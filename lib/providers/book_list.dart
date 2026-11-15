import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/tag.dart';
import 'package:anx_reader/enums/sort_field.dart';
import 'package:anx_reader/enums/sort_order.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/providers/tb_groups.dart';
import 'package:anx_reader/providers/sync_database_revision.dart';
import 'package:anx_reader/providers/book_filters.dart';
import 'package:anx_reader/providers/bookshelf_pins.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/providers/tags.dart'
    show kNoTagFilterId, tagSelectionProvider;
import 'package:anx_reader/service/linked_books.dart';
import 'package:lpinyin/lpinyin.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'book_list.g.dart';

@riverpod
class BookList extends _$BookList {
  String? _query;
  List<List<Book>> groupBooks(List<Book> books) {
    var groupedBooks = <List<Book>>[];
    for (var book in books) {
      if (book.groupId == 0) {
        groupedBooks.add([book]);
      } else {
        var existingGroup = groupedBooks.firstWhere(
          (group) => group.first.groupId == book.groupId,
          orElse: () => [],
        );
        if (existingGroup.isEmpty) {
          groupedBooks.add([book]);
        } else {
          existingGroup.add(book);
        }
      }
    }
    return groupedBooks;
  }

  int getChineseCompareResult(String a, String b) {
    String pinyina = '';
    String pinyinb = '';
    try {
      pinyina = PinyinHelper.getPinyin(a, format: PinyinFormat.WITHOUT_TONE);
    } catch (e) {
      pinyina = a;
    }
    try {
      pinyinb = PinyinHelper.getPinyin(b, format: PinyinFormat.WITHOUT_TONE);
    } catch (e) {
      pinyinb = b;
    }

    return pinyina.compareTo(pinyinb);
  }

  /// Linked books keep an opaque key in `filePath`; resolve it so directory
  /// libraries are sorted by the real on-disk name instead of a UUID.
  String _fileNameOf(Book book) {
    final path = LinkedBooks.resolve(book.filePath) ?? book.filePath;
    return p.basename(path);
  }

  bool _isRecentlyRead(Book book, DateTime now, Duration window) {
    final hasReadingHistory = book.readingPositionClock != null ||
        book.readingPercentage > 0.02 ||
        book.lastReadPosition.isNotEmpty;
    if (!hasReadingHistory) return false;
    // `lastReadTime` falls back to `updateTime` when no position record
    // exists, so require an actual reading trace before applying the window.
    return now.difference(book.lastReadTime).inSeconds.abs() <=
        window.inSeconds;
  }

  List<Book> sortBooks(List<Book> books) {
    final field = Prefs().sortField;
    final ascending = Prefs().sortOrder == SortOrderEnum.ascending;
    // Recently read books stay on top when sorting by name. Manual pins are
    // applied afterwards by applyBookshelfPins and therefore still win.
    final recentFirst = field != SortFieldEnum.lastReadTime &&
        Prefs().recentReadFirstWhenFileNameSort;
    final now = DateTime.now();
    final window = Duration(days: Prefs().recentReadWindowDays);
    books.sort((a, b) {
      if (recentFirst) {
        final ra = _isRecentlyRead(a, now, window);
        final rb = _isRecentlyRead(b, now, window);
        if (ra != rb) return ra ? -1 : 1;
      }
      int compareResult;
      switch (field) {
        case SortFieldEnum.title:
          compareResult = getChineseCompareResult(a.title, b.title);
          break;
        case SortFieldEnum.author:
          compareResult = getChineseCompareResult(a.author, b.author);
          break;
        case SortFieldEnum.lastReadTime:
          compareResult = a.lastReadTime.compareTo(b.lastReadTime);
          if (compareResult == 0) {
            // Local IDs and query order differ between synchronized devices.
            compareResult =
                (a.md5 ?? a.filePath).compareTo(b.md5 ?? b.filePath);
          }
          break;
        case SortFieldEnum.progress:
          compareResult = a.readingPercentage.compareTo(b.readingPercentage);
          break;
        case SortFieldEnum.importTime:
          compareResult = a.createTime.compareTo(b.createTime);
          break;
        case SortFieldEnum.fileName:
          compareResult =
              getChineseCompareResult(_fileNameOf(a), _fileNameOf(b));
          if (compareResult == 0) {
            compareResult =
                (a.md5 ?? a.filePath).compareTo(b.md5 ?? b.filePath);
          }
          break;
      }
      return ascending ? compareResult : -compareResult;
    });
    return books;
  }

  bool _matchesStatus(Book book, ReadingStatusFilter status) {
    const notStartThreshold = 0.02;
    const finishedThreshold = 0.98;
    switch (status) {
      case ReadingStatusFilter.none:
        return true;
      case ReadingStatusFilter.finished:
        return book.readingPercentage >= finishedThreshold;
      case ReadingStatusFilter.reading:
        return book.readingPercentage > notStartThreshold &&
            book.readingPercentage < finishedThreshold;
      case ReadingStatusFilter.notStarted:
        return book.readingPercentage <= notStartThreshold;
    }
  }

  Future<List<List<Book>>> _buildWithFilters({String? query}) async {
    ref.watch(syncDatabaseRevisionProvider);
    ref.watch(bookshelfPinsProvider);
    final status = ref.watch(readingStatusFilterNotifierProvider);
    final selectedTags = ref.watch(tagSelectionProvider);

    final books = await bookDao.selectNotDeleteBooks();
    final filteredByQuery = query == null || query.isEmpty
        ? books
        : books
            .where(
              (book) =>
                  book.title.contains(query) || book.author.contains(query),
            )
            .toList();

    final filteredByStatus =
        filteredByQuery.where((book) => _matchesStatus(book, status)).toList();

    List<Book> filteredByTags = filteredByStatus;
    if (selectedTags.isNotEmpty) {
      final tagMap = await bookTagDao.bookIdToTagIds(
          bookIds: filteredByStatus.map((b) => b.id).toList());
      if (selectedTags.contains(kNoTagFilterId)) {
        // Filter books without any tags
        filteredByTags = filteredByStatus.where((book) {
          final tags = tagMap[book.id];
          return tags == null || tags.isEmpty;
        }).toList();
      } else {
        // Filter books that contain all selected tags
        filteredByTags = filteredByStatus.where((book) {
          final tags = tagMap[book.id];
          if (tags == null || tags.isEmpty) return false;
          return selectedTags.every((id) => tags.contains(id));
        }).toList();
      }
    }

    final sortedBooks = sortBooks(filteredByTags);
    return applyBookshelfPins(
        groupBooks(sortedBooks), ref.read(bookshelfPinsProvider));
  }

  @override
  Future<List<List<Book>>> build() async {
    return _buildWithFilters(query: _query);
  }

  Future<void> refresh() async {
    state = AsyncData(await _buildWithFilters(query: _query));
  }

  Future<void> moveBooksToFolder(Iterable<int> bookIds,
      {int? groupId, String? newFolderName}) async {
    await bookDao.moveBooksToFolder(bookIds,
        groupId: groupId, newFolderName: newFolderName);
    ref.invalidate(groupDaoProvider);
    // The transaction has committed. A separate refresh failure must not offer
    // to create the same folder again as though the move itself had failed.
    ref.invalidateSelf();
  }

  void moveBook(Book data, int groupId) {
    updateBook(data.copyWith(groupId: groupId));
    // insert a new group if not exists
    ref.read(groupDaoProvider.notifier).insertGroup(groupId);
    refresh();
  }

  void updateBook(Book book) {
    bookDao.updateBook(book);
    refresh();
  }

  void dissolveGroup(List<Book> books) {
    ref
        .read(bookshelfPinsProvider.notifier)
        .setPinned(folderPinKey(books.first.groupId), false)
        .catchError((Object error) {
      // Pin cleanup must not prevent the existing folder dissolve operation.
      AnxLog.log.warning('Could not clear dissolved folder pin: $error');
    });
    for (var book in books) {
      updateBook(book.copyWith(groupId: 0));
    }
    // delete the group
    ref.read(groupDaoProvider.notifier).hardDeleteGroup(books.first.groupId);
    refresh();
  }

  void removeFromGroup(Book book) {
    updateBook(book.copyWith(groupId: 0));
    refresh();
  }

  void reorder(List<List<Book>> books) {
    state =
        AsyncData(applyBookshelfPins(books, ref.read(bookshelfPinsProvider)));
  }

  void moveBookToTop(int bookId) {
    var groups = state.value!.map((group) {
      if (group.any((book) => book.id == bookId)) {
        return [
          group.firstWhere((book) => book.id == bookId),
          ...group.where((b) => b.id != bookId)
        ];
      }
      return group;
    }).toList();

    state = AsyncData(applyBookshelfPins([
      groups.firstWhere((group) => group.any((book) => book.id == bookId)),
      ...groups.where((group) => group.every((book) => book.id != bookId))
    ], ref.read(bookshelfPinsProvider)));
  }

  Future<void> search(String? value) async {
    _query = value;
    state = AsyncData(await _buildWithFilters(query: value));
  }
}
