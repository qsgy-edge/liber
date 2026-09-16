"""Score every candidate's 繁体→简体 conversion against the accuracy gold sets.

The question here is not "does it agree with the frozen reader" but "is the
Simplified output right for a reader who only reads Simplified", so the numbers
are against references (Wikipedia's `zh-cn` variant rendering of a `zh-tw` page;
OpenCC's hand-made cases) *and* against one property that needs no reference at
all:

- **`traditional left`** — how many characters in the output are still
  Traditional, i.e. characters the t2s table has a mapping for. That is exactly
  what the reader would notice, and the reference itself has some, because
  Wikipedia's variant renderer is not a complete character conversion.

The reference-based errors are split by what happened at each source position:

- **missed** — the reference converted it, the candidate left it (the reader
  still sees Traditional where they should not);
- **wrong** — both converted it, differently (character-layer mistake, or a
  different wording choice);
- **over, correct** — the candidate converted a position the reference left
  Traditional, *and* the result is that character's own Simplified form. The
  candidate is more complete than the reference here, which is what we want;
- **over, other** — the candidate changed a position the reference left alone,
  to something that is not the plain character mapping (usually a wording choice
  the reference did not make).

Every disagreement is also classified: whether the candidate carries a
Traditional character the reference does not, whether the reference does and the
candidate does not, or whether both sides are Simplified already and only the
wording differs. Nothing here is a verdict on its own — the reference is one
community's choice, and Taiwan→mainland word choice has no legal standard — so
each set also reports the most frequent disagreements, counted per page so a
repeated citation template cannot dominate.

Usage:
  python tool/text_engine_prototype/score_eval.py [--eval <dir>] [--out <dir>]
"""
import argparse
import collections
import difflib
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DEFAULT_EVAL = pathlib.Path('D:/liber-probe/text-engine/eval')
TRADITIONAL_TABLE = ROOT / 'packages/fjs/liber_text/assets/hanlp-tc/t2s.txt'
SIMPLIFIED_TABLE = ROOT / 'packages/fjs/liber_text/assets/hanlp-tc/s2t.txt'

# Which candidates belong to which direction: a t2s candidate run over an s2t
# set would only add noise to the table.
T2S_CANDIDATES = [
    'frozen',
    'liber-now',
    'hanlp',
    'hanlp+exclude',
    'hanlp+tw+hk',
    'opencc-t2s',
    'opencc-t2s+exclude',
    'opencc-tw2s',
    'opencc-tw2sp',
]
S2T_CANDIDATES = [
    'frozen',
    'liber-generic',
    'liber-taiwan',
    'liber-hongkong',
    'opencc-s2t',
    'opencc-s2tw',
    'opencc-s2twp',
    'opencc-s2hk',
]


def load_character_map() -> dict[str, str]:
    """The characters the t2s table actually changes, and what they become.

    The table also carries identity entries (and entries for characters that are
    legal in both scripts, like 著), so "a table key" is not the same as
    "Traditional"; only a mapping that changes the character is.
    """
    table = {}
    for line in TRADITIONAL_TABLE.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        key, _, value = line.partition('=')
        if len(key) == 1 and len(value) == 1 and key != value:
            table[key] = value
    return table


