import 'dart:io';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/book_import_source.dart';
import 'package:anx_reader/service/linked_books.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = 'file/ios-linked-test.epub';
  late Directory root;
  late File original;
  late Map<String, String> bookmarks;
  final calls = <MethodCall>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('modu-linked-books-');
    documentPath = '${root.path}/private';
    await Directory('$documentPath/file').create(recursive: true);
    original = await File('${root.path}/original.epub').writeAsString('book');
    bookmarks = {key: original.path};
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LinkedBooks.channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'restoreLinks':
          return bookmarks;
        case 'link':
          return {'key': key, 'path': original.path};
        case 'forgetLink':
          bookmarks.remove(call.arguments['key']);
          return null;
        case 'pick':
          return <dynamic>[];
      }
      throw MissingPluginException();
    });
    await LinkedBooks.restore();
  });
  tearDown(() async {
    bookmarks.clear();
    await LinkedBooks.restore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LinkedBooks.channel, null);
    documentPath = '';
    await root.delete(recursive: true);
  });

  test('link reads original without copying or serializing external paths',
      () async {
    final linked = await LinkedBooks.link('selected-1');
    final book = Book.mock().copyWith(filePath: linked);
    expect(book.fileFullPath, original.path);
    expect(await File(book.fileFullPath).readAsString(), 'book');
    expect(await getFileDir().list().toList(), isEmpty);
    expect(book.toMap()['file_path'], key);
    expect(book.toMap().values, isNot(contains(original.path)));
    expect(getBasePath(key), isNot(original.path));
  });

  test(
      'restore follows refreshed paths; revoked access falls back only to owned storage',
      () async {
    final book = Book.mock().copyWith(filePath: key);
    final moved = await original.rename('${root.path}/moved.epub');
    bookmarks[key] = moved.path;
    await LinkedBooks.restore();
    expect(book.fileFullPath, moved.path);
    bookmarks.clear();
    await LinkedBooks.restore();
    expect(book.fileFullPath, getBasePath(key));
    expect(await File(book.fileFullPath).exists(), false);
    expect(await moved.readAsString(), 'book');
  });

  test('forget removes only bookmark, preserving original bytes', () async {
    await LinkedBooks.forget(key);
    expect(LinkedBooks.resolve(key), isNull);
    expect(bookmarks, isEmpty);
    expect(await original.readAsString(), 'book');
    expect(await getFileDir().list().toList(), isEmpty);
    calls.clear();
    await LinkedBooks.forget('file/ordinary.epub');
    expect(calls, isEmpty);
  });

  test('recognizes Android linked keys and forgets them', () async {
    const androidKey = 'file/android-linked-abc.epub';
    bookmarks[androidKey] = original.path;
    await LinkedBooks.restore();
    expect(LinkedBooks.isLinked(androidKey), isTrue);
    expect(LinkedBooks.resolve(androidKey), original.path);
    await LinkedBooks.forget(androidKey);
    expect(bookmarks.containsKey(androidKey), isFalse);
    expect(LinkedBooks.resolve(androidKey), isNull);
    calls.clear();
    await LinkedBooks.forget('file/plain.epub');
    expect(calls, isEmpty);
  });

  test(
      'in-place picker uses direct formats while ordinary folder import is unchanged',
      () async {
    await MobileBookFolder.pick(
        files: true, extensions: LinkedBooks.extensions);
    expect(calls.last.arguments['files'], true);
    expect(calls.last.arguments['extensions'],
        ['epub', 'pdf', 'mobi', 'azw3', 'fb2']);
    await MobileBookFolder.pick();
    expect(calls.last.arguments['files'], false);
    expect(calls.last.arguments['extensions'], contains('txt'));
    expect(calls.any((call) => call.method == 'copy'), false);
  });
}
