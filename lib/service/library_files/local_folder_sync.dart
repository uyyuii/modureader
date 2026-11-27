import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/service/linked_books.dart';
import 'package:anx_reader/service/library_files/linked_book_registry.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:path/path.dart' as p;

const String localFolderSyncBindingsKey = 'localFolderSyncBindings';
const String localFolderSyncIgnoredKey = 'localFolderSyncIgnored';
const String localFolderSyncRecursiveKey = 'localFolderSyncRecursive';

/// One real directory on the phone mapped to one folder on the bookshelf.
///
/// Books are never copied: a binding only says "new files found here belong
/// to that shelf folder".
class LocalFolderBinding {
  const LocalFolderBinding({
    required this.path,
    required this.groupId,
    required this.groupName,
    required this.auto,
    required this.enabled,
  });

  final String path;

  /// 0 means the bookshelf root; any other value is a tb_groups row id.
  final int groupId;
  final String groupName;

  /// true: inferred from books already on the shelf (no stored override).
  /// false: explicitly pinned by the user.
  final bool auto;
  final bool enabled;

  String get title {
    final name = p.basename(path);
    return name.isEmpty ? path : name;
  }

  String targetLabel(String rootLabel) =>
      groupId == 0 ? rootLabel : (groupName.isEmpty ? '#$groupId' : groupName);

  LocalFolderBinding copyWith({
    int? groupId,
    String? groupName,
    bool? auto,
    bool? enabled,
  }) =>
      LocalFolderBinding(
        path: path,
        groupId: groupId ?? this.groupId,
        groupName: groupName ?? this.groupName,
        auto: auto ?? this.auto,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'groupId': groupId,
        'groupName': groupName,
        'enabled': enabled,
      };

  static LocalFolderBinding? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    final groupId = raw['groupId'];
    return LocalFolderBinding(
      path: path,
      groupId: groupId is int ? groupId : 0,
      groupName: raw['groupName'] is String ? raw['groupName'] as String : '',
      auto: false,
      enabled: raw['enabled'] != false,
    );
  }
}

class FolderSyncOutcome {
  const FolderSyncOutcome({
    required this.added,
    required this.existing,
    required this.failed,
    required this.perFolder,
  });

  final int added;
  final int existing;
  final int failed;

  /// New book count keyed by source directory path.
  final Map<String, int> perFolder;
}

/// Incremental "add the new books" for directory-linked libraries.
///
/// The mapping is deliberately zero-configuration: any directory that already
/// has linked books on the shelf is a candidate, and the shelf folder holding
/// most of those books becomes its target. Users can override or remove any
/// candidate, and overrides survive restarts in SharedPreferences.
class LocalFolderSync {
  /// Hard cap per directory: a long-press on a huge tree must not walk it all.
  static const int maxFilesPerFolder = 2000;

  static List<LocalFolderBinding> _readPinned() {
    try {
      final raw = Prefs().prefs.getString(localFolderSyncBindingsKey);
      if (raw == null || raw.isEmpty) return <LocalFolderBinding>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <LocalFolderBinding>[];
      final result = <LocalFolderBinding>[];
      for (final item in decoded) {
        final binding = LocalFolderBinding.fromJson(item);
        if (binding != null) result.add(binding);
      }
      return result;
    } catch (_) {
      return <LocalFolderBinding>[];
    }
  }

