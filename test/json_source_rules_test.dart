import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/json_source_rules.dart';

/// The document `tool/jsonpath_probe/JsonPathProbe.java` was run against, in the
/// shape that probe reads. Every expectation below is a line of
/// `tool/jsonpath_probe/transcript.txt`, produced by json-path 2.9.0 — the
/// library the frozen `AnalyzeByJSonPath.kt` wraps — or, where this adapter
/// refuses a form, a case the probe names as the library's own refusal.
final document =
    jsonDecode(r'''
{
  "code": 0,
  "nul": null,
  "nums": [1,2,3,4],
  "data": [
    {"hasContent":1,"content":"A","title":"T1","n":5,"s":"10","tags":["x","y"]},
    {"hasContent":0,"content":"B","title":"","n":10,"s":"9","tags":[]},
    {"hasContent":"1","content":"C","n":15.5,"tags":["z","y"]},
    {"content":"D","n":20,"m":{"deep":true}},
    {"hasContent":2,"content":"E","n":null}
  ],
  "meta": {"className":"玄幻","step":1},
  "menus": [
    {"title":"M1","url":"/m1","children":[{"title":"C1"},{"url":"/c2"}]},
    {"url":"/m2"}
  ],
  "plain": ["p1","p2","p3"]
}
''')
        as Map<String, Object?>;

List<Object?> data = document['data']! as List<Object?>;
Map<String, Object?> meta = document['meta']! as Map<String, Object?>;

/// The `content` of the rows a filter kept.
List<Object?> contents(String filter) => JsonSourceRules.values(
  document,
  r'$.data'
  '$filter'
  r'.content',
);

