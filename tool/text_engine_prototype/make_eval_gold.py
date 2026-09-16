"""Build the 繁体→简体 accuracy gold sets (ticket #19's follow-up question).

Two sets, both read-only inputs to the scorer:

- `gold-opencc.jsonl` — OpenCC's own `test/testcases/testcases.json` (Apache-2.0),
  filtered to the directions that end in Simplified Chinese. These are hand-made
  cases aimed at the hard spots, so they are dense in L2 ambiguity and small.
- `gold-wikipedia.jsonl` — the same Wikipedia articles rendered `variant=zh-tw`
  and `variant=zh-cn`, aligned line by line and then sentence by sentence. This is
  the real-world distribution: a Taiwan-rendered Traditional text and what the
  same article reads like in mainland Simplified, word choice included.

Neither is an authority. The first is OpenCC's own opinion of correct output; the
second is MediaWiki's conversion tables' opinion. They are *references*: a
candidate that disagrees has to be looked at, not automatically failed. The
scorer prints every disagreement it counts so the disagreements can be judged.

Usage:
  python tool/text_engine_prototype/make_eval_gold.py [--pages <dir>] [--out <dir>]
"""
import argparse
import hashlib
import json
import pathlib
import re
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TESTCASES_URL = 'https://raw.githubusercontent.com/BYVoid/OpenCC/master/test/testcases/testcases.json'
DEFAULT_PAGES = pathlib.Path('D:/liber-probe/text-engine/pages')
DEFAULT_OUT = pathlib.Path('D:/liber-probe/text-engine/eval')

# Which expected fields of a test case mean "Traditional in, Simplified out".
DIRECTIONS = {
    't2s': ('L2', 'OpenCC t2s: characters only, no regional wording'),
    'tw2s': ('L2+L3', 'OpenCC tw2s: Taiwan wording mapped to mainland wording, characters converted'),
    'hk2s': ('L2+L3', 'OpenCC hk2s: Hong Kong wording mapped to mainland wording'),
    'tw2sp': ('L2+L3', 'OpenCC tw2sp: Taiwan phrases and characters to mainland Simplified'),
    'hk2sp': ('L2+L3', 'OpenCC hk2sp: Hong Kong phrases and characters to mainland Simplified'),
}

# The other direction: Simplified in, Traditional (or regional) out.
DIRECTIONS_S2T = {
    's2t': ('L2', 'OpenCC s2t: characters only, no regional wording'),
    's2tw': ('L2+L3', 'OpenCC s2tw: Taiwan glyph norm'),
    's2twp': ('L2+L3', 'OpenCC s2twp: Taiwan glyph norm and wording'),
    's2hk': ('L2+L3', 'OpenCC s2hk: Hong Kong glyph norm'),
    's2hkp': ('L2+L3', 'OpenCC s2hkp: Hong Kong glyph norm and wording'),
}

SENTENCE_END = '。！？；…'


def fetch_testcases(cache: pathlib.Path) -> dict:
    path = cache / 'opencc-testcases.json'
    if not path.exists():
        request = urllib.request.Request(
            TESTCASES_URL, headers={'User-Agent': 'liber-ticket19-eval'})
        with urllib.request.urlopen(request, timeout=90) as response:
            raw = response.read().decode('utf-8')
        # The file is JSON with trailing commas, which OpenCC's own reader tolerates.
        path.write_text(re.sub(r',(\s*[}\]])', r'\1', raw), encoding='utf-8', newline='\n')
    return json.loads(path.read_text(encoding='utf-8'))


def opencc_rows(cache: pathlib.Path, direction: str = 't2s') -> list[dict]:
    rows = []
    table = DIRECTIONS if direction == 't2s' else DIRECTIONS_S2T
    for case in fetch_testcases(cache)['cases']:
        for config, expected in case['expected'].items():
            if config not in table:
                continue
            layer, note = table[config]
            rows.append({
                'id': f"opencc-{case['id']}-{config}",
                'origin': 'opencc-testcases',
                'config': config,
                'layer': layer,
                'note': note,
                'source': case['input'],
                'reference': expected,
            })
    return rows


def split_sentences(line: str) -> list[str]:
    parts = re.findall(f'[^{SENTENCE_END}]*[{SENTENCE_END}]+|[^{SENTENCE_END}]+$', line)
    return [part.strip() for part in parts if part.strip()]


