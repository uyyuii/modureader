import 'dart:io';
import 'dart:math' as math;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/reading_time.dart';
import 'package:anx_reader/l10n/modu_strings.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/book_source_format.dart';
import 'package:anx_reader/service/linked_books.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Read-only facts about a book, opened from the shelf's book menu.
///
/// Nothing here writes to the database, so it is safe for in-place/linked
/// books whose source lives outside the app's private storage. File lookups
/// and the reading-time query run asynchronously inside the dialog so the
/// popup menu closes immediately.
Future<void> showBookInfoDialog(BuildContext context, Book book) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _BookInfoDialog(book: book),
  );
}

class _BookInfoDialog extends StatefulWidget {
  const _BookInfoDialog({required this.book});

  final Book book;

  @override
  State<_BookInfoDialog> createState() => _BookInfoDialogState();
}

class _BookInfoDialogState extends State<_BookInfoDialog> {
  // Resolve once: rebuilding the dialog must not re-run the file/DB lookups.
  late final Future<_BookFacts> _facts = _loadFacts(widget.book);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_BookFacts>(
      future: _facts,
      builder: (context, snapshot) {
        final facts = snapshot.data;
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.info_outline, size: 22),
              const SizedBox(width: 8),
              Text(ModuStrings.text(context, '书籍信息', 'Book info')),
            ],
          ),
          content: facts == null
              ? const SizedBox(
                  width: 200,
                  height: 88,
                  child: Center(child: CircularProgressIndicator()),
                )
              : _buildContent(context, widget.book, facts),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(ModuStrings.text(context, '关闭', 'Close')),
            ),
          ],
        );
      },
    );
  }
}

class _BookFacts {
  const _BookFacts({
    required this.size,
    required this.modified,
    required this.available,
    required this.readingSeconds,
  });

  final int size;
  final DateTime? modified;
  final bool available;
  final int readingSeconds;
}

Future<_BookFacts> _loadFacts(Book book) async {
  var size = 0;
  DateTime? modified;
  var available = false;
  if (!kIsWeb) {
    try {
      final file = File(book.fileFullPath);
      if (file.existsSync()) {
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.file) {
          available = true;
          size = stat.size;
          modified = stat.modified;
        }
      }
    } catch (_) {
      // A linked original may have lost its URI permission, or the book is
      // cloud-only. Report "unavailable" instead of leaking an exception.
    }
  }

  var readingSeconds = 0;
  try {
    readingSeconds =
        await readingTimeDao.selectTotalReadingTimeByBookId(book.id);
  } catch (_) {
    // Statistics are best-effort; the dialog still shows the file facts.
  }

  return _BookFacts(
    size: size,
    modified: modified,
    available: available,
    readingSeconds: readingSeconds,
  );
}

Widget _buildContent(BuildContext context, Book book, _BookFacts facts) {
  final width = math.min(
      420.0, math.max(240.0, MediaQuery.sizeOf(context).width - 64));
  return SizedBox(
    width: width,
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(context, '书名', 'Title', book.title),
          _row(context, '作者', 'Author',
              book.author.trim().isEmpty ? '—' : book.author),
          _row(context, '格式', 'Format',
              BookSourceFormat(Prefs().prefs).format(book)),
          _row(
            context,
            '来源',
            'Source',
            LinkedBooks.isLinked(book.filePath)
                ? ModuStrings.text(context, '原位添加（不复制）', 'In-place (no copy)')
                : ModuStrings.text(context, '应用内导入', 'Imported into app'),
          ),
          _row(
            context,
            '文件大小',
            'File size',
            facts.available
                ? _formatSize(facts.size)
                : ModuStrings.text(context, '文件不可用', 'File unavailable'),
          ),
          _pathRow(context, book.fileFullPath),
          _row(
            context,
            '文件修改时间',
            'File modified',
            facts.modified == null
                ? '—'
                : DateFormat('yyyy-MM-dd HH:mm:ss')
                    .format(facts.modified!.toLocal()),
          ),
          _row(context, '阅读时长', 'Reading time',
              _duration(context, facts.readingSeconds)),
          _row(context, '导入时间', 'Imported',
              DateFormat('yyyy-MM-dd HH:mm').format(book.createTime.toLocal())),
          _row(context, '最近阅读', 'Last read',
              DateFormat('yyyy-MM-dd HH:mm').format(book.lastReadTime.toLocal())),
          _row(context, '阅读进度', 'Progress',
              '${(book.readingPercentage * 100).toStringAsFixed(1)}%'),
        ],
      ),
    ),
  );
}

Widget _row(BuildContext context, String zh, String en, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              ModuStrings.text(context, zh, en),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ],
    ),
  );
}

Widget _pathRow(BuildContext context, String path) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              ModuStrings.text(context, '文件路径', 'File path'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            path,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        InkWell(
          onTap: () {
            final message =
                ModuStrings.text(context, '路径已复制', 'Path copied');
            Clipboard.setData(ClipboardData(text: path));
            AnxToast.show(message, context: context);
          },
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(
              Icons.copy,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ],
    ),
  );
}

String _duration(BuildContext context, int seconds) {
  if (seconds <= 0) {
    return ModuStrings.text(context, '暂无统计', 'No reading time yet');
  }
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours == 0) {
    return ModuStrings.format(context, '{minutes} 分钟', '{minutes} min',
        values: {'minutes': minutes});
  }
  return ModuStrings.format(
    context,
    '{hours} 小时 {minutes} 分钟',
    '{hours} h {minutes} min',
    values: {'hours': hours, 'minutes': minutes},
  );
}

String _formatSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
  final i = math.min(
      suffixes.length - 1, (math.log(bytes) / math.log(1024)).floor());
  return '${(bytes / math.pow(1024, i)).toStringAsFixed(2)} ${suffixes[i]}';
}
