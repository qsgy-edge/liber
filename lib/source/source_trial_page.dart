import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../store/shelf.dart';
import 'book_source_pipeline.dart' show sourceCheckKeyword;
import 'html_source_browser.dart';

class SourceTrialPage extends StatefulWidget {
  const SourceTrialPage({
    super.key,
    required this.sources,
    required this.service,
  });
  final List<ImportedBookSource> sources;

  /// The space's shelf, which a source trial writes into once a book is read.
  final ShelfService service;
  @override
  State<SourceTrialPage> createState() => _SourceTrialPageState();
}

class _SourceTrialPageState extends State<SourceTrialPage> {
  final keyword = TextEditingController();
  late List<Map<String, dynamic>> sources;
  int? selected;

  /// What the page last did, or null before it has done anything: the initial
  /// line is the build's, because it is copy (`lib/l10n/`) and a `State` field
  /// has no context to read it with.
  String? status;

  @override
  void initState() {
    super.initState();
    sources = widget.sources.map((item) => item.data).toList();
    if (sources.isNotEmpty) selected = 0;
  }

  @override
  void dispose() {
    keyword.dispose();
    super.dispose();
  }

  Future<void> openSource() async {
    final l10n = AppLocalizations.of(context);
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) return;
      final data = jsonDecode(utf8.decode(await file.readAsBytes()));
      final items = data is List ? data : [data];
      if (items.isEmpty ||
          items.any(
            (item) =>
                item is! Map<String, dynamic> ||
                item['bookSourceUrl'] is! String,
          )) {
        throw FormatException(l10n.sourceJsonRequired);
      }
      if (!mounted) return;
      setState(() {
        sources = items.cast<Map<String, dynamic>>();
        selected = 0;
        status = l10n.sourcesLoaded(sources.length);
      });
    } catch (error) {
      if (mounted) setState(() => status = l10n.loadSourceFailed('$error'));
    }
  }

  /// Opens the browser on the selected source.
  ///
  /// The browser holds the pipeline and decides which adapter the source's
  /// rules need, so a JSON source is searched, shelved and read exactly like an
  /// HTML one instead of stopping at a text preview (ticket #29).
  Future<void> run() async {
    final l10n = AppLocalizations.of(context);
    var keywordText = keyword.text.trim();
    if (keywordText.isEmpty) {
      try {
        keywordText = sourceCheckKeyword(sources[selected!], '');
      } on FormatException catch (error) {
        setState(() => status = l10n.readSourceFailed(error.message));
        return;
      }
    }
    if (keywordText.isEmpty) {
      setState(() => status = l10n.enterKeyword);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => HtmlSourceBrowser(
          source: sources[selected!],
          keyword: keywordText,
          service: widget.service,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final message = status ?? l10n.chooseSourceAndKeyword;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.actionSourceTrial)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(l10n.sourceTrialIntro),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                try {
                  final saved = await widget.service.lastRead();
                  if (!mounted) return;
                  if (saved == null) {
                    setState(() => status = l10n.noOnlineReading);
                    return;
                  }
                  // A book whose source was deleted (#53) has no source object
                  // to hand the browser: say so instead of opening an empty one.
                  if (saved.sourceMissing) {
                    setState(() => status = l10n.lastReadSourceDeleted);
                    return;
                  }
                  if (!context.mounted) return;
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => HtmlSourceBrowser(
                        source: saved.sourceJson,
                        keyword: '',
                        resume: saved,
                        service: widget.service,
                      ),
                    ),
                  );
                } catch (e) {
                  if (mounted) setState(() => status = l10n.resumeFailed('$e'));
                }
              },
              icon: const Icon(Icons.history),
              label: Text(l10n.continueLastReading),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () async {
                try {
                  final data =
                      jsonDecode(
                            await rootBundle.loadString(
                              'book_sources/shudugu.json',
                            ),
                          )
                          as List;
                  if (!mounted) return;
                  setState(() {
                    sources = data.cast<Map<String, dynamic>>();
                    selected = 0;
                    keyword.text = '凡人修仙传';
                    status = l10n.shuduguLoaded;
                  });
                } catch (e) {
                  if (mounted) {
                    setState(() => status = l10n.loadSourceFailed('$e'));
                  }
                }
              },
              child: Text(l10n.useShuduguSource),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: openSource,
              child: Text(l10n.chooseSourceJson),
            ),
          ),
          if (sources.isNotEmpty)
            DropdownButton<int>(
              isExpanded: true,
              value: selected,
              items: [
                for (var i = 0; i < sources.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '${sources[i]['bookSourceName'] ?? sources[i]['bookSourceUrl']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => selected = value),
            ),
          TextField(
            controller: keyword,
            decoration: InputDecoration(labelText: l10n.searchKeyword),
            onSubmitted: (_) => run(),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: selected == null ? null : run,
              child: Text(l10n.search),
            ),
          ),
          const SizedBox(height: 16),
          SelectableText(message),
        ],
      ),
    );
  }
}
