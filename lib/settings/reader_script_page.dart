import 'dart:async';

import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:flutter/material.dart';

import '../store/space_store.dart';
import 'reader_script.dart';

/// The reader's Chinese-conversion setting: the installation's choice and, when
/// the screen is opened from a book, that book's override.
///
/// The screen owns only the rows it writes. Whoever pushed it re-resolves
/// through [ReaderScriptSetting.resolve] when it comes back, which is what
/// re-renders an open book without reopening it — no file is indexed again and
/// the reader's stored position does not move.
class ReaderScriptPage extends StatefulWidget {
  const ReaderScriptPage({
    super.key,
    required this.store,
    this.bookId = '',
    this.bookTitle,
  });

  /// The open space's store, the one the setting's two rows live in.
  final SpaceStore store;

  /// The book whose override this screen also edits, or empty for the
  /// installation's choice alone.
  final String bookId;

  /// The book's title, so the override names the book it belongs to.
  final String? bookTitle;

  @override
  State<ReaderScriptPage> createState() => _ReaderScriptPageState();
}

class _ReaderScriptPageState extends State<ReaderScriptPage> {
  ReaderScriptChoice? _global;
  ReaderScriptChoice? _book;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Reads the two rows once: the installation's choice and, when this screen
  /// was opened from a book, that book's override.
  Future<void> _load() async {
    try {
      final stored = await widget.store.setting(ReaderScriptSetting.key);
      final override = widget.bookId.isEmpty
          ? null
          : await widget.store.setting(
              ReaderScriptSetting.key,
              bookId: widget.bookId,
            );
      if (!mounted) return;
      setState(() {
        _global = ReaderScriptSetting.globalChoice(stored);
        _book = override == null
            ? ReaderScriptChoice.followGlobal
            : ReaderScriptSetting.bookChoice(override);
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = '读取设置失败：$error');
    }
  }

  Future<void> _selectGlobal(ReaderScriptChoice choice) async {
    setState(() => _global = choice);
    try {
      await ReaderScriptSetting.putGlobal(widget.store, choice);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '保存设置失败：$error');
    }
  }

  Future<void> _selectBook(ReaderScriptChoice choice) async {
    setState(() => _book = choice);
    try {
      await ReaderScriptSetting.putBook(widget.store, widget.bookId, choice);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '保存设置失败：$error');
    }
  }

  /// What the two rows resolve to right now, so a reader sees what a choice and
  /// the system locale together produce.
  ConvertTarget? get _effective {
    final global = _global;
    final book = _book;
    if (book != null && book != ReaderScriptChoice.followGlobal) {
      return ReaderScriptSetting.targetFor(
        book,
        ReaderScriptSetting.systemLocale(),
      );
    }
    return global == null
        ? null
        : ReaderScriptSetting.targetFor(
            global,
            ReaderScriptSetting.systemLocale(),
          );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final global = _global;
    final book = _book;
    return Scaffold(
      appBar: AppBar(title: const Text('中文转换')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            '默认跟随系统语言：zh-CN → 简体（大陆用词），zh-TW → 繁體（台灣），'
            'zh-HK → 繁體（香港），其他语言 → 不转换。',
            key: const ValueKey('reader-script-default'),
          ),
          const SizedBox(height: 8),
          Text(
            '当前系统语言：${ReaderScriptSetting.systemLocale().toLanguageTag()}',
            key: const ValueKey('reader-script-locale'),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            '当前生效：${describeReaderScript(_effective)}',
            key: const ValueKey('reader-script-effective'),
            style: theme.textTheme.titleMedium,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, key: const ValueKey('reader-script-error')),
          ],
          const SizedBox(height: 16),
          Text('安装设置', style: theme.textTheme.titleLarge),
          if (global == null)
            const ListTile(title: Text('正在读取…'))
          else
            RadioGroup<ReaderScriptChoice>(
              groupValue: global,
              onChanged: (choice) {
                if (choice != null) unawaited(_selectGlobal(choice));
              },
              child: Column(
                children: [
                  for (final choice in _installationChoices)
                    RadioListTile<ReaderScriptChoice>(
                      key: ValueKey('reader-script-global-${choice.slug}'),
                      value: choice,
                      title: Text(choice.label),
                    ),
                ],
              ),
            ),
          if (widget.bookId.isNotEmpty) ...[
            const Divider(height: 32),
            Text(
              '本书覆盖：${widget.bookTitle ?? widget.bookId}',
              style: theme.textTheme.titleLarge,
            ),
            if (book == null)
              const ListTile(title: Text('正在读取…'))
            else
              RadioGroup<ReaderScriptChoice>(
                groupValue: book,
                onChanged: (choice) {
                  if (choice != null) unawaited(_selectBook(choice));
                },
                child: Column(
                  children: [
                    for (final choice in _bookChoices)
                      RadioListTile<ReaderScriptChoice>(
                        key: ValueKey('reader-script-book-${choice.slug}'),
                        value: choice,
                        title: Text(choice.label),
                      ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// The installation's list: follow the locale, then the five manual choices.
  static const List<ReaderScriptChoice> _installationChoices = [
    ReaderScriptChoice.followLocale,
    ...ReaderScriptSetting.manualChoices,
  ];

  /// A book's list: no override, then the five manual choices.
  static const List<ReaderScriptChoice> _bookChoices = [
    ReaderScriptChoice.followGlobal,
    ...ReaderScriptSetting.manualChoices,
  ];
}
