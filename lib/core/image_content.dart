import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'content.dart';

String _hash(Uint8List bytes) => sha256.convert(bytes).toString();
Future<String> imageHash(Uint8List bytes) => compute(_hash, bytes);

/// Validate dimensions before any native or Flutter decoder sees remote bytes.
ImageMeta pngMetadata(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33 ||
      bytes.length > cachedItemBytes ||
      !listEquals(bytes.sublist(0, 8), signature) ||
      !listEquals(bytes.sublist(12, 16), [73, 72, 68, 82])) {
    throw const FormatException('Use a PNG image up to 16 MiB.');
  }
  final header = ByteData.sublistView(bytes);
  if (header.getUint32(8) != 13) {
    throw const FormatException('Invalid PNG header.');
  }
  return ImageMeta.fromJson({
    'mime': 'image/png',
    'width': header.getUint32(16),
    'height': header.getUint32(20),
    'size': bytes.length,
  });
}

class ImageContent {
  ImageContent(this.payload, this.png);
  final ClipPayload payload;
  final Uint8List png;

  static Future<ImageContent> create(Uint8List png, {String? text}) async {
    final meta = {...pngMetadata(png).toJson(), 'sha256': await imageHash(png)};
    return ImageContent(
      ClipPayload.fromJson({
        'kind': text?.isNotEmpty == true ? 'mixed' : 'image',
        if (text?.isNotEmpty == true) 'text': text,
        if (text?.isNotEmpty == true) 'image': meta else ...meta,
      }),
      png,
    );
  }

  static Future<void> verify(ClipPayload payload, Uint8List bytes) async {
    final actual = pngMetadata(bytes);
    final expected = payload.image!;
    if (actual.width != expected.width ||
        actual.height != expected.height ||
        actual.size != expected.size ||
        expected.hash != null && await imageHash(bytes) != expected.hash) {
      throw const FormatException('The image does not match its description.');
    }
  }
}
