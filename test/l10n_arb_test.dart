import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/l10n/app_localizations.dart';
import 'package:liber/settings/interface_language.dart';

/// The interface's four ARB files (#28).
///
/// `app_zh.arb` is the template and the Simplified copy; `app_en.arb` is
/// hand-written beside it; the two Traditional files are generated from the
/// template by `tool/l10n/generate_traditional.dart` through the engine's word
/// tables. Whatever their provenance, every one of them carries the template's
/// exact key set: a message that is missing would silently render the
/// *template's* value under another locale instead of failing, and a message
/// whose value is its own key would render as the identifier.
const Map<String, String> arbFiles = {
  'zh': 'lib/l10n/app_zh.arb',
  'en': 'lib/l10n/app_en.arb',
  'zh_Hant_TW': 'lib/l10n/app_zh_Hant_TW.arb',
  'zh_Hant_HK': 'lib/l10n/app_zh_Hant_HK.arb',
};

void main() {
  test('ARB 目录里只有 l10n.yaml 认识的四个界面', () {
    final found = Directory('lib/l10n')
        .listSync()
        .whereType<File>()
        .map((file) => file.path.replaceAll(r'\', '/'))
        .where((path) => path.endsWith('.arb'))
        .toSet();
    expect(
      found,
      arbFiles.values.toSet(),
      reason: '多出来的一个 ARB 要么该进 l10n.yaml 的列表，要么该删掉',
    );
  });

  test('每个 ARB 的键集与模板完全一致', () {
    final template = _messages(arbFiles['zh']!);
    expect(template, isNotEmpty);
    for (final entry in arbFiles.entries) {
      final messages = _messages(entry.value);
      expect(
        messages.keys.toSet(),
        template.keys.toSet(),
        reason: '${entry.value} 的键集与模板不一致',
      );
    }
  });

  test('没有空值，也没有把键名当译文的条目', () {
    for (final entry in arbFiles.entries) {
      final messages = _messages(entry.value);
      for (final message in messages.entries) {
        expect(
          message.value,
          isNotEmpty,
          reason: '${entry.value} 的 ${message.key} 是空的',
        );
        expect(
          message.value,
          isNot(message.key),
          reason: '${entry.value} 的 ${message.key} 没有译文，只是键名',
        );
      }
    }
  });

  test('生成代码为模板的每个键都生成了一个 getter', () {
    final generated = File(
      'lib/l10n/app_localizations.dart',
    ).readAsStringSync();
    for (final key in _messages(arbFiles['zh']!).keys) {
      // A message without placeholders is a getter; one with placeholders is a
      // method taking them.
      expect(
        RegExp('String get $key\\b|String $key\\(').hasMatch(generated),
        isTrue,
        reason: '$key 在 ARB 里，但生成代码里没有它；先运行 flutter gen-l10n',
      );
    }
  });

  test('四个界面就是应用支持的四个 locale', () {
    // The order is not asserted: the generated list follows the ARB file names
    // and ours is the settings screen's order. The set is what matters — the
    // application passes its own `Locale`, so Flutter's own matching order is
    // never consulted.
    expect(
      AppLocalizations.supportedLocales.toSet(),
      InterfaceLanguageSetting.supportedLocales.toSet(),
    );
  });

  test('每个 locale 读到的就是它自己的那份', () async {
    final zh = await AppLocalizations.delegate.load(const Locale('zh'));
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    final tw = await AppLocalizations.delegate.load(
      InterfaceLanguageSetting.traditionalTaiwan,
    );
    final hk = await AppLocalizations.delegate.load(
      InterfaceLanguageSetting.traditionalHongKong,
    );
    expect(zh.shelfTitle, '书架');
    expect(en.shelfTitle, 'Bookshelf');
    expect(tw.shelfTitle, '書架');
    expect(hk.shelfTitle, '書架');
    // The engine's word tables, not just the characters: the Taiwan interface
    // says 檔案 where the Simplified one says 文件, and Hong Kong keeps 文件.
    expect(tw.folder, '資料夾');
    expect(hk.folder, '資料夾');
    expect(en.folder, 'Folder');
  });
}

/// One ARB file's messages: its keys without the `@`-prefixed metadata and
/// `@@locale`.
Map<String, String> _messages(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  return {
    for (final entry in (decoded as Map<String, Object?>).entries)
      if (!entry.key.startsWith('@')) entry.key: entry.value! as String,
  };
}
