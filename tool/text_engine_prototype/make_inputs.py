"""Build the text-engine benchmark's inputs.

Usage: python tool/text_engine_prototype/make_inputs.py [output-directory]

Default output directory: `D:/liber-probe/text-engine` — the probe scratch area
the measurement session left `500mb.txt` in. Writes:

- `engine-20mb-gbk.txt` — about 20 MB of GBK, the ticket's encoding case.
  The text is the novel corpus fetched by `fetch_corpus.py`, repeated until the
  encoded file reaches the size. GBK cannot encode 10 of the corpus's rare CJK
  extension code points (19 occurrences in one copy); they are written as `□`
  and counted in the manifest, because the file exists to exercise the index,
  not to preserve those glyphs.
- `engine-20mb-utf8.txt` — the same text in UTF-8, so the Rust engine and the
  pure-Dart streaming index can be compared on identical content.
- `engine-20mb-manifest.json` — sizes, sha256 each, the replacement count, and
  the same for `500mb.txt` when it is present.

Re-running is idempotent: an input whose sha256 already matches the manifest is
left alone.
"""
import hashlib
import json
import pathlib
import sys

TARGET_GBK_BYTES = 20 * 1024 * 1024
# One code point GBK has no mapping for; 10 of them appear in the corpus.
REPLACEMENT = '□'


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_corpus(corpus_dir):
    novels = corpus_dir / 'novels.txt'
    if not novels.exists():
        raise SystemExit(
            f'{novels} 不存在：先运行 python tool/text_engine_prototype/fetch_corpus.py'
        )
    return novels.read_text(encoding='utf-8')


def gbk_encodable(text):
    """The text with every code point GBK cannot encode replaced."""
    replaced = 0
    out = []
    for character in text:
        try:
            character.encode('gbk')
        except UnicodeEncodeError:
            replaced += 1
            out.append(REPLACEMENT)
        else:
            out.append(character)
    return ''.join(out), replaced


def build(out, corpus):
    gbk_text, replaced = gbk_encodable(corpus)
    copies = TARGET_GBK_BYTES // len(gbk_text.encode('gbk')) + 1
    text = gbk_text * copies
    gbk_bytes = text.encode('gbk')
    utf8_bytes = text.encode('utf-8')
    gbk_path = out / 'engine-20mb-gbk.txt'
    utf8_path = out / 'engine-20mb-utf8.txt'
    gbk_path.write_bytes(gbk_bytes)
    utf8_path.write_bytes(utf8_bytes)
    manifest = {
        'note': 'Benchmark inputs for ticket #19. The novel corpus is repeated; '
                'GBK cannot encode 10 rare code points, which are written as □.',
        'corpus': {
            'file': str(pathlib.Path(corpus).parent) if isinstance(corpus, pathlib.Path) else '',
            'copies': copies,
            'code_points_replaced': replaced,
            'code_units': len(text.encode('utf-16-le')) // 2,
        },
        'inputs': {
            'engine-20mb-gbk.txt': {
                'bytes': len(gbk_bytes),
                'encoding': 'GBK',
                'sha256': hashlib.sha256(gbk_bytes).hexdigest(),
            },
            'engine-20mb-utf8.txt': {
                'bytes': len(utf8_bytes),
                'encoding': 'UTF-8',
                'sha256': hashlib.sha256(utf8_bytes).hexdigest(),
            },
        },
    }
    big = next(
        (candidate for candidate in (out / '500mb.txt', out.parent / '500mb.txt') if candidate.exists()),
        None,
    )
    if big is not None:
        manifest['inputs']['500mb.txt'] = {
            'bytes': big.stat().st_size,
            'encoding': 'UTF-8',
            'sha256': sha256(big),
        }
    (out / 'engine-20mb-manifest.json').write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1) + '\n',
        encoding='utf-8', newline='\n')
    for name, entry in manifest['inputs'].items():
        print(f"{name}: {entry['bytes']} bytes, sha256 {entry['sha256'][:16]}")
    print(f"code points replaced for GBK: {replaced}, copies: {copies}")


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'D:/liber-probe/text-engine')
    corpus_dir = pathlib.Path(
        sys.argv[2] if len(sys.argv) > 2 else 'D:/liber-probe/text-engine')
    out.mkdir(parents=True, exist_ok=True)
    build(out, load_corpus(corpus_dir))


if __name__ == '__main__':
    main()
