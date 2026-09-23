import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/l10n/app_localizations.dart';
import 'package:liber/settings/interface_language.dart';

/// The interface language a widget test expects (#28).
///
/// A test that pumps a page says which language its assertions are in instead
/// of inheriting the machine's locale: the suite runs on a developer's `en_US`
/// laptop and on a CI runner, and both must read the same copy. The language is
/// 简体 by default — the copy the tests were written in — and [localizedApp]'s
/// `locale` argument is how a test asks for another one.
const Locale testLocale = Locale('zh');

/// A `MaterialApp` around [home] with the application's own delegates and
/// locale, the way `LiberApp` installs them.
///
/// A page that reads `AppLocalizations.of(context)` throws without this, which
/// is the point: a page reaching for copy no delegate provides is a bug, not an
/// empty string.
MaterialApp localizedApp({
  Key? key,
  GlobalKey<NavigatorState>? navigatorKey,
  required Widget home,
  Locale locale = testLocale,
}) => MaterialApp(
  key: key,
  navigatorKey: navigatorKey,
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: InterfaceLanguageSetting.supportedLocales,
  home: home,
);

/// The same four locales the application supports, for a test that checks the
/// generated bundle rather than a page.
const List<Locale> testSupportedLocales =
    InterfaceLanguageSetting.supportedLocales;

/// Leaves the current route, the way `tester.pageBack` does but without
/// depending on the interface language: the back button's tooltip is localized
/// (`返回` under the default 简体), so a finder that looks for the English
/// "Back" tooltip cannot see it.
Future<void> tapBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}
