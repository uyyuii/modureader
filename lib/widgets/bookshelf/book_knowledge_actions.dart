import 'package:anx_reader/utils/app_motion.dart';

import 'dart:io';

import 'package:anx_reader/service/linked_books.dart';
import 'package:anx_reader/l10n/modu_strings.dart';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/service/knowledge/book_knowledge_index_queue.dart';
import 'package:anx_reader/service/knowledge/book_knowledge_index_service.dart';
import 'package:anx_reader/service/knowledge/local_book_requirement.dart';
import 'package:anx_reader/service/knowledge/embedding_provider.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> queueBookForVectorization(
  Book book, {
  BookKnowledgeIndexQueue? queue,
  void Function(String)? showMessage,
}) async {
  final notify = showMessage ?? (message) => AnxToast.show(message);
  try {
    await requireLocalBookForIndexing(book);
    await EmbeddingProviderFactory.validateForBook(book);
  } on LocalBookRequiredException {
    notify('《${book.title}》${LocalBookRequiredException.message}');
    return;
  } on StateError catch (error) {
    notify(error.message);
    return;
  } on FormatException {
    notify('向量模型配置无效，请前往「设置 → 离线本地模型设置 → 向量模型」检查接口和模型配置');
    return;
  }
  final added = (queue ?? bookKnowledgeIndexQueue).enqueue(book);
  notify(added ? '《${book.title}》已加入向量化队列' : '《${book.title}》已在向量化队列中');
}

Future<void> queueBooksForVectorization(
  Iterable<Book> books, {
  BookKnowledgeIndexQueue? queue,
  void Function(String)? showMessage,
}) async {
  final notify = showMessage ?? (message) => AnxToast.show(message);
  // Count each book once, even when a selection contains duplicate records.
  final list = {for (final book in books) book.id: book}.values.toList();
  if (list.isEmpty) return;
  try {
    EmbeddingProviderFactory.requireEnabled();
  } on StateError catch (error) {
    notify(error.message);
    return;
  }
  final localBooks = <Book>[];
  var missing = 0;
  var unavailable = 0;
  final modelErrors = <String>{};
  for (final book in list) {
    try {
      await requireLocalBookForIndexing(book);
      await EmbeddingProviderFactory.validateForBook(book);
      localBooks.add(book);
    } on LocalBookRequiredException {
      // Continue with local books; missing files must not become failed jobs.
      missing++;
    } on StateError catch (error) {
      unavailable++;
      modelErrors.add(error.message);
    } on FormatException {
      unavailable++;
      modelErrors.add('向量模型配置无效，请前往「设置 → 离线本地模型设置 → 向量模型」检查接口和模型配置');
    }
  }
  // Batch validation can take time; do not enqueue if switched off meanwhile.
  try {
    EmbeddingProviderFactory.requireEnabled();
  } on StateError catch (error) {
    notify(error.message);
    return;
  }
  final added = (queue ?? bookKnowledgeIndexQueue).enqueueAll(localBooks);
  if (missing > 0 || unavailable > 0) {
    final queued = added > 0
        ? '已将 $added 本书加入向量化队列。'
        : localBooks.isNotEmpty
        ? '本地书籍已在队列中或队列暂不可用。'
        : '';
    notify(
      [
        queued,
        if (missing > 0) '已跳过 $missing 本尚未下载或本地文件不可用的书籍，请先下载后再向量化。',
        if (unavailable > 0)
          '已跳过 $unavailable 本向量模型不可用的书籍。${modelErrors.join('；')}',
      ].where((text) => text.isNotEmpty).join(),
    );
    return;
  }
  if (added == 0) {
    notify('所选书籍已在向量化队列中');
  } else {
    notify('已将 $added 本书加入向量化队列');
  }
}

enum DeleteBookMode { referenceOnly, deleteSource }

