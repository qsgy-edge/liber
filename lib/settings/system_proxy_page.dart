import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../store/space_store.dart';
import 'system_proxy.dart';

/// The system-proxy switch (#87): whether the requests this product sends
/// through `dart:io`'s `HttpClient` follow the machine's proxy configuration
/// instead of the direct connection the product always used.
///
/// The screen owns only the one row it writes, the way
/// `AutoChangeSourcePage`, `InterfaceLanguagePage` and `ReaderScriptPage` do;
/// it is one switch and not a general settings home.
///
/// Nothing has to be reported upwards: the transport reads the row when it
/// builds a request's client, so a flip is on the next request rather than on
/// the next opening of a page.
class SystemProxyPage extends StatefulWidget {
  const SystemProxyPage({super.key, required this.store});

  /// The open space's store, the one the setting's row lives in.
  final SpaceStore store;

  @override
  State<SystemProxyPage> createState() => _SystemProxyPageState();
}

class _SystemProxyPageState extends State<SystemProxyPage> {
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
      final stored = await widget.store.setting(SystemProxySetting.key);
      if (!mounted) return;
      setState(() => _enabled = SystemProxySetting.fromStored(stored));
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
      await SystemProxySetting.putGlobal(widget.store, enabled: enabled);
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
      appBar: AppBar(title: Text(l10n.actionSystemProxy)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(l10n.systemProxyHint, key: const ValueKey('system-proxy-hint')),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, key: const ValueKey('system-proxy-error')),
          ],
          const SizedBox(height: 16),
          if (enabled == null)
            ListTile(title: Text(l10n.loading))
          else
            SwitchListTile(
              key: const ValueKey('system-proxy-switch'),
              value: enabled,
              onChanged: (value) => unawaited(_select(value)),
              title: Text(l10n.systemProxyLabel),
            ),
        ],
      ),
    );
  }
}
