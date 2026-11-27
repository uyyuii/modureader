import 'dart:async';

import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/tb_groups.dart';
import 'package:anx_reader/service/library_files/linked_book_registry.dart';
import 'package:anx_reader/service/library_files/local_folder_sync.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opens the incremental-sync panel. Returns true when books were added, so
/// the caller can reload its listing.
Future<bool> showLocalFolderSyncSheet(
  BuildContext context, {
  required String currentPath,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Material(
      color: Theme.of(sheetContext).colorScheme.surface,
      child: _LocalFolderSyncSheet(currentPath: currentPath),
    ),
  ).then<bool>((value) => value ?? false);
}

class _GroupChoice {
  const _GroupChoice(this.groupId, this.name, {this.create = false});

  final int groupId;
  final String name;
  final bool create;
}

class _LocalFolderSyncSheet extends ConsumerStatefulWidget {
  const _LocalFolderSyncSheet({required this.currentPath});

  final String currentPath;

  @override
  ConsumerState<_LocalFolderSyncSheet> createState() =>
      _LocalFolderSyncSheetState();
}

class _LocalFolderSyncSheetState
    extends ConsumerState<_LocalFolderSyncSheet> {
  List<LocalFolderBinding> _bindings = const <LocalFolderBinding>[];
  Map<String, int> _pending = const <String, int>{};
  Set<String> _checked = <String>{};
  bool _zh = true;
  bool _loading = true;
  bool _syncing = false;
  bool _synced = false;
  bool _recursive = false;
  int _done = 0;
  int _total = 0;
  String _currentFolder = '';
  FolderSyncOutcome? _outcome;
  String? _error;

  String _t(String zh, String en) => _zh ? zh : en;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _zh = Localizations.localeOf(context).languageCode == 'zh';
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  int get _selectedPending => _bindings
      .where((binding) => _checked.contains(binding.path))
      .fold<int>(0, (sum, binding) => sum + (_pending[binding.path] ?? 0));

  Future<void> _load({bool keepChecked = false}) async {
    if (!mounted) return;
    final previous = keepChecked ? Set<String>.from(_checked) : null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final recursive = LocalFolderSync.loadRecursive();
      final bindings = await LocalFolderSync.discover();
      final known = await LinkedBookRegistry.booksByPath();
      final knownPaths = known.keys.toSet();
      final pending = <String, int>{};
      for (final binding in bindings) {
        final files = await LocalFolderSync.newFiles(
          binding,
          knownPaths,
          recursive: recursive,
        );
        pending[binding.path] = files.length;
      }
      if (!mounted) return;
      setState(() {
        _recursive = recursive;
        _bindings = bindings;
        _pending = pending;
        _checked = previous == null
            ? <String>{for (final binding in bindings) binding.path}
            : <String>{
                for (final path in previous)
                  if (bindings.any((binding) => binding.path == path)) path,
              };
        _loading = false;
      });
    } catch (error) {
      AnxLog.warning('Folder sync panel load failed: $error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _toggleRecursive(bool value) async {
    if (_syncing) return;
    await LocalFolderSync.saveRecursive(value);
    await _load(keepChecked: true);
  }

  Future<void> _chooseGroup(LocalFolderBinding binding) async {
    if (_syncing) return;
    final Map<int, String> groups;
    try {
      groups = await LocalFolderSync.groupNames();
    } catch (error) {
      AnxLog.warning('Folder sync could not list shelf folders: $error');
      return;
    }
    final choice = await showDialog<_GroupChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('目标书架文件夹', 'Target shelf folder')),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ListTile(
                  title: Text(_t('书架根（不分组）', 'Bookshelf root (no folder)')),
                  onTap: () => Navigator.pop(
                      dialogContext, const _GroupChoice(0, '')),
                ),
                for (final entry in groups.entries)
                  if (entry.key != 0 && entry.value.isNotEmpty)
                    ListTile(
                      title: Text(entry.value,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(
                          dialogContext, _GroupChoice(entry.key, entry.value)),
                    ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: Text(
                    '${_t('新建同名文件夹：', 'Create folder: ')}${binding.title}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(
                    dialogContext,
                    _GroupChoice(-1, binding.title, create: true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    var groupId = choice.groupId;
    var name = choice.name;
    if (choice.create) {
      try {
        groupId = await LocalFolderSync.createGroup(choice.name);
        name = choice.name;
        ref.invalidate(groupDaoProvider);
      } catch (error) {
        AnxLog.warning('Folder sync could not create a shelf folder: $error');
        _toast(_t('创建书架文件夹失败。', 'Could not create the shelf folder.'));
        return;
      }
    }
    await LocalFolderSync.setGroup(binding.path, groupId, name);
    await _load(keepChecked: true);
  }

  Future<void> _bindCurrent() async {
    if (widget.currentPath.isEmpty || _syncing) return;
    var binding = LocalFolderBinding(
      path: widget.currentPath,
      groupId: 0,
      groupName: '',
      auto: false,
      enabled: true,
    );
    for (final item in _bindings) {
      if (item.path == widget.currentPath) {
        binding = item;
        break;
      }
    }
    await _chooseGroup(binding);
  }

  Future<void> _remove(LocalFolderBinding binding) async {
    if (_syncing) return;
    await LocalFolderSync.remove(binding.path);
    await _load(keepChecked: true);
  }

  Future<void> _startSync() async {
    if (_syncing) return;
    final selected = <LocalFolderBinding>[
      for (final binding in _bindings)
        if (_checked.contains(binding.path)) binding,
    ];
    final estimated = _selectedPending;
    if (selected.isEmpty || estimated == 0) {
      _toast(_t('没有发现新增书籍。', 'No new books found.'));
      return;
    }
    setState(() {
      _syncing = true;
      _done = 0;
      _total = estimated;
      _currentFolder = '';
      _outcome = null;
      _error = null;
    });
    try {
      final outcome = await LocalFolderSync.run(
        bindings: selected,
        recursive: _recursive,
        refreshShelf: () async {
          ref.invalidate(groupDaoProvider);
          await ref.read(bookListProvider.notifier).refresh();
        },
        onProgress: (done, total, folder) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
            _currentFolder = folder;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _synced = true;
      });
    } catch (error) {
      AnxLog.warning('Folder sync failed: $error');
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _syncing = false;
          _currentFolder = '';
        });
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

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.82;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildHeader(),
              const Divider(height: 1),
              Flexible(child: _buildContent()),
              const Divider(height: 1),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _t('同步本地文件夹的新书', 'Sync new books from local folders'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            _t(
              '只扫描已关联的文件夹，把新出现的书直接登记原文件并放进对应的书架文件夹；已在书架的书不会重复添加或移动。',
              'Only linked folders are scanned. New files are registered in place and put into their shelf folder; books already on the shelf are never added again or moved.',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _t('包含子文件夹', 'Include subfolders'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Switch(
                value: _recursive,
                onChanged: _syncing || _loading
                    ? null
                    : (value) => unawaited(_toggleRecursive(value)),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Text(
                _t('已关联 ${_bindings.length} 个文件夹',
                    '${_bindings.length} linked folders'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              TextButton(
                onPressed: _syncing || _loading || _bindings.isEmpty
                    ? null
                    : () => setState(() {
                          _checked = <String>{
                            for (final binding in _bindings) binding.path,
                          };
                        }),
                child: Text(_t('全选', 'Select all')),
              ),
              TextButton(
                onPressed: _syncing || _loading || _checked.isEmpty
                    ? null
                    : () => setState(() => _checked = <String>{}),
                child: Text(_t('全不选', 'Clear')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const Center(child: Padding(
        padding: EdgeInsets.all(24),
        child: CircularProgressIndicator(),
      ));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );
    }
    if (_bindings.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _t(
              '还没有可同步的文件夹。先在书架里通过「浏览本地文件」添加一批书，或用下方按钮把当前目录绑定到一个书架文件夹。',
              'No folders to sync yet. Add a batch of books through "Browse local files" first, or bind the current directory with the button below.',
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _bindings.length,
      itemBuilder: (context, index) => _buildRow(_bindings[index]),
    );
  }

  Widget _buildRow(LocalFolderBinding binding) {
    final pending = _pending[binding.path] ?? 0;
    final checked = _checked.contains(binding.path);
    return ListTile(
      key: ValueKey<String>(binding.path),
      contentPadding: const EdgeInsets.only(left: 8, right: 8),
      leading: Checkbox(
        value: checked,
        onChanged: _syncing
            ? null
            : (bool? value) => setState(() {
                  if (value == true) {
                    _checked.add(binding.path);
                  } else {
                    _checked.remove(binding.path);
                  }
                }),
      ),
      title: Text(
        '${binding.title}  →  ${binding.targetLabel(_t('书架根', 'Root'))}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${binding.path}\n'
        '${_t('待新增 $pending 本', '$pending new')}'
        '${binding.auto ? '  ·  ${_t('自动识别', 'auto-detected')}' : ''}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: _t('修改目标书架文件夹', 'Change target shelf folder'),
            onPressed: _syncing
                ? null
                : () => unawaited(_chooseGroup(binding)),
            icon: const Icon(Icons.edit),
          ),
          IconButton(
            tooltip: _t('移除关联', 'Remove this link'),
            onPressed: _syncing ? null : () => unawaited(_remove(binding)),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      onTap: _syncing
          ? null
          : () => setState(() {
                if (!_checked.remove(binding.path)) {
                  _checked.add(binding.path);
                }
              }),
    );
  }

  Widget _buildFooter() {
    final outcome = _outcome;
    final pending = _selectedPending;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_syncing) ...<Widget>[
            LinearProgressIndicator(
              value: _total > 0 ? (_done / _total).clamp(0.0, 1.0) : null,
            ),
            const SizedBox(height: 6),
            Text(
              _t('正在处理 $_done/$_total … $_currentFolder',
                  'Processing $_done/$_total … $_currentFolder'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (!_syncing && outcome != null) ...<Widget>[
            Text(
              _t(
                '已添加 ${outcome.added} 本，跳过 ${outcome.existing} 本，失败 ${outcome.failed} 本。',
                'Added ${outcome.added}, skipped ${outcome.existing}, failed ${outcome.failed}.',
              ),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (outcome.perFolder.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  outcome.perFolder.entries
                      .map((entry) =>
                          '${_folderName(entry.key)} +${entry.value}')
                      .join('   '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              if (widget.currentPath.isNotEmpty)
                TextButton.icon(
                  onPressed: _syncing ? null : () => unawaited(_bindCurrent()),
                  icon: const Icon(Icons.add),
                  label: Text(
                    _t('绑定当前目录', 'Bind current folder'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _syncing || _loading
                    ? null
                    : () {
                        if (_synced) {
                          Navigator.pop(context, true);
                        } else {
                          unawaited(_startSync());
                        }
                      },
                icon: Icon(_synced ? Icons.check : Icons.sync),
                label: Text(
                  _synced
                      ? _t('完成', 'Done')
                      : _t('同步全部（$pending）', 'Sync all ($pending)'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _folderName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    for (var i = parts.length - 1; i >= 0; i--) {
      if (parts[i].isNotEmpty) return parts[i];
    }
    return path;
  }
}
