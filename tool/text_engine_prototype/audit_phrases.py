"""Audit a phrase table against the Wikipedia reference, entry by entry.

OpenCC's Taiwan/Hong Kong phrase lists are the best free source for mainland
wording, but they are one community's choices: TWPhrasesRev maps 檔案館 to
文件馆 where the mainland word is 档案馆, and 存檔 to 存盘 where it is 存档. This
script finds those entries by *asking the corpus*: for every entry, what does the
`zh-cn` rendering of the same article actually say where the `zh-tw` rendering
has the key?

For each entry the script counts three outcomes at every occurrence:

- `match` — the reference used exactly the table's value;
- `differ` — the reference converted too, to something else (the interesting
  case: the table says 文件馆, the reference says 档案馆);
- `kept` — the reference left the word alone (either the word is fine in the
  mainland too, or the reference is incomplete).

Entries that pass a visibility threshold and disagree are printed with their
alternatives and two examples, which is what a human decides on. The same pass
runs over Legado's exclude list, where the question is the opposite: does the
reference really keep those words verbatim?

Usage:
  python tool/text_engine_prototype/audit_phrases.py [--eval <dir>] [--out <path>]
"""
import argparse
import collections
import difflib
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DEFAULT_EVAL = pathlib.Path('D:/liber-probe/text-engine/eval')
DICT_DIR = pathlib.Path('D:/liber-probe/text-engine/opencc-dict')
CRATE = ROOT / 'packages/fjs/liber_text'

# Legado's fixT2sDict, the words the frozen reader protects from t2s.
LEGADO_EXCLUDE = [
    '槃', '划槳', '列根', '雪梨', '雪糕', '零錢', '零钱', '離線', '碟片', '模組', '桌球', '案頭',
    '機車', '電漿', '鳳梨', '魔戒', '載入', '菲林', '整合', '變數', '路易斯', '非同步', '出租车',
    '周杰倫', '马铃薯', '馬鈴薯', '機械人', '電單車', '電扶梯', '音效卡', '飆車族', '點陣圖',
    '個入球', '顆進球', '魔獸紀元', '高空彈跳', '铁达尼号', '魔鬼終結者', '純文字檔案',
]


def load_character_map() -> dict[str, str]:
    """The HanLP t2s character table: what each Traditional character becomes."""
    table = {}
    for line in (CRATE / 'assets/hanlp-tc/t2s.txt').read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        key, _, value = line.partition('=')
        if len(key) == 1 and len(value) == 1 and key != value:
            table[key] = value
    return table


def char_convert(text: str, characters: dict[str, str]) -> str:
    return ''.join(characters.get(character, character) for character in text)


def read_opencc(path: pathlib.Path) -> dict[str, str]:
    table = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        key, _, values = line.partition('\t')
        words = values.split()
        if key and words:
            table[key] = words[0]
    return table


def change_map(source: str, target: str) -> dict:
    """Source position -> what the target has there ('' if dropped); missing = unchanged."""
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


def index_keys(keys: list[str]) -> dict[str, list[str]]:
    """First character -> the keys that start with it, longest first."""
    by_first: dict[str, list[str]] = collections.defaultdict(list)
    for key in keys:
        by_first[key[0]].append(key)
    for entries in by_first.values():
        entries.sort(key=len, reverse=True)
    return by_first


def occurrences(source: str, by_first: dict[str, list[str]]) -> list[tuple[int, str]]:
    """Longest-match occurrences of the key set in `source`, non-overlapping."""
    found = []
    at = 0
    while at < len(source):
        for key in by_first.get(source[at], ()):
            if source.startswith(key, at):
                found.append((at, key))
                at += len(key)
                break
        else:
            at += 1
    return found


