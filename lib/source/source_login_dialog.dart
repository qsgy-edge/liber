import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import 'js_source_runtime.dart' show SourceScriptError;
import 'source_login.dart';

/// The login surface of one source — the frozen `SourceLoginDialog`
/// (`ui/login/SourceLoginDialog.kt`): the form the source's `loginUi` field
/// describes, over [SourceLoginSession].
///
/// The frozen dialog is a full-screen form with an OK/显示登录头/删除登录头/日志
/// menu; this is a dialog with the same actions. The log menu item has no
/// counterpart: this product has no source debug console (ADR 0011 §6), and the
/// source's messages are recorded in the runtime and shown as notices instead.
///
/// `true` comes back from [showDialog] when the OK action stored what the user
/// entered and ran the login script — the point at which the frozen dialog
/// dismisses.
///
/// One divergence is recorded: a row's `style` (`RowUi.style`, a FlexChildStyle)
/// is not applied, because the frozen layout engine it describes is not this
/// dialog's.
class SourceLoginDialog extends StatefulWidget {
  const SourceLoginDialog({super.key, required this.session});

  final SourceLoginSession session;

  @override
  State<SourceLoginDialog> createState() => _SourceLoginDialogState();
}

class _SourceLoginDialogState extends State<SourceLoginDialog> {
  final _fields = <String, TextEditingController>{};
  late List<SourceLoginRow> _rows;
  String _status = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _rows = widget.session.rows;
    for (final row in _rows) {
      if (row.isField) {
        _fields.putIfAbsent(row.name, TextEditingController.new);
      }
    }
    _readLoginInfo();
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The frozen dialog seeds every field with the stored login information
  /// (`source.getLoginInfoMap()?.get(rowUi.name)`, `SourceLoginDialog.kt:52-85`),
  /// so a user who logs in twice does not retype what the source kept.
  Future<void> _readLoginInfo() async {
    try {
      final info = await widget.session.loginInfo();
      if (!mounted || info == null) return;
      setState(() {
        for (final row in _rows) {
          final value = info[row.name];
          if (value != null) _fields[row.name]?.text = value;
        }
      });
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _status = AppLocalizations.of(
            context,
          ).readLoginInfoFailed(_message(error)),
        );
      }
    }
  }

  /// The frozen `getLoginData`: every text/password row contributes its field's
  /// text under the row's name — an empty field included, which is what makes
  /// the frozen emptiness test a test of the form's rows and not of its values.
  Map<String, String> _loginData() => {
    for (final row in _rows)
      if (row.isField && _fields[row.name] != null)
        row.name: _fields[row.name]!.text,
  };

  /// The frozen OK: store what the form collected and run the source's login
  /// script (`SourceLoginDialog.kt:158-183`). A login that fails keeps the form
  /// open with the script's own error, as the frozen dialog's 登录出错 toast
  /// does.
  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final stored = await widget.session.submit(_loginData());
      if (!mounted) return;
      if (!stored) {
        setState(() {
          _busy = false;
          _status = AppLocalizations.of(context).loginInfoUnavailable;
        });
        return;
      }
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = AppLocalizations.of(context).loginError(_message(error));
      });
    }
  }

  /// A button row's action: a script evaluated with the form's data as `result`,
  /// or — for an absolute-URL action — the named refusal this product has
  /// instead of opening the system browser.
  Future<void> _runButton(SourceLoginRow row) async {
    setState(() => _busy = true);
    try {
      await widget.session.runButton(row, _loginData());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = AppLocalizations.of(context).buttonExecuted(row.name);
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = AppLocalizations.of(
          context,
        ).buttonFailed(row.name, _message(error));
      });
    }
  }

  Future<void> _showLoginHeader() async {
    final l10n = AppLocalizations.of(context);
    final header = await widget.session.loginHeader();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.loginHeaderTitle),
        content: SelectableText(header ?? l10n.noLoginHeader),
        actions: [
          if (header != null)
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: header));
                Navigator.of(context).pop();
              },
              child: Text(l10n.copy),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
  }

  Future<void> _removeLoginHeader() async {
    await widget.session.removeLoginHeader();
    if (mounted) {
      setState(() => _status = AppLocalizations.of(context).loginHeaderCleared);
    }
  }

  static String _message(Object error) => error is SourceScriptError
      ? (error.message.isEmpty ? error.category : error.message)
      : '$error';

  Widget _row(SourceLoginRow row) {
    if (row.isField) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          key: ValueKey('login-field-${row.name}'),
          controller: _fields[row.name],
          obscureText: row.type == 'password',
          decoration: InputDecoration(labelText: row.name),
        ),
      );
    }
    if (row.isButton) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: OutlinedButton(
          key: ValueKey('login-button-${row.name}'),
          onPressed: _busy ? null : () => _runButton(row),
          child: Text(row.name),
        ),
      );
    }
    // The frozen `when(rowUi.type)` renders nothing for any other value.
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = widget.session.source['bookSourceName'];
    return AlertDialog(
      title: Text(l10n.loginSourceTitle('${name ?? widget.session.sourceRef}')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_rows.isEmpty)
                Text(l10n.loginUiEmpty)
              else
                for (final row in _rows) _row(row),
              if (_status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_status, key: const ValueKey('login-status')),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _showLoginHeader,
          child: Text(l10n.loginHeaderAction),
        ),
        TextButton(
          onPressed: _busy ? null : _removeLoginHeader,
          child: Text(l10n.removeLoginHeader),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(l10n.confirm),
        ),
      ],
    );
  }
}
