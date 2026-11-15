import 'package:anx_reader/utils/app_motion.dart';
import 'package:anx_reader/utils/bookshelf_grid_layout.dart';
import 'dart:async';
import 'dart:io';
import 'package:anx_reader/l10n/modu_strings.dart';
import 'package:anx_reader/widgets/home_navigation_metrics.dart';
import 'dart:math';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/enums/sort_field.dart';
import 'package:anx_reader/enums/sort_order.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/tag.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/book_filters.dart';
import 'package:anx_reader/providers/last_read_book_provider.dart';
import 'package:anx_reader/providers/tags.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/knowledge/book_knowledge_index_queue.dart';
import 'package:anx_reader/service/knowledge/book_knowledge_index_service.dart';
import 'package:anx_reader/page/home_page/local_library_page.dart';
import 'package:anx_reader/page/search/search_page.dart';
import 'package:anx_reader/utils/color/hash_color.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/bookshelf/book_import_picker.dart';
import 'package:anx_reader/widgets/bookshelf/book_folder.dart';
import 'package:anx_reader/widgets/bookshelf/book_selection_actions.dart';
import 'package:anx_reader/widgets/bookshelf/stop_vectorization_button.dart';
import 'package:anx_reader/widgets/bookshelf/sync_button.dart';
import 'package:anx_reader/widgets/common/container/filled_container.dart';
import 'package:anx_reader/widgets/common/tag_chip.dart';
import 'package:anx_reader/widgets/common/anx_segmented_button.dart';
import 'package:anx_reader/widgets/tips/bookshelf_tips.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icons_plus/icons_plus.dart';

class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key, this.controller});
  final ScrollController? controller;

  @override
  ConsumerState<BookshelfPage> createState() => BookshelfPageState();
}

