import 'dart:async';
import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/page/home_page/remote_library_page.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/service/linked_books.dart';
import 'package:anx_reader/service/library_files/linked_book_registry.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/widgets/bookshelf/local_folder_sync_sheet.dart';
import 'package:anx_reader/widgets/home_navigation_metrics.dart';
import 'package:anx_reader/widgets/home_navigation_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

const String _groupByFolderKey = 'localBrowserGroupByFolder';

/// Browses the phone's real directories and adds selected books in place.
///
/// Unlike the old "directory library", no root folder is remembered and no
/// folder ever needs to be authorised again: with "All files access" granted
/// once, any directory on the device can be opened. Books are registered via
/// [LinkedBookRegistry.ensurePath], which keeps the original absolute path;
/// nothing is staged, copied or imported.
class LocalLibraryPage extends ConsumerStatefulWidget {
  const LocalLibraryPage({super.key});

  @override
  ConsumerState<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _FsEntry {
  const _FsEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size = 0,
    this.modified,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime? modified;
}

class _LocalLibraryPageState extends ConsumerState<LocalLibraryPage>
    with WidgetsBindingObserver {
  // A single long-press on a folder must not walk an unbounded tree.
  static const int _maxFolderScan = 2000;

  String _root = '';
  String _current = '';
  List<_FsEntry> _folders = const <_FsEntry>[];
  List<_FsEntry> _books = const <_FsEntry>[];
  bool _loading = true;
  String? _error;
  bool _accessGranted = !Platform.isAndroid;
  bool _checkingAccess = true;
  bool _groupByFolder = false;
  bool _scanning = false;
  bool _adding = false;
  int _progress = 0;
  int _progressTotal = 0;
  final Set<String> _selected = <String>{};
  bool _selectionMode = false;

  // The folders visited on the way to the current one. Back walks this stack,
  // so several quick back gestures move up several levels even while the
  // directory listing is still loading.
  final List<String> _history = <String>[];
  // Only the newest directory listing may write state. Otherwise a slower,
  // older listing could overwrite a newer destination.
  int _loadGeneration = 0;

  // When this page is the "Library" tab, the navigation shell owns the system
  // back gesture. Register a handler with it so the page can dismiss its
  // selection mode and walk up its own directory stack first; the shell only
  // switches back to the bookshelf when the browser is at the storage root.
  // Standalone pushed pages keep using their own PopScope below.
  final Object _backToken = Object();
  HomeBackRegistrar? _registerBack;

  bool get _shellOwnsBack => _registerBack != null;

  bool _consumeBack() {
    // A running add or folder scan is not a navigation step; do not let the
    // gesture interrupt it.
    if (_adding || _scanning) return true;
    if (_selectionMode) {
      _clearSelection();
      return true;
    }
    // Inside a subfolder, back goes up one level. Only at the storage root
    // does the shell turn the gesture into "go to the bookshelf".
    if (_canGoUp) {
      _goUp();
      return true;
    }
    return false;
  }

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _t(String zh, String en) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _groupByFolder = Prefs().prefs.getBool(_groupByFolderKey) ?? false;
    unawaited(_boot());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _registerBack = HomeBackDispatcher.of(context);
    _registerBack?.call(
      _backToken,
      HomeNavigationDestination.remoteLibrary,
      _consumeBack,
    );
  }

