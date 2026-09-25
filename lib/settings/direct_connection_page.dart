import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../store/space_store.dart';
import 'direct_connection.dart';

/// The direct-connection switch (#87): whether the requests this product sends
/// through `dart:io`'s `HttpClient` bypass the system proxy.
///
/// The screen owns only the one row it writes, the way
/// `AutoChangeSourcePage`, `InterfaceLanguagePage` and `ReaderScriptPage` do;
/// it is one switch and not a general settings home.
///
/// Nothing has to be reported upwards: the transport reads the row when it
/// builds a request's client, so a flip is on the next request rather than on
/// the next opening of a page.
class DirectConnectionPage extends StatefulWidget {
  const DirectConnectionPage({super.key, required this.store});

  /// The open space's store, the one the setting's row lives in.
  final SpaceStore store;

  @override
  State<DirectConnectionPage> createState() => _DirectConnectionPageState();
}

class _DirectConnectionPageState extends State<DirectConnectionPage> {
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
      final stored = await widget.store.setting(DirectConnectionSetting.key);
      if (!mounted) return;
      setState(() => _enabled = DirectConnectionSetting.fromStored(stored));
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
      await DirectConnectionSetting.putGlobal(widget.store, enabled: enabled);
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
      appBar: AppBar(title: Text(l10n.actionDirectConnection)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            l10n.directConnectionHint,
            key: const ValueKey('direct-connection-hint'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, key: const ValueKey('direct-connection-error')),
          ],
          const SizedBox(height: 16),
          if (enabled == null)
            ListTile(title: Text(l10n.loading))
          else
            SwitchListTile(
              key: const ValueKey('direct-connection-switch'),
              value: enabled,
              onChanged: (value) => unawaited(_select(value)),
              title: Text(l10n.directConnectionLabel),
            ),
        ],
      ),
    );
  }
}
