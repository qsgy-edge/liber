"""Suggest phrase-table entries from the evaluation's own misses.

The scorer reports *where* the shipped conversion disagrees with the reference;
this turns those disagreements into two lists a human can accept or reject in a
minute, because the remaining misses are almost all wording:

- `著` compounds: every miss where the reference wrote 着 and the source had
  `X著` — the stem `X` is what the table is missing (the zhù words are already
  protected in the crate, so those never show up here).
- word-level pairs: source spans the reference rewrote one way and the candidate
  another way, counted by how many times each pair occurs. Long sentences give
  noisy alignments, so the report keeps the pairs of two to six characters and
  lets the short-sentence subset speak.

Usage:
  python tool/text_engine_prototype/suggest_phrases.py [--eval <dir>] [--top 60]
"""
import argparse
import collections
import difflib
import json
import pathlib

DEFAULT_EVAL = pathlib.Path('D:/liber-probe/text-engine/eval')
HERE = pathlib.Path(__file__).resolve().parent
PROTECTED = set()
for line in (HERE / 'phrase_decisions.tsv').read_text(encoding='utf-8').splitlines():
    if line.startswith('add'):
        PROTECTED.add(line.split('\t')[1])


def replace_segments(source: str, target: str) -> dict:
    """Source span -> what the target put there, for rewritten spans only."""
    segments = {}
    if len(source) == len(target):
        # Cheap path; a same-length rewrite is one character per position unless
        # the two strings share a longer context, which the counts do not need.
        pass
    matcher = difflib.SequenceMatcher(None, list(source), list(target), autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == 'replace' and i1 != i2:
            segments[(i1, i2)] = ''.join(target[j1:j2])
    return segments


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--eval', type=pathlib.Path, default=DEFAULT_EVAL)
    parser.add_argument('--candidate', default='liber-now')
    parser.add_argument('--top', type=int, default=60)
    arguments = parser.parse_args()

    gold = arguments.eval / 'gold-wikipedia.jsonl'
    rows = [json.loads(line) for line in gold.read_text(encoding='utf-8').splitlines() if line.strip()]
    outputs = {
        row['id']: row['output']
        for row in (json.loads(line) for line in
                    (arguments.eval / 'out-wikipedia' / f'{arguments.candidate}.jsonl')
                    .read_text(encoding='utf-8').splitlines() if line.strip())
    }

    stems = collections.Counter()
    pairs = collections.Counter()
    short_pairs = collections.Counter()
    examples = collections.defaultdict(list)
    for row in rows:
        source, reference = row['source'], row['reference']
        output = outputs[row['id']]
        # 著 → 着, stem by stem.
        for index, character in enumerate(source):
            if character != '著' or index == 0:
                continue
            if reference[index] == '着' and output[index] == '著':
                stem = source[index - 1]
                if stem + '著' not in PROTECTED:
                    stems[stem] += 1
        # Wording: same source span, two different rewrites.
        reference_segments = replace_segments(source, reference)
        candidate_segments = replace_segments(source, output)
        for span, reference_text in reference_segments.items():
            candidate_text = candidate_segments.get(span)
            if candidate_text is None or candidate_text == reference_text:
                continue
            if not (2 <= len(reference_text) <= 6 and 2 <= len(candidate_text) <= 6):
                continue
            key = (candidate_text, reference_text)
            pairs[key] += 1
            if len(source) <= 40:
                short_pairs[key] += 1
            if len(examples[key]) < 2:
                examples[key].append(source)

    print('=== 著 stems the table is missing (candidate 著, reference 着)')
    for stem, count in stems.most_common(arguments.top):
        print(f'  {stem}著 → {stem}着  ×{count}')
    print('\n=== wording pairs: candidate kept/wrote the left, reference the right')
    print('    (short-sentence counts first, all sentences in brackets)')
    for (candidate, reference), count in short_pairs.most_common(arguments.top):
        sample = examples[(candidate, reference)][0][:60]
        print(f'  {candidate} → {reference}   ×{count} (all {pairs[(candidate, reference)]})'
              f'   e.g. {sample}')


if __name__ == '__main__':
    main()
