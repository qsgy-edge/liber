import 'package:fjs/fjs.dart';

import '../source/native_library.dart';

/// The local-file text engine: what a file is, one pass that indexes it, bounded
/// window reads, and the Chinese conversion the reader and the Book Source host
/// surface share.
///
/// D10 puts the work in a Rust crate (`packages/fjs/liber_text`) behind the same
/// native library as the JavaScript runtime and the HTML rule adapter, and D4
/// fixes the shape: a whole TXT is decoded once into sparse byte ↔ code-unit
/// anchors plus chapter boundaries, and afterwards only windows of a few tens of
/// KB are read. The indexing and window calls are asynchronous because their
/// decoding must not run on the UI isolate; [t2s] and [s2t] are synchronous
/// because a Book Source rule calls `java.t2s` inside its own script.
///
/// The conversion tables and their measured divergence from the frozen reader
/// are recorded in ADR 0010, and the fixtures in
/// `packages/fjs/liber_text/assets/conversion_fixtures.tsv` pin them.
class TextEngine {
  TextEngine._();

  /// Detects [path]'s encoding without indexing the whole file.
  static Future<TextDetection> detectEncoding(String path) async {
    await NativeLibrary.ready;
    return textDetectEncoding(path: path);
  }

  /// Indexes a local file in one pass.
  ///
  /// [options] defaults to the frozen reader's own: one anchor per 32 KiB, its
  /// two enabled default TXT chapter rules, and a 4 MiB window-scan limit.
  static Future<TextIndex> index(String path, {TextIndexOptions? options}) async {
    await NativeLibrary.ready;
    return textIndexFile(path: path, options: options ?? textDefaultOptions());
  }

  /// Reads at most [maxCodeUnits] starting exactly at [codeUnitOffset], seeking
  /// to [anchor] first.
  ///
  /// Pass the nearest stored anchor — the whole point of the sparse index — or
  /// `null` to start at the beginning of the file. A read whose scan from the
  /// anchor would exceed [maxScanBytes] fails with
  /// [TextEngineError_AnchorTooFar] rather than quietly reading the book.
  static Future<TextWindow> readWindow({
    required String path,
    required String encoding,
    required int codeUnitOffset,
    required int maxCodeUnits,
    required int maxScanBytes,
    TextAnchor? anchor,
  }) async {
    await NativeLibrary.ready;
    return textReadWindow(
      request: TextWindowRequest(
        path: path,
        encoding: encoding,
        anchor: anchor,
        codeUnitOffset: codeUnitOffset,
        maxCodeUnits: maxCodeUnits,
        maxScanBytes: maxScanBytes,
      ),
    );
  }

  /// Traditional to Simplified, the frozen `java.t2s`.
  ///
  /// Synchronous, so the native library must already be initialized — the
  /// JavaScript runtime and every caller here initialize it through
  /// [NativeLibrary] before their first call.
  static String t2s(String text) =>
      textConvert(text: text, direction: TextDirection.traditionalToSimplified);

  /// Simplified to Traditional, the frozen `java.s2t`.
  static String s2t(String text) =>
      textConvert(text: text, direction: TextDirection.simplifiedToTraditional);
}
