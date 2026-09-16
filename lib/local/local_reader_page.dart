import 'dart:async';

import 'package:flutter/material.dart';

import 'local_reader.dart';

/// The local reader: one bounded window of a local file at a time, opened at the
/// position D4's tiers restored, and paged by code-unit offset.
///
/// The page owns nothing but the session it was handed: [LocalReader] holds the
/// index, the position and the window, so a widget test can drive this page with
/// a fake engine instead of the native library.
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
    unawaited(_run(widget.reader.open));
  }

  Future<void> _run(Future<void> Function() action) async {
    await action();
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    await widget.reader.save();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('阅读位置已保存')));
  }

  @override
  Widget build(BuildContext context) {
    final reader = widget.reader;
    final position = reader.position;
    return Scaffold(
      appBar: AppBar(
        title: Text(reader.book.title),
        actions: [
          FilledButton.icon(
            onPressed: reader.busy || reader.error != null ? null : _save,
            icon: const Icon(Icons.bookmark_add),
            label: const Text('保存位置'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: reader.busy
          ? const Center(child: CircularProgressIndicator())
          : reader.error != null
          ? Center(child: Text('无法读取：${reader.error}'))
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
                          child: const Text('上一页'),
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
                          child: const Text('下一页'),
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
