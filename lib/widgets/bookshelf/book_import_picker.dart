import 'package:anx_reader/service/receive_file/external_book_inbox.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/app_motion.dart';
import 'dart:io';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/sync_status.dart';
import 'package:anx_reader/service/linked_books.dart';
import 'package:anx_reader/service/md5_service.dart';

import 'package:anx_reader/l10n/modu_strings.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/book_import_source.dart';
import 'package:anx_reader/utils/get_path/get_temp_dir.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

// One acquisition/selection flow at a time, including drops on a reading page.
bool _pickingBooks = false;

Future<void> pickBooksForImport(BuildContext context, WidgetRef ref,
    {bool folder = false,
    bool inPlace = false,
    List<String>? droppedPaths}) async {
  if (_pickingBooks) return;
  _pickingBooks = true;
  final mobileFolder = folder && (Platform.isAndroid || Platform.isIOS);
  try {
    if (droppedPaths != null) {
      final entries = await discoverBookImportFiles(droppedPaths);
      externalBookInbox.add(entries.map((entry) => entry.id));
      return;
    }
    if (inPlace && !LinkedBooks.supported) return;
    if (inPlace) {
      final allowed = await _ensureLinkedAccess(context);
      if (!allowed || !context.mounted) return;
    }
    List<BookImportEntry>? entries;
    if (inPlace) {
      entries = await _withImportProgress(
          context,
          () => MobileBookFolder.pick(
              files: !folder, extensions: LinkedBooks.extensions));
    } else if (mobileFolder) {
      entries = await _withImportProgress(context, MobileBookFolder.pick);
    } else if (folder) {
      final path = await FilePicker.platform.getDirectoryPath();
      if (path == null || !context.mounted) return;
      entries = await _withImportProgress(
          context, () => discoverBookImportFiles([path]));
    } else {
      final picked = await FilePicker.platform.pickFiles(
        // Mobile providers may not register MIME/UTI types for AZW3/FB2/MD.
        // Filter the returned names instead of hiding valid books in the picker.
        type: Platform.isAndroid || Platform.isIOS
            ? FileType.any
            : FileType.custom,
        allowedExtensions:
            Platform.isAndroid || Platform.isIOS ? null : allowBookExtensions,
        allowMultiple: true,
      );
      if (picked == null || !context.mounted) return;
      if (picked.files.any((e) => e.path == null)) {
        throw const FileSystemException(
            'Selected file is not available locally');
      }
      entries = await _withImportProgress(
          context,
          () => discoverBookImportFiles(
              picked.files.map((e) => e.path!).toList()));
    }
    if (entries == null || !context.mounted) return;
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ModuStrings.text(
              context,
              inPlace
                  ? '原位添加支持 EPUB、PDF、MOBI、AZW3、FB2；其他格式请用普通导入。'
                  : '没有找到支持的书籍文件',
              inPlace
                  ? 'In-place reading supports EPUB, PDF, MOBI, AZW3 and FB2. Use normal import for other formats.'
                  : 'No supported books found'))));
      return;
    }
    final selected = await showDialog<List<BookImportEntry>>(
      animationStyle: AppMotion.style,
      context: context,
      builder: (_) => BookImportSelection(entries: entries!, inPlace: inPlace),
    );
    if (selected == null || selected.isEmpty || !context.mounted) return;
    if (inPlace) {
      var failed = 0;
      await _withImportProgress(context, () async {
        for (final entry in selected) {
          String? key;
          try {
            key = await LinkedBooks.link(entry.id);
            final file = File(LinkedBooks.resolve(key)!);
            final md5 = await MD5Service.calculateFileMd5(file.path);
            if (md5 == null) {
              throw const FileSystemException('Cannot verify book');
            }
            final existing = await bookDao.getBookByMd5(md5);
            // Keep existing imported files and records; renew missing links only.
            if (existing != null &&
                !existing.isDeleted &&
                await File(existing.fileFullPath).exists()) {
              await LinkedBooks.forget(key);
              key = null;
              continue;
            }
            await getBookMetadata(file,
                md5: md5,
                linkedPath: key,
                sourceFormat: entry.name.split('.').last.toLowerCase());
            key = null; // The saved book now owns this bookmark.
          } catch (_) {
            failed++;
          } finally {
            if (key != null &&
                !(await bookDao.getCurrentBooks()).contains(key)) {
              await LinkedBooks.forget(key);
            }
          }
        }
        await ref.read(bookListProvider.notifier).refresh();
        ref.invalidate(syncStatusProvider);
      });
      if (failed > 0 && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ModuStrings.format(
                context,
                '{count} 本书未能添加，请检查文件和授权后重试。',
                '{count} books could not be added. Check files and access, then retry.',
                values: {'count': failed}))));
      }
      return;
    }
    final files = await _withImportProgress(
        context,
        () async => mobileFolder
            ? await MobileBookFolder.stage(selected)
            : await stageBookImportFiles(selected, await getAnxTempDir()));
    if (!context.mounted) {
      for (final file in files) {
        if (await file.exists()) await file.delete();
      }
      return;
    }
    importBookList(files, context, ref);
  } catch (error, stack) {
    if (droppedPaths != null) {
      AnxLog.severe('Dropped book import failed: $error\n$stack');
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ModuStrings.text(
              context,
              '无法读取所选文件或文件夹，请检查访问权限及文件是否已下载到本机后重试。',
              'Unable to read the selection. Check access and download cloud files locally, then try again.'))));
    }
  } finally {
    try {
      if (mobileFolder || inPlace) {
        await MobileBookFolder.release();
      }
    } finally {
      _pickingBooks = false;
    }
  }
}

