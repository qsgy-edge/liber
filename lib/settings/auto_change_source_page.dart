import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../store/space_store.dart';
import 'auto_change_source.dart';

/// The automatic switch-source switch (#69): the frozen
/// `AppConfig.autoChangeSource` as a user-visible setting, one row the shelf
/// reads at the moment it needs it.
///
/// The screen owns only the one row it writes, the way
/// `InterfaceLanguagePage` and `ReaderScriptPage` do; it is one switch and not
/// a general settings home — that shape is still fog on the map.
class AutoChangeSourcePage extends StatefulWidget {
  const AutoChangeSourcePage({super.key, required this.store});

  /// The open space's store, the one the setting's row lives in.
  final SpaceStore store;

  @override
  State<AutoChangeSourcePage> createState() => _AutoChangeSourcePageState();
}

class _AutoChangeSourcePageState extends State<AutoChangeSourcePage> {
  /// The row as it was read; null until the store answered.
  bool? _enabled;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final stored = await widget.store.setting(AutoChangeSourceSetting.key);
      if (!mounted) return;
      setState(() => _enabled = AutoChangeSourceSetting.fromStored(stored));
    } on Object catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        setState(() => _error = l10n.readSettingsFailed('$error'));
      }
    }
  }

  Future<void> _select(bool enabled) async {
    setState(() {
      _enabled = enabled;
      _error = null;
    });
    try {
      await AutoChangeSourceSetting.putGlobal(widget.store, enabled: enabled);
    } on Object catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        setState(() => _error = l10n.saveSettingsFailed('$error'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final enabled = _enabled;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.actionAutoChangeSource)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            l10n.autoChangeSourceHint,
            key: const ValueKey('auto-change-source-hint'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, key: const ValueKey('auto-change-source-error')),
          ],
          const SizedBox(height: 16),
          if (enabled == null)
            ListTile(title: Text(l10n.loading))
          else
            SwitchListTile(
              key: const ValueKey('auto-change-source-switch'),
              value: enabled,
              onChanged: (value) => unawaited(_select(value)),
              title: Text(l10n.autoChangeSourceLabel),
            ),
        ],
      ),
    );
  }
}