def change_map(source: str, target: str) -> dict:
    """For each source position that `target` changed, what it became ('' if dropped)."""
    map_: dict[int, str] = {}
    if len(source) == len(target):
        for index, (before, after) in enumerate(zip(source, target)):
            if before != after:
                map_[index] = after
        return map_
    matcher = difflib.SequenceMatcher(None, list(source), list(target), autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == 'equal':
            continue
        segment = ''.join(target[j1:j2])
        for index in range(i1, i2):
            map_[index] = segment
    return map_


def classify(reference_segment: str, candidate_segment: str, character_map: dict) -> str:
    """Why two conversions disagree: leftover characters, or wording."""
    reference_traditional = any(character in character_map for character in reference_segment)
    candidate_traditional = any(character in character_map for character in candidate_segment)
    if candidate_traditional and not reference_traditional:
        return 'candidate keeps Traditional'
    if reference_traditional and not candidate_traditional:
        return 'reference keeps Traditional'
    return 'wording differs'


def is_wording_variant(reference_segment: str, candidate_segment: str,
                       character_map: dict) -> bool:
    """Two rewrites that are both Simplified and both plausible mainland wording.

    电脑 against 计算机, 信息 against 资讯: this product chose a word the
    reference did not, but nothing here is a character error, and mainland usage
    accepts both. Counting these as errors would reward agreement with one
    reference's style; the scorer keeps them separate and reports both rates.
    """
    if len(reference_segment) < 2 or len(candidate_segment) < 2:
        return False
    if reference_segment == candidate_segment:
        return False
    return not any(character in character_map
                   for character in reference_segment + candidate_segment)


def traditional_left(text: str, character_map: dict) -> int:
    """Characters the reader would still read as Traditional."""
    return sum(1 for character in text if character in character_map)


def load_simplified_map() -> dict[str, str]:
    """The s2t character table: the characters that have a Traditional form."""
    table = {}
    for line in SIMPLIFIED_TABLE.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        key, _, value = line.partition('=')
        if len(key) == 1 and len(value) == 1 and key != value:
            table[key] = value
    return table


def score_row(row: dict, output: str, character_map: dict) -> dict:
    source, reference = row['source'], row['reference']
    reference_changes = change_map(source, reference)
    candidate_changes = change_map(source, output)
    counts = collections.Counter()
    pairs: dict[str, collections.Counter] = {
        'wrong': collections.Counter(),
        'missed': collections.Counter(),
        'over_other': collections.Counter(),
    }
    for index, character in enumerate(source):
        expected = reference_changes.get(index)
        actual = candidate_changes.get(index)
        if expected is None and actual is None:
            counts['kept'] += 1
            continue
        if expected is not None and actual == expected:
            counts['converted'] += 1
            continue
        if expected is not None and actual is None:
            counts['missed'] += 1
            pairs['missed'][f'{character}→{expected}'] += 1
            continue
        if expected is not None:
            counts['wrong'] += 1
            if is_wording_variant(expected, actual, character_map):
                counts['wording'] += 1
            counts['why:' + classify(expected, actual, character_map)] += 1
            pairs['wrong'][f'{expected}→{actual}'] += 1
            continue
        # Only the candidate changed this position. If it wrote something free of
        # Traditional characters where the source had a Traditional one, it is
        # converting further than the reference rather than disagreeing (a phrase
        # mapping such as 計畫 → 计划 lands here, as it should).
        if character_map.get(character) == actual or (
            character in character_map
            and not any(part in character_map for part in actual)
        ):
            counts['over_correct'] += 1
        else:
            counts['over_other'] += 1
            if is_wording_variant(character, actual, character_map):
                counts['wording'] += 1
            counts['why:' + classify(character, actual, character_map)] += 1
            pairs['over_other'][f'{character}→{actual}'] += 1
    return {
        'counts': counts,
        'pairs': pairs,
        'exact': output == reference,
        'candidate_traditional': traditional_left(output, character_map),
        'reference_traditional': traditional_left(reference, character_map),
        'source_traditional': traditional_left(source, character_map),
        'code_units': len(output),
    }


def score_set(gold_path: pathlib.Path, out_dir: pathlib.Path, character_map: dict,
              simplified_map: dict | None = None) -> dict:
    rows = [json.loads(line) for line in gold_path.read_text(encoding='utf-8').splitlines() if line.strip()]
    candidates = {}
    allowed = S2T_CANDIDATES if gold_path.stem.endswith('s2t') else T2S_CANDIDATES
    for path in sorted(out_dir.glob('*.jsonl')):
        if path.stem not in allowed:
            continue
        candidates[path.stem] = {
            row['id']: row['output']
            for row in (json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip())
        }
    report = {}
    names = sorted(candidates, key=lambda name: allowed.index(name) if name in allowed else 99)
    for name in names:
        outputs = candidates[name]
        totals = collections.Counter()
        pair_pages: dict[str, dict[str, set]] = {
            'wrong': collections.defaultdict(set),
            'missed': collections.defaultdict(set),
            'over_other': collections.defaultdict(set),
        }
        exact = short_exact = short_rows = 0
        positions = 0
        samples = []
        for row in rows:
            output = outputs.get(row['id'])
            if output is None:
                raise SystemExit(f'{name} has no output for {row["id"]}')
            result = score_row(row, output, character_map)
            totals.update(result['counts'])
            totals['candidate_traditional'] += result['candidate_traditional']
            totals['reference_traditional'] += result['reference_traditional']
            totals['source_traditional'] += result['source_traditional']
            if simplified_map is not None:
                totals['candidate_simplified'] += sum(
                    1 for character in output if character in simplified_map)
                totals['reference_simplified'] += sum(
                    1 for character in row['reference'] if character in simplified_map)
            totals['code_units'] += result['code_units']
            positions += sum(result['counts'].values())
            exact += bool(result['exact'])
            if len(row['source']) <= 32:
                short_rows += 1
                short_exact += bool(result['exact'])
            page = row.get('title', row.get('id'))
            for kind, pairs in result['pairs'].items():
                for pair, count in pairs.items():
                    pair_pages[kind][pair].add((page, row['id']))
                    pair_pages[kind][pair].add((page, f"extra{count}"))
            if not result['exact'] and len(samples) < 20 and len(row['source']) <= 120:
                samples.append({
                    'id': row['id'],
                    'title': row.get('title'),
                    'source': row['source'],
                    'reference': row['reference'],
                    'candidate': output,
                    'counts': dict(result['counts']),
                })
        errors = totals.get('missed', 0) + totals.get('wrong', 0) + totals.get('over_other', 0)
        core_errors = errors - totals.get('wording', 0)
        report[name] = {
            'rows': len(rows),
            'exact': exact,
            'exact_rate': exact / len(rows) if rows else 0.0,
            'short_rows': short_rows,
            'short_exact': short_exact,
            'short_exact_rate': short_exact / short_rows if short_rows else 0.0,
            'counts': dict(totals),
            'positions': positions,
            'error_positions': errors,
            'error_rate': errors / positions if positions else 0.0,
            'core_error_positions': core_errors,
            'core_error_rate': core_errors / positions if positions else 0.0,
            'wording_positions': totals.get('wording', 0),
            'candidate_traditional_per_1k': 1000 * totals['candidate_traditional'] / totals['code_units']
            if totals['code_units'] else 0.0,
            'reference_traditional_per_1k': 1000 * totals['reference_traditional'] / totals['code_units']
            if totals['code_units'] else 0.0,
            'source_traditional_per_1k': 1000 * totals['source_traditional'] / totals['code_units']
            if totals['code_units'] else 0.0,
            'candidate_residue_per_1k': 1000 * (totals['candidate_simplified'] if simplified_map
                                                else totals['candidate_traditional'])
            / totals['code_units'] if totals['code_units'] else 0.0,
            'reference_residue_per_1k': 1000 * (totals['reference_simplified'] if simplified_map
                                                else totals['reference_traditional'])
            / totals['code_units'] if totals['code_units'] else 0.0,
            'top_pairs': {
                kind: sorted(((pair, len(pages)) for pair, pages in pairs.items()),
                             key=lambda item: -item[1])[:25]
                for kind, pairs in pair_pages.items()
            },
            'samples': samples,
        }
    return {'gold': str(gold_path), 'rows': len(rows), 'candidates': report}


def markdown(report: dict) -> str:
    lines = [
        '# 繁体→简体 accuracy, measured against references',
        '',
        'A disagreement is not proof of an error. The reference is one community\'s',
        'choice — Wikipedia\'s `zh-cn` variant renderer, or OpenCC\'s hand-made cases —',
        'and Chinese word choice for Taiwan→mainland conversion has no legal standard.',
        'Two things are read together: how much Traditional is left in the output',
        '(independent of any reference, and what a Simplified-only reader sees), and how',
        'the disagreements with the reference split. `over, correct` means the candidate',
        'converted a position the reference left Traditional and got the plain character',
        'mapping right: that is the candidate being more complete, not an error.',
        '',
        'Two error rates are printed. The first counts every position where the two',
        'outputs differ; the second drops *wording variants* — positions where both',
        'sides are already Simplified and only the word choice differs (电脑 against',
        '计算机, 信息 against 资讯). Neither is wrong in mainland usage, and scoring',
        "them as errors would reward agreeing with one reference's style.",
        '',
    ]
    for set_name, set_report in report['sets'].items():
        lines.append(f"## {set_name} ({set_report['rows']} rows)")
        lines.append('')
        lines.append('| candidate | exact | short exact | error rate | error excl. wording | wording | missed | wrong | over, correct | over, other | '
                     + ('Simplified left /1k' if set_name.endswith('s2t')
                        else 'Traditional left /1k')
                     + ' (candidate / reference) |')
        lines.append('|---|---|---|---|---|---|---|---|---|---|---|')
        for name, candidate in set_report['candidates'].items():
            counts = candidate['counts']
            lines.append(
                f"| {name} | {candidate['exact']}/{candidate['rows']} "
                f"({candidate['exact_rate']:.1%}) | {candidate['short_exact']}/{candidate['short_rows']} "
                f"({candidate['short_exact_rate']:.1%}) | {candidate['error_rate']:.2%} | "
                f"{candidate['core_error_rate']:.2%} | {candidate['wording_positions']} | "
                f"{counts.get('missed', 0)} | {counts.get('wrong', 0)} | "
                f"{counts.get('over_correct', 0)} | {counts.get('over_other', 0)} | "
                f"{candidate['candidate_residue_per_1k']:.2f} / "
                f"{candidate['reference_residue_per_1k']:.2f} |")
        lines.append('')
        for name, candidate in set_report['candidates'].items():
            for kind, label in (('wrong', 'both converted, differently'),
                                ('missed', 'left as Traditional where the reference converted'),
                                ('over_other', 'changed where the reference did not')):
                pairs = candidate['top_pairs'].get(kind) or []
                if pairs:
                    lines.append(f"- **{name}** — {label} (per-page counts): "
                                 + ', '.join(f'{pair}×{count}' for pair, count in pairs[:12]))
        lines.append('')
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--eval', type=pathlib.Path, default=DEFAULT_EVAL)
    parser.add_argument('--out', type=pathlib.Path, default=None)
    arguments = parser.parse_args()
    out = arguments.out or arguments.eval
    character_map = load_character_map()
    simplified_map = load_simplified_map()
    report = {
        'note': 'Accuracy evaluation for Chinese conversion in both directions. References: '
                "gold-opencc* is OpenCC's own hand-made cases (Apache-2.0); gold-wikipedia* is "
                'zh.wikipedia.org variant=zh-tw against variant=zh-cn (CC BY-SA 4.0, not '
                'committed). The residue column counts characters still in the *other* script '
                '(Traditional left in a Simplified output, Simplified left in a Traditional '
                'one) against the HanLP character tables, independent of any reference.',
        'characterMapEntries': len(character_map),
        'sets': {},
    }
    for name in ('opencc', 'wikipedia', 'opencc-s2t', 'wikipedia-s2t'):
        gold = arguments.eval / f'gold-{name}.jsonl'
        out_dir = arguments.eval / f'out-{name}'
        if gold.exists() and out_dir.exists():
            report['sets'][name] = score_set(gold, out_dir, character_map,
                                             simplified_map=simplified_map if name.endswith('s2t') else None)
    (out / 'eval-report.json').write_text(
        json.dumps(report, ensure_ascii=False, indent=1) + '\n', encoding='utf-8', newline='\n')
    print(markdown(report))


if __name__ == '__main__':
    main()
