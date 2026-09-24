import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The cleartext WebView policy #71 decided (2026-09-24), pinned where it lives.
///
/// The decision — permit `http://` Book Source requests in the WebView paths on
/// every platform, with `NSAllowsArbitraryLoadsInWebContent` as Apple's
/// declaration and nothing broader — is written down in
/// `docs/adr/0011-bound-untrusted-book-sources.md` §5's addendum. Its only
/// executable half is these two plists: the text transport (`dart:io`) never
/// consults ATS, Android carries the baseline's cleartext config unchanged, and
/// no Apple runtime row exists yet (`not-run`, #56). A silent removal of the key
/// would therefore be invisible until an Apple WebView run, so this file reads
/// both plists and fails when the declaration drifts.
///
/// It reads the files as text rather than parsing property lists: a malformed
/// plist already fails each Apple job's build, and this row is about which keys
/// the file carries.
void main() {
  const plists = {
    'ios/Runner/Info.plist': 'iOS',
    'macos/Runner/Info.plist': 'macOS',
  };

  /// The `<dict>` that follows [key], as its own text, or null when the key is
  /// absent. Keys and values in these files are one element per line, which is
  /// what the Xcode-written template looks like.
  String? dictAfter(String text, String key) {
    final marker = '<key>$key</key>';
    final at = text.indexOf(marker);
    if (at < 0) return null;
    final start = text.indexOf('<dict>', at);
    if (start < 0) return null;
    final end = text.indexOf('</dict>', start);
    if (end < 0) return null;
    return text.substring(start, end);
  }

  for (final entry in plists.entries) {
    final name = entry.value;
    group('$name Info.plist (#71)', () {
      late final String text = File(entry.key).readAsStringSync();

      test('declares cleartext for web-view content only', () {
        final dict = dictAfter(text, 'NSAppTransportSecurity');
        expect(
          dict,
          isNotNull,
          reason: '$name 少了 NSAppTransportSecurity（#71 决定在 WebView 路径放行 http）',
        );
        final keys = RegExp(
          r'<key>([^<]+)</key>',
        ).allMatches(dict!).map((match) => match.group(1)).toList();
        expect(
          keys,
          ['NSAllowsArbitraryLoadsInWebContent'],
          reason: '这个字典只放 WebView 的豁免；其它键属于别的决定',
        );
        expect(
          RegExp(
            r'<key>NSAllowsArbitraryLoadsInWebContent</key>\s*<true\s*/>',
          ).hasMatch(dict),
          isTrue,
          reason: '豁免必须是 true',
        );
      });

      test('does not widen ATS beyond web-view content', () {
        for (final broad in [
          'NSAllowsArbitraryLoads',
          'NSExceptionDomains',
          'NSAllowsLocalNetworking',
        ]) {
          expect(
            text.contains('<key>$broad</key>'),
            isFalse,
            reason: '$name 不应声明 $broad（#71 只豁免 WebView 内容，其余 ATS 保持）',
          );
        }
      });
    });
  }

  test('Android keeps the baseline cleartext posture, unchanged by #71', () {
    final config = File(
      'android/app/src/main/res/xml/network_security_config.xml',
    ).readAsStringSync();
    expect(
      config.contains('cleartextTrafficPermitted="true"'),
      isTrue,
      reason: '#71 不改 Android：冻结基线的 cleartext 配置保持原样',
    );
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest.contains('android:networkSecurityConfig'), isTrue);
    expect(manifest.contains('android.permission.INTERNET'), isTrue);
  });
}