Future<bool> confirmAndDeleteBooksFromBookshelf(
  BuildContext context,
  WidgetRef ref,
  Iterable<Book> books,
) async {
  final list = books.toList(growable: false);
  if (list.isEmpty) return false;

  final hasLinked = list.any((book) => LinkedBooks.isLinked(book.filePath));
  var mode = DeleteBookMode.referenceOnly;

  final confirmed = await showDialog<DeleteBookMode>(
    animationStyle: AppMotion.style,
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) {
        final title = list.length == 1
            ? ModuStrings.text(dialogContext, '删除书籍', 'Delete book')
            : ModuStrings.format(
                dialogContext,
                '删除 {count} 本书',
                'Delete {count} books',
                values: {'count': list.length},
              );
        final target = list.length == 1
            ? '《${list.first.title}》'
            : '所选的 ${list.length} 本书';
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ModuStrings.format(
                    dialogContext,
                    '选择如何处理{target}的源文件。封面、阅读记录和本地索引都会被删除。',
                    'Choose what happens to the source file of {target}. Covers, reading history and local indexes are always removed.',
                    values: {'target': target},
                  ),
                ),
                const SizedBox(height: 8),
                RadioListTile<DeleteBookMode>(
                  value: DeleteBookMode.referenceOnly,
                  groupValue: mode,
                  onChanged: (value) {
                    if (value != null) setState(() => mode = value);
                  },
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    ModuStrings.text(
                      dialogContext,
                      '仅移出书架（保留源文件）',
                      'Remove from shelf only (keep source)',
                    ),
                  ),
                  subtitle: Text(
                    ModuStrings.text(
                      dialogContext,
                      '原位添加的书会保留设备上的原书；普通导入的私有副本会继续占用应用存储。',
                      'In-place originals stay on the device; normal imports keep their private copy and its storage usage.',
                    ),
                  ),
                ),
                RadioListTile<DeleteBookMode>(
                  value: DeleteBookMode.deleteSource,
                  groupValue: mode,
                  onChanged: (value) {
                    if (value != null) setState(() => mode = value);
                  },
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    ModuStrings.text(
                      dialogContext,
                      '移出书架并删除源文件',
                      'Remove and delete source file',
                    ),
                  ),
                  subtitle: Text(
                    ModuStrings.text(
                      dialogContext,
                      '永久删除设备上的源文件：原位添加的是原书，普通导入的是私有副本。此操作不可恢复。',
                      'Permanently delete the source on this device: the original for in-place books, the private copy for normal imports. This cannot be undone.',
                    ),
                  ),
                ),
                if (hasLinked)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      ModuStrings.text(
                        dialogContext,
                        '所选书籍包含“原位添加”的书，选择删除源文件会删除你设备上的原书。',
                        'The selection contains in-place books; deleting source files removes your original books from this device.',
                      ),
                      style: TextStyle(
                        color: Theme.of(dialogContext).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(ModuStrings.text(dialogContext, '取消', 'Cancel')),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: mode == DeleteBookMode.deleteSource
                    ? Colors.red
                    : null,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(mode),
              child: Text(
                mode == DeleteBookMode.deleteSource
                    ? ModuStrings.text(
                        dialogContext,
                        '删除源文件并移出',
                        'Delete file & remove',
                      )
                    : ModuStrings.text(
                        dialogContext,
                        '移出书架',
                        'Remove from shelf',
                      ),
              ),
            ),
          ],
        );
      },
    ),
  );
  if (confirmed == null) return false;

  await deleteBooksFromBookshelf(ref, list, mode: confirmed);
  return true;
}

/// Removes shelf records, queue work and the persisted knowledge index.
/// Only [DeleteBookMode.deleteSource] touches the book file itself, so removing
/// a reference never destroys an in-place original by accident.
Future<void> deleteBooksFromBookshelf(
  WidgetRef ref,
  Iterable<Book> books, {
  DeleteBookMode mode = DeleteBookMode.referenceOnly,
}) async {
  final list = books.toList(growable: false);
  var failedDeletes = 0;
  for (final book in list) {
    await bookKnowledgeIndexQueue.cancelAndRemove(book.id);
    await bookDao.setDeleted(book.id, true);
    if (mode == DeleteBookMode.deleteSource) {
      // Linked books resolve this to the external original; normal imports to
      // their private copy, so both choices stay explicit.
      if (!await _deleteIfPresent(File(book.fileFullPath))) failedDeletes++;
    }
    await LinkedBooks.forget(book.filePath);
    if (!await _deleteIfPresent(File(book.coverFullPath))) failedDeletes++;
    await BookKnowledgeIndexService().deleteIndex(book);
  }
  await ref.read(bookListProvider.notifier).refresh();
  final base = mode == DeleteBookMode.deleteSource
      ? (list.length == 1 ? '书籍及源文件已删除' : '已删除 ${list.length} 本书及其源文件')
      : (list.length == 1 ? '已移出书架，源文件保留' : '已移出 ${list.length} 本书，源文件保留');
  AnxToast.show(failedDeletes > 0 ? '$base；$failedDeletes 个文件删除失败' : base);
}

Future<bool> _deleteIfPresent(File file) async {
  try {
    if (await file.exists()) await file.delete();
    return true;
  } on Object catch (error, stackTrace) {
    AnxLog.severe('Failed to delete ${file.path}: $error\n$stackTrace');
    return false;
  }
}
