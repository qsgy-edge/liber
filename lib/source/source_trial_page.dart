import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../store/shelf.dart';
import 'http_source_transport.dart';
import 'html_source_browser.dart';
import 'json_source_pipeline.dart';
import 'source_tls_confirmation.dart';

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
  bool busy = false;
  String status = '选择书源并输入关键词。';
  SourceReadingResult? result;

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
        throw const FormatException('请选择 Legado 单个书源或书源数组 JSON');
      }
      if (!mounted) return;
      setState(() {
        sources = items.cast<Map<String, dynamic>>();
        selected = 0;
        result = null;
        status = '已载入 ${sources.length} 个书源，仅用于本次试读';
      });
    } catch (error) {
      if (mounted) setState(() => status = '载入失败：$error');
    }
  }

  Future<void> run() async {
    if (busy || selected == null || keyword.text.trim().isEmpty) return;
    final source = sources[selected!];
    final search = source['ruleSearch'];
    final listRule = search is Map ? '${search['bookList'] ?? ''}' : '';
    if (listRule.isEmpty ||
        listRule.startsWith('@js:') ||
        listRule.startsWith('<js>') ||
        listRule.startsWith('@XPath:') ||
        listRule.startsWith('/')) {
      setState(() {
        result = null;
        status = '试读失败：暂不支持该列表规则，请选择其他书源。';
      });
      return;
    }
    final jsonRule =
        listRule.startsWith('@Json:') ||
        listRule.startsWith(r'$.') ||
        listRule.startsWith(r'$[');
    if (search is Map && !jsonRule) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => HtmlSourceBrowser(
            source: source,
            keyword: keyword.text.trim(),
            service: widget.service,
          ),
        ),
      );
      return;
    }
    setState(() {
      busy = true;
      result = null;
    });
    try {
      final output = await withTlsExceptionConfirmation(
        context: context,
        hostState: widget.service.hostState,
        sourceRef: '${source['bookSourceUrl'] ?? ''}',
        sourceName: '${source['bookSourceName'] ?? ''}',
        run: () => JsonSourcePipeline(
          HttpSourceTransport(),
          hostState: widget.service.hostState,
        ).run(
          source,
          keyword.text.trim(),
          (state) {
            if (mounted) setState(() => status = state.message);
          },
        ),
      );
      if (mounted) setState(() => result = output);
    } catch (error) {
      if (mounted) setState(() => status = '试读失败：$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('书源试读')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('搜索后选书，再查看目录和正文。当前支持速读谷及就爱文学所用的部分规则；登录和共享脚本库尚未支持。'),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      try {
                        final saved = await widget.service.lastRead();
                        if (!mounted) return;
                        if (saved == null) {
                          setState(() => status = '尚无在线阅读记录');
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
                        if (mounted) setState(() => status = '恢复失败：$e');
                      }
                    },
              icon: const Icon(Icons.history),
              label: const Text('继续上次阅读'),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: busy
                  ? null
                  : () async {
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
                          result = null;
                          status = '已载入速读谷，点击搜索后选择书籍';
                        });
                      } catch (e) {
                        if (mounted) setState(() => status = '载入失败：$e');
                      }
                    },
              child: const Text('使用速读谷书源'),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: busy ? null : openSource,
              child: const Text('选择书源 JSON'),
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
              onChanged: busy
                  ? null
                  : (value) => setState(() => selected = value),
            ),
          TextField(
            controller: keyword,
            enabled: !busy,
            decoration: const InputDecoration(labelText: '搜索关键词'),
            onSubmitted: (_) => run(),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: busy || selected == null ? null : run,
              child: Text(busy ? '正在读取…' : '搜索'),
            ),
          ),
          const SizedBox(height: 16),
          SelectableText(status),
          if (result case final output?) ...[
            const Divider(height: 32),
            Text(
              output.title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text('${output.chapters.length} 章 · ${output.chapters.first.name}'),
            const SizedBox(height: 16),
            SelectableText(output.content),
            ExpansionTile(
              title: const Text('请求记录'),
              children: [
                for (final entry in output.trace)
                  ListTile(
                    title: Text(entry.stage.name),
                    subtitle: SelectableText(entry.path),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
