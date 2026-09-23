import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../store/space_store.dart';
import 'interface_language.dart';

/// The name the settings screen shows for one interface-language choice.
///
/// A language names itself: the two Traditional interfaces show 繁體中文, the
/// Simplified one 简体中文, and English "English" whichever interface is
/// current, which is why these are ARB messages and not a table in code.
String interfaceLanguageLabel(
  AppLocalizations l10n,
  InterfaceLanguageChoice choice,
) => switch (choice) {
  InterfaceLanguageChoice.followLocale => l10n.followSystemLanguage,
  InterfaceLanguageChoice.english => l10n.languageEnglish,
  InterfaceLanguageChoice.simplified => l10n.languageSimplified,
  InterfaceLanguageChoice.traditionalTaiwan => l10n.languageTraditionalTaiwan,
  InterfaceLanguageChoice.traditionalHongKong =>
    l10n.languageTraditionalHongKong,
};

/// The interface's own language (#28): which of the four interfaces in
/// `lib/l10n/` the widgets read.
///
/// The screen owns only the one row it writes. It hands the resolved locale back
/// through [onLocaleChanged] the moment the row is stored, so the widgets above
/// this route — this screen included — re-render in the new language without a
/// restart: `MaterialApp.locale` is what the application rebuilds with, and
/// `AppLocalizations` re-resolves on that rebuild.
///
/// The setting has nothing to do with the content's script: the reader's own
/// conversion setting (`ReaderScriptPage`, #27) is a separate row, and an
/// English interface with Simplified books is a state both rows can be put
/// into.
class InterfaceLanguagePage extends StatefulWidget {
  const InterfaceLanguagePage({
    super.key,
    required this.store,
    this.onLocaleChanged,
  });

  /// The open space's store, the one the setting's row lives in.
  final SpaceStore store;

  /// Called with the locale the stored choice resolves to, so the application
  /// rebuilds in it. Null when the caller does not own the app's locale.
  final ValueChanged<Locale>? onLocaleChanged;

  @override
  State<InterfaceLanguagePage> createState() => _InterfaceLanguagePageState();
}

class _InterfaceLanguagePageState extends State<InterfaceLanguagePage> {
  InterfaceLanguageChoice? _choice;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final stored = await widget.store.setting(InterfaceLanguageSetting.key);
      if (!mounted) return;
      setState(() => _choice = InterfaceLanguageSetting.globalChoice(stored));
    } on Object catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        setState(() => _error = l10n.readSettingsFailed('$error'));
      }
    }
  }

  Future<void> _select(InterfaceLanguageChoice choice) async {
    setState(() {
      _choice = choice;
      _error = null;
    });
    try {
      await InterfaceLanguageSetting.putGlobal(widget.store, choice);
      if (!mounted) return;
      widget.onLocaleChanged?.call(
        InterfaceLanguageSetting.localeFor(
          choice,
          InterfaceLanguageSetting.systemLocale(),
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        setState(() => _error = l10n.saveSettingsFailed('$error'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final choice = _choice;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.actionInterfaceLanguage)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            l10n.interfaceLanguageIntro,
            key: const ValueKey('interface-language-intro'),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.interfaceLanguageFollowHint,
            key: const ValueKey('interface-language-hint'),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.systemLocaleLine(
              InterfaceLanguageSetting.systemLocale().toLanguageTag(),
            ),
            key: const ValueKey('interface-language-locale'),
            style: theme.textTheme.bodySmall,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, key: const ValueKey('interface-language-error')),
          ],
          const SizedBox(height: 16),
          if (choice == null)
            ListTile(title: Text(l10n.loading))
          else
            RadioGroup<InterfaceLanguageChoice>(
              groupValue: choice,
              onChanged: (selected) {
                if (selected != null) unawaited(_select(selected));
              },
              child: Column(
                children: [
                  for (final item in InterfaceLanguageSetting.choices)
                    RadioListTile<InterfaceLanguageChoice>(
                      key: ValueKey('interface-language-${item.slug}'),
                      value: item,
                      title: Text(interfaceLanguageLabel(l10n, item)),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