  @override
  void dispose() {
    _registerBack?.call(
      _backToken,
      HomeNavigationDestination.remoteLibrary,
      null,
    );
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The permission is granted in system settings; re-check on return.
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      unawaited(_resume());
    }
  }

  Future<void> _boot() async {
    final granted = await _checkAccess();
    if (!granted || !mounted) return;
    await _resolveRoot();
    await _load();
  }

  Future<void> _resume() async {
    final wasGranted = _accessGranted;
    final granted = await _checkAccess();
    if (granted && (!wasGranted || _root.isEmpty)) {
      if (_root.isEmpty) await _resolveRoot();
      await _load();
    }
  }

  Future<bool> _checkAccess() async {
    if (!Platform.isAndroid) {
      if (mounted) {
        setState(() {
          _checkingAccess = false;
          _accessGranted = true;
        });
      }
      return true;
    }
    var granted = false;
    try {
      granted = await LinkedBooks.hasAllFilesAccess();
    } catch (_) {
      granted = false;
    }
    if (mounted) {
      setState(() {
        _checkingAccess = false;
        _accessGranted = granted;
      });
    }
    return granted;
  }

  Future<void> _resolveRoot() async {
    if (!Platform.isAndroid) {
      _root = Directory.current.path;
      _current = _root;
      return;
    }
    var found = '';
    for (final candidate in <String>['/storage/emulated/0', '/sdcard']) {
      try {
        if (await Directory(candidate).exists()) {
          found = candidate;
          break;
        }
      } catch (_) {
        // A restricted mount must not hide the other candidates.
      }
    }
    _root = found.isEmpty ? '/storage/emulated/0' : found;
    _current = _root;
  }

  bool get _canGoUp =>
      _root.isNotEmpty && _current.isNotEmpty && _current != _root;

  /// Guards against ever browsing above the storage root.
  bool _underRoot(String path) {
    if (path == _root) return true;
    final prefix = _root.endsWith(Platform.pathSeparator)
        ? _root
        : _root + Platform.pathSeparator;
    return path.startsWith(prefix);
  }

  Future<void> _load({String? path}) async {
    final target = path ?? _current;
    if (target.isEmpty || !mounted) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    final folders = <_FsEntry>[];
    final books = <_FsEntry>[];
    var skipped = 0;
    String? loadError;
    try {
      final directory = Directory(target);
      if (!await directory.exists()) {
        throw FileSystemException('Directory missing', target);
      }
      await for (final entity in directory.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        try {
          if (entity is Directory) {
            folders.add(_FsEntry(
                path: entity.path, name: name, isDirectory: true));
          } else if (entity is File) {
            final extension =
                p.extension(name).replaceFirst('.', '').toLowerCase();
            if (!LinkedBooks.extensions.contains(extension)) continue;
            final stat = await entity.stat();
            books.add(_FsEntry(
              path: entity.path,
              name: name,
              isDirectory: false,
              size: stat.size,
              modified: stat.modified,
            ));
          }
        } catch (_) {
          skipped++;
        }
      }
    } catch (error) {
      loadError = _t('无法读取此目录：$error', 'Cannot read this folder: $error');
    }
    folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    books.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    // A newer navigation (a second back gesture, "up" or "root") wins; an
    // older listing must not overwrite the current destination.
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _current = target;
      _folders = folders;
      _books = books;
      _loading = false;
      if (loadError != null) {
        _error = loadError;
      } else if (skipped > 0) {
        _error = _t('$skipped 个条目无法访问，已跳过。',
            '$skipped items could not be accessed and were skipped.');
      }
    });
  }

  void _enter(_FsEntry folder) {
    if (_adding || _scanning) return;
    // Keep the pending selection: books from several folders can be added in
    // one pass, or one folder at a time on consecutive passes. Remember the
    // parent so a back gesture returns exactly here.
    _history.add(_current);
    unawaited(_load(path: folder.path));
  }

  void _goUp() {
    if (!_canGoUp || _adding || _scanning) return;
    final parent = _history.isNotEmpty
        ? _history.removeLast()
        : p.dirname(_current);
    if (parent.isEmpty || parent == _current) return;
    // An unexpected path must not escape the storage root.
    final target = _underRoot(parent) ? parent : _root;
    if (target == _current) return;
    unawaited(_load(path: target));
  }

  void _goRoot() {
    if (_adding || _scanning || _root.isEmpty) return;
    // Going to the root deliberately ends the browsing stack: the next back
    // gesture belongs to the navigation shell again.
    _history.clear();
    unawaited(_load(path: _root));
  }

  Future<void> _selectFolder(_FsEntry folder) async {
    if (_scanning || _adding) return;
    setState(() => _scanning = true);
    final found = <String>[];
    try {
      await for (final entity in Directory(folder.path)
          .list(recursive: true, followLinks: false)) {
        if (found.length >= _maxFolderScan) break;
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        final extension =
            p.extension(name).replaceFirst('.', '').toLowerCase();
        if (!LinkedBooks.extensions.contains(extension)) continue;
        found.add(entity.path);
      }
    } catch (error) {
      AnxLog.warning('Local browser folder scan failed: $error');
    }
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _selectionMode = true;
      _selected.addAll(found);
    });
    _toast(found.length >= _maxFolderScan
        ? _t('文件夹较大，已选取前 $_maxFolderScan 本书',
            'Large folder: selected the first $_maxFolderScan books')
        : _t('已选取 ${found.length} 本书', 'Selected ${found.length} books'));
  }

  void _toggle(String path) {
    if (_adding) return;
    setState(() {
      if (!_selected.remove(path)) _selected.add(path);
      _selectionMode = _selected.isNotEmpty;
    });
  }

  void _selectAllHere() {
    if (_adding) return;
    setState(() {
      _selected.addAll(_books.map((entry) => entry.path));
      _selectionMode = _selected.isNotEmpty;
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
      _selectionMode = false;
    });
  }

  Future<void> _openSyncSheet() async {
    if (_adding || _scanning) return;
    final changed = await showLocalFolderSyncSheet(
      context,
      currentPath: _current,
    );
    if (changed && mounted) await _load();
  }

  Future<void> _openWebdav() async {
    if (_adding) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => const RemoteLibraryPage(),
      ),
    );
    if (mounted) await _load();
  }

  // No context access here: this runs inside an async add loop.
  String _folderLabel(String path, String rootLabel) {
    final parent = p.dirname(path);
    var name = parent == _root ? rootLabel : p.basename(parent);
    if (name.isEmpty || name == '.' || name == Platform.pathSeparator) {
      name = rootLabel;
    }
    // tb_groups.name is capped at 100 characters by the DAO.
    return name.length > 100 ? name.substring(0, 100) : name;
  }

  Future<int?> _existingGroupId(String name) async {
    try {
      final db = await DBHelper().database;
      final rows = await db.query(
        'tb_groups',
        columns: <String>['id'],
        where: 'name = ? AND is_deleted = 0',
        whereArgs: <Object?>[name],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return int.tryParse(rows.first['id'].toString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _addSelected() async {
    if (_adding || _selected.isEmpty || !mounted) return;
    if (!Platform.isAndroid) {
      _toast(_t('原位添加仅支持 Android 设备。',
          'In-place adding is supported on Android only.'));
      return;
    }
    if (!await LinkedBooks.hasAllFilesAccess()) {
      _toast(_t('请先授予“所有文件访问权限”。',
          'Grant “All files access” first.'));
      await _checkAccess();
      return;
    }

    // Cache locale-dependent strings before entering the await loop so no
    // BuildContext is touched after an async gap.
    final bool isZh = _zh;
    final rootLabel = isZh ? '手机存储' : 'Phone storage';
    final paths = _selected.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    setState(() {
      _adding = true;
      _progress = 0;
      _progressTotal = paths.length;
    });

    var added = 0;
    var skipped = 0;
    var failed = 0;
    // Only newly inserted books are moved into folders: re-adding a book that
    // is already on the shelf must never silently change its existing folder.
    final newIdsByFolder = <String, List<int>>{};
    try {
      final known = await LinkedBookRegistry.booksByPath();
      final existingIds = known.values.map((book) => book.id).toSet();
      for (final path in paths) {
        try {
          final book = await LinkedBookRegistry.ensurePath(path,
              knownBooks: known);
          if (!existingIds.contains(book.id)) {
            added++;
            if (_groupByFolder) {
              newIdsByFolder
                  .putIfAbsent(_folderLabel(path, rootLabel), () => <int>[])
                  .add(book.id);
            }
          } else {
            skipped++;
          }
        } catch (error) {
          failed++;
          AnxLog.warning('Local browser could not add $path: $error');
        }
        if (mounted) {
          setState(() => _progress++);
        }
      }
      await ref.read(bookListProvider.notifier).refresh();
      for (final entry in newIdsByFolder.entries) {
        final groupId = await _existingGroupId(entry.key);
        await ref.read(bookListProvider.notifier).moveBooksToFolder(
              entry.value,
              groupId: groupId,
              newFolderName: groupId == null ? entry.key : null,
            );
      }
      if (newIdsByFolder.isNotEmpty) {
        await ref.read(bookListProvider.notifier).refresh();
      }
    } catch (error) {
      failed += paths.length - _progress;
      AnxLog.warning('Local browser add failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _adding = false;
          _selected.clear();
          _selectionMode = false;
        });
        final zhText = '已添加 $added 本' +
            (skipped > 0 ? '，已在书架 $skipped 本' : '') +
            (failed > 0 ? '，失败 $failed 本' : '');
        final enText = 'Added $added books' +
            (skipped > 0 ? ', $skipped already on the shelf' : '') +
            (failed > 0 ? ', $failed failed' : '');
        _toast(isZh ? zhText : enText);
        // Stay on this page: the next folder can be added right away.
      }
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(message), duration: const Duration(seconds: 3)));
  }

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _dateLabel(DateTime? value) {
    if (value == null) return '';
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  @override
  Widget build(BuildContext context) {
    // As a home tab the shell owns back; as a pushed route this page does.
    final shellOwnsBack = _shellOwnsBack;
    return PopScope(
      canPop: shellOwnsBack ? true : !_selectionMode && !_adding,
      onPopInvokedWithResult: (didPop, result) {
        if (shellOwnsBack) return;
        if (!didPop && !_adding && mounted) _clearSelection();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_current.isEmpty || _current == _root
              ? _t('文件库 · 手机目录', 'Library · Phone files')
              : p.basename(_current)),
          actions: <Widget>[
            IconButton(
              tooltip: _t('同步新增书籍', 'Sync new books'),
              onPressed: _loading || _adding || _scanning
                  ? null
                  : () => unawaited(_openSyncSheet()),
              icon: const Icon(Icons.sync),
            ),
            IconButton(
              tooltip: _t('WebDAV 书库', 'WebDAV library'),
              onPressed: _adding ? null : () => unawaited(_openWebdav()),
              icon: const Icon(Icons.cloud_outlined),
            ),
            IconButton(
              tooltip: _t('上一级', 'Parent folder'),
              onPressed: _canGoUp && !_adding ? _goUp : null,
              icon: const Icon(Icons.arrow_upward),
            ),
            PopupMenuButton<int>(
              icon: const Icon(Icons.more_vert),
              tooltip: _t('更多', 'More'),
              onSelected: (int value) {
                if (value == 0) _goRoot();
                if (value == 1) unawaited(_load());
                if (value == 2) unawaited(_openSyncSheet());
              },
              itemBuilder: (context) => <PopupMenuEntry<int>>[
                PopupMenuItem<int>(
                  value: 0,
                  child: Text(_t('返回存储根目录', 'Go to storage root')),
                ),
                PopupMenuItem<int>(
                  value: 1,
                  child: Text(_t('刷新', 'Refresh')),
                ),
                PopupMenuItem<int>(
                  value: 2,
                  child: Text(_t('管理同步文件夹 / 绑定当前目录',
                      'Manage sync folders / bind current')),
                ),
              ],
            ),
          ],
        ),
        bottomNavigationBar: _selectionMode ? _buildActionBar() : null,
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_checkingAccess) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_accessGranted) return _buildAccessGate();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildPathBar(),
        if (_scanning || _adding)
          LinearProgressIndicator(
            value: _adding && _progressTotal > 0
                ? _progress / _progressTotal
                : null,
          ),
        Expanded(child: _buildList()),
      ],
    );
  }

  Widget _buildAccessGate() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.folder_open, size: 56),
            const SizedBox(height: 12),
            Text(
              _t(
                '浏览本地文件需要“所有文件访问权限”。授权一次即可浏览手机上任意目录，不必逐个文件夹重新授权；原书不会被复制或修改。',
                'Browsing local files needs “All files access”. Grant it once to browse any folder on the device without authorising folders one by one. Originals are never copied or modified.',
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                await LinkedBooks.requestAllFilesAccess();
              },
              child: Text(_t('去设置', 'Open settings')),
            ),
            TextButton(
              onPressed: () async {
                final granted = await _checkAccess();
                if (granted && _root.isEmpty) await _resolveRoot();
                if (granted) await _load();
              },
              child: Text(_t('已授权，重试', 'I granted it, retry')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPathBar() {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: _goRoot,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
              child: Text(
                _current,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: Text(
              _t(
                '点文件夹进入浏览；轻点或长按书籍选取，长按文件夹可整夹选取。添加后不会退出，可继续添加下一个文件夹。顶栏的同步按钮可一键把各文件夹新增的书放进对应的书架文件夹。所有书籍直接读取原文件。',
                'Tap a folder to browse; tap or long-press books to select, long-press a folder to select the whole folder. Stay here after adding to pick the next folder. The sync button in the app bar adds newly arrived books to their matching shelf folders in one tap. Every book is read directly from its original file.',
              ),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).hintColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final folderCount = _folders.length;
    final bookCount = _books.length;
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: 16 +
            MediaQuery.paddingOf(context).bottom +
            HomeNavigationClearance.of(context),
      ),
      itemCount: folderCount + bookCount + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          if (_error == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          );
        }
        final item = index - 1;
        if (item == folderCount + bookCount) {
          if (_error != null || folderCount + bookCount > 0) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_t(
                '此目录没有子文件夹或支持的书籍文件（EPUB、PDF、MOBI、AZW3、FB2）。',
                'No subfolders or supported books (EPUB, PDF, MOBI, AZW3, FB2) here.')),
          );
        }
        if (item < folderCount) {
          return _folderTile(_folders[item]);
        }
        return _bookTile(_books[item - folderCount]);
      },
    );
  }

  Widget _folderTile(_FsEntry entry) {
    return ListTile(
      key: ValueKey<String>('d:${entry.path}'),
      leading: const Icon(Icons.folder_outlined),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_t('文件夹 · 长按选取整夹', 'Folder · long-press to select all'),
          style: Theme.of(context).textTheme.bodySmall),
      onTap: () => _enter(entry),
      onLongPress: () => unawaited(_selectFolder(entry)),
    );
  }

  Widget _bookTile(_FsEntry entry) {
    final selected = _selected.contains(entry.path);
    final date = _dateLabel(entry.modified);
    return ListTile(
      key: ValueKey<String>('f:${entry.path}'),
      leading: Icon(selected ? Icons.check_circle : Icons.book,
          color: selected ? Theme.of(context).colorScheme.primary : null),
      title: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${_sizeLabel(entry.size)}  ·  $date',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      selected: selected,
      onTap: () => _toggle(entry.path),
      onLongPress: () => _toggle(entry.path),
    );
  }

  Widget _buildActionBar() {
    final count = _selected.length;
    return SafeArea(
      child: Material(
        elevation: 6,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Padding(
          // Reserve the floating home bar's height when this page is a tab.
          padding: EdgeInsets.fromLTRB(
              16, 8, 16, 12 + HomeNavigationClearance.of(context)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _t('已选 $count 本', '$count books selected'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  TextButton(
                    onPressed: _adding ? null : _selectAllHere,
                    child: Text(_t('全选本目录', 'Select all here')),
                  ),
                  TextButton(
                    onPressed: _adding ? null : _clearSelection,
                    child: Text(_t('清空', 'Clear')),
                  ),
                ],
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _t('按文件夹名称生成书架文件夹',
                              'Create a shelf folder per source folder'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          _t('勾选后，每个来源文件夹会在书架生成同名文件夹',
                              'When on, each source folder becomes a same-named shelf folder'),
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _groupByFolder,
                    onChanged: _adding
                        ? null
                        : (bool value) {
                            setState(() => _groupByFolder = value);
                            unawaited(
                                Prefs().prefs.setBool(_groupByFolderKey, value));
                          },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _adding || count == 0
                    ? null
                    : () => unawaited(_addSelected()),
                icon: _adding
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: Text(_adding
                    ? _t('正在添加 $_progress/$_progressTotal …',
                        'Adding $_progress/$_progressTotal …')
                    : _t('加入书架（$count）', 'Add to bookshelf ($count)')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