  static Set<String> _readIgnored() {
    try {
      final raw = Prefs().prefs.getString(localFolderSyncIgnoredKey);
      if (raw == null || raw.isEmpty) return <String>{};
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded.whereType<String>().toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> _writePinned(
      Iterable<LocalFolderBinding> bindings) async {
    await Prefs().prefs.setString(
          localFolderSyncBindingsKey,
          jsonEncode(<Object?>[
            for (final binding in bindings) binding.toJson(),
          ]),
        );
  }

  static Future<void> _writeIgnored(Set<String> ignored) async {
    await Prefs().prefs.setString(
          localFolderSyncIgnoredKey,
          jsonEncode(ignored.toList()),
        );
  }

  static bool loadRecursive() =>
      Prefs().prefs.getBool(localFolderSyncRecursiveKey) ?? false;

  static Future<void> saveRecursive(bool value) async {
    await Prefs().prefs.setBool(localFolderSyncRecursiveKey, value);
  }

  static Future<Map<int, String>> groupNames() async {
    final result = <int, String>{0: ''};
    try {
      final db = await DBHelper().database;
      final rows = await db.query(
        'tb_groups',
        columns: <String>['id', 'name'],
        where: 'is_deleted = 0',
      );
      for (final row in rows) {
        final id = int.tryParse(row['id'].toString());
        if (id != null) result[id] = row['name']?.toString() ?? '';
      }
    } catch (error) {
      AnxLog.warning('Folder sync could not read shelf folders: $error');
    }
    return result;
  }

  static Future<int> createGroup(String name) async {
    final db = await DBHelper().database;
    final now = DateTime.now().toIso8601String();
    return db.insert('tb_groups', <String, Object?>{
      'name': name,
      'parent_id': 0,
      'is_deleted': 0,
      'create_time': now,
      'update_time': now,
    });
  }

  /// Pinned bindings first, then every directory inferred from the shelf.
  static Future<List<LocalFolderBinding>> discover() async {
    final names = await groupNames();
    final pinned = _readPinned();
    final ignored = _readIgnored();
    final inferred = <String, Map<int, int>>{};

    try {
      final books = await bookDao.selectNotDeleteBooks();
      for (final book in books) {
        // Imported copies live in the app's private directory and are not
        // sources for incremental sync; only original-path links count.
        if (!LinkedBooks.isLinked(book.filePath)) continue;
        final full = book.fileFullPath;
        if (full.isEmpty || !p.isAbsolute(full)) continue;
        final parent = p.dirname(full);
        final counts = inferred.putIfAbsent(parent, () => <int, int>{});
        counts[book.groupId] = (counts[book.groupId] ?? 0) + 1;
      }
    } catch (error) {
      AnxLog.warning('Folder sync could not inspect the shelf: $error');
    }

    final result = <LocalFolderBinding>[];
    final pinnedPaths = <String>{};
    for (final binding in pinned) {
      pinnedPaths.add(binding.path);
      // A deleted shelf folder must not leave a broken target behind.
      final valid = binding.groupId == 0 || names.containsKey(binding.groupId)
          ? binding.groupId
          : 0;
      result.add(binding.copyWith(
        groupId: valid,
        groupName: valid == 0 ? '' : (names[valid] ?? ''),
      ));
    }
    for (final entry in inferred.entries) {
      if (pinnedPaths.contains(entry.key) || ignored.contains(entry.key)) {
        continue;
      }
      final groupId = _majority(entry.value);
      result.add(LocalFolderBinding(
        path: entry.key,
        groupId: groupId,
        groupName: groupId == 0 ? '' : (names[groupId] ?? ''),
        auto: true,
        enabled: true,
      ));
    }
    result.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return result;
  }

  /// Most common shelf folder among the books already in that directory.
  /// Ties prefer a real folder over the bookshelf root.
  static int _majority(Map<int, int> counts) {
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        if (a.key == 0) return 1;
        if (b.key == 0) return -1;
        return a.key.compareTo(b.key);
      });
    return entries.isEmpty ? 0 : entries.first.key;
  }

  static Future<void> pin(LocalFolderBinding binding) async {
    final next = <LocalFolderBinding>[
      for (final item in _readPinned())
        if (item.path != binding.path) item,
      binding.copyWith(auto: false, enabled: true),
    ];
    await _writePinned(next);
    final ignored = _readIgnored()..remove(binding.path);
    await _writeIgnored(ignored);
  }

