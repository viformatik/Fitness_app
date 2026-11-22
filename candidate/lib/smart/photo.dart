import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class PhotoInput {
  final Uint8List bytes;
  final int maxBytes;
  final int maxDimension;
  const PhotoInput(this.bytes, {this.maxBytes = 1200000, this.maxDimension = 1600});
}

class CompressedPhoto {
  final Uint8List bytes;
  final String mime;
  final int width;
  final int height;
  final int originalBytes;
  const CompressedPhoto({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
    required this.originalBytes,
  });
  String get sizeLabel => '${(bytes.length / 1024).round()} КБ';
}

/// Decode, normalize orientation and re-encode photos before they are held in
/// widget state or sent to the AI. This prevents a 12 MP camera frame from
/// dominating memory on mobile web. Called through compute where available.
CompressedPhoto compressPhotoSync(PhotoInput input) {
  if (input.bytes.isEmpty) {
    throw ArgumentError('Пустой файл изображения');
  }
  final decoded = img.decodeImage(input.bytes);
  if (decoded == null) {
    throw ArgumentError('Не удалось прочитать фото. Выберите JPG, PNG или WebP.');
  }
  if (decoded.width * decoded.height > 50000000) {
    throw ArgumentError('Фото слишком большое. Сделайте снимок с меньшим разрешением.');
  }
  final oriented = img.bakeOrientation(decoded);
  Uint8List? smallest;
  var smallestWidth = oriented.width;
  var smallestHeight = oriented.height;
  for (final maxDimension in [input.maxDimension, 1200, 900]) {
    final scale = math.min(
      1.0,
      maxDimension / math.max(oriented.width, oriented.height),
    );
    final resized = scale >= 1
        ? oriented
        : img.copyResize(
            oriented,
            width: math.max(1, (oriented.width * scale).round()),
            height: math.max(1, (oriented.height * scale).round()),
            interpolation: img.Interpolation.average,
          );
    for (final quality in [78, 65, 50]) {
      final bytes = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
      if (smallest == null || bytes.length < smallest.length) {
        smallest = bytes;
        smallestWidth = resized.width;
        smallestHeight = resized.height;
      }
      if (bytes.length <= input.maxBytes) {
        return CompressedPhoto(
          bytes: bytes,
          mime: 'image/jpeg',
          width: resized.width,
          height: resized.height,
          originalBytes: input.bytes.length,
        );
      }
    }
  }
  if (smallest != null && smallest.length <= input.maxBytes * 2) {
    return CompressedPhoto(
      bytes: smallest,
      mime: 'image/jpeg',
      width: smallestWidth,
      height: smallestHeight,
      originalBytes: input.bytes.length,
    );
  }
  throw StateError('Не удалось достаточно сжать фото. Выберите изображение поменьше.');
}

Future<CompressedPhoto> compressPhoto(
  Uint8List bytes, {
  int maxBytes = 1200000,
  int maxDimension = 1600,
}) async {
  final input = PhotoInput(bytes, maxBytes: maxBytes, maxDimension: maxDimension);
  try {
    return await compute<PhotoInput, CompressedPhoto>(compressPhotoSync, input);
  } catch (_) {
    // Web targets without workers still parse once, only after user intent.
    // If decoding itself is invalid, the same clear error is raised here.
    return compressPhotoSync(input);
  }
}
