import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/local/text_engine.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

/// The bridge's two conversion paths (#27): the character-only direction the
/// Book Source host surface calls (`java.t2s`/`java.s2t`) and the reader's own
/// target, which rewrites wording as well (ADR 0010's revision).
///
/// A plain (non-widget) test: the engine is in the native library, which only
/// this binding settles. `tool/host_surface_gate.dart` carries the same
/// character-only cases through an actual source rule.
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  test('java.t2s 只换字：台湾用词原样留着', () {
    // The wording cases the ADR records: the character table leaves them, the
    // reader's Simplified target rewrites them.
    expect(TextEngine.t2s('硬碟'), '硬碟');
    expect(TextEngine.t2s('滑鼠'), '滑鼠');
    expect(TextEngine.t2s('記憶體'), '记忆体');
    expect(TextEngine.convertTo('硬碟', ConvertTarget.simplifiedMainland), '硬盘');
    expect(TextEngine.convertTo('滑鼠', ConvertTarget.simplifiedMainland), '鼠标');
    expect(TextEngine.convertTo('記憶體', ConvertTarget.simplifiedMainland), '内存');
  });

  test('四个目标的用词各不相同', () {
    // 简体 rewrites the Taiwan word, 繁體（通用）keeps it, 繁體（台灣）writes the
    // Taiwan word for the mainland one, 繁體（香港）keeps the generic spelling.
    expect(TextEngine.convertTo('軟件', ConvertTarget.simplifiedMainland), '软件');
    expect(TextEngine.convertTo('軟件', ConvertTarget.traditionalGeneric), '軟件');
    expect(TextEngine.convertTo('軟件', ConvertTarget.traditionalTaiwan), '軟體');
    expect(TextEngine.convertTo('軟件', ConvertTarget.traditionalHongKong), '軟件');
    // The reverse direction: the Taiwan and the generic target want different
    // words for the same mainland one.
    expect(TextEngine.convertTo('硬盘', ConvertTarget.traditionalGeneric), '硬盤');
    expect(TextEngine.convertTo('硬盘', ConvertTarget.traditionalTaiwan), '硬碟');
    expect(TextEngine.convertTo('硬盘', ConvertTarget.traditionalHongKong), '硬碟');
    expect(TextEngine.convertTo('里面', ConvertTarget.traditionalTaiwan), '裡面');
  });

  test('通用方向与只换字的方向一致', () {
    // `TraditionalGeneric` is the character path's own output: a reader who
    // asks for no regional norm gets exactly what `java.s2t` returns.
    for (final text in ['龙应台的小说在台湾很受欢迎。', '软件与鼠标']) {
      expect(
        TextEngine.convertTo(text, ConvertTarget.traditionalGeneric),
        TextEngine.s2t(text),
      );
    }
  });
}
