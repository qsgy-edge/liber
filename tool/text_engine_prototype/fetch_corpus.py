"""Fetch the real-text corpus the ticket-#19 conversion decision is measured on.

Usage: python tool/text_engine_prototype/fetch_corpus.py [output-directory]

The default output directory is `D:/liber-probe/text-engine` (beside the
`500mb.txt` the measurement session left there); override it with the argument.
Three corpus files are written:

- `novels.txt` — public-domain novel chapters from zh.wikisource (三國演義 and
  紅樓夢), the reference Traditional-script novel corpus. Public domain, so the
  crate's fixtures may quote short excerpts from it.
- `modern-tw.txt` — zh.wikipedia articles rendered with `variant=zh-tw`, i.e.
  modern prose as a Taiwan reader sees it. This is the part of the corpus that
  exercises Taiwan vocabulary, which a classical novel never does.
- `modern-cn.txt` — the same articles rendered with `variant=zh-cn`, the
  Simplified counterpart for the `s2t` direction.

`modern-*.txt` are CC BY-SA 4.0 and are *not* committed: the repository keeps
the fetch script, the manifest, hashes and word-level diff hunks, never whole
lines of Wikipedia text.

- `corpus-manifest.json` — every page with the revision id the text came from,
  its timestamp and URL, the sha256 of the text it contributed, and the sha256
  of each corpus file. Pages get edited, so re-running the fetch cannot
  reproduce these bytes; the manifest is what makes the measurement's input
  identifiable, and the measurement names the revision it read.

Text comes from `action=parse` with `prop=text|revid` (the `extracts` API
returned empty text for most wikisource chapters, which are transclusions),
stripped of markup: script/style/table/sup elements dropped, tags replaced by
spaces, entities unescaped, blank-line runs collapsed.

Usage of the Wikimedia API is throttled: four workers, a delay between
requests, and exponential backoff on 429. Each fetched page is cached under
`<output>/pages/`, so a re-run fetches only what is missing — a full fetch of
all three corpora takes tens of minutes and a re-run has to be cheap.
"""
import concurrent.futures
import hashlib
import html
import json
import pathlib
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

WIKISOURCE_PAGES = [
    *[f'三國演義/第{n:03d}回' for n in range(1, 121)],
    *[f'紅樓夢/第{n:03d}回' for n in range(1, 41)],
]
WIKIPEDIA_PAGES = [
    '臺灣', '臺北市', '高雄市', '臺中市', '臺南市', '新竹市', '花蓮縣', '澎湖縣',
    '臺灣鐵路運輸', '臺北捷運', '高雄捷運', '臺灣高鐵', '桃園國際機場',
    '臺灣棒球', '王建民', '中華職棒', '臺灣籃球', '戴資穎',
    '珍珠奶茶', '滷肉飯', '牛肉麵', '鳳梨酥', '臺灣夜市', '蚵仔煎',
    '半導體', '台積電', '聯發科技', '鴻海科技集團', '個人電腦', '網際網路',
    '颱風', '地震', '臺灣黑熊', '臺灣藍鵲', '玉山', '阿里山',
    '鄧麗君', '周杰倫', '五月天', '臺灣電影', '歌仔戲', '布袋戲',
    '臺灣原住民族', '客家話', '臺灣閩南語', '注音符號', '繁體中文',
]
USER_AGENT = 'liber-ticket19-corpus/0.1 (compatibility measurement harness)'
WORKERS = 2
RETRIES = 10
DELAY = 1.0
# Set in main(): the per-page cache directory under the output directory.
CACHE = pathlib.Path('.')
_print_lock = threading.Lock()


class Throttle:
    """One request at a time, with a minimum gap between requests."""

    def __init__(self, delay):
        self.delay = delay
        self.lock = threading.Lock()
        self.next_at = 0.0

    def wait(self):
        with self.lock:
            now = time.monotonic()
            sleep = max(0.0, self.next_at - now)
            self.next_at = max(now, self.next_at) + self.delay
        if sleep:
            time.sleep(sleep)


THROTTLE = Throttle(DELAY)


def get(host, params):
    params = {'format': 'json', 'formatversion': '2', **params}
    url = f'https://{host}/w/api.php?' + urllib.parse.urlencode(params)
    delay = 2.0
    for attempt in range(RETRIES + 1):
        THROTTLE.wait()
        request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                return json.load(response)
        except (urllib.error.HTTPError, urllib.error.URLError) as error:
            code = getattr(error, 'code', None)
            if attempt == RETRIES or (code is not None and code != 429):
                raise
            time.sleep(delay)
            delay *= 2


