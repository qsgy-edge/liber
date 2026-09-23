import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../store/shelf.dart';
import 'book_source_pipeline.dart';
import 'book_source_service.dart';
import 'html_source_browser.dart';
import 'http_source_transport.dart';
import 'java_regex.dart';
import 'js_source_runtime.dart' show SourceHostMessage;
import 'precise_search_page.dart';
import 'source_notice.dart';
import 'source_tls_confirmation.dart';

/// Inline online section of the existing bookshelf; the parent owns scrolling.
///
/// The list comes from the space's store: a book is on the shelf because
/// `books.shelved` says so, and removing one keeps its chapters and its
/// position. A book whose source was deleted (#53) stays in the list marked as
/// unopenable — its row, its chapters and its position are what the shelf has to
/// keep — and only its removal is offered for it.
class OnlineBookshelf extends StatefulWidget {
  const OnlineBookshelf({
    super.key,
    required this.service,
    this.revision = 0,
    this.transport,
  });
  final ShelfService service;
  final BookSourceTransport? transport;

  /// Bumped by the parent when something outside this widget changed the shelf.
  final int revision;

  @override
  State<OnlineBookshelf> createState() => _OnlineBookshelfState();
}

class _OnlineBookshelfState extends State<OnlineBookshelf> {
  List<ShelfEntry> books = const <ShelfEntry>[];
  bool loading = true;
  String? busyId, error;
  final _bookUrl = TextEditingController();
  bool matchingUrl = false;
  String? urlResult;

  @override
  void dispose() {
    _bookUrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  @override
  void didUpdateWidget(OnlineBookshelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) unawaited(reload());
  }

  Future<void> reload() async {
    try {
      final saved = await widget.service.onlineShelf();
      if (mounted) {
        setState(() {
          books = saved;
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = AppLocalizations.of(context).readOnlineShelfFailed('$e');
        });
      }
    }
  }

  /// A pipeline for one analysis of [source], built the way the source's rules
  /// need: a JSON source gets the JSON adapter (ticket #29).
  BookSourcePipeline _openPipeline(
    Map<String, dynamic> source,
    BookSourceTransport transport,
  ) => openBookSourcePipeline(
    source,
    transport,
    hostState: widget.service.hostState,
    androidId: widget.service.androidId,
    onHostMessage: _showHostNotice,
  );

