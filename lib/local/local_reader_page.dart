import 'dart:async';

import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../settings/reader_script.dart';
import '../settings/reader_script_page.dart';
import 'local_reader.dart';

/// The local reader: one bounded window of a local file at a time, opened at the
/// position D4's tiers restored, and paged by code-unit offset.
///
/// The page owns nothing but the session it was handed: [LocalReader] holds the
/// index, the position and the window, so a widget test can drive this page with
/// a fake engine instead of the native library. It is also where the reader's
/// conversion setting (#27) is consumed: the page resolves it before opening the
/// book and again after the settings screen closes, which re-renders the window
/// without reopening the book.
class LocalReaderPage extends StatefulWidget {
  const LocalReaderPage({super.key, required this.reader});

  final LocalReader reader;

  @override
  State<LocalReaderPage> createState() => _LocalReaderPageState();
}

class _LocalReaderPageState extends State<LocalReaderPage> {
  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  /// Resolves this book's script once and opens the book with it, so a book
  /// whose system locale asks for 繁體 opens in 繁體 without the setting being
  /// touched.
  Future<void> _open() async {
    final reader = widget.reader;
    await reader.applyScript(await _resolve());
    if (!mounted) return;
    await _run(reader.open);
  }

  /// Opens the conversion screen for the book being read, then re-renders the
  /// page in the new script: no index pass, no reopen. A window in the file's
  /// own text is re-rendered from the page it already holds; a processed unit is
  /// run through the one text entry again.
  Future<void> _openScriptSettings() async {
    final reader = widget.reader;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScriptPage(
          store: reader.library.store,
          bookId: reader.book.id,
          bookTitle: reader.book.title,
        ),
      ),
    );
    if (!mounted) return;
    await reader.applyScript(await _resolve());
    if (mounted) setState(() {});
  }

  Future<ConvertTarget?> _resolve() => ReaderScriptSetting.resolve(
    widget.reader.library.store,
    bookId: widget.reader.book.id,
  );

  Future<void> _run(Future<void> Function() action) async {
    await action();
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    await widget.reader.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).positionSaved)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final reader = widget.reader;
    final position = reader.position;
    return Scaffold(
      appBar: AppBar(
        title: Text(reader.book.title),
        actions: [
          IconButton(
            onPressed: reader.busy ? null : _openScriptSettings,
            tooltip: l10n.readerScriptTitle,
            icon: const Icon(Icons.translate),
          ),
          FilledButton.icon(
            onPressed: reader.busy || reader.error != null ? null : _save,
            icon: const Icon(Icons.bookmark_add),
            label: Text(l10n.savePosition),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: reader.busy
          ? const Center(child: CircularProgressIndicator())
          : reader.error != null
          ? Center(child: Text(l10n.cannotRead('${reader.error}')))
          : Column(
              children: [
                if (reader.notice != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          reader.notice!,
                          key: const ValueKey('reader-notice'),
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      reader.text,
                      // A window is a few thousand code units: the paragraphs
                      // are rendered as one text block, and paging — not
                      // scrolling — is what moves the reader through the book.
                      key: const ValueKey('reader-window'),
                      style: const TextStyle(fontSize: 20, height: 1.8),
                    ),
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        OutlinedButton(
                          onPressed: reader.busy || !reader.hasPrevious
                              ? null
                              : () => _run(reader.previous),
                          child: Text(l10n.previousPage),
                        ),
                        Text(
                          position == null
                              ? ''
                              : 'offset ${position.textOffset} / '
                                    '${position.textLength}',
                          key: const ValueKey('reader-offset'),
                        ),
                        FilledButton(
                          onPressed: reader.busy || !reader.hasNext
                              ? null
                              : () => _run(reader.next),
                          child: Text(l10n.nextPage),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
