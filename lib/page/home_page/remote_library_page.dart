import 'package:anx_reader/widgets/settings/setting_help_title.dart';
import 'package:anx_reader/utils/app_motion.dart';
import 'package:anx_reader/l10n/modu_strings.dart';
import 'package:anx_reader/widgets/home_navigation_metrics.dart';

import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/home_page/local_library_page.dart';
import 'package:anx_reader/page/settings_page/remote_library.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/book_import_source.dart';
import 'package:anx_reader/widgets/bookshelf/book_import_picker.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/service/md5_service.dart';
import 'package:anx_reader/service/remote_library/webdav_library.dart';
import 'package:anx_reader/service/remote_library/library_view_options.dart';
import 'package:anx_reader/service/library_files/linked_book_registry.dart';
import 'package:anx_reader/utils/get_path/get_cache_dir.dart';
import 'package:anx_reader/widgets/remote_library_controls.dart';
import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart';
import 'package:anx_reader/utils/get_path/get_temp_dir.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class RemoteLibraryPage extends ConsumerStatefulWidget {
  const RemoteLibraryPage({super.key, this.clientFactory});
  final WebdavLibrary Function(LibraryConnection)? clientFactory;
  @override
  ConsumerState<RemoteLibraryPage> createState() => _RemoteLibraryPageState();
}