def strip_markup(markup):
    markup = re.sub(r'(?is)<(script|style|table|sup|ref|h[1-6])[^>]*>.*?</\1>', ' ', markup)
    markup = re.sub(r'(?s)<[^>]+>', ' ', markup)
    markup = html.unescape(markup)
    markup = markup.replace('\u00a0', ' ')
    markup = re.sub(r'[ \t]+', ' ', markup)
    markup = re.sub(r'\n\s*\n+', '\n', markup)
    return markup.strip()


def fetch_page(host, page, variant):
    cache_key = hashlib.sha256(f'{host}|{variant}|{page}'.encode('utf-8')).hexdigest()[:16]
    cache_path = CACHE / f'{cache_key}.json'
    if cache_path.exists():
        return page, json.loads(cache_path.read_text(encoding='utf-8'))
    params = {
        'action': 'parse',
        'page': page,
        'prop': 'text|revid',
        'redirects': '1',
        'disabletoc': '1',
        'disableeditsection': '1',
    }
    if variant:
        params['variant'] = variant
    data = get(host, params)
    if 'parse' not in data:
        row = {'missing': True, 'requested': page, 'host': host, 'variant': variant}
    else:
        parsed = data['parse']
        text = strip_markup(parsed['text'])
        row = {
            'requested': page,
            'host': host,
            'variant': variant,
            'title': parsed['title'],
            'revision': parsed.get('revid'),
            'url': f'https://{host}/wiki/' + urllib.parse.quote(parsed['title'].replace(' ', '_')),
            'characters': len(text),
            'sha256': hashlib.sha256(text.encode('utf-8')).hexdigest(),
            'text': text,
        }
    cache_path.write_text(json.dumps(row, ensure_ascii=False) + '\n', encoding='utf-8', newline='\n')
    with _print_lock:
        print(f'  {host}/{variant or "asis"} {row.get("title", page)}: '
              f'{row.get("characters", 0)} characters', flush=True)
    return page, row


def fetch_all(host, pages, variant):
    rows = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = [pool.submit(fetch_page, host, page, variant) for page in pages]
        for future in futures:
            _, row = future.result()
            rows.append(row)
    return rows


def write_corpus(out, file_name, rows):
    body = '\n'.join(row['text'] for row in rows if not row.get('missing'))
    path = out / file_name
    path.write_text(body, encoding='utf-8', newline='\n')
    for row in rows:
        row.pop('text', None)
    return body


def main():
    global CACHE
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'D:/liber-probe/text-engine')
    out.mkdir(parents=True, exist_ok=True)
    CACHE = out / 'pages'
    CACHE.mkdir(exist_ok=True)
    print('zh.wikisource.org chapters')
    novels_rows = fetch_all('zh.wikisource.org', WIKISOURCE_PAGES, None)
    novels = write_corpus(out, 'novels.txt', novels_rows)
    print('zh.wikipedia.org articles, variant=zh-tw')
    modern_tw_rows = fetch_all('zh.wikipedia.org', WIKIPEDIA_PAGES, 'zh-tw')
    modern_tw = write_corpus(out, 'modern-tw.txt', modern_tw_rows)
    print('zh.wikipedia.org articles, variant=zh-cn')
    modern_cn_rows = fetch_all('zh.wikipedia.org', WIKIPEDIA_PAGES, 'zh-cn')
    modern_cn = write_corpus(out, 'modern-cn.txt', modern_cn_rows)

    def source(host, file_name, variant, body, rows):
        missing = [row['requested'] for row in rows if row.get('missing')]
        return {
            'host': host,
            'variant': variant,
            'file': file_name,
            'sha256': hashlib.sha256(body.encode('utf-8')).hexdigest(),
            'characters': len(body),
            'missing': missing,
            'pages': [row for row in rows if not row.get('missing')],
        }

    manifest = {
        'note': 'Provenance record for the ticket-#19 conversion measurement. '
                'modern-tw.txt and modern-cn.txt are fetched but never committed '
                '(CC BY-SA 4.0); only hashes and diff hunks are recorded.',
        'sources': [
            source('zh.wikisource.org', 'novels.txt', None, novels, novels_rows),
            source('zh.wikipedia.org', 'modern-tw.txt', 'zh-tw', modern_tw, modern_tw_rows),
            source('zh.wikipedia.org', 'modern-cn.txt', 'zh-cn', modern_cn, modern_cn_rows),
        ],
    }
    (out / 'corpus-manifest.json').write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1) + '\n',
        encoding='utf-8', newline='\n')
    for entry in manifest['sources']:
        print(f"{entry['file']}: {entry['characters']} characters, "
              f"{len(entry['pages'])} pages, {len(entry['missing'])} missing, "
              f"sha256 {entry['sha256']}")


if __name__ == '__main__':
    main()
