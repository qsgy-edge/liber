import 'package:fjs/fjs.dart';

import 'native_library.dart';

/// One fetched page plus every rule of one pipeline stage, evaluated together.
///
/// The frozen reader parses a page once and evaluates each rule against that
/// tree. [HtmlRuleBatch] keeps that shape across the bridge: jobs are declared
/// first and run in a single call, so a document is marshalled once per page
/// instead of once per selector.
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

  /// Elements matching [rule] in the whole document.
  HtmlElementSet elements(String id, String rule) =>
      HtmlElementSet._(this, _add(id, rule, null, HtmlJobOutput.elements));

  /// The value [rule] yields for the document itself.
  HtmlString documentText(String id, String rule) =>
      HtmlString._(this, _add(id, rule, null, HtmlJobOutput.text));

  /// One value per element matched by [context].
  HtmlStringList elementsText(String id, String rule, HtmlElementSet context) =>
      HtmlStringList._(this, _add(id, rule, context.id, HtmlJobOutput.text));

  String _add(String id, String rule, String? parent, HtmlJobOutput output) {
    if (_ran) throw StateError('该规则批次已经执行');
    _jobs.add(
      HtmlRuleJob(id: id, rule: rule, parent: parent, output: output),
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
    final outcomes = await htmlAnalyze(html: html, jobs: _jobs);
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
  bool get isNotEmpty => length != 0;
}

/// One value per element of an [HtmlElementSet].
class HtmlStringList {
  HtmlStringList._(this._batch, this.id);

  final HtmlRuleBatch _batch;
  final String id;

  List<String> get values => _batch._result(id).values;
  String operator [](int index) => values[index];
  int get length => values.length;
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

  bool get isEmpty => value.isEmpty;
  bool get isNotEmpty => value.isNotEmpty;
}