void main() {
  test('supports arrays and recursive JSONPath values', () {
    final root = {
      'data': [
        {'novelId': '1', 'name': 'A'},
        {'novelId': '2', 'name': 'B'},
      ],
      'meta': {'className': '玄幻'},
    };
    expect(JsonSourceRules.list(root, r'$.data[*]').length, 2);
    expect(JsonSourceRules.text(root, r'$.data[0].novelId'), '1');
    expect(JsonSourceRules.values(root, r'$..className'), ['玄幻']);
    expect(
      JsonSourceRules.template(
        root,
        'id='
        '{{'
        r'$.data[1].novelId'
        '}}',
      ),
      'id=2',
    );
  });

  group('filters', () {
    test('the forms the used sources reach', () {
      // `$.data[?(@.hasContent==1)].content` matches the row whose value is the
      // *string* "1" too: the frozen `NumberNode.equals` parses the string.
      expect(contents('[?(@.hasContent==1)]'), ['A', 'C']);
      expect(contents('[?(@.hasContent=="1")]'), ['A', 'C']);
      expect(contents("[?(@.hasContent=='1')]"), ['A', 'C']);
      // `$..menus..[?(@.title)]`: the map itself and the nested one.
      expect(JsonSourceRules.values(document, r'$..menus..[?(@.title)]'), [
        (document['menus']! as List).first,
        ((document['menus']! as List).first as Map)['children']![0],
      ]);
      // `.[?(@.title)]` without a leading `$`: json-path prefixes `$.`, so the
      // rule is the recursive `$..[?(@.title)]` and finds the nested titles.
      expect(JsonSourceRules.values(document, r'.[?(@.title)]'), [
        data[0],
        data[1],
        (document['menus']! as List).first,
        ((document['menus']! as List).first as Map)['children']![0],
      ]);
    });

    test('comparisons, and the pairings that compare nothing', () {
      expect(contents('[?(@.n > 9)]'), ['B', 'C', 'D']);
      expect(contents('[?(@.n < 9)]'), ['A']);
      expect(contents('[?(@.n <= 10)]'), ['A', 'B']);
      expect(contents('[?(@.n != 10)]'), ['A', 'C', 'D', 'E']);
      expect(contents('[?(@.s >= "10")]'), ['A', 'B']);
      expect(contents("[?(@.s < '10')]"), <Object?>[]);
      // A string against a number matches nothing: the frozen `<`/`>` need both
      // operands to be numbers or both to be strings.
      expect(contents('[?(@.s > 9)]'), <Object?>[]);
      expect(contents('[?(@.n > "9")]'), <Object?>[]);
    });

    test('a comparison against a missing key is false, not an error', () {
      expect(contents('[?(@.missing==1)]'), <Object?>[]);
      expect(contents('[?(@.missing != 1)]'), ['A', 'B', 'C', 'D', 'E']);
    });

    test('existence: the compiler form, not the `exists` operator', () {
      // `[?(@.hasContent)]` is the existence check the frozen compiler builds,
      // and a present-but-null key counts as existing.
      expect(JsonSourceRules.values(document, r'$.data[?(@.nulKey)]'), isEmpty);
      expect(JsonSourceRules.values(document, r'$.data[?(@.hasContent)]'), [
        data[0],
        data[1],
        data[2],
        data[4],
      ]);
      expect(contents('[?(!@.hasContent)]'), ['D']);
      expect(contents('[?(@.missing)]'), <Object?>[]);
      // Written out by hand, `exists` reads the path's own *value*: the frozen
      // `ExistsEvaluator` needs two booleans, so this matches nothing at all.
      expect(contents('[?(@.hasContent exists true)]'), <Object?>[]);
    });

    test('logical operators, grouping and negation', () {
      expect(contents('[?(@.hasContent && @.n > 9)]'), ['B', 'C']);
      expect(contents('[?(@.hasContent==1 || @.hasContent==2)]'), [
        'A',
        'C',
        'E',
      ]);
      expect(contents('[?(!(@.hasContent==1))]'), ['B', 'D', 'E']);
      expect(contents('[?(@.hasContent==1 && @.missing)]'), <Object?>[]);
    });

    test('a nested filter reads the contained document', () {
      expect(contents('[?(@.m[?(@.deep)])]'), ['D']);
      expect(JsonSourceRules.values(document, r'$..menus[?(@.title)]'), [
        (document['menus']! as List).first,
      ]);
    });

    test('the operator set the frozen library reaches beyond existence', () {
      // `=~` is a full match (`Matcher.matches`), and its flags are the ones a
      // Dart RegExp carries exactly.
      expect(contents(r'[?(@.content =~ /^[ABC]$/)]'), ['A', 'B', 'C']);
      expect(contents(r'[?(@.content =~ /^[ab]$/i)]'), ['A', 'B']);
      expect(contents(r'[?(@.content =~ /A/)]'), ['A']);
      // `in`/`nin` hold a JSON list literal, single-quoted or not.
      expect(contents('[?(@.hasContent in [1,2])]'), ['A', 'C', 'E']);
      expect(contents("[?(@.hasContent in ['1'])]"), ['A', 'C']);
      expect(contents('[?(@.hasContent nin [1,2])]'), ['B', 'D']);
      // `size` and `empty` read a string's or an array's own length.
      expect(contents('[?(@.title size 2)]'), ['A']);
      expect(contents('[?(@.tags size 2)]'), ['A', 'C']);
      expect(contents('[?(@.title empty false)]'), ['A']);
      expect(contents('[?(@.title empty true)]'), ['B']);
      expect(contents('[?(@.tags empty true)]'), ['B']);
      // `=~` needs exactly one pattern operand: a string on both sides matches
      // nothing rather than being compiled as a pattern.
      expect(contents('[?(@.content =~ "A")]'), <Object?>[]);
    });

    test('a filter over scalars, and over the map it points at', () {
      expect(JsonSourceRules.values(document, r'$.nums[?(@>2)]'), [3, 4]);
      expect(JsonSourceRules.values(document, r"$.plain[?(@=='p2')]"), ['p2']);
      expect(JsonSourceRules.values(document, r'$.meta[?(@.className)]'), [
        meta,
      ]);
      expect(
        JsonSourceRules.values(document, r"$.meta[?(@.className=='玄幻')]"),
        [meta],
      );
    });

    test('a filter after another filter keeps reading the matches', () {
      expect(
        JsonSourceRules.values(document, r'$.data[?(@.hasContent)].content'),
        ['A', 'B', 'C', 'E'],
      );
    });
  });

  group('slices', () {
    List<Object?> slice(String text) => JsonSourceRules.values(
      document,
      r'$.data'
      '$text'
      r'.content',
    );

    test('the frozen slice forms', () {
      expect(slice('[1:3]'), ['B', 'C']);
      expect(slice('[0:2]'), ['A', 'B']);
      expect(slice('[:2]'), ['A', 'B']);
      expect(slice('[2:]'), ['C', 'D', 'E']);
      expect(slice('[:-2]'), ['A', 'B', 'C']);
      expect(slice('[:99]'), ['A', 'B', 'C', 'D', 'E']);
      expect(slice('[7:]'), <Object?>[]);
      expect(slice('[10:20]'), <Object?>[]);
      expect(slice('[3:1]'), <Object?>[]);
      // `SLICE_BETWEEN` does not resolve a negative end against the length, so
      // `[1:-1]` selects nothing where `[:-2]` gives all but the last two.
      expect(slice('[1:-1]'), <Object?>[]);
    });

    test('negative indexes and a negative open end count from the end', () {
      expect(slice('[-2:]'), ['D', 'E']);
      expect(JsonSourceRules.values(document, r'$.data[-1]'), [data[4]]);
      expect(JsonSourceRules.values(document, r'$.data[-99]'), <Object?>[]);
      expect(JsonSourceRules.values(document, r'$.data[0,2].content'), [
        'A',
        'C',
      ]);
    });

    test(
      'a third slice field is ignored, exactly as the frozen parse ignores it',
      () {
        // `ArraySliceOperation.parse` reads two fields and drops the rest, so the
        // jar returns the same matches for `[1:3:2]` and `[1:3]`.
        expect(slice('[1:3:2]'), slice('[1:3]'));
        expect(slice('[1:3:2]'), ['B', 'C']);
      },
    );

    test('a slice reads its matches as a set, not as one value', () {
      // The frozen `ArraySliceToken` is indefinite, so a token after it sees
      // each match: `[0]` over the *maps* a slice picked out matches nothing.
      expect(JsonSourceRules.values(document, r'$.data[1:3][0].content'), []);
      expect(JsonSourceRules.values(document, r'$.data[1:3].tags[0]'), ['z']);
    });

    test('a slice on an object or a null fails loudly', () {
      expect(
        () => JsonSourceRules.values(document, r'$.meta[1:2]'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('can only be applied to arrays'),
          ),
        ),
      );
      expect(
        () => JsonSourceRules.values(document, r'$.meta.className[1:2]'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => JsonSourceRules.values(document, r'$.nul[1:2]'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('is null'),
          ),
        ),
      );
    });

    test('a scan whose array token is not the leaf is refused by name', () {
      // The frozen `ScanPathToken.walkArray` applies the *next* token to every
      // element and reports a property leaf only for the element whose index the
      // token before the leaf names, so `$..[0].content` answers a set decided by
      // that comparison. Nothing uses the form, so the adapter refuses it.
      for (final rule in [
        r'$..[0].content',
        r'$..[1:2].content',
        r'$..*.content',
      ]) {
        expect(
          () => JsonSourceRules.values(document, rule),
          throwsA(isA<UnsupportedError>()),
          reason: rule,
        );
      }
      // The whole-array form is well defined and read: the first element of
      // every array the scan meets, in document order.
      expect(JsonSourceRules.values(document, r'$..[0]'), [
        1,
        data[0],
        'x',
        'z',
        (document['menus']! as List).first,
        ((document['menus']! as List).first as Map)['children']![0],
        'p1',
      ]);
    });
  });

  group('refusals', () {
    test('an unsupported form fails with the named error, never silently', () {
      const unsupported = <String>[
        // A single `=` is not an operator: the frozen filter compiler answers
        // "Expected character: )".
        r'$.data[?(@.hasContent=1)].content',
        // Arithmetic and functions in a filter path.
        r'$.data[?(@.title.length() > 1)].content',
        // Operators the frozen library knows and this adapter does not run.
        r"$.data[?(@.title contains 'T')].content",
        r'$.data[?(@.hasContent === 1)].content',
        // A literal where an operator's own operand shape is required.
        r"$.data[?(@.title size 'two')].content",
        r'$.data[?(@.title empty 1)].content',
        r"$.data[?(@.title in 'abc')].content",
        r'$.data[?(@.title exists 1)].content',
        // Path shapes: a quoted property, an unquoted name, a trailing dot, an
        // unterminated bracket, a space inside a slice, no-bound slices.
        r"$.data['title']",
        r'$.data[a:b]',
        r'$.data.',
        r'$.data..',
        r'$..',
        r'$.data*',
        r'$.data[1:3',
        r'$.data[ 1 : 3 ]',
        r'$.data[::2]',
        r'$.data[:]',
        r'$.data[+1:2]',
        // A rule that is not a path at all.
        r'@Other:$.a',
      ];
      for (final rule in unsupported) {
        expect(
          () => JsonSourceRules.values(document, rule),
          throwsA(
            isA<UnsupportedError>().having(
              (error) => '$error',
              'message',
              contains('Unsupported JSON rule'),
            ),
          ),
          reason: rule,
        );
        expect(
          () => JsonSourceRules.validate(rule),
          throwsA(isA<UnsupportedError>()),
          reason: 'validate $rule',
        );
      }
    });

    test('the forms the used sources reach validate without a document', () {
      for (final rule in [
        r'$.data[?(@.hasContent==1)].content',
        r'$..menus..[?(@.title)]',
        r'.[?(@.title)]',
        r'$.data[1:2]',
      ]) {
        expect(
          () => JsonSourceRules.validate(rule),
          returnsNormally,
          reason: rule,
        );
      }
      // The gate is the parse, not a probe against an empty document: a rule
      // whose shape the *document* would refuse is still a rule the reader runs.
      expect(() => JsonSourceRules.validate(r'$[1:2]'), returnsNormally);
    });
  });

  test(
    'a dot-leading rule is read as a path rather than answered with its text',
    () {
      // The frozen reader decides a rule's mode from the content it was given, so
      // a rule a JSON body sees is a path whatever its first character is.
      expect(JsonSourceRules.extract({'content': 'A'}, '.content'), 'A');
      expect(JsonSourceRules.extract(document, '.[?(@.title)]'), isNotNull);
      // A dot-leading rule that is not a path is refused by name, where the frozen
      // reader answers with the library's swallowed exception.
      expect(
        () => JsonSourceRules.extract({'content': 'A'}, '.content@text'),
        throwsA(isA<UnsupportedError>()),
      );
    },
  );

  test('extract and list keep the field shapes the pipelines pass', () {
    expect(
      JsonSourceRules.list(document, r'$.data[?(@.hasContent==1)].content'),
      ['A', 'C'],
    );
    expect(
      JsonSourceRules.text(document, r'$.data[?(@.content=="D")].content'),
      'D',
    );
    expect(JsonSourceRules.read(document, r'$.data[0].content'), 'A');
    expect(
      JsonSourceRules.read(document, r'$.data[?(@.missing)].content'),
      isNull,
    );
  });

  test('a value rule joins what it matched, as the frozen getString does', () {
    // A definite path whose value is an array joins its elements, and an
    // indefinite one joins its matches — the frozen
    // `if (ob is List<*>) ob.joinToString("\n") else ob.toString()`.
    expect(JsonSourceRules.extract(document, r'$.plain'), 'p1\np2\np3');
    expect(
      JsonSourceRules.extract(document, r'$.data[?(@.hasContent==1)].content'),
      'A\nC',
    );
    // One match is the same text it always was, and no match is the empty field
    // the missing value leaves.
    expect(JsonSourceRules.extract(document, r'$.data[0].title'), 'T1');
    expect(
      JsonSourceRules.extract(document, r'$.data[?(@.missing)].content'),
      '',
    );
    expect(
      JsonSourceRules.extract(
        document,
        r'$.data[?(@.missing)].content##$##,{"webView":true}',
      ),
      '',
    );
    expect(
      JsonSourceRules.extract(document, r'$.data[0].content##$##,{"webView":true}'),
      'A,{"webView":true}',
    );
    // `list()` is the frozen `getStringList`, which hands the list back itself.
    expect(
      JsonSourceRules.list(document, r'$.data[?(@.hasContent==1)].content'),
      ['A', 'C'],
    );
  });

  test(
    'source-derived: value merges join or stop at the first nonempty part',
    () {
      const root = {
        'a': 'A',
        'b': 'B',
        'blank': '',
        'arr': ['x', 'y'],
      };
      expect(JsonSourceRules.extract(root, r'$.a&&$.b'), 'A\nB');
      expect(
        JsonSourceRules.extract(root, r'$.missing||$.blank||$.b||$.a'),
        'B',
      );
      expect(JsonSourceRules.extract(root, r'$.arr&&$.a'), 'x\ny\nA');
      expect(JsonSourceRules.extract(root, r'$.a&&$.b##B##C'), 'A\nC');
      // RuleAnalyzer splits on the first top-level operator; getString then
      // evaluates each split part recursively (no invented global precedence).
      expect(JsonSourceRules.extract(root, r'$.a&&$.missing||$.b'), 'A\nB');
      expect(JsonSourceRules.extract(root, r'$.a||$.b&&$.arr'), 'A');
      expect(JsonSourceRules.extract(root, r'$.missing||$.blank'), '');
      expect(JsonSourceRules.extract({'a': null, 'b': 'B'}, r'$.a||$.b'), 'B');
      expect(
        JsonSourceRules.extract({'a': 'null', 'b': 'B'}, r'$.a||$.b'),
        'null',
      );
    },
  );

  test(
    'source-derived: list merges concatenate, stop, or interleave to first length',
    () {
      const root = {
        'short': ['a', 'b'],
        'long': ['1', '2', '3'],
        'empty': [],
      };
      expect(JsonSourceRules.list(root, r'$.short&&$.long'), [
        'a',
        'b',
        '1',
        '2',
        '3',
      ]);
      expect(JsonSourceRules.list(root, r'$.empty||$.short||$.long'), [
        'a',
        'b',
      ]);
      expect(JsonSourceRules.list(root, r'$.short%%$.long'), [
        'a',
        '1',
        'b',
        '2',
      ]);
      expect(JsonSourceRules.list(root, r'$.long%%$.short'), [
        '1',
        'a',
        '2',
        'b',
        '3',
      ]);
      expect(
        () => JsonSourceRules.validate(r'$.short%%$.long', forList: true),
        returnsNormally,
      );
      expect(
        () => JsonSourceRules.validate(r'$.short%%$.long'),
        throwsA(isA<UnsupportedError>()),
      );
    },
  );

  test(
    'source-derived: list merge skips definite scalar and null branches',
    () {
      const root = {
        'scalar': 'x',
        'nul': null,
        'chapters': [
          {'name': 'One'},
        ],
        'rows': [
          {'name': 'Two'},
        ],
      };
      expect(
        JsonSourceRules.list(root, r'$.scalar||$.chapters'),
        root['chapters'],
      );
      expect(
        JsonSourceRules.list(root, r'$.nul||$.chapters'),
        root['chapters'],
      );
      expect(
        JsonSourceRules.list(root, r'$.scalar&&$.chapters'),
        root['chapters'],
      );
      expect(JsonSourceRules.list(root, r'$.rows[*].name||$.chapters'), [
        'Two',
      ]);
      // Existing simple-list callers still receive a scalar as one result.
      expect(JsonSourceRules.list(root, r'$.scalar'), ['x']);
    },
  );

  test(
    'source-derived: filter operators and quoted delimiters stay in one path',
    () {
      const root = {
        'rows': [
          {'a': true, 'b': false, 'tag': 'x&&y', 'value': 'A'},
          {'a': false, 'b': true, 'tag': 'x||y', 'value': 'B'},
        ],
        'tail': 'C',
      };
      const rule = r'$.rows[?(@.a || @.b)].value&&$.tail';
      expect(JsonSourceRules.extract(root, rule), 'A\nB\nC');
      expect(
        JsonSourceRules.list(
          root,
          r'$.rows[?(@.tag=="x&&y")].value&&$.rows[?(@.tag=="x||y")].value',
        ),
        ['A', 'B'],
      );
      expect(() => JsonSourceRules.validate(rule), returnsNormally);
      expect(
        JsonSourceRules.extract(
          root,
          r"$.rows[?(@.tag=='x&&y')].value||$.tail",
        ),
        'A',
      );
    },
  );

  test(
    'source-derived: @Json: selects JSON mode without entering the path',
    () {
      const root = {
        'a': 'A',
        'b': ['B'],
      };
      expect(JsonSourceRules.extract(root, r'@Json:$.a&&$.b'), 'A\nB');
      expect(JsonSourceRules.list(root, r'@jSoN:$.b'), ['B']);
      expect(JsonSourceRules.template(root, r'@JSON:$.a'), 'A');
      expect(
        () => JsonSourceRules.validate(r'@JSON:$.a||$.b'),
        returnsNormally,
      );
    },
  );
}
