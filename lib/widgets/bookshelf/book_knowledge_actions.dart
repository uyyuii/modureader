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

/// A second, explicit confirmation for the irreversible option. It shows the
/// real path that is about to disappear, so a directory-linked book is never
/// deleted because of a mis-tapped radio button.
Future<bool> _confirmDeleteSource(
  BuildContext context,
  List<Book> books,
  List<String> sourcePaths,
) async {
  final target = books.length == 1
      ? '《${books.first.title}》'
      : '所选的 ${books.length} 本书';
  final ok = await showDialog<bool>(
    animationStyle: AppMotion.style,
    context: context,
    builder: (confirmContext) => AlertDialog(
      title: Text(ModuStrings.text(
          confirmContext, '确认删除原文件？', 'Delete original files?')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ModuStrings.format(
                confirmContext,
                '即将从设备上永久删除{target}的原文件，此操作不可恢复。',
                'This permanently deletes the source file of {target} from this device. This cannot be undone.',
                values: {'target': target},
              ),
            ),
            if (books.length == 1) ...[
              const SizedBox(height: 8),
              Text(
                sourcePaths.first,
                style: Theme.of(confirmContext).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(confirmContext).pop(false),
          child: Text(ModuStrings.text(confirmContext, '取消', 'Cancel')),
        ),
        TextButton(
          style: TextButton.styleFrom(
              foregroundColor: Theme.of(confirmContext).colorScheme.error),
          onPressed: () => Navigator.of(confirmContext).pop(true),
          child: Text(ModuStrings.text(
              confirmContext, '确认删除', 'Delete files')),
        ),
      ],
    ),
  );
  return ok == true;
}

Future<bool> confirmAndDeleteBooksFromBookshelf(
  BuildContext context,
  WidgetRef ref,
  Iterable<Book> books,
) async {
  final list = books.toList(growable: false);
  if (list.isEmpty) return false;

  final hasLinked = list.any((book) => LinkedBooks.isLinked(book.filePath));
  // Resolve once: linked books point at the real path on the device, normal
  // imports at the private copy inside the app's own storage.
  final sourcePaths = list.map((book) => book.fileFullPath).toList();
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
                    '请选择对{target}的处理方式。两种操作都会清除封面、阅读记录和本地索引。',
                    'Choose how to handle {target}. Both options clear covers, reading history and local indexes.',
                    values: {'target': target},
                  ),
                ),
                if (list.length == 1) ...[
                  const SizedBox(height: 8),
                  Text(
                    ModuStrings.text(dialogContext, '原文件：', 'File: ') +
                        sourcePaths.first,
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                ],
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
                      '从书架上移除（不删除原文件）',
                      'Remove from shelf (keep original file)',
                    ),
                  ),
                  subtitle: Text(
                    ModuStrings.text(
                      dialogContext,
                      '只删除书架记录，设备上的文件保持不动；普通导入的私有副本会继续占用应用存储。',
                      'Only the shelf record is removed and files stay untouched; private copies of normal imports still use app storage.',
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
                      '删除原文件',
                      'Delete original file',
                    ),
                  ),
                  subtitle: Text(
                    ModuStrings.text(
                      dialogContext,
                      '同时永久删除设备上的文件：目录直读／原位添加删的是原书，普通导入删的是应用内副本。不可恢复。',
                      'Also permanently deletes the file: the original for directory/in-place books, the private copy for normal imports. Cannot be undone.',
                    ),
                  ),
                ),
                if (hasLinked)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      ModuStrings.text(
                        dialogContext,
                        '所选书籍包含目录直读／原位添加的书，选择「删除原文件」会删掉你设备上的原书。',
                        'The selection contains directory-linked books; "Delete original file" removes the real books on this device.',
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
              onPressed: () async {
                if (mode == DeleteBookMode.deleteSource &&
                    !await _confirmDeleteSource(
                        dialogContext, list, sourcePaths)) {
                  return;
                }
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop(mode);
                }
              },
              child: Text(
                mode == DeleteBookMode.deleteSource
                    ? ModuStrings.text(
                        dialogContext,
                        '删除原文件并移除',
                        'Delete file & remove',
                      )
                    : ModuStrings.text(
                        dialogContext,
                        '确认移除',
                        'Remove',
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
  var deletedSourceFiles = 0;
  var missingSourceFiles = 0;
  for (final book in list) {
    await bookKnowledgeIndexQueue.cancelAndRemove(book.id);
    await bookDao.setDeleted(book.id, true);
    if (mode == DeleteBookMode.deleteSource) {
      // Linked books resolve this to the external original; normal imports to
      // their private copy. Report the outcome instead of claiming success
      // when the file is already gone or the OS refuses the delete.
      final source = File(book.fileFullPath);
      if (await source.exists()) {
        if (await _deleteIfPresent(source)) {
          deletedSourceFiles++;
        } else {
          failedDeletes++;
        }
      } else {
        missingSourceFiles++;
      }
    }
    await LinkedBooks.forget(book.filePath);
    if (!await _deleteIfPresent(File(book.coverFullPath))) failedDeletes++;
    await BookKnowledgeIndexService().deleteIndex(book);
  }
  await ref.read(bookListProvider.notifier).refresh();
  final base = mode == DeleteBookMode.deleteSource
      ? (list.length == 1 ? '书籍已从书架移除' : '已从书架移除 ${list.length} 本书')
      : (list.length == 1 ? '已移出书架，原文件保留' : '已移出 ${list.length} 本书，原文件保留');
  final details = <String>[
    if (deletedSourceFiles > 0) '已删除 $deletedSourceFiles 个原文件',
    if (missingSourceFiles > 0) '$missingSourceFiles 个原文件已不存在',
    if (failedDeletes > 0) '$failedDeletes 个文件删除失败（请检查「所有文件访问权限」）',
  ];
  AnxToast.show(details.isEmpty ? base : '$base；${details.join('，')}');
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
