import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/utils/import_book.dart' show saveImageBytesToLocal;
import 'package:anx_reader/utils/log/common.dart';
import 'package:archive/archive_io.dart' hide ZLibDecoder;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

typedef _CoverBytes = ({Uint8List bytes, String extension});

/// Extracts a cover directly from the book file on disk, without a WebView.
///
/// The old cover-only path went through `getBookMetadata(coverOnly: true)`,
/// which creates a headless WebView whose bootstrap unconditionally fetches
/// the *whole book* into a browser Blob (see `book.js` `loadBook`). Chromium
/// spills large Blobs to `app_webview/default/blob_storage/<uuid>`, so a
/// directory scan of a few hundred books produced hundreds of megabytes of
/// random-name files. This extractor never opens a WebView:
///  * EPUB: read only the zip central directory plus the one cover entry.
///  * PDF:  render page 1 with Android's system PdfRenderer via a method
///          channel; the app never loads the PDF into a WebView for this.
///
/// Writing still goes through [saveImageBytesToLocal], so the configurable
/// cover size/quality, the `cover/<id>-<ts>` naming and the sync/WebDAV paths
/// are identical to a normal import.
class LightweightCoverExtractor {
  LightweightCoverExtractor._();

  static const MethodChannel _channel =
      MethodChannel('com.modu.reader/book_folder');

  /// A cover is one small picture, never a whole book. Refuse oversized
  /// entries so a malformed epub cannot balloon memory.
  static const int _maxImageBytes = 24 * 1024 * 1024;

  /// The startup legacy repair and the cover widget's lazy request can target
  /// the same row at the same time. Share the work so only one file is written.
  static final Map<int, Future<String?>> _inFlight =
      <int, Future<String?>>{};

  /// Returns the database-relative cover path, or null when the format is
  /// unsupported or the book has no usable embedded cover.
  static Future<String?> extract({
    required String fileFullPath,
    required int bookId,
  }) {
    final pending = _inFlight[bookId];
    if (pending != null) return pending;
    final future = _extract(fileFullPath: fileFullPath, bookId: bookId);
    _inFlight[bookId] = future;
    return future.whenComplete(() => _inFlight.remove(bookId));
  }

  static Future<String?> _extract({
    required String fileFullPath,
    required int bookId,
  }) async {
    if (bookId <= 0 || !await File(fileFullPath).exists()) return null;
    final format = p.extension(fileFullPath).replaceFirst('.', '').toLowerCase();
    Uint8List? bytes;
    var imageExtension = 'jpg';
    try {
      switch (format) {
        case 'epub':
          final found = await _epubCover(fileFullPath);
          if (found == null) return null;
          bytes = found.bytes;
          imageExtension = found.extension;
          break;
        case 'pdf':
          bytes = await _pdfCover(fileFullPath);
          break;
        default:
          // mobi / azw3 / fb2 need their own parsers. Falling back to a
          // WebView here would recreate the blob_storage problem, so keep
          // the generated text placeholder instead.
          return null;
      }
    } catch (error) {
      AnxLog.warning('Lightweight cover extraction failed: $error');
      return null;
    }
    if (bytes == null || bytes.isEmpty) return null;
    // `image` cannot decode SVG. The old path wrote such covers as
    // `*.svg+xml`, a file Flutter's FileImage can never display.
    try {
      if (img.decodeImage(bytes) == null) return null;
    } catch (_) {
      return null;
    }
    final name = 'cover/$bookId-${DateTime.now().microsecondsSinceEpoch}';
    return saveImageBytesToLocal(bytes, name, extension: imageExtension);
  }

