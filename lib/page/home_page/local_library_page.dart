import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/linked_books.dart';
import 'package:anx_reader/service/library_files/linked_book_registry.dart';
import 'package:anx_reader/utils/app_motion.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

/// Browses a real directory as a library. Files are registered as linked
/// books, so opening one never copies it into Modu's private storage.
class LocalLibraryPage extends ConsumerStatefulWidget {
  const LocalLibraryPage({super.key});

  @override
  ConsumerState<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends ConsumerState<LocalLibraryPage> {
  static const _rootKey = 'localDirectoryLibraryRoot';
  String? _root;
  bool _loading = true;
  String? _error;
  final Map<String, List<Book>> _groups = {};

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _t(String zh, String en) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _restoreRoot();
  }

  Future<void> _restoreRoot() async {
    final root = Prefs().prefs.getString(_rootKey);
    if (root == null || root.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    _root = root;
    await _scan();
  }

  Future<bool> _ensureAndroidAccess() async {
    if (!Platform.isAndroid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _t(
                '目录书库目前仅支持 Android。',
                'The directory library currently supports Android only.',
              ),
            ),
          ),
        );
      }
      return false;
    }
    if (await LinkedBooks.hasAllFilesAccess()) return true;
    if (!mounted) return false;
    final openSettings = await showDialog<bool>(
      animationStyle: AppMotion.style,
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('需要“所有文件访问权限”', 'All files access required')),
        content: Text(
          _t(
            '目录书库直接读取原文件，不复制到应用内，因此需要“所有文件访问权限”。请在系统设置中为默读开启后重试。',
            'The directory library reads original files in place, so Modu needs the “All files access” permission. Enable it in system settings and try again.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_t('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_t('去设置', 'Open settings')),
          ),
        ],
      ),
    );
    if (openSettings == true) await LinkedBooks.requestAllFilesAccess();
    return false;
  }

  Future<void> _pickRoot() async {
    if (!await _ensureAndroidAccess()) return;
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null || !mounted) return;
    if (!await Directory(path).exists()) {
      setState(
        () => _error = _t('无法访问所选目录', 'Selected directory is unavailable'),
      );
      return;
    }
    _root = path;
    await Prefs().prefs.setString(_rootKey, path);
    await _scan();
  }

  Future<void> _scan() async {
    final root = _root;
    if (root == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final groups = <String, List<Book>>{};
    var skipped = 0;
    try {
      final directory = Directory(root);
      if (!await directory.exists()) {
        throw FileSystemException('Directory missing', root);
      }
      final paths = <String>[];
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        final extension = p.extension(name).replaceFirst('.', '').toLowerCase();
        if (!LinkedBooks.extensions.contains(extension)) continue;
        paths.add(entity.path);
      }
      paths.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      final known = await LinkedBookRegistry.booksByPath();
      for (final path in paths) {
        try {
          final book = await LinkedBookRegistry.ensurePath(
            path,
            knownBooks: known,
          );
          var relative = p.relative(p.dirname(path), from: root);
          if (relative == '.') relative = '';
          final label = relative.isEmpty
              ? _t('根目录', 'Root')
              : relative.replaceAll(Platform.pathSeparator, ' / ');
          groups.putIfAbsent(label, () => []).add(book);
        } catch (error) {
          skipped++;
          AnxLog.warning('Directory library skipped $path: $error');
        }
      }
      if (!mounted) return;
      setState(() {
        _groups
          ..clear()
          ..addAll(groups);
        _loading = false;
        if (skipped > 0) {
          _error = _t(
            '$skipped 个文件无法读取，已跳过。',
            '$skipped files could not be read and were skipped.',
          );
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _t('目录扫描失败：$error', 'Directory scan failed: $error');
      });
    }
  }

  Future<void> _open(Book book) async {
    await pushToReadingPage(ref, context, book);
    if (!mounted) return;
    // Reading writes progress to the database; refresh just this row.
    try {
      final latest = await bookDao.selectBookById(book.id);
      if (!mounted) return;
      setState(() {
        for (final list in _groups.values) {
          final index = list.indexWhere((item) => item.id == latest.id);
          if (index != -1) list[index] = latest;
        }
      });
    } catch (_) {
      // The row may have been deleted while reading; the next scan reconciles.
    }
  }

  String _status(Book book) {
    if (book.readingPercentage >= 0.98) {
      return _t('已读完', 'Finished');
    }
    if (book.lastReadPosition.isNotEmpty || book.readingPercentage > 0.02) {
      return _t(
        '阅读中 ${(book.readingPercentage * 100).round()}%',
        'Reading ${(book.readingPercentage * 100).round()}%',
      );
    }
    return _t('未读', 'Unread');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_t('本地文件库', 'Local library')),
        actions: [
          IconButton(
            tooltip: _t('选择目录', 'Choose directory'),
            onPressed: _pickRoot,
            icon: const Icon(Icons.folder_open_outlined),
          ),
          IconButton(
            tooltip: _t('刷新', 'Refresh'),
            onPressed: _loading ? null : _scan,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_root == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_open, size: 56),
              const SizedBox(height: 12),
              Text(
                _t(
                  '选择一个存放书籍的目录，默读会直接读取原文件，不复制、不导入。',
                  'Choose a book folder. Modu reads the originals directly without copying or importing them.',
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _pickRoot,
                child: Text(_t('选择目录', 'Choose directory')),
              ),
            ],
          ),
        ),
      );
    }
    final children = <Widget>[];
    if (_error != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
    }
    if (_groups.isEmpty && _error == null) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _t('目录中没有支持的书籍文件。', 'No supported book files in this directory.'),
          ),
        ),
      );
    }
    for (final entry in _groups.entries) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: Text(
            entry.key,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ),
      );
      children.addAll(entry.value.map(_buildBookRow));
    }
    children.add(SizedBox(height: 24 + MediaQuery.paddingOf(context).bottom));
    return ListView(children: children);
  }

  Widget _buildBookRow(Book book) {
    final progress = book.readingPercentage.clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _open(book),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  height: 64,
                  child: BookCover(book: book, radius: 4),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _status(book),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: progress, minHeight: 3),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
