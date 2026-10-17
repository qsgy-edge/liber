import 'package:fjs/fjs.dart';

import 'native_library.dart';

/// One fetched page plus every rule of one pipeline stage, evaluated together.
///
/// The frozen reader parses a page once and evaluates each rule against that
/// tree. [HtmlRuleBatch] keeps that shape across the bridge: jobs are declared
/// first and run in a single call. A stage may declare a second batch when
/// per-item list grouping needs the first batch's count.
///
/// A batch fails as a whole: the first rule the adapter cannot evaluate throws
/// here, which is how the frozen reader behaves too (its analysis aborts on the
/// first unsupported rule).
class HtmlRuleBatch {
  HtmlRuleBatch(this.html);

  final String html;
  final _jobs = <HtmlRuleJob>[];
  final _outcomes = <String, HtmlJobOutcome>{};
  bool _ran = false;

  /// Elements matching [rule], optionally scoped to one earlier selection.
  HtmlElementSet elements(
    String id,
    String rule, {
    HtmlElementSet? parent,
    int? parentIndex,
  }) => HtmlElementSet._(
    this,
    _add(
      id,
      rule,
      parent?.id,
      HtmlJobOutput.elements,
      parentIndex: parentIndex,
    ),
  );

  /// CSS selection over all parent contexts, deduplicated by native identity.
  HtmlElementSet collectionCssSelect(
    String id,
    String css, {
    HtmlElementSet? parent,
    int? parentIndex,
  }) => HtmlElementSet._(
    this,
    _add(id, css, parent?.id, HtmlJobOutput.collectionCssSelect, parentIndex: parentIndex),
  );

  /// Replays a serializable node path against this batch's original document.
  HtmlElementSet selection(
    String id,
    Iterable<({String rule, int? parentIndex, bool cssSelect})> steps,
  ) {
    HtmlElementSet? parent;
    var index = 0;
    for (final step in steps) {
      final stepId = '$id:${index++}';
      parent = step.cssSelect
          ? collectionCssSelect(stepId, step.rule, parent: parent, parentIndex: step.parentIndex)
          : elements(stepId, step.rule, parent: parent, parentIndex: step.parentIndex);
    }
    return parent ?? elements(id, ':root');
  }

  /// The value [rule] yields for the document itself, in the frozen
  /// `AnalyzeByJSoup.getString` shape: a document rule's matches are joined with
  /// `"\n"` before the `##` replacement runs on the join, and the result is
  /// entity-unescaped last.
  HtmlString documentText(String id, String rule) =>
      HtmlString._(this, _add(id, rule, null, HtmlJobOutput.text));

  /// The values [rule] yields for the document itself, in the frozen
  /// `AnalyzeRule.getStringList` shape: one value per match, the `##` replacement
  /// applied to each value, and no entity unescape.
  ///
  /// A rule whose whole value is a list is read this way by the frozen stages
  /// ([documentText] is the joined, unescaped read of the same rule); a rule the
  /// pipeline reads as one value keeps using [documentText].
  HtmlStringList documentTextList(String id, String rule) =>
      HtmlStringList._(this, _add(id, rule, null, HtmlJobOutput.textList));

  /// The value [rule] yields for the document itself, in the frozen
  /// `AnalyzeRule.getString(rule, unescape = false)` shape: the joined extraction
  /// and the `##` replacement with no entity unescape. The frozen content stage
  /// reads `ruleContent.content` this way (`BookContent.kt:177`) and runs its one
  /// unescape after the formatter.
  HtmlString documentTextRaw(String id, String rule) =>
      HtmlString._(this, _add(id, rule, null, HtmlJobOutput.textRaw));

  /// One value per element matched by [context].
  HtmlStringList elementsText(String id, String rule, HtmlElementSet context) =>
      HtmlStringList._(this, _add(id, rule, context.id, HtmlJobOutput.text));

  /// List extraction scoped to each context. The `@html` item snapshot uses
  /// this output to preserve serialized entities before scalar evaluation.
  HtmlStringList elementsTextList(
    String id,
    String rule,
    HtmlElementSet context,
  ) => HtmlStringList._(
    this,
    _add(id, rule, context.id, HtmlJobOutput.textList),
  );

  /// First present raw attribute; empty and whitespace remain actual values.
  HtmlStringList rawAttribute(String id, String name, HtmlElementSet context) =>
      HtmlStringList._(this, _add(id, name, context.id, HtmlJobOutput.rawAttribute));

  String _add(
    String id,
    String rule,
    String? parent,
    HtmlJobOutput output, {
    int? parentIndex,
  }) {
    if (_ran) throw StateError('该规则批次已经执行');
    if (parentIndex != null && (parentIndex < 0 || parentIndex > 0x7fffffff)) {
      throw UnsupportedError('parentIndex 必须是非负 i32 索引');
    }
    _jobs.add(
      HtmlRuleJob(
        id: id,
        rule: rule,
        parent: parent,
        parentIndex: parentIndex,
        output: output,
      ),
    );
    return id;
  }

  /// Evaluates every declared job in one bridge call.
  Future<void> run() async {
    if (_ran) throw StateError('该规则批次已经执行');
    if (_jobs.isEmpty) {
      _ran = true;
      return;
    }
    await NativeLibrary.ready;
    final outcomes = htmlAnalyze(html: html, jobs: _jobs);
    _ran = true;
    for (final outcome in outcomes) {
      final failure = outcome.failure;
      if (failure != null) throw _ruleFailure(failure);
      _outcomes[outcome.id] = outcome;
    }
  }

  HtmlJobOutcome _result(String id) {
    final outcome = _outcomes[id];
    if (outcome == null) throw StateError('该规则任务尚未执行：$id');
    return outcome;
  }
}

Object _ruleFailure(HtmlJobFailure failure) => switch (failure.kind) {
  'parse' => FormatException(failure.message),
  'runtime' => StateError(failure.message),
  _ => UnsupportedError(failure.message),
};

/// The element matches of one [HtmlRuleBatch.elements] job. The adapter keeps
/// the tree; later jobs address these matches as contexts by index.
class HtmlElementSet {
  HtmlElementSet._(this._batch, this.id);

  final HtmlRuleBatch _batch;
  final String id;

  int get length => _batch._result(id).count;
  bool get isEmpty => length == 0;
}

/// The values one job extracted, one entry each: one value per element of an
/// [HtmlElementSet] for an [HtmlRuleBatch.elementsText] job, or one value per
/// match for an [HtmlRuleBatch.documentTextList] job.
class HtmlStringList {
  HtmlStringList._(this._batch, this.id);

  final HtmlRuleBatch _batch;
  final String id;

  List<String> get values => _batch._result(id).values;
}

/// The value one rule yields for the document or for a single context.
class HtmlString {
  HtmlString._(this._batch, this.id);

  final HtmlRuleBatch _batch;
  final String id;

  String get value {
    final values = _batch._result(id).values;
    return values.isEmpty ? '' : values.first;
  }

  /// Whether the rule extracted a value before its `##` replacement ran.
  bool get hasMatch => _batch._result(id).count > 0;

  bool get isEmpty => value.isEmpty;
}