  /// Read the publication title/creator from an EPUB OPF without a WebView.
  ///
  /// The file browser registers books in bulk; starting `getBookMetadata`
  /// for each one would fetch the whole book into a Chromium Blob and
  /// recreate the `blob_storage` blow-up. Only the zip central directory
  /// and the two small XML entries are inflated here.
  static Future<({String? title, String? author})?> readEpubMetadata(
    String path,
  ) async {
    if (p.extension(path).toLowerCase() != '.epub') return null;
    final input = InputFileStream(path);
    try {
      final zip = ZipDirectory.read(input);
      final headers = <String, ZipFileHeader>{};
      for (final header in zip.fileHeaders) {
        final name = _normalize(header.filename);
        if (name.isNotEmpty && !name.endsWith('/')) headers[name] = header;
      }
      if (headers.isEmpty) return null;

      var opfPath = 'OEBPS/content.opf';
      final container = await _text(headers, 'META-INF/container.xml');
      if (container != null) {
        try {
          final doc = XmlDocument.parse(container);
          for (final node in doc.descendants.whereType<XmlElement>()) {
            if (node.name.local != 'rootfile') continue;
            final fullPath = node.getAttribute('full-path');
            if (fullPath != null && fullPath.isNotEmpty) {
              opfPath = _normalize(fullPath);
            }
            break;
          }
        } catch (_) {
          // Fall back to the conventional path / scanning for *.opf.
        }
      }
      final opf =
          await _text(headers, opfPath) ?? await _firstOpfText(headers);
      if (opf == null) return null;

      try {
        final doc = XmlDocument.parse(opf);
        for (final metadata in doc.descendants.whereType<XmlElement>()) {
          if (metadata.name.local != 'metadata') continue;
          String? title;
          final authors = <String>[];
          for (final node in metadata.children.whereType<XmlElement>()) {
            final local = node.name.local.toLowerCase();
            final prefix = (node.name.prefix ?? '').toLowerCase();
            if (local != 'title' && local != 'creator') continue;
            // Dublin Core is the normal case; accept unprefixed elements in
            // the few OPFs that declare a default DC namespace.
            if (prefix.isNotEmpty && prefix != 'dc') continue;
            final value = node.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
            if (value.isEmpty) continue;
            if (local == 'title') {
              title ??= _usableTitle(value);
            } else if (authors.length < 8 && !authors.contains(value)) {
              authors.add(value);
            }
          }
          return (
            title: title,
            author: authors.isEmpty ? null : authors.join(', '),
          );
        }
      } catch (_) {
        // A malformed OPF is not fatal: callers keep the file-name fallback.
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      await input.close();
    }
  }

  static String? _usableTitle(String value) =>
      value.toLowerCase() == 'unknown' ? null : value;

  // ---------------------------------------------------------------------------
  // PDF: first page via Android's system renderer (API 21+). No Dart PDF
  // package exists in this project and the WebView route is what we are
  // removing, so a tiny platform channel is the only complete option.
  // ---------------------------------------------------------------------------
  static Future<Uint8List?> _pdfCover(String path) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('renderPdfCover', {
        'path': path,
        'maxWidth': 600,
      });
    } catch (error) {
      AnxLog.warning('PDF first-page cover unavailable: $error');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // EPUB: only the zip central directory and the chosen cover entry are read.
  // ---------------------------------------------------------------------------
  static Future<_CoverBytes?> _epubCover(String path) async {
    final input = InputFileStream(path);
    try {
      final zip = ZipDirectory.read(input);
      final headers = <String, ZipFileHeader>{};
      for (final header in zip.fileHeaders) {
        final name = _normalize(header.filename);
        if (name.isNotEmpty && !name.endsWith('/')) headers[name] = header;
      }
      if (headers.isEmpty) return null;

      var opfPath = 'OEBPS/content.opf';
      final container = await _text(headers, 'META-INF/container.xml');
      if (container != null) {
        try {
          final doc = XmlDocument.parse(container);
          for (final node in doc.descendants.whereType<XmlElement>()) {
            if (node.name.local != 'rootfile') continue;
            final fullPath = node.getAttribute('full-path');
            if (fullPath != null && fullPath.isNotEmpty) {
              opfPath = _normalize(fullPath);
            }
            break;
          }
        } catch (_) {
          // Fall back to the conventional path / scanning for *.opf.
        }
      }
      final opf =
          await _text(headers, opfPath) ?? await _firstOpfText(headers);
      if (opf == null) return null;

      final candidates = _coverCandidates(opf, opfPath);
      // The loop uses an index because an XHTML cover page appends the image
      // referenced from inside it, which must then be tried as well.
      for (var i = 0; i < candidates.length; i++) {
        final candidate = candidates[i];
        final extension = _imageExtension(candidate);
        if (extension == null) {
          for (final src in await _imagesInCoverPage(headers, candidate)) {
            final resolved = _resolveHref(src, candidate);
            if (!candidates.contains(resolved)) candidates.add(resolved);
          }
          continue;
        }
        final key = _matchEntry(headers, candidate);
        if (key == null) continue;
        final bytes = await _entryBytes(headers[key]!);
        if (bytes == null) continue;
        try {
          if (img.decodeImage(bytes) == null) continue;
        } catch (_) {
          continue;
        }
        return (bytes: bytes, extension: extension);
      }
      return null;
    } finally {
      await input.close();
    }
  }

  /// Mirrors the cover lookup order used by foliate-js `epub.js`, so the
  /// lightweight path finds the same cover the reader used to show.
  static List<String> _coverCandidates(String opf, String opfPath) {
    final result = <String>[];
    void add(String? href) {
      if (href == null || href.isEmpty) return;
      final resolved = _resolveHref(href, opfPath);
      if (!result.contains(resolved)) result.add(resolved);
    }

    try {
      final doc = XmlDocument.parse(opf);
      final items = doc.descendants
          .whereType<XmlElement>()
          .where((node) => node.name.local == 'item')
          .toList();
      bool isImage(XmlElement node) =>
          (node.getAttribute('media-type') ?? '')
              .toLowerCase()
              .startsWith('image/');
      String? hrefOfId(String? id) {
        if (id == null || id.isEmpty) return null;
        for (final item in items) {
          if (item.getAttribute('id') == id) return item.getAttribute('href');
        }
        return null;
      }

      // 1. EPUB 3 `properties="cover-image"`.
      for (final item in items) {
        if ((item.getAttribute('properties') ?? '')
                .toLowerCase()
                .contains('cover-image') &&
            isImage(item)) {
          add(item.getAttribute('href'));
        }
      }
      // 2. EPUB 2 `<meta name="cover" content="..."/>`.
      for (final node in doc.descendants.whereType<XmlElement>()) {
        if (node.name.local == 'meta' &&
            node.getAttribute('name')?.toLowerCase() == 'cover') {
          add(hrefOfId(node.getAttribute('content')));
        }
      }
      // 3. `<guide><reference type="cover" href="..."/></guide>`.
      for (final node in doc.descendants.whereType<XmlElement>()) {
        if (node.name.local == 'reference' &&
            (node.getAttribute('type') ?? '')
                .toLowerCase()
                .contains('cover')) {
          add(node.getAttribute('href'));
        }
      }
      // 4. Conventional manifest ids.
      for (final item in items) {
        final id = (item.getAttribute('id') ?? '').toLowerCase();
        if (const ['cover', 'cover-image', 'coverimage'].contains(id) &&
            isImage(item)) {
          add(item.getAttribute('href'));
        }
      }
      // 5. Conventional cover file names in the href.
      for (final item in items) {
        final href = (item.getAttribute('href') ?? '').toLowerCase();
        if (isImage(item) &&
            (href.contains('/cover.') ||
                href.contains('/cover_') ||
                href.endsWith('cover.jpg') ||
                href.endsWith('cover.jpeg') ||
                href.endsWith('cover.png') ||
                href.endsWith('cover.gif'))) {
          add(item.getAttribute('href'));
        }
      }
      // 6. Title page images.
      for (final item in items) {
        if ((item.getAttribute('id') ?? '')
                .toLowerCase()
                .contains('titlepage') &&
            isImage(item)) {
          add(item.getAttribute('href'));
        }
      }
      // 7. Any raster image in the manifest (SVG cannot be decoded by
      // `image`, so it is deliberately excluded).
      for (final item in items) {
        final mediaType = (item.getAttribute('media-type') ?? '').toLowerCase();
        if (isImage(item) && !mediaType.contains('svg')) {
          add(item.getAttribute('href'));
        }
      }
    } catch (_) {
      // Keep the fixed-name fallbacks below even for a malformed OPF.
    }
    // 8. Covers shipped outside the manifest (Apple's iTunesArtwork etc.).
    for (final name in const [
      'iTunesArtwork',
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
      'cover.gif'
    ]) {
      add(name);
    }
    return result;
  }

  static Future<List<String>> _imagesInCoverPage(
    Map<String, ZipFileHeader> headers,
    String candidate,
  ) async {
    final key = _matchEntry(headers, candidate, exact: true);
    if (key == null) return const <String>[];
    final bytes = await _entryBytes(headers[key]!);
    if (bytes == null) return const <String>[];
    final text = utf8.decode(bytes, allowMalformed: true);
    final found = <String>[];
    for (final pattern in [
      RegExp(r'''<img[^>]+src\s*=\s*["']([^"']+)["']''',
          caseSensitive: false),
      RegExp(r'''<image[^>]+(?:xlink:href|href)\s*=\s*["']([^"']+)["']''',
          caseSensitive: false),
    ]) {
      for (final match in pattern.allMatches(text)) {
        final src = match.group(1);
        if (src != null && src.isNotEmpty && !src.startsWith('data:')) {
          found.add(src);
        }
      }
    }
    return found;
  }

  static Future<String?> _firstOpfText(
      Map<String, ZipFileHeader> headers) async {
    for (final name in headers.keys) {
      if (name.toLowerCase().endsWith('.opf')) {
        return _text(headers, name);
      }
    }
    return null;
  }

  static Future<String?> _text(
      Map<String, ZipFileHeader> headers, String name) async {
    final key = _matchEntry(headers, name, exact: true);
    if (key == null) return null;
    final bytes = await _entryBytes(headers[key]!);
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Inflate exactly one zip entry. `ZipDirectory.read` only parses headers;
  /// `ZipDecoder` would eagerly inflate everything in the book.
  static Future<Uint8List?> _entryBytes(ZipFileHeader header) async {
    final entry = header.file;
    if (entry == null) return null;
    final size = header.uncompressedSize;
    if (size == null || size <= 0 || size > _maxImageBytes) return null;
    if ((entry.flags & 1) != 0) return null; // encrypted
    final method = entry.compressionMethod;
    if (method != 0 && method != 8) return null; // store / deflate only
    final raw = entry.rawContent;
    if (raw == null) return null;

    Stream<List<int>> chunks() async* {
      while (!raw.isEOS) {
        yield raw.readBytes(raw.length.clamp(0, 16384)).toUint8List();
      }
    }

    final builder = BytesBuilder(copy: false);
    final stream = method == 8
        ? chunks().transform(ZLibDecoder(raw: true))
        : chunks();
    await for (final chunk in stream) {
      builder.add(chunk);
      if (builder.length > _maxImageBytes) return null;
    }
    final data = builder.takeBytes();
    return data.isEmpty ? null : data;
  }

  static String? _matchEntry(
    Map<String, ZipFileHeader> headers,
    String name, {
    bool exact = false,
  }) {
    final normalized = _normalize(name);
    if (headers.containsKey(normalized)) return normalized;
    final lower = normalized.toLowerCase();
    for (final key in headers.keys) {
      if (key.toLowerCase() == lower) return key;
    }
    if (exact) return null;
    // Some OPFs omit the directory prefix of the cover file.
    final base = p.posix.basename(lower);
    for (final key in headers.keys) {
      if (p.posix.basename(key).toLowerCase() == base) return key;
    }
    return null;
  }

  static String _resolveHref(String href, String basePath) {
    if (href.contains('://')) return href;
    final dir = p.posix.dirname(basePath);
    return _normalize(dir == '.' ? href : p.posix.join(dir, href));
  }

  /// Normalize a zip entry / OPF href into a zip-root-relative posix path.
  static String _normalize(String path) {
    var value = path.replaceAll('\\', '/');
    final hash = value.indexOf('#');
    if (hash >= 0) value = value.substring(0, hash);
    final query = value.indexOf('?');
    if (query >= 0) value = value.substring(0, query);
    try {
      value = Uri.decodeFull(value);
    } catch (_) {
      // calibre sometimes writes malformed escapes; keep the raw text.
    }
    value = value
        .replaceAll(RegExp(r'%2c', caseSensitive: false), ',')
        .replaceAll(RegExp(r'%3a', caseSensitive: false), ':');
    final parts = <String>[];
    for (final part in value.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(part);
    }
    return parts.join('/');
  }

  static String? _imageExtension(String name) {
    final lower = name.toLowerCase();
    if (lower == 'itunesartwork' || lower.endsWith('/itunesartwork')) {
      return 'jpg';
    }
    if (lower.endsWith('.png')) return 'png';
    if (lower.endsWith('.webp')) return 'webp';
    if (lower.endsWith('.gif')) return 'gif';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'jpg';
    if (lower.endsWith('.bmp')) return 'bmp';
    // .svg / .xhtml / unknown: handled as a cover page or skipped.
    return null;
  }
}