class BookshelfPageState extends ConsumerState<BookshelfPage>
    with AutomaticKeepAliveClientMixin {
  late final _scrollController = widget.controller ?? ScrollController();
  final _gridViewKey = GlobalKey();
  bool _dragging = false;
  final GlobalKey _tagButtonKey = GlobalKey();
  final TextEditingController _editTagController = TextEditingController();
  final Set<int> _selectedBookIds = <int>{};
  bool _selectionMode = false;
  // Guard against double taps while the database reloads and the reader opens.
  bool _openingLastRead = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_recoverAutomaticVectorizationQueue());
  }

  Future<void> _recoverAutomaticVectorizationQueue() async {
    final prefs = Prefs();
    if (!prefs.vectorModelEnabled || !prefs.autoVectorizeOnImport) return;

    try {
      final books = await bookDao.selectNotDeleteBooks();
      final indexService = BookKnowledgeIndexService();
      final added = await enqueueMissingBooksForAutomaticIndexing(
        books: books,
        vectorModelEnabled: prefs.vectorModelEnabled,
        autoVectorizeOnImport: prefs.autoVectorizeOnImport,
        hasIndex: indexService.hasIndex,
        isBookAvailable: (book) => File(book.fileFullPath).existsSync(),
        shouldContinue: () =>
            mounted && prefs.vectorModelEnabled && prefs.autoVectorizeOnImport,
      );
      if (added > 0) {
        AnxLog.info('Recovered $added books into the vectorization queue');
      }
    } catch (error, stackTrace) {
      AnxLog.warning(
        'Failed to recover automatic vectorization queue: '
        '$error\n$stackTrace',
      );
    }
  }

  @override
  void dispose() {
    _editTagController.dispose();
    super.dispose();
  }

  /// Reopen the last book that was actually being read. The provider caches
  /// its first result, so reload it first: the user may have read a different
  /// book from the statistics dashboard or another tab since then.
  Future<void> _openLastReadBook() async {
    if (_openingLastRead) return;
    _openingLastRead = true;
    try {
      await ref.read(lastReadBookProvider.notifier).refresh();
      if (!mounted) return;
      final book = ref.read(lastReadBookProvider).valueOrNull?.book;
      if (book == null) {
        AnxToast.show(ModuStrings.text(
            context, '还没有可继续阅读的书籍', 'No book to continue reading yet'));
        return;
      }
      // Same entry point as tapping a cover: resumes at lastReadPosition and
      // keeps the linked-book / WebDAV availability checks intact.
      await pushToReadingPage(ref, context, book);
      if (!mounted) return;
      // Progress and reading-time rows change while the reader was open.
      await ref.read(bookListProvider.notifier).refresh();
      await ref.read(lastReadBookProvider.notifier).refresh();
    } finally {
      _openingLastRead = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final statusFilter = ref.watch(readingStatusFilterNotifierProvider);
    final selectedTags = ref.watch(tagSelectionProvider);
    final tagsAsync = ref.watch(tagListProvider);
    final booksAsync = ref.watch(bookListProvider);
    final lastReadBook = ref.watch(lastReadBookProvider).valueOrNull?.book;
    final listMode = Prefs().bookshelfListMode;
    final visibleBooks = booksAsync.valueOrNull
            ?.expand((group) => group)
            .toList(growable: false) ??
        const <Book>[];
    final selectedBooks = visibleBooks
        .where((book) => _selectedBookIds.contains(book.id))
        .toList(growable: false);

    void setBookSelected(Book book, bool selected) {
      setState(() {
        _selectionMode = true;
        if (selected) {
          _selectedBookIds.add(book.id);
        } else {
          _selectedBookIds.remove(book.id);
        }
      });
    }

    void exitSelectionMode() {
      setState(() {
        _selectionMode = false;
        _selectedBookIds.clear();
      });
    }

    Widget buildFilterBar() {
      final statusChips = [
        _StatusChip(
          label: L10n.of(context).bookshelfFilterFinished,
          selected: statusFilter == ReadingStatusFilter.finished,
          onTap: () {
            ref
                .read(readingStatusFilterNotifierProvider.notifier)
                .toggle(ReadingStatusFilter.finished);
            ref.read(bookListProvider.notifier).refresh();
          },
        ),
        _StatusChip(
          label: L10n.of(context).bookshelfFilterReading,
          selected: statusFilter == ReadingStatusFilter.reading,
          onTap: () {
            ref
                .read(readingStatusFilterNotifierProvider.notifier)
                .toggle(ReadingStatusFilter.reading);
            ref.read(bookListProvider.notifier).refresh();
          },
        ),
        _StatusChip(
          label: L10n.of(context).bookshelfFilterNotStarted,
          selected: statusFilter == ReadingStatusFilter.notStarted,
          onTap: () {
            ref
                .read(readingStatusFilterNotifierProvider.notifier)
                .toggle(ReadingStatusFilter.notStarted);
            ref.read(bookListProvider.notifier).refresh();
          },
        ),
      ];

      Future<void> showTagEditDialog(Tag tag) async {
        await TagChip.showEditDialog(
          context: context,
          initialName: tag.name,
          initialColor: tag.color ?? hashColor(tag.name),
          onRename: (newName) async {
            await ref
                .read(tagListProvider.notifier)
                .updateTag(tag.id, newName: newName);
            ref.read(bookListProvider.notifier).refresh();
          },
          onColorChange: (color) async {
            await ref
                .read(tagListProvider.notifier)
                .updateTag(tag.id, color: color);
            ref.read(bookListProvider.notifier).refresh();
          },
          onDelete: () async {
            await ref.read(tagListProvider.notifier).deleteTag(tag.id);
            if (selectedTags.contains(tag.id)) {
              ref.read(tagSelectionProvider.notifier).toggle(tag.id);
            }
            ref.read(bookListProvider.notifier).refresh();
          },
        );
      }

      Future<void> showTagMenu() async {
        final tags = tagsAsync.when(
          data: (value) => value,
          loading: () => const <Tag>[],
          error: (_, __) => const <Tag>[],
        );

        if (!context.mounted) return;

        final renderBox =
            _tagButtonKey.currentContext?.findRenderObject() as RenderBox?;
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox?;
        if (renderBox == null || overlay == null) return;

        final position = RelativeRect.fromRect(
          Rect.fromPoints(
            renderBox.localToGlobal(Offset.zero, ancestor: overlay),
            renderBox.localToGlobal(
              renderBox.size.bottomRight(Offset.zero),
              ancestor: overlay,
            ),
          ),
          Offset.zero & overlay.size,
        );

        final liveSelected = {...selectedTags};

        final boxMaxWidth = max(MediaQuery.of(context).size.width * 0.8, 500.0);

        await showMenu<int>(
          popUpAnimationStyle: AppMotion.style,
          color: Colors.transparent,
          shadowColor: Colors.transparent,
          context: context,
          position: position,
          constraints: BoxConstraints(maxHeight: 360, maxWidth: boxMaxWidth),
          items: [
            PopupMenuItem<int>(
              enabled: false,
              padding: EdgeInsets.zero,
              child: Align(
                alignment: Alignment.topRight,
                child: FilledContainer(
                  constraints:
                      BoxConstraints(maxHeight: 340, maxWidth: boxMaxWidth),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: StatefulBuilder(
                    builder: (context, setStateMenu) {
                      return SingleChildScrollView(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (tags.isEmpty)
                              Text(
                                L10n.of(context).tagsEmptyHint,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            // "No tag" virtual option - only show when there are tags
                            if (tags.isNotEmpty)
                              TagChip(
                                label: L10n.of(context).noTagFilter,
                                color: Colors.grey,
                                selected: liveSelected.contains(kNoTagFilterId),
                                onTap: () {
                                  setStateMenu(() {
                                    if (liveSelected.contains(kNoTagFilterId)) {
                                      liveSelected.remove(kNoTagFilterId);
                                    } else {
                                      // Mutual exclusion: clear other tags when selecting "no tag"
                                      liveSelected.clear();
                                      liveSelected.add(kNoTagFilterId);
                                    }
                                  });
                                  ref
                                      .read(tagSelectionProvider.notifier)
                                      .toggle(kNoTagFilterId);
                                  ref.read(bookListProvider.notifier).refresh();
                                },
                                dense: false,
                              ),
                            for (final tag in tags)
                              TagChip(
                                label: tag.name,
                                color: tag.color,
                                selected: liveSelected.contains(tag.id),
                                onTap: () {
                                  setStateMenu(() {
                                    if (liveSelected.contains(tag.id)) {
                                      liveSelected.remove(tag.id);
                                    } else {
                                      // Mutual exclusion: clear "no tag" when selecting a regular tag
                                      liveSelected.remove(kNoTagFilterId);
                                      liveSelected.add(tag.id);
                                    }
                                  });
                                  ref
                                      .read(tagSelectionProvider.notifier)
                                      .toggle(tag.id);
                                  ref.read(bookListProvider.notifier).refresh();
                                },
                                onLongPress: () {
                                  Navigator.of(context).pop();
                                  Future.microtask(
                                      () => showTagEditDialog(tag));
                                },
                                dense: false,
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      }

      final selectedTagWidgets = tagsAsync.when(
        data: (tags) {
          final tagMap = {for (final t in tags) t.id: t};
          final List<Widget> chips = [];

          // Display "no tag" chip
          if (selectedTags.contains(kNoTagFilterId)) {
            chips.add(Padding(
              padding: const EdgeInsets.only(left: 8),
              child: TagChip(
                label: L10n.of(context).noTagFilter,
                color: Colors.grey,
                selected: true,
                onTap: () {
                  ref
                      .read(tagSelectionProvider.notifier)
                      .toggle(kNoTagFilterId);
                  ref.read(bookListProvider.notifier).refresh();
                },
                dense: true,
              ),
            ));
          }

          // Display regular tag chips
          chips.addAll(selectedTags
              .where((id) => id != kNoTagFilterId)
              .map((id) => tagMap[id])
              .whereType<Tag>()
              .map((tag) => Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: TagChip(
                      label: tag.name,
                      color: tag.color,
                      selected: true,
                      onTap: () {
                        ref.read(tagSelectionProvider.notifier).toggle(tag.id);
                        ref.read(bookListProvider.notifier).refresh();
                      },
                      dense: true,
                    ),
                  )));

          return Row(children: chips);
        },
        loading: () => const SizedBox.shrink(),
        error: (_, __) => const SizedBox.shrink(),
      );

      return Container(
        height: 40,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 5),
        child: Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ...statusChips,
                    selectedTagWidgets,
                  ],
                ),
              ),
            ),
            IconButton(
              key: _tagButtonKey,
              icon: const Icon(EvaIcons.pricetags_outline, size: 22),
              tooltip: L10n.of(context).bookshelfFilterTagsTooltip,
              onPressed: showTagMenu,
            ),
          ],
        ),
      );
    }

    Widget buildBookshelfBody = booksAsync.when(
      data: (books) {
        return books.isEmpty
            ? const Center(child: BookshelfTips())
            : LayoutBuilder(builder: (context, constraints) {
                final padding = EdgeInsets.fromLTRB(
                    20,
                    12,
                    20,
                    12 +
                        MediaQuery.paddingOf(context).bottom +
                        HomeNavigationClearance.of(context));
                Widget buildEntry(int index) {
                  final group = books[index];
                  return BookFolder(
                    key: ValueKey<String>(group.first.groupId == 0
                        ? 'book:${group.first.id}'
                        : 'folder:${group.first.groupId}'),
                    books: group,
                    listMode: listMode,
                    selectionMode: _selectionMode,
                    selectedBookIds: _selectedBookIds,
                    selectedBooks: selectedBooks,
                    onSelectionChanged: setBookSelected,
                  );
                }

                if (listMode) {
                  return ListView.separated(
                    key: const ValueKey('bookshelf-list'),
                    controller: _scrollController,
                    padding: padding,
                    itemCount: books.length,
                    itemBuilder: (_, index) => buildEntry(index),
                    separatorBuilder: (_, __) => const Divider(height: 1),
                  );
                }
                const crossSpacing = 20.0;
                const mainSpacing = 30.0;
                // Shared with the opened-folder dialog: the column/row
                // settings must resolve to the same card geometry everywhere.
                final geometry = resolveBookshelfGridGeometry(
                  maxWidth: constraints.maxWidth,
                  viewportHeight: constraints.maxHeight.isFinite
                      ? constraints.maxHeight
                      : MediaQuery.sizeOf(context).height,
                  padding: padding,
                  crossSpacing: crossSpacing,
                  mainSpacing: mainSpacing,
                  preferredColumns: Prefs().bookshelfGridColumns,
                  rows: Prefs().bookshelfGridRows,
                  coverWidth: Prefs().bookCoverWidth,
                );
                return GridView(
                  key: _gridViewKey,
                  controller: _scrollController,
                  padding: padding,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: geometry.columns,
                    childAspectRatio: geometry.childAspectRatio,
                    mainAxisSpacing: mainSpacing,
                    crossAxisSpacing: crossSpacing,
                  ),
                  children: [
                    for (var index = 0; index < books.length; index++)
                      buildEntry(index),
                  ],
                );
              });
      },
      loading: () => const Center(
          child: EinkStaticIndicator(child: CircularProgressIndicator())),
      error: (error, stack) => Center(child: Text(error.toString())),
    );

    Widget body = Column(
      children: [
        if (!_selectionMode) buildFilterBar(),
        if (_selectionMode)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: BookSelectionActions(
              books: selectedBooks,
              onCompleted: exitSelectionMode,
            ),
          ),
        const _KnowledgeQueueBanner(),
        Expanded(
          child: DropTarget(
            onDragDone: (detail) async {
              setState(() {
                _dragging = false;
              });
              await pickBooksForImport(context, ref,
                  droppedPaths: detail.files.map((file) => file.path).toList());
            },
            onDragEntered: (detail) {
              setState(() {
                _dragging = true;
              });
            },
            onDragExited: (detail) {
              setState(() {
                _dragging = false;
              });
            },
            child: Stack(
              children: [
                buildBookshelfBody,
                // Compact "resume reading" button. It floats above the
                // centered home navigation bar instead of overlapping it:
                // the clearance is exactly the inset scroll views reserve.
                if (!_selectionMode && !_dragging && visibleBooks.isNotEmpty)
                  Positioned(
                    right: 16,
                    bottom: max(
                      16.0,
                      MediaQuery.paddingOf(context).bottom +
                          HomeNavigationClearance.of(context) +
                          8,
                    ),
                    child: _ContinueReadingButton(
                      title: lastReadBook?.title,
                      onPressed: _openLastReadBook,
                    ),
                  ),
                if (_dragging)
                  Container(
                    color: Theme.of(context).colorScheme.surface.withAlpha(90),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            EvaIcons.arrowhead_down_outline,
                            size: 48,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          Text(
                            L10n.of(context).bookshelfDragging,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    PreferredSizeWidget appBar = AppBar(
      forceMaterialTransparency: true,
      title: _selectionMode
          ? Text(ModuStrings.format(
              context, '已选 {count} 本', '{count} books selected',
              values: {'count': selectedBooks.length}))
          : Container(
              height: 34,
              constraints: const BoxConstraints(maxWidth: 400),
              child: FilledContainer(
                color: Theme.of(context).colorScheme.surface.withAlpha(80),
                child: InkWell(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const SearchPage(),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.search, color: Colors.grey),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            L10n.of(context).searchBooksOrNotes,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: Theme.of(context).hintColor),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
      actions: _selectionMode
          ? [
              TextButton(
                onPressed: visibleBooks.isEmpty
                    ? null
                    : () {
                        setState(() {
                          if (selectedBooks.length == visibleBooks.length) {
                            _selectedBookIds.clear();
                          } else {
                            _selectedBookIds
                              ..clear()
                              ..addAll(visibleBooks.map((book) => book.id));
                          }
                        });
                      },
                child: Text(
                  selectedBooks.length == visibleBooks.length &&
                          visibleBooks.isNotEmpty
                      ? ModuStrings.text(context, '取消全选', 'Deselect all')
                      : ModuStrings.text(context, '全选', 'Select all'),
                ),
              ),
              IconButton(
                tooltip: ModuStrings.text(context, '退出选择', 'Exit selection'),
                onPressed: exitSelectionMode,
                icon: const Icon(Icons.close),
              ),
            ]
          : [
              if (visibleBooks.isNotEmpty)
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectionMode = true;
                      _selectedBookIds.clear();
                    });
                  },
                  child: Text(ModuStrings.text(context, '选择', 'Select')),
                ),
              const SyncButton(),
              IconButton(
                key: const ValueKey('bookshelf-view-toggle'),
                tooltip: listMode
                    ? ModuStrings.text(
                        context, '切换为缩略图', 'Switch to thumbnails')
                    : ModuStrings.text(context, '切换为列表', 'Switch to list'),
                icon:
                    Icon(listMode ? Icons.grid_view : Icons.view_list_outlined),
                onPressed: () {
                  if (_scrollController.hasClients) _scrollController.jumpTo(0);
                  setState(() => Prefs().bookshelfListMode = !listMode);
                },
              ),
              PopupMenuButton<int>(
                popUpAnimationStyle: AppMotion.style,
                icon: const Icon(Icons.add),
                tooltip: ModuStrings.text(context, '添加书籍', 'Add books'),
                onSelected: (mode) {
                  if (mode == 4) {
                    // Directory library: browse a real folder and register
                    // the books in place. No staging, no copy, no import step.
                    Navigator.of(context)
                        .push<void>(MaterialPageRoute<void>(
                            builder: (_) => const LocalLibraryPage()))
                        .then((_) {
                      if (mounted) {
                        ref.read(bookListProvider.notifier).refresh();
                      }
                    });
                    return;
                  }
                  pickBooksForImport(context, ref,
                      folder: mode.isOdd, inPlace: mode >= 2);
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                      value: 4,
                      child: Text(ModuStrings.text(context,
                          '浏览目录加入书架（不导入）', 'Browse folder, add in place'))),
                  // The legacy copy-based importer stays available behind a
                  // setting because TXT/Markdown/UMD still need conversion.
                  if (!Prefs().hideLegacyImport) ...[
                    PopupMenuItem(
                        value: 0,
                        child: Text(ModuStrings.text(context,
                            '选择文件（复制导入，较慢）', 'Select files (copies files)'))),
                    PopupMenuItem(
                        value: 1,
                        child: Text(ModuStrings.text(context,
                            '导入文件夹（复制导入）', 'Import folder (copies files)'))),
                  ],
                  if (Platform.isIOS || Platform.isAndroid) ...[
                    PopupMenuItem(
                        value: 2,
                        child: Text(ModuStrings.text(context, '原位添加文件（不复制）',
                            'Add files in place (no copy)'))),
                    PopupMenuItem(
                        value: 3,
                        child: Text(ModuStrings.text(context, '原位添加文件夹（不复制）',
                            'Add folder in place (no copy)'))),
                  ],
                ],
              ),
              IconButton(
                  icon: const Icon(Icons.sort),
                  onPressed: () {
                    showMenu(
                      popUpAnimationStyle: AppMotion.style,
                      context: context,
                      position: RelativeRect.fromLTRB(
                        MediaQuery.of(context).size.width,
                        MediaQuery.of(context).padding.top + kToolbarHeight,
                        0.0,
                        0.0,
                      ),
                      items: [
                        for (var sortField in SortFieldEnum.values)
                          PopupMenuItem(
                              child: Text(
                                sortField.getL10n(context),
                                style: TextStyle(
                                  color: sortField == Prefs().sortField
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                              onTap: () {
                                Prefs().sortField = sortField;
                                ref.read(bookListProvider.notifier).refresh();
                              }),
                        PopupMenuItem(
                          enabled: false,
                          child: StatefulBuilder(builder: (_, setState) {
                            return Row(
                              children: [
                                Expanded(
                                  child: AnxSegmentedButton<SortOrderEnum>(
                                    onSelectionChanged: (value) {
                                      Prefs().sortOrder = value.first;
                                      ref
                                          .read(bookListProvider.notifier)
                                          .refresh();
                                      setState(() {});
                                    },
                                    segments: SortOrderEnum.values
                                        .map(
                                          (e) => SegmentButtonItem(
                                            value: e,
                                            label: e.getL10n(
                                                navigatorKey.currentContext!),
                                          ),
                                        )
                                        .toList(),
                                    selected: {Prefs().sortOrder},
                                  ),
                                ),
                              ],
                            );
                          }),
                        ),
                        PopupMenuItem(
                          enabled: false,
                          child: StatefulBuilder(builder: (_, setState) {
                            return SizedBox(
                              width: 240,
                              child: SwitchListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(ModuStrings.text(
                                    context, '最近阅读优先', 'Recent reads first')),
                                subtitle: Text(
                                  ModuStrings.text(
                                      context,
                                      '按文件名排序时，把最近读过的书放在最前',
                                      'Keep recently read books first when sorting by name'),
                                  maxLines: 2,
                                ),
                                value:
                                    Prefs().recentReadFirstWhenFileNameSort,
                                onChanged: (value) {
                                  Prefs().recentReadFirstWhenFileNameSort =
                                      value;
                                  ref
                                      .read(bookListProvider.notifier)
                                      .refresh();
                                  setState(() {});
                                },
                              ),
                            );
                          }),
                        ),
                      ],
                    );
                  }),
            ],
    );

    return PopScope(
        canPop: !_selectionMode,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _selectionMode) exitSelectionMode();
        },
        child: Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          appBar: appBar,
          body: body,
        ));
  }
}

/// Small bottom-right shortcut that opens the most recently read book.
/// A long press shows the book title through the built-in FAB tooltip.
class _ContinueReadingButton extends StatelessWidget {
  const _ContinueReadingButton({required this.title, required this.onPressed});

  final String? title;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final hasTitle = title != null && title!.trim().isNotEmpty;
    final tooltip = hasTitle
        ? ModuStrings.format(context, '继续阅读：{title}',
            'Continue reading: {title}',
            values: {'title': title!})
        : ModuStrings.text(context, '继续阅读最近读过的书',
            'Resume the last book you read');
    final eInk = Prefs().eInkMode;
    return FloatingActionButton.small(
      // Skip the FAB's own hero flight; the reader animates from the
      // matching book cover on the shelf instead.
      heroTag: null,
      tooltip: tooltip,
      elevation: eInk ? 0 : 3,
      focusElevation: eInk ? 0 : 4,
      hoverElevation: eInk ? 0 : 4,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
      onPressed: onPressed,
      child: const Icon(Icons.play_arrow_rounded, size: 24),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        labelPadding: const EdgeInsets.all(0),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        checkmarkColor: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

class _KnowledgeQueueBanner extends StatelessWidget {
  const _KnowledgeQueueBanner();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: bookKnowledgeIndexQueue,
      builder: (context, _) {
        final active = bookKnowledgeIndexQueue.activeItems;
        if (active.isEmpty) return const SizedBox.shrink();
        final current = bookKnowledgeIndexQueue.current ?? active.first;
        final queued = bookKnowledgeIndexQueue.queuedCount;
        final statusLabel = switch (current.status) {
          BookKnowledgeQueueStatus.queued => '等待开始',
          BookKnowledgeQueueStatus.extracting => '读取章节',
          BookKnowledgeQueueStatus.preparing => '整理章节',
          BookKnowledgeQueueStatus.vectorizing =>
            '生成向量 ${((current.progress ?? 0) * 100).round()}%',
          BookKnowledgeQueueStatus.cancelling => '正在取消',
          _ => '后台处理',
        };

        return Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.hub_outlined, size: 19),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '后台向量化：${current.book.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),
                    Text(
                        queued > 0
                            ? '$statusLabel · 排队 $queued 本'
                            : statusLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 5),
                    EinkStaticIndicator(
                        child:
                            LinearProgressIndicator(value: current.progress)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const StopVectorizationButton(compact: true),
            ],
          ),
        );
      },
    );
  }
}