def audit(rows: list[dict], table: dict[str, str], by_first, label: str) -> dict:
    stats: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    examples: dict[str, list] = collections.defaultdict(list)
    for row in rows:
        source, reference = row['source'], row['reference']
        changes = change_map(source, reference)
        for at, key in occurrences(source, by_first):
            end = at + len(key)
            changed = [index for index in range(at, end) if index in changes]
            if not changed:
                produced = key
            elif len(changed) == end - at:
                # Every position of the key was rewritten. When they all point at
                # the same replaced segment, that segment is the reference's
                # wording for the whole key; several distinct segments mean the
                # alignment crossed other edits too, which is not evidence.
                segments = list(dict.fromkeys(changes[index] for index in changed))
                produced = segments[0] if len(segments) == 1 else None
            else:
                produced = None
            if produced is None:
                stats[key]['mixed'] += 1
                continue
            outcome = 'match' if produced == table[key] else ('kept' if produced == key else 'differ')
            stats[key][outcome] += 1
            stats[key]['seen:' + produced] += 1
            if outcome != 'match' and len(examples[key]) < 2:
                examples[key].append({'source': source[max(0, at - 12):end + 12],
                                      'reference': produced, 'table': table[key],
                                      'title': row.get('title')})
    report = {}
    for key, counts in sorted(stats.items(), key=lambda item: -sum(item[1].values())):
        total = counts['match'] + counts['differ'] + counts['kept']
        alternatives = sorted(((seen.split(':', 1)[1], count) for seen, count in counts.items()
                               if seen.startswith('seen:') and seen.split(':', 1)[1] != table[key]),
                              key=lambda item: -item[1])
        report[key] = {
            'value': table[key],
            'total': total,
            'mixed': counts['mixed'],
            'alternatives': alternatives[:5],
            'match': counts['match'],
            'differ': counts['differ'],
            'kept': counts['kept'],
            'match_rate': counts['match'] / total if total else 0.0,
            'examples': examples.get(key, []),
        }
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--eval', type=pathlib.Path, default=DEFAULT_EVAL)
    parser.add_argument('--out', type=pathlib.Path, default=None)
    parser.add_argument('--min-total', type=int, default=1)
    parser.add_argument('--max-match-rate', type=float, default=0.8)
    parser.add_argument('--print', choices=('flagged', 'seen'), default='flagged')
    arguments = parser.parse_args()
    out = arguments.out or arguments.eval / 'audit-phrases.json'

    gold = arguments.eval / 'gold-wikipedia.jsonl'
    rows = [json.loads(line) for line in gold.read_text(encoding='utf-8').splitlines() if line.strip()]
    print(f'{len(rows)} reference rows from {gold}')

    characters = load_character_map()
    raw_tables = {
        'TWPhrasesRev': read_opencc(DICT_DIR / 'TWPhrasesRev.txt'),
        'HKPhrasesRev': read_opencc(DICT_DIR / 'HKPhrasesRev.txt'),
        'legado-exclude': {word: word for word in LEGADO_EXCLUDE},
    }
    tables = {}
    no_op = {}
    for name, table in raw_tables.items():
        tables[name] = {key: char_convert(value, characters) for key, value in table.items()}
        no_op[name] = {key for key, value in tables[name].items()
                       if value == char_convert(key, characters)}
    report = {}
    for name, table in tables.items():
        by_first = index_keys(list(table))
        audited = audit(rows, table, by_first, name)
        flagged = {key: entry for key, entry in audited.items()
                   if entry['total'] >= arguments.min_total
                   and entry['match_rate'] < arguments.max_match_rate}
        report[name] = {
            'entries': len(table),
            'no_op_entries': sorted(no_op[name]),
            'seen': len(audited),
            'flagged': flagged,
            'all': audited if arguments.min_total > 1 else None,
        }
        print(f'\n=== {name}: {len(table)} entries, {len(audited)} seen in the corpus, '
              f'{len(flagged)} disagreement-heavy')
        shown = audited if arguments.print == 'seen' else flagged
        for key, entry in sorted(shown.items(), key=lambda item: -item[1]['total'])[:400]:
            example = entry['examples'][0] if entry['examples'] else None
            alternatives = ', '.join(f'{value}×{count}' for value, count in entry['alternatives'][:3])
            print(f"  {key} → {entry['value']}  n={entry['total']} "
                  f"(match {entry['match']}, differ {entry['differ']}, kept {entry['kept']})"
                  + (f"  ref: {alternatives}" if alternatives else ''))
    out.write_text(json.dumps(report, ensure_ascii=False, indent=1) + '\n', encoding='utf-8',
                    newline='\n')
    print(f'\nwrote {out}')


if __name__ == '__main__':
    main()
