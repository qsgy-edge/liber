import 'package:html/dom.dart';

/// Source-derived CSS and Legado chain/index/extraction subset.
/// XPath, JS rules and general Jsoup pseudo-selectors remain unsupported.
class HtmlSourceRules {
  static String _selector(String selector) => selector.replaceAllMapped(
    RegExp(r'''\[([\w-]+)(\^?=)([^"'\]]+)\]'''),
    (m) => '[${m[1]}${m[2]}"${m[3]}"]',
  );

  static List<Element> _select(Node node, String selector) => switch (node) {
    Document document => document.querySelectorAll(selector),
    Element element => element.querySelectorAll(selector),
    DocumentFragment fragment => fragment.querySelectorAll(selector),
    _ => <Element>[],
  };

  static List<Element> _css(Node context, String selector) {
    selector = _selector(selector);
    String? ownText;
    final own = RegExp(
      r':matchesOwn\(\^([^()\\.*+?\[\]{}|]+)\$\)$',
    ).firstMatch(selector);
    if (own != null) {
      ownText = own[1];
      selector = selector.substring(0, own.start);
    }
    if (selector.contains(':')) {
      throw UnsupportedError('暂不支持此 CSS 扩展：$selector');
    }
    final elements = _select(context, selector);
    // Jsoup Element.select includes the context element itself.
    if (context is Element &&
        context.parentNode != null &&
        _select(context.parentNode!, selector).contains(context)) {
      elements.insert(0, context);
    }
    if (ownText != null) {
      elements.removeWhere((e) => _ownText(e) != ownText);
    }
    return elements;
  }

  static List<Element> elements(Node context, String rule) {
    rule = rule.trim();
    if (rule.startsWith('@CSS:')) return _css(context, rule.substring(5));
    if (rule.isEmpty ||
        rule.contains('&&') ||
        rule.contains('||') ||
        rule.contains('%%') ||
        rule.contains('@js:') ||
        rule.contains('@XPath:')) {
      throw UnsupportedError('暂不支持该元素规则');
    }
    var nodes = <Node>[context];
    for (final part in rule.split('@')) {
      final next = <Element>[];
      for (final node in nodes) {
        next.addAll(_step(node, part.trim()));
      }
      nodes = next;
    }
    return nodes.cast<Element>();
  }

  static List<Element> _step(Node node, String rule) {
    final index = RegExp(r'([.!])(-?\d+(?::-?\d+)*)$').firstMatch(rule);
    final selector = index == null ? rule : rule.substring(0, index.start);
    List<Element> items;
    if (selector.startsWith('text.')) {
      final needle = selector.substring(5).toLowerCase();
      items = _css(
        node,
        '*',
      ).where((e) => _ownText(e).toLowerCase().contains(needle)).toList();
    } else {
      items = _css(node, selector);
    }
    if (index == null) return items;
    // Legacy colon syntax is an ordered list, not a start:end:step range.
    final positions = <int>{};
    for (final raw in index[2]!.split(':')) {
      var i = int.parse(raw);
      if (i < 0) i += items.length;
      if (i >= 0 && i < items.length) positions.add(i);
    }
    if (index[1] == '!') {
      return [
        for (var i = 0; i < items.length; i++)
          if (!positions.contains(i)) items[i],
      ];
    }
    return [for (final i in positions) items[i]];
  }

  static String _normal(String value) =>
      value.replaceAll(RegExp(r'[\s\u00a0]+'), ' ').trim();
  static String _ownText(Element element) =>
      _normal(element.nodes.whereType<Text>().map((n) => n.data).join());

  static String replace(String text, String rule) {
    final parts = rule.split('##');
    if (parts.length < 2) return text;
    if (parts.length > 3 || (parts.length == 3 && parts[2].isNotEmpty)) {
      throw UnsupportedError('暂不支持该替换形式');
    }
    return text.replaceAll(RegExp(parts[1]), '');
  }

  static String text(Node context, String rule) {
    final base = rule.split('##').first.trim();
    final at = base.lastIndexOf('@');
    final operation = at < 0 ? base : base.substring(at + 1);
    if (!['text', 'textNodes', 'href', 'src'].contains(operation)) {
      throw UnsupportedError('不支持的提取方式：$operation');
    }
    final items = at < 0
        ? (context is Element ? [context] : <Element>[])
        : elements(context, base.substring(0, at));
    final values = <String>[];
    for (final item in items) {
      final value = switch (operation) {
        'text' => _normal(item.text),
        'textNodes' =>
          item.nodes
              .whereType<Text>()
              .map((n) => _normal(n.data))
              .where((v) => v.isNotEmpty)
              .join('\n'),
        _ => item.attributes[operation] ?? '',
      };
      if (value.isNotEmpty &&
          (operation == 'text' ||
              operation == 'textNodes' ||
              !values.contains(value))) {
        values.add(value);
      }
    }
    return replace(values.join('\n'), rule);
  }
}
