import 'dart:typed_data';

import 'package:fjs/fjs.dart';

import 'native_library.dart';

/// The charset bridge: the frozen request layer's bytes ↔ text, on the Rust
/// `liber_text` engine (`packages/fjs/liber_text`), which already owns the
/// encodings `dart:convert` cannot decode.
///
/// One implementation serves both directions and both halves of the `charset`
/// option. A response body is decoded with the charset the frozen response path
/// resolves (`OkHttpUtils.kt:78-96`, `EncodingDetect.kt:18-50`), and the
/// `charset` request option percent-escapes the bytes [encode] returns
/// (`AnalyzeUrl.kt:294-334`). `dart:convert` decodes only UTF-8, Latin-1 and
/// ASCII, so this is the only place a GBK, GB18030 or Big5 byte becomes text.
class SourceEncoding {
  SourceEncoding._();

  /// Encodes [text] with the named charset.
  ///
  /// A name the engine does not know throws [TextEngineError_UnknownEncoding],
  /// the frozen `Charset.forName` failure.
  static Future<Uint8List> encode(String text, String encoding) async {
    await NativeLibrary.ready;
    return textEncodeBytes(text: text, encoding: encoding);
  }

  /// Decodes [bytes] with [encoding], or with the engine's own detection when it
  /// is null — the frozen `EncodingDetect.getEncode` fallback.
  static Future<String> decode(Uint8List bytes, {String? encoding}) async {
    await NativeLibrary.ready;
    return textDecodeBytes(bytes: bytes, encoding: encoding);
  }

  /// Whether [error] is the engine's "unknown charset label" failure.
  ///
  /// The frozen client treats that answer differently in the two places a label
  /// arrives: `MediaType.charset()` returns null for a `Content-Type` charset it
  /// cannot resolve, while `Charset.forName` on the document's own meta charset
  /// is left to throw.
  static bool isUnknownEncoding(Object error) =>
      error is TextEngineError_UnknownEncoding;
}