class _RemoteLibraryPageState extends ConsumerState<RemoteLibraryPage> {
  WebdavLibrary? _client;
  Uri? _directory;
  List<LibraryEntry> _entries = [];
  (List<LibraryEntry>, LibraryViewOptions, String)? _visibleKey;
  List<LibraryEntry> _visibleEntries = [];
  CancelToken? _listing, _download;
  String? _error, _activeName;
  String _filter = '';
  LibraryViewOptions _viewOptions = const LibraryViewOptions();
  bool _loading = true, _importing = false;
  int _received = 0, _total = -1;
  final _imported = <String>{};
  final Map<String, Book> _remoteProgress = {};
  bool get zh => Localizations.localeOf(context).languageCode == 'zh';
  String t(String cn, String en) => zh ? cn : en;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final options = await LibraryViewOptionsStore.load();
    if (!mounted) return;
    setState(() => _viewOptions = options);
    await _connect();
  }

  Future<void> _changeViewOptions(LibraryViewOptions options) async {
    setState(() => _viewOptions = options);
    try {
      await LibraryViewOptionsStore.save(options);
    } catch (_) {
      if (!mounted) return;
      _message(
        ModuStrings.text(
          context,
          '排序已生效，但无法保存到本机。',
          'Sorting applied, but preferences could not be saved.',
        ),
      );
    }
  }

  Future<void> _connect() async {
    final connection = await LibraryConnectionStore.load();
    if (!mounted) return;
    _listing?.cancel();
    _client?.close();
    _client = null;
    setState(() {
      _entries = [];
      _directory = null;
      _error = null;
    });
    if (connection == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      _client =
          widget.clientFactory?.call(connection) ?? WebdavLibrary(connection);
      await _browse(_client!.root);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = libraryError(error, zh, listing: true);
        });
      }
    }
  }

  Future<void> _browse(Uri directory) async {
    _listing?.cancel();
    final token = CancelToken();
    _listing = token;
    setState(() {
      _loading = true;
      _error = null;
      _directory = directory;
      _entries = [];
    });
    try {
      final entries = await _client!.list(directory, cancelToken: token);
      if (!mounted || token.isCancelled) return;
      setState(() {
        _entries = entries;
        _directory = directory;
      });
      try {
        final books = await LinkedBookRegistry.booksByPath();
        final progress = <String, Book>{};
        for (final entry in entries) {
          if (entry.isDirectory || !entry.isBook) continue;
          final file = await _cacheFileFor(entry);
          final book = books[file.path];
          if (book != null) progress[entry.uri.toString()] = book;
        }
        if (!mounted || token.isCancelled) return;
        setState(() {
          _remoteProgress
            ..clear()
            ..addAll(progress);
        });
      } catch (_) {
        // Progress decoration is optional; listing must still render.
      }
    } catch (error) {
      AnxLog.warning(
        'Remote library listing failed: ${error.runtimeType}'
        '${error is LibraryListingException ? ' (${error.reason})' : ''}'
        '${error is DioException ? ', HTTP ${error.response?.statusCode}' : ''}',
      );
      if (mounted && !token.isCancelled) {
        setState(() => _error = libraryError(error, zh, listing: true));
      }
    } finally {
      if (mounted && !token.isCancelled) setState(() => _loading = false);
    }
  }

  Future<void> _settings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(
              ModuStrings.text(context, '远程书库设置', 'Remote library settings'),
            ),
          ),
          body: const RemoteLibrarySettings(),
        ),
      ),
    );
    if (mounted) await _connect();
  }

  void _message(String value) {
    if (mounted) AnxToast.show(value, context: context);
  }

  Future<File> _cacheFileFor(LibraryEntry entry) async {
    final cacheRoot = Directory(
      '${(await getAnxCacheDir()).path}/remote-library',
    );
    await cacheRoot.create(recursive: true);
    final extension = entry.name.split('.').last.toLowerCase();
    final digest = sha1.convert(utf8.encode(entry.uri.toString())).toString();
    return File('${cacheRoot.path}/$digest.$extension');
  }

  Future<void> _getBook(LibraryEntry entry) async {
    if (_activeName != null) return;
    if (!Platform.isAndroid) {
      // Non-Android platforms have no raw-path link plugin yet; keep the
      // previous download-and-import behavior instead of failing at runtime.
      final token = CancelToken();
      _download = token;
      setState(() => _activeName = entry.name);
      try {
        final added = await _importEntry(entry, _client!, token);
        if (mounted) {
          _message(
            added
                ? t('已下载并导入本地书架。', 'Downloaded and imported to your bookshelf.')
                : t(
                    '书架中已存在这本书，无需重复导入。',
                    'This book is already available on your bookshelf.',
                  ),
          );
        }
      } catch (error) {
        if (mounted) _message(libraryError(error, zh));
      } finally {
        if (mounted) {
          setState(() {
            _activeName = null;
            _importing = false;
            _download = null;
          });
        }
      }
      return;
    }
    final token = CancelToken();
    _download = token;
    setState(() {
      _activeName = entry.name;
      _received = 0;
      _total = -1;
      _importing = false;
    });
    try {
      final file = await _cacheFileFor(entry);
      if (!await file.exists()) {
        final partial = File('${file.path}.part');
        if (await partial.exists()) await partial.delete();
        await _client!.download(entry, partial, token, (received, total) {
          if (mounted && (received == total || received % (256 * 1024) == 0)) {
            setState(() {
              _received = received;
              _total = total;
            });
          }
        });
        if (token.isCancelled) throw StateError('Cancelled');
        await partial.rename(file.path);
      }
      if (!mounted || token.isCancelled) return;
      final books = await LinkedBookRegistry.booksByPath();
      final book = await LinkedBookRegistry.ensurePath(
        file.path,
        knownBooks: books,
        title: entry.name,
      );
      if (!mounted) return;
      setState(() => _activeName = null);
      await pushToReadingPage(ref, context, book);
      if (mounted && _directory != null) await _browse(_directory!);
    } catch (error) {
      if (!mounted) return;
      _message(
        token.isCancelled
            ? t('下载已取消。', 'Download cancelled.')
            : libraryError(error, zh),
      );
    } finally {
      if (mounted) {
        setState(() {
          _activeName = null;
          _importing = false;
          _download = null;
        });
      }
    }
  }

  Future<bool> _importEntry(
    LibraryEntry entry,
    WebdavLibrary client,
    CancelToken token,
  ) async {
    final container = ProviderScope.containerOf(context, listen: false);
    Directory? temporary;
    try {
      temporary = await (await getAnxTempDir()).createTemp('modu-webdav-');
      // URI-derived immediate-child names are checked by the service, and the
      // unique staging directory prevents clobbering a user's local book.
      final localName = entry.name.replaceAll(
        RegExp(r'[<>:"/\\|?*\x00-\x1f]'),
        '_',
      );
      final file = File('${temporary.path}/$localName');
      final progressClock = Stopwatch()..start();
      await client.download(entry, file, token, (received, total) {
        if (mounted &&
            (progressClock.elapsedMilliseconds >= 100 || received == total)) {
          progressClock.reset();
          setState(() {
            _received = received;
            _total = total;
          });
        }
      });
      if (!mounted || token.isCancelled) throw StateError('Cancelled');
      setState(() => _importing = true);
      final hash = await MD5Service.calculateFileMd5(file.path);
      if (!mounted) throw StateError('Cancelled');
      final duplicate = hash == null
          ? null
          : await MD5Service.checkDuplicateByMd5(hash);
      if (!mounted) throw StateError('Cancelled');
      final alreadyPresent =
          duplicate != null &&
          !duplicate.isDeleted &&
          File(duplicate.fileFullPath).existsSync();
      if (!alreadyPresent) {
        await importBook(
          file,
          ref,
          onImported: () => container.read(bookListProvider.notifier).refresh(),
        );
      }
      if (mounted) setState(() => _imported.add(entry.uri.toString()));
      return !alreadyPresent;
    } finally {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
    }
  }

  Future<void> _getFolder(Uri directory) async {
    if (_activeName != null) return;
    final client = _client!;
    final token = CancelToken();
    _download = token;
    setState(() {
      _activeName = t('扫描文件夹（含子文件夹）', 'Scanning folder (including subfolders)');
      _received = 0;
      _total = -1;
    });
    var added = 0, skipped = 0, failed = 0;
    String? lastFailure;
    try {
      final entries = await client.discoverBooks(directory, cancelToken: token);
      if (!mounted || token.isCancelled) return;
      if (entries.isEmpty) {
        _message(t('没有找到支持的书籍文件', 'No supported books found'));
        return;
      }
      final byId = {for (final e in entries) e.uri.toString(): e};
      final selected = await showDialog<List<BookImportEntry>>(
        context: context,
        animationStyle: AppMotion.style,
        builder: (_) => BookImportSelection(
          entries: entries
              .map(
                (e) => BookImportEntry(
                  id: e.uri.toString(),
                  name: e.name,
                  label: e.uri.pathSegments
                      .skip(directory.pathSegments.length - 1)
                      .join('/'),
                ),
              )
              .toList(),
        ),
      );
      if (selected == null || !mounted || token.isCancelled) return;
      for (var i = 0; i < selected.length; i++) {
        if (!mounted || token.isCancelled) break;
        final entry = byId[selected[i].id]!;
        setState(() {
          _activeName = '${i + 1}/${selected.length} · ${entry.name}';
          _received = 0;
          _total = -1;
          _importing = false;
        });
        try {
          if (await _importEntry(entry, client, token)) {
            added++;
          } else {
            skipped++;
          }
        } catch (error) {
          if (token.isCancelled || !mounted) break;
          failed++;
          lastFailure = _importing
              ? t('书籍解析失败', 'Book import failed')
              : libraryError(error, zh);
        }
      }
      if (mounted) {
        _message(
          t(
            '${token.isCancelled ? '已取消。' : ''}导入 $added 本，重复跳过 $skipped 本，失败 $failed 本。${lastFailure ?? ''}',
            '${token.isCancelled ? 'Cancelled. ' : ''}Imported $added, skipped $skipped duplicates, failed $failed. ${lastFailure ?? ''}',
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        _message(
          token.isCancelled
              ? t('已取消文件夹扫描。', 'Folder scan cancelled.')
              : libraryError(error, zh, listing: true),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _activeName = null;
          _importing = false;
          _download = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _listing?.cancel();
    _download?.cancel();
    _client?.close();
    super.dispose();
  }

  String _size(int? bytes) => bytes == null
      ? '—'
      : bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';

  String _remoteStatus(LibraryEntry entry) {
    final book = _remoteProgress[entry.uri.toString()];
    if (book == null) {
      return ModuStrings.text(context, ' · 未读', ' · Unread');
    }
    if (book.readingPercentage >= 0.98) {
      return ModuStrings.text(context, ' · 已读完', ' · Finished');
    }
    if (book.lastReadPosition.isNotEmpty || book.readingPercentage > 0.02) {
      return ModuStrings.text(
        context,
        ' · 阅读中 ${(book.readingPercentage * 100).round()}%',
        ' · Reading ${(book.readingPercentage * 100).round()}%',
      );
    }
    return ModuStrings.text(context, ' · 未读', ' · Unread');
  }

  String _entrySubtitle(LibraryEntry entry) {
    final status = entry.isBook ? _remoteStatus(entry) : '';
    final info = entry.isDirectory
        ? ModuStrings.text(context, '文件夹', 'Folder')
        : '${_size(entry.size)}${entry.isBook ? '' : ModuStrings.text(context, ' · 不支持导入', ' · Import not supported')}$status';
    final date = switch (_viewOptions.sort) {
      LibrarySortField.createdAt => entry.createdAt,
      LibrarySortField.modifiedAt => entry.modifiedAt,
      _ => null,
    };
    if (_viewOptions.sort != LibrarySortField.createdAt &&
        _viewOptions.sort != LibrarySortField.modifiedAt) {
      return info;
    }
    final label = _viewOptions.sort == LibrarySortField.createdAt
        ? ModuStrings.text(context, '添加', 'Added')
        : ModuStrings.text(context, '修改', 'Modified');
    return '$info · $label: ${date == null ? ModuStrings.text(context, '未提供', 'Not provided') : DateFormat('yyyy-MM-dd HH:mm').format(date.toLocal())}';
  }

  @override
  Widget build(BuildContext context) {
    final directory = _directory;
    final root = _client?.root;
    final visibleKey = (_entries, _viewOptions, _filter);
    // Download progress must not re-sort a large directory on every repaint.
    if (_visibleKey != visibleKey) {
      _visibleKey = visibleKey;
      _visibleEntries = _viewOptions.apply(_entries, query: _filter);
    }
    final visible = _visibleEntries;
    return Scaffold(
      appBar: AppBar(
        title: Text(ModuStrings.text(context, '文件库', 'Library')),
        actions: [
          IconButton(
            tooltip: ModuStrings.text(context, '本地目录', 'Local folder'),
            onPressed: _activeName == null
                ? () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LocalLibraryPage(),
                      ),
                    );
                    if (mounted) await _connect();
                  }
                : null,
            icon: const Icon(Icons.folder_open_outlined),
          ),
          IconButton(
            tooltip: t('导入当前文件夹', 'Import current folder'),
            onPressed:
                _loading ||
                    _error != null ||
                    directory == null ||
                    _activeName != null
                ? null
                : () => _getFolder(directory),
            icon: const Icon(Icons.drive_folder_upload_outlined),
          ),
          IconButton(
            tooltip: ModuStrings.text(context, '刷新', 'Refresh'),
            onPressed: _loading
                ? null
                : () => directory == null ? _connect() : _browse(directory),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: ModuStrings.text(
              context,
              '远程书库设置',
              'Remote library settings',
            ),
            onPressed: _activeName == null ? _settings : null,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          if (root != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  IconButton(
                    tooltip: ModuStrings.text(context, '上一级', 'Parent folder'),
                    icon: const Icon(Icons.arrow_upward),
                    onPressed:
                        _loading || directory == null || directory == root
                        ? null
                        : () => _browse(directory.resolve('../')),
                  ),
                  TextButton(
                    onPressed: _loading ? null : () => _browse(root),
                    child: Text(ModuStrings.text(context, '根目录', 'Root')),
                  ),
                  Expanded(
                    child: SelectableText(
                      directory == null
                          ? '/'
                          : '/${directory.pathSegments.skip(root.pathSegments.length - 1).join('/')}',
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
            ),
          if (root != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                onChanged: (value) => setState(() => _filter = value),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: ModuStrings.text(
                    context,
                    '筛选当前目录中的文件',
                    'Filter files in this folder',
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          if (root != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: RemoteLibraryControls(
                options: _viewOptions,
                onChanged: _changeViewOptions,
              ),
            ),
          if (_activeName != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _importing
                              ? t(
                                  '正在导入：$_activeName',
                                  'Importing: $_activeName',
                                )
                              : '$_activeName · ${_size(_received)} / ${_size(_total < 0 ? null : _total)}',
                        ),
                      ),
                      TextButton(
                        onPressed: _importing
                            ? null
                            : () => _download?.cancel(),
                        child: Text(ModuStrings.text(context, '取消', 'Cancel')),
                      ),
                    ],
                  ),
                  EinkStaticIndicator(
                    child: LinearProgressIndicator(
                      value: _importing || _total <= 0
                          ? null
                          : (_received / _total).clamp(0, 1),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(
                    child: EinkStaticIndicator(
                      child: CircularProgressIndicator(),
                    ),
                  )
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: _activeName == null ? _settings : null,
                            child: Text(
                              ModuStrings.text(
                                context,
                                '检查连接设置',
                                'Check connection settings',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : root == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.folder_open_outlined, size: 64),
                        const SizedBox(height: 16),
                        Text(
                          ModuStrings.text(
                            context,
                            '连接 WebDAV，浏览远程目录并直接阅读；首次打开会缓存到本机。',
                            'Connect WebDAV to browse and read remote books directly; the first open is cached locally.',
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _settings,
                          child: Text(
                            ModuStrings.text(
                              context,
                              '配置书库 WebDAV',
                              'Configure library WebDAV',
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : visible.isEmpty
                ? Center(
                    child: Text(
                      ModuStrings.text(
                        context,
                        '当前目录没有匹配的文件。',
                        'No matching files in this folder.',
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.only(
                      bottom:
                          12 +
                          MediaQuery.paddingOf(context).bottom +
                          (_activeName == null
                              ? HomeNavigationClearance.of(context)
                              : 0),
                    ),
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final entry = visible[index];
                      final imported = _imported.contains(entry.uri.toString());
                      return ListTile(
                        key: ValueKey('library-entry:${entry.uri}'),
                        leading: Icon(
                          entry.isDirectory
                              ? Icons.folder_outlined
                              : entry.isBook
                              ? Icons.menu_book_outlined
                              : Icons.insert_drive_file_outlined,
                        ),
                        title: Text(entry.name),
                        subtitle: Text(_entrySubtitle(entry)),
                        onTap: entry.isDirectory
                            ? () => _browse(entry.uri)
                            : null,
                        trailing: entry.isDirectory
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: t('导入文件夹', 'Import folder'),
                                    onPressed: _activeName == null
                                        ? () => _getFolder(entry.uri)
                                        : null,
                                    icon: const Icon(Icons.download_outlined),
                                  ),
                                  const Icon(Icons.chevron_right),
                                ],
                              )
                            : !entry.isBook
                            ? null
                            : IconButton(
                                tooltip: imported
                                    ? ModuStrings.text(
                                        context,
                                        '本次已导入',
                                        'Imported this session',
                                      )
                                    : ModuStrings.text(
                                        context,
                                        '下载并导入书架',
                                        'Download and import',
                                      ),
                                onPressed: _activeName != null || imported
                                    ? null
                                    : () => _getBook(entry),
                                icon: Icon(
                                  imported
                                      ? Icons.check_circle_outline
                                      : Icons.download_outlined,
                                ),
                              ),
                      );
                    },
                  ),
          ),
          if (_activeName != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                8,
                8,
                8,
                8 + HomeNavigationClearance.of(context),
              ),
              child: SettingHelp(
                title: Text(ModuStrings.text(context, "下载", "Download")),
                description: Text(
                  ModuStrings.text(
                    context,
                    "下载完成前请保持此页打开。",
                    "Keep this page open until the download finishes.",
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