  static Future<void> remove(String path) async {
    final next = <LocalFolderBinding>[
      for (final item in _readPinned())
        if (item.path != path) item,
    ];
    await _writePinned(next);
    // Also ignore it, otherwise an inferred candidate would reappear at once.
    final ignored = _readIgnored()..add(path);
    await _writeIgnored(ignored);
  }

  static Future<void> setGroup(
    String path,
    int groupId,
    String groupName,
  ) async {
    var base = LocalFolderBinding(
      path: path,
      groupId: 0,
      groupName: '',
      auto: false,
      enabled: true,
    );
    for (final binding in await discover()) {
      if (binding.path == path) {
        base = binding;
        break;
      }
    }
    await pin(base.copyWith(groupId: groupId, groupName: groupName));
  }

  /// Book files in [binding] that are not registered on the shelf yet.
  static Future<List<String>> newFiles(
    LocalFolderBinding binding,
    Set<String> knownPaths, {
    required bool recursive,
  }) async {
    final directory = Directory(binding.path);
    final found = <String>[];
    try {
      if (!await directory.exists()) return found;
      await for (final entity in directory.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (found.length >= maxFilesPerFolder) break;
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        final extension =
            p.extension(name).replaceFirst('.', '').toLowerCase();
        if (!LinkedBooks.extensions.contains(extension)) continue;
        final absolute = File(entity.path).absolute.path;
        if (knownPaths.contains(absolute)) continue;
        found.add(entity.path);
      }
    } catch (error) {
      AnxLog.warning('Folder sync scan failed for ${binding.path}: $error');
    }
    return found;
  }

  /// Register every new file in place and put only those new rows into the
  /// bound shelf folder. Books already on the shelf are never moved.
  static Future<FolderSyncOutcome> run({
    required List<LocalFolderBinding> bindings,
    required bool recursive,
    required Future<void> Function() refreshShelf,
    void Function(int done, int total, String folder)? onProgress,
  }) async {
    final known = await LinkedBookRegistry.booksByPath();
    final knownIds = <int>{for (final book in known.values) book.id};
    final knownPaths = known.keys.toSet();
    final jobs = <String, LocalFolderBinding>{};
    for (final binding in bindings) {
      if (!binding.enabled) continue;
      final files = await newFiles(binding, knownPaths, recursive: recursive);
      for (final file in files) {
        final absolute = File(file).absolute.path;
        // The first binding wins when recursive scanning reaches a file that
        // also belongs to another bound directory.
        jobs.putIfAbsent(absolute, () => binding);
      }
    }

    final paths = jobs.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    var added = 0;
    var existing = 0;
    var failed = 0;
    final newIdsByGroup = <int, List<int>>{};
    final perFolder = <String, int>{};

    for (var index = 0; index < paths.length; index++) {
      final path = paths[index];
      final binding = jobs[path]!;
      onProgress?.call(index, paths.length, binding.title);
      try {
        final book =
            await LinkedBookRegistry.ensurePath(path, knownBooks: known);
        if (!knownIds.contains(book.id)) {
          added++;
          knownIds.add(book.id);
          newIdsByGroup
              .putIfAbsent(binding.groupId, () => <int>[])
              .add(book.id);
          perFolder[binding.path] = (perFolder[binding.path] ?? 0) + 1;
        } else {
          existing++;
        }
      } catch (error) {
        failed++;
        AnxLog.warning('Folder sync could not add $path: $error');
      }
    }
    onProgress?.call(paths.length, paths.length, '');

    for (final entry in newIdsByGroup.entries) {
      // groupId 0 is the bookshelf root, where new books already land.
      if (entry.key == 0) continue;
      try {
        await bookDao.moveBooksToFolder(entry.value, groupId: entry.key);
      } catch (error) {
        AnxLog.warning(
            'Folder sync could not move books into ${entry.key}: $error');
      }
    }
    await refreshShelf();
    return FolderSyncOutcome(
      added: added,
      existing: existing,
      failed: failed,
      perFolder: perFolder,
    );
  }
}