def wikipedia_rows(pages: pathlib.Path, limit_pages: int | None,
                   direction: str = 't2s') -> tuple[list[dict], dict]:
    """Lines from page pairs that align: same page, `zh-tw` against `zh-cn`.

    For `t2s` the source is the Taiwan rendering and the reference is the
    mainland one; for `s2t` the two trade places, which makes the same corpus a
    reference for Traditional output.
    """
    by_request: dict[str, dict] = {}
    for path in sorted(pages.glob('*.json')):
        row = json.loads(path.read_text(encoding='utf-8'))
        if row.get('missing') or row.get('host') != 'zh.wikipedia.org':
            continue
        if row.get('variant') not in ('zh-tw', 'zh-cn'):
            continue
        by_request.setdefault(row['requested'], {})[row['variant']] = row

    stats = {
        'pages_paired': 0,
        'pages_unpaired': 0,
        'pages_line_count_mismatch': 0,
        'lines_total': 0,
        'lines_aligned_exactly': 0,
        'lines_sentence_aligned': 0,
        'lines_unsplittable': 0,
        'sentences': 0,
        'sentences_identical': 0,
    }
    rows = []
    for requested, variants in sorted(by_request.items()):
        if 'zh-tw' not in variants or 'zh-cn' not in variants:
            stats['pages_unpaired'] += 1
            continue
        if limit_pages is not None and stats['pages_paired'] >= limit_pages:
            break
        stats['pages_paired'] += 1
        tw, cn = variants['zh-tw'], variants['zh-cn']
        tw_lines = tw['text'].split('\n')
        cn_lines = cn['text'].split('\n')
        if len(tw_lines) != len(cn_lines):
            # A variant renderer that adds or drops a line makes the whole page
            # impossible to align; drop it and count it.
            stats['pages_line_count_mismatch'] += 1
            continue
        for index, (tw_line, cn_line) in enumerate(zip(tw_lines, cn_lines)):
            stats['lines_total'] += 1
            if tw_line == cn_line:
                stats['lines_aligned_exactly'] += 1
            tw_sentences = split_sentences(tw_line)
            cn_sentences = split_sentences(cn_line)
            if len(tw_sentences) != len(cn_sentences) or not tw_sentences:
                stats['lines_unsplittable'] += 1
                continue
            stats['lines_sentence_aligned'] += 1
            if direction == 's2t':
                tw_sentences, cn_sentences = cn_sentences, tw_sentences
            for number, (source, reference) in enumerate(zip(tw_sentences, cn_sentences)):
                if len(source) < 4:
                    continue
                stats['sentences'] += 1
                if source == reference:
                    stats['sentences_identical'] += 1
                rows.append({
                    'id': f"wikipedia-{tw.get('revision')}-{index}-{number}",
                    'origin': 'wikipedia-zh-cn' if direction == 't2s' else 'wikipedia-zh-tw',
                    'config': 'tw-variant',
                    'layer': 'L2+L3',
                    'note': 'zh.wikipedia.org rendered variant=zh-tw against variant=zh-cn',
                    'title': tw.get('title'),
                    'revision': tw.get('revision'),
                    'source': source,
                    'reference': reference,
                })
    return rows, stats


def write_jsonl(path: pathlib.Path, rows: list[dict]) -> str:
    body = ''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows)
    path.write_text(body, encoding='utf-8', newline='\n')
    return hashlib.sha256(body.encode('utf-8')).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pages', type=pathlib.Path, default=DEFAULT_PAGES)
    parser.add_argument('--out', type=pathlib.Path, default=DEFAULT_OUT)
    parser.add_argument('--limit-pages', type=int, default=None)
    parser.add_argument('--direction', choices=('t2s', 's2t'), default='t2s')
    arguments = parser.parse_args()
    suffix = '' if arguments.direction == 't2s' else '-s2t'
    opencc_name = f'gold-opencc{suffix}.jsonl'
    wikipedia_name = f'gold-wikipedia{suffix}.jsonl' 
    arguments.out.mkdir(parents=True, exist_ok=True)

    opencc = opencc_rows(arguments.out, arguments.direction)
    wikipedia, stats = wikipedia_rows(arguments.pages, arguments.limit_pages, arguments.direction)

    manifest_path = arguments.out / 'gold-manifest.json'
    existing = {}
    if manifest_path.exists():
        # The two directions are generated one run each, so merge instead of
        # overwriting: the manifest is evidence and must describe every set on
        # disk.
        existing = json.loads(manifest_path.read_text(encoding='utf-8')).get('sets', {})
    manifest = {
        'note': 'Gold sets for the accuracy evaluation of both conversion directions. '
                'Regenerate with tool/text_engine_prototype/make_eval_gold.py '
                '(and the same script with --direction s2t).',
        'sets': {
            **existing,
            opencc_name: {
                'rows': len(opencc),
                'sha256': write_jsonl(arguments.out / opencc_name, opencc),
                'source': TESTCASES_URL,
                'license': 'OpenCC is Apache-2.0; these are its own hand-made cases.',
                'by_config': {
                    config: sum(1 for row in opencc if row['config'] == config)
                    for config in (DIRECTIONS if arguments.direction == 't2s' else DIRECTIONS_S2T)
                },
            },
            wikipedia_name: {
                'rows': len(wikipedia),
                'sha256': write_jsonl(arguments.out / wikipedia_name, wikipedia),
                'source': 'zh.wikipedia.org, variant=zh-tw against variant=zh-cn',
                'license': 'CC BY-SA 4.0; kept out of the repository, hashes only.',
                'stats': stats,
            },
        },
    }
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8', newline='\n')
    print(json.dumps(manifest['sets'], ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
