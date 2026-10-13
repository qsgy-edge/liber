import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../store/shelf.dart';

/// All Book Sources in the current space, including those excluded from search.
class BookSourceManagementPage extends StatefulWidget {
  const BookSourceManagementPage({super.key, required this.service});

  final ShelfService service;

  @override
  State<BookSourceManagementPage> createState() =>
      _BookSourceManagementPageState();
}

class _BookSourceManagementPageState extends State<BookSourceManagementPage> {
  final _filter = TextEditingController();
  List<ImportedBookSource> _sources = const [];
  List<ImportedBookSource> _visible = const [];
  final _pending = <String>{};
  final _failed = <String>{};
  bool _loading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  String _name(ImportedBookSource source) =>
      '${source.data['bookSourceName'] ?? source.id}';

  void _applyFilter() {
    final query = _filter.text.trim().toLowerCase();
    _visible = [
      for (final source in _sources)
        if (_name(source).toLowerCase().contains(query) ||
            source.id.toLowerCase().contains(query))
          source,
    ];
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final sources = await widget.service.sources();
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _applyFilter();
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _setEnabled(ImportedBookSource source, bool enabled) async {
    if (_pending.contains(source.id)) return;
    setState(() {
      _pending.add(source.id);
      _failed.remove(source.id);
    });
    try {
      await widget.service.setSourceEnabled(source.id, enabled);
      if (!mounted) return;
      setState(() {
        _sources = [
          for (final current in _sources)
            if (current.id == source.id)
              ImportedBookSource(
                id: current.id,
                data: {...current.data, 'enabled': enabled},
              )
            else
              current,
        ];
        _applyFilter();
      });
    } on Object {
      if (mounted) setState(() => _failed.add(source.id));
    } finally {
      if (mounted) setState(() => _pending.remove(source.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.bookSourcesTitle)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: TextField(
              key: const ValueKey('book-source-filter'),
              controller: _filter,
              decoration: InputDecoration(
                labelText: l10n.findBookSources,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _filter.text.isEmpty
                    ? null
                    : IconButton(
                        key: const ValueKey('book-source-clear-filter'),
                        tooltip: l10n.clearBookSourceFilter,
                        onPressed: () => setState(() {
                          _filter.clear();
                          _applyFilter();
                        }),
                        icon: const Icon(Icons.clear),
                      ),
              ),
              onChanged: (_) => setState(_applyFilter),
            ),
          ),
          if (_loading)
            const LinearProgressIndicator(key: ValueKey('book-source-loading'))
          else if (_loadFailed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Text(l10n.bookSourcesLoadFailed),
                  TextButton(
                    key: const ValueKey('book-source-retry'),
                    onPressed: _load,
                    child: Text(l10n.retry),
                  ),
                ],
              ),
            )
          else if (_visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _sources.isEmpty
                    ? l10n.noSourcesInSpace
                    : l10n.noMatchingBookSources,
                key: const ValueKey('book-source-empty'),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                key: const ValueKey('book-source-list'),
                itemCount: _visible.length,
                itemBuilder: (_, index) {
                  final source = _visible[index];
                  final enabled = source.data['enabled'] != false;
                  final pending = _pending.contains(source.id);
                  return SwitchListTile(
                    key: ValueKey('book-source-enabled-${source.id}'),
                    title: Text(_name(source)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(source.id),
                        Text(
                          enabled
                              ? l10n.bookSourceEnabled
                              : l10n.bookSourceDisabled,
                        ),
                        if (_failed.contains(source.id))
                          Text(
                            l10n.bookSourceToggleFailed,
                            key: ValueKey('book-source-error-${source.id}'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                    secondary: pending
                        ? SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              key: ValueKey('book-source-pending-${source.id}'),
                              strokeWidth: 2,
                            ),
                          )
                        : null,
                    value: enabled,
                    onChanged: pending
                        ? null
                        : (value) => unawaited(_setEnabled(source, value)),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