/// Android reads linked books through real file paths, which requires the
/// special "All files access" grant on Android 11+ (the legacy storage
/// permission on older releases). The picker opens only after it is granted.
Future<bool> _ensureLinkedAccess(BuildContext context) async {
  if (!Platform.isAndroid) return true;

  final sdk = await LinkedBooks.androidSdkInt();
  if (sdk < 30) {
    final status = await Permission.storage.request();
    if (status.isGranted) return true;
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ModuStrings.text(
              context,
              '请允许“存储”权限后重试原位添加。',
              'Allow storage access, then try adding in place again.'))));
    }
    return false;
  }

  if (await LinkedBooks.hasAllFilesAccess()) return true;
  if (!context.mounted) return false;

  final openSettings = await showDialog<bool>(
    animationStyle: AppMotion.style,
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(ModuStrings.text(
          dialogContext, '需要“所有文件访问权限”', 'All files access required')),
      content: Text(ModuStrings.text(
          dialogContext,
          '“原位添加”直接读取原书、不复制文件，因此需要“所有文件访问权限”。\n\n请在系统设置中为默读开启该权限，返回后再次选择“原位添加”。原书不会被修改。',
          'Reading books in place opens the original file without copying it, so Modu needs the “All files access” permission.\n\nEnable it for Modu in system settings, come back and choose “Add in place” again. Originals are never modified.')),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(ModuStrings.text(dialogContext, '取消', 'Cancel'))),
        FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child:
                Text(ModuStrings.text(dialogContext, '去设置', 'Open settings'))),
      ],
    ),
  );
  if (openSettings == true) {
    await LinkedBooks.requestAllFilesAccess();
  }
  return false;
}

Future<T> _withImportProgress<T>(
    BuildContext context, Future<T> Function() work) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(children: [
              const EinkStaticIndicator(child: CircularProgressIndicator()),
              const SizedBox(width: 20),
              Expanded(
                  child: Text(
                      ModuStrings.text(context, '正在准备书籍…', 'Preparing books…')))
            ]),
          )));
  navigator.push(route);
  try {
    return await work();
  } finally {
    if (route.isActive) navigator.removeRoute(route);
  }
}

class BookImportSelection extends StatefulWidget {
  const BookImportSelection(
      {super.key, required this.entries, this.inPlace = false});
  final List<BookImportEntry> entries;
  final bool inPlace;
  @override
  State<BookImportSelection> createState() => _BookImportSelectionState();
}

class _BookImportSelectionState extends State<BookImportSelection> {
  late final selected = widget.entries.map((e) => e.id).toSet();
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(ModuStrings.text(
            context,
            widget.inPlace ? '原位添加书籍' : '选择要导入的书籍',
            widget.inPlace ? 'Add books in place' : 'Select books to import')),
        content: SizedBox(
            width: 520,
            height: MediaQuery.sizeOf(context).height * .55,
            child: ListView.builder(
                itemCount: widget.entries.length + 2,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Text(ModuStrings.text(
                        context,
                        widget.inPlace
                            ? '原位读取 EPUB、PDF、MOBI、AZW3、FB2，不复制原书。仅本机授权，不上传原书或包含在备份中；封面和索引仍占空间。移动或删除原文件可能导致无法阅读。TXT、Markdown、UMD 需使用普通导入以转换格式。'
                            : '支持 EPUB、MOBI、AZW3、FB2、PDF、TXT、Markdown、UMD。文件夹包含子文件夹，原文件保持不变。',
                        widget.inPlace
                            ? 'Read EPUB, PDF, MOBI, AZW3 and FB2 in place without copying. Access is device-local; originals are not uploaded or included in backups. Covers and indexes still use space. Moving or deleting originals can break access. Use normal import for TXT, Markdown and UMD conversion.'
                            : 'EPUB, MOBI, AZW3, FB2, PDF, TXT, Markdown and UMD. Includes subfolders; original files are kept.'));
                  }
                  if (index == 1) {
                    return CheckboxListTile(
                      title:
                          Text(ModuStrings.text(context, '全选', 'Select all')),
                      subtitle: Text(ModuStrings.format(
                          context, '已选 {count} 本', '{count} books selected',
                          values: {'count': selected.length})),
                      value: selected.length == widget.entries.length
                          ? true
                          : selected.isEmpty
                              ? false
                              : null,
                      tristate: true,
                      onChanged: (_) => setState(() {
                        if (selected.length == widget.entries.length) {
                          selected.clear();
                        } else {
                          selected.addAll(widget.entries.map((e) => e.id));
                        }
                      }),
                    );
                  }
                  final entry = widget.entries[index - 2];
                  return CheckboxListTile(
                      key: ValueKey(entry.id),
                      title: Text(entry.name),
                      subtitle: Text(entry.label),
                      value: selected.contains(entry.id),
                      onChanged: (value) => setState(() {
                            if (value == true) {
                              selected.add(entry.id);
                            } else {
                              selected.remove(entry.id);
                            }
                          }));
                })),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(ModuStrings.text(context, '取消', 'Cancel'))),
          FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      widget.entries
                          .where((e) => selected.contains(e.id))
                          .toList()),
              child: Text(ModuStrings.text(
                  context,
                  widget.inPlace ? '添加所选' : '导入所选',
                  widget.inPlace ? 'Add selected' : 'Import selected'))),
        ],
      );
}

/// Used by the reader as well as the bookshelf; directory drops use the same
/// safe staging pipeline, without picker confirmations or result dialogs.
class BookImportDropTarget extends ConsumerWidget {
  const BookImportDropTarget({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) => DropTarget(
        onDragDone: (detail) => pickBooksForImport(context, ref,
            droppedPaths: detail.files.map((e) => e.path).toList()),
        child: child,
      );
}