  Future<void> open(ShelfEntry entry) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => HtmlSourceBrowser(
          source: entry.sourceJson,
          keyword: '',
          resume: entry,
          service: widget.service,
          pipeline: widget.transport == null
              ? null
              : _openPipeline(entry.sourceJson, widget.transport!),
        ),
      ),
    );
    if (mounted) await reload();
  }

  Future<void> openUrl() async {
    if (matchingUrl) return;
    final text = _bookUrl.text.trim();
    final url = Uri.tryParse(text);
    if (url == null ||
        !url.hasAuthority ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        (url.scheme != 'http' && url.scheme != 'https')) {
      setState(() => urlResult = AppLocalizations.of(context).invalidBookUrl);
      return;
    }
    setState(() {
      matchingUrl = true;
      urlResult = null;
    });
    try {
      final matches = <ImportedBookSource>[];
      final failures = <String>[];
      for (final source in await widget.service.sources()) {
        final pattern = '${source.data['bookUrlPattern'] ?? ''}';
        if (pattern.isEmpty) continue;
        try {
          if (javaMatchesWhole(pattern, text, label: 'bookUrlPattern')) {
            matches.add(source);
          }
        } on UnsupportedError catch (e) {
          failures.add('${source.data['bookSourceName'] ?? source.id}：$e');
        }
      }
      if (!mounted) return;
      setState(() {
        matchingUrl = false;
        urlResult = [
          if (matches.isEmpty) AppLocalizations.of(context).noSourceMatchesUrl,
          ...failures,
        ].join('\n');
      });
      if (matches.isEmpty) return;
      final ImportedBookSource? chosen;
      if (matches.length == 1) {
        chosen = matches.single;
      } else {
        chosen = await showDialog<ImportedBookSource>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(AppLocalizations.of(dialogContext).chooseSource),
            content: SizedBox(
              width: (MediaQuery.sizeOf(dialogContext).width - 80).clamp(
                0.0,
                360.0,
              ),
              height: (80.0 * matches.length + (failures.isEmpty ? 0.0 : 120.0))
                  .clamp(0.0, MediaQuery.sizeOf(dialogContext).height * 0.6),
              child: ListView(
                children: [
                  for (final source in matches)
                    ListTile(
                      title: Text(
                        '${source.data['bookSourceName'] ?? source.id}',
                      ),
                      subtitle: Text(source.id),
                      onTap: () => Navigator.pop(dialogContext, source),
                    ),
                  if (failures.isNotEmpty) Text(failures.join('\n')),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(AppLocalizations.of(dialogContext).cancel),
              ),
            ],
          ),
        );
      }
      if (!mounted || chosen == null) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => HtmlSourceBrowser(
            source: chosen!.data,
            keyword: '',
            directBook: HtmlBook(url: url, title: ''),
            service: widget.service,
            transport: widget.transport,
          ),
        ),
      );
      if (mounted) await reload();
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              urlResult = AppLocalizations.of(context).openBookUrlFailed('$e'),
        );
      }
    } finally {
      if (mounted) setState(() => matchingUrl = false);
    }
  }

  /// Shows a source's rate-limited `toast`/`longToast` notice on this widget's
  /// messenger; a disposed widget drops it silently.
  void _showHostNotice(SourceHostMessage message) {
    if (!mounted) return;
    showSourceNotice(context, message);
  }

  Future<void> action(String action, ShelfEntry entry) async {
    // 换源 is not a write on its own: the page it opens searches, and
    // `ShelfService.switchSource` writes when a candidate is picked.
    if (action == 'switch') {
      final switched = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => PreciseSearchPage(
            service: widget.service,
            switchBook: entry,
            transport: widget.transport,
          ),
        ),
      );
      if (mounted && switched == true) await reload();
      return;
    }
    setState(() {
      busyId = entry.id;
      error = null;
    });
    try {
      if (action == 'remove') {
        await widget.service.remove(entry.id);
      } else {
        final source = entry.sourceJson;
        final pipeline = _openPipeline(
          source,
          widget.transport ?? HttpSourceTransport(),
        );
        try {
          final (book, chapters) = await withTlsExceptionConfirmation(
            context: context,
            hostState: widget.service.hostState,
            sourceRef: entry.sourceRef,
            sourceName: '${source['bookSourceName'] ?? ''}',
            run: () => pipeline.details(entry.htmlBook),
          );
          await widget.service.updateCatalog(entry.sourceRef, book, chapters);
        } finally {
          pipeline.cancel();
        }
      }
      if (mounted) await reload();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = AppLocalizations.of(
            context,
          ).operationFailedShelfKept('$e'),
        );
      }
    } finally {
      if (mounted) setState(() => busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.onlineShelfTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _bookUrl,
                  decoration: InputDecoration(
                    labelText: l10n.bookUrl,
                    prefixIcon: Icon(Icons.link),
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => openUrl(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: l10n.openBookUrl,
                onPressed: matchingUrl ? null : openUrl,
                icon: matchingUrl
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward),
              ),
            ],
          ),
        ),
        if (urlResult != null && urlResult!.isNotEmpty)
          Text(urlResult!, style: Theme.of(context).textTheme.bodySmall),
        if (loading) const LinearProgressIndicator(),
        if (error != null)
          Row(
            children: [
              Expanded(child: Text(error!)),
              TextButton(onPressed: reload, child: Text(l10n.retry)),
            ],
          ),
        if (!loading && books.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(l10n.shelfFromSourceHint),
          ),
        for (final entry in books)
          ListTile(
            title: Text(entry.title),
            subtitle: Text(
              entry.sourceMissing
                  ? l10n.sourceDeletedKept
                  : entry.chapterKey.isEmpty
                  ? l10n.notReadYet
                  : entry.chapterName ?? l10n.continueLastChapter,
            ),
            leading: Icon(
              entry.sourceMissing ? Icons.link_off : Icons.menu_book_outlined,
            ),
            enabled: busyId == null,
            // Nothing can open a book whose source is gone: the only action that
            // makes sense for it is taking it off the shelf.
            onTap: entry.sourceMissing ? null : () => open(entry),
            trailing: busyId == entry.id
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(),
                  )
                : PopupMenuButton<String>(
                    enabled: busyId == null,
                    tooltip: l10n.bookActions,
                    onSelected: (value) => action(value, entry),
                    itemBuilder: (_) => [
                      if (!entry.sourceMissing)
                        PopupMenuItem(
                          value: 'refresh',
                          child: Text(l10n.updateTableOfContents),
                        ),
                      if (!entry.sourceMissing)
                        PopupMenuItem(
                          value: 'switch',
                          child: Text(l10n.switchSource),
                        ),
                      PopupMenuItem(
                        value: 'remove',
                        child: Text(l10n.removeFromShelf),
                      ),
                    ],
                  ),
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}
