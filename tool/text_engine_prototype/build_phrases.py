"""Build Liber's own phrase tables from OpenCC's, plus the hand decisions.

Inputs:
  - `packages/fjs/liber_text/assets/hanlp-tc/t2s.txt`   (character table, for values written in Traditional)
  - OpenCC's `TWPhrasesRev.txt` / `HKPhrasesRev.txt`    (Apache-2.0, downloaded by the audit)
  - `tool/text_engine_prototype/phrase_decisions.tsv`   (keep / override / add, with reasons)

Outputs, all committed:
  - `packages/fjs/liber_text/assets/phrases/tw2s.txt`   (Taiwan wording -> mainland wording)
  - `packages/fjs/liber_text/assets/phrases/hk2s.txt`   (Hong Kong wording -> mainland wording)
  - `packages/fjs/liber_text/assets/phrases/rejected.tsv` (what was dropped or overridden, and why)
  - `packages/fjs/liber_text/assets/phrases/README.md`  (provenance, licence, rules, counts)

Usage:
  python tool/text_engine_prototype/build_phrases.py [--dict <dir>]
"""
import argparse
import collections
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CRATE = ROOT / 'packages/fjs/liber_text'
OUT = CRATE / 'assets/phrases'
DEFAULT_DICT = pathlib.Path('D:/liber-probe/text-engine/opencc-dict')

SOURCES = {'tw2s': 'TWPhrasesRev.txt', 'hk2s': 'HKPhrasesRev.txt'}


def load_character_map() -> dict[str, str]:
    table = {}
    for line in (CRATE / 'assets/hanlp-tc/t2s.txt').read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        key, _, value = line.partition('=')
        if len(key) == 1 and len(value) == 1 and key != value:
            table[key] = value
    return table


def load_opencc(path: pathlib.Path) -> dict[str, str]:
    table = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        key, _, values = line.partition('\t')
        words = values.split()
        if key and words:
            table[key] = words[0]
    return table


def load_decisions(path: pathlib.Path) -> dict[str, dict[str, tuple[str, str]]]:
    """action -> key -> (value, reason); the value is empty for `drop`."""
    decisions: dict[str, dict[str, tuple[str, str]]] = collections.defaultdict(dict)
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        action, key, value, reason = (line.split('\t') + ['', '', ''])[:4]
        decisions[action][key] = (value, reason)
    return decisions


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dict', type=pathlib.Path, default=DEFAULT_DICT)
    arguments = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)

    characters = load_character_map()
    decisions = load_decisions(HERE / 'phrase_decisions.tsv')
    dropped = decisions['drop']
    overridden = decisions['override']
    added = decisions['add']

    report = {}
    for name, source in SOURCES.items():
        opencc = load_opencc(arguments.dict / source)
        rows: list[tuple[str, str]] = []
        rejected: list[tuple[str, str, str, str]] = []
        for key, value in opencc.items():
            simplified = ''.join(characters.get(character, character) for character in value)
            if key in dropped:
                rejected.append(('drop', key, simplified, dropped[key][1]))
                continue
            if key in overridden:
                # The override is given in Simplified already.
                rows.append((key, overridden[key][0]))
                rejected.append(('override', key, overridden[key][0], f'was {simplified}: {overridden[key][1]}'))
                continue
            if simplified == key:
                # A no-op entry would protect the word from the character table.
                rejected.append(('drop', key, simplified, 'no-op: identity in Simplified'))
                continue
            rows.append((key, simplified))
        # Our own entries last, so a hand entry wins over an OpenCC one.
        for key, (value, _) in added.items():
            if all(existing != key for existing, _ in rows):
                rows.append((key, value))
        rows.sort(key=lambda row: (-len(row[0]), row[0]))
        body = (
            f'# Liber phrase table: {name} — regional wording mapped to mainland wording.\n'
            f'# Built by tool/text_engine_prototype/build_phrases.py from OpenCC\'s {source}\n'
            '# (Apache-2.0) plus the hand decisions in phrase_decisions.tsv; every value is\n'
            '# written in Simplified. See README.md next to this file for the rules and the\n'
            '# rejected entries. Format: key=value per line, # comments — the same reader as\n'
            '# assets/hanlp-tc/t2s.txt.\n'
            + ''.join(f'{key}={value}\n' for key, value in rows))
        (OUT / f'{name}.txt').write_text(body, encoding='utf-8', newline='\n')
        rejected.sort(key=lambda row: (row[0], row[1]))
        (OUT / f'{name}-rejected.tsv').write_text(
            '# action\tkey\tvalue\treason\n'
            + ''.join('\t'.join(row) + '\n' for row in rejected), encoding='utf-8', newline='\n')
        report[name] = {
            'source': source,
            'opencc_entries': len(opencc),
            'kept_from_opencc': sum(1 for key, _ in rows if key in opencc),
            'overridden': sum(1 for key, _ in rows if key in overridden),
            'added': sum(1 for key, _ in rows if key in added),
            'dropped': sum(1 for action, key, _, _ in rejected if action == 'drop'),
            'no_op_dropped': sum(1 for action, _, _, reason in rejected
                                 if action == 'drop' and reason.startswith('no-op')),
            'entries': len(rows),
            'rejected': len(rejected),
        }
    (OUT / 'build-report.json').write_text(
        __import__('json').dumps(report, ensure_ascii=False, indent=1) + '\n',
        encoding='utf-8', newline='\n')
    print(__import__('json').dumps(report, ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
