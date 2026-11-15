import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Covers are stored once and reused for the shelf, detail page and TTS.
/// Keeping them at this size cuts typical covers from hundreds of KB or more
/// to a few dozen KB, and keeps shelf decoding cheap. These are only the
/// defaults; the user can tune them in Appearance settings.
const int _defaultMaxCoverWidth = 600;
const int _defaultMaxCoverHeight = 900;
const int _defaultJpegQuality = 82;
const String _coverOptimizedPrefsKey = 'coverCompressionV1';

typedef CoverCompression = ({Uint8List bytes, String extension});

/// Everything the background isolate needs. SharedPreferences is not readable
/// inside [compute], so the current settings must be passed in explicitly.
class _CoverInput {
  const _CoverInput(this.bytes, this.extension, this.maxWidth, this.maxHeight,
      this.jpegQuality);

  final Uint8List bytes;
  final String extension;
  final int maxWidth;
  final int maxHeight;
  final int jpegQuality;
}

CoverCompression _compressCoverEntry(_CoverInput input) => compressCoverBytes(
      input.bytes,
      input.extension,
      maxWidth: input.maxWidth,
      maxHeight: input.maxHeight,
      jpegQuality: input.jpegQuality,
    );

Future<CoverCompression> _compressCover(
  Uint8List bytes,
  String extension, {
  bool force = false,
}) {
  final prefs = Prefs();
  final minBytes = force ? 0 : prefs.coverMinCompressBytes;
  if (bytes.length <= minBytes) {
    return Future.value((bytes: bytes, extension: extension));
  }
  return compute(
    _compressCoverEntry,
    _CoverInput(
      bytes,
      extension,
      prefs.coverMaxWidth,
      prefs.coverMaxHeight,
      prefs.coverJpegQuality,
    ),
  );
}

/// Re-encode an already stored cover with the current settings, ignoring the
/// size threshold. Used by the storage manager's "recompress all" action.
Future<CoverCompression> recompressCoverBytes(
        Uint8List bytes, String extension) =>
    _compressCover(bytes, extension, force: true);

/// Pure function so it can run on a background isolate via [compute].
CoverCompression compressCoverBytes(
  Uint8List bytes,
  String extension, {
  int maxWidth = _defaultMaxCoverWidth,
  int maxHeight = _defaultMaxCoverHeight,
  int jpegQuality = _defaultJpegQuality,
}) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return (bytes: bytes, extension: extension);
    }
    // Flutter normally applies EXIF orientation while decoding; re-encoding
    // without baking it would rotate phone-photo custom covers.
    final oriented = img.bakeOrientation(decoded);
    final scale = math.min(
      maxWidth / oriented.width,
      maxHeight / oriented.height,
    );
    var resized = oriented;
    if (scale < 1) {
      resized = img.copyResize(
        oriented,
        width: math.max(1, (oriented.width * scale).round()),
        height: math.max(1, (oriented.height * scale).round()),
        interpolation: img.Interpolation.linear,
      );
    }
    final lower = extension.toLowerCase();
    // Keep alpha-capable formats transparent; everything else becomes JPEG.
    if (lower == 'png' || lower == 'gif' || lower == 'webp') {
      return (bytes: img.encodePng(resized, level: 6), extension: 'png');
    }
    return (
      bytes: img.encodeJpg(resized, quality: jpegQuality),
      extension: 'jpg',
    );
  } catch (error) {
    AnxLog.warning('Cover compression failed: $error');
    return (bytes: bytes, extension: extension);
  }
}

Future<String> saveImageToLocal(String? imageFile, String name) async {
  if (imageFile == null) {
    return name;
  }
  try {
    // image is base64 encoded
    // data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD//gA8Q1JFQVRPUjogZ2...
    final List<String> parts = imageFile.split(',');
    if (parts.length < 2) return name;
    final String base64String = parts[1];
    final Uint8List bytes = base64.decode(base64String);
    final extension = parts[0].split('/')[1].split(';')[0];

    return saveImageBytesToLocal(bytes, name, extension: extension);
  } catch (e) {
    AnxLog.severe('Error saving image\n$e');
    return name;
  }
}

/// Persists an image from raw bytes (for example a user-picked custom cover),
/// resizing and re-encoding it instead of writing the original file verbatim.
Future<String> saveImageBytesToLocal(
  Uint8List bytes,
  String name, {
  String extension = 'jpg',
}) async {
  final finalName = '$name.$extension';
  final file = File(getBasePath(finalName));
  await file.parent.create(recursive: true);
  try {
    final result = await _compressCover(bytes, extension);
    final compressedName = '$name.${result.extension}';
    final compressedFile = File(getBasePath(compressedName));
    await compressedFile.writeAsBytes(result.bytes, flush: true);
    return compressedName;
  } catch (error) {
    // Never lose a custom cover just because the optional compression failed.
    AnxLog.warning('Cover compression fallback: $error');
    await file.writeAsBytes(bytes, flush: true);
    return finalName;
  }
}

/// One-time maintenance for libraries imported before cover compression.
/// Keeps the existing file name so database rows and sync paths stay valid.
class CoverOptimizer {
  static Future<void> runOnce() async {
    final prefs = Prefs().prefs;
    if (prefs.getBool(_coverOptimizedPrefsKey) == true) return;

    // Let the first frame and the bookshelf load before touching disk.
    await Future<void>.delayed(const Duration(seconds: 12));
    try {
      final dir = getCoverDir();
      if (!await dir.exists()) return;
      final minBytes = Prefs().coverMinCompressBytes;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final dot = entity.path.lastIndexOf('.');
        final extension = dot == -1
            ? ''
            : entity.path.substring(dot + 1).toLowerCase();
        if (extension != 'jpg' && extension != 'jpeg' && extension != 'png') {
          continue;
        }
        try {
          final stat = await entity.stat();
          if (stat.size < minBytes) continue;
          final bytes = await entity.readAsBytes();
          final result = await _compressCover(bytes, extension);
          if (result.bytes.length >= bytes.length) continue;

          final temp = File('${entity.path}.cover-tmp');
          final backup = File('${entity.path}.cover-bak');
          await temp.writeAsBytes(result.bytes, flush: true);
          if (await backup.exists()) await backup.delete();
          await entity.rename(backup.path);
          try {
            await temp.rename(entity.path);
          } catch (_) {
            if (await backup.exists()) await backup.rename(entity.path);
            rethrow;
          }
          if (await backup.exists()) await backup.delete();
        } catch (error) {
          AnxLog.warning('Cover optimization failed for one file: $error');
        }
      }
      await prefs.setBool(_coverOptimizedPrefsKey, true);
    } catch (error) {
      AnxLog.warning('Cover optimization skipped: $error');
    }
  }
}
