# Test data for `liber_text`

Both files are excerpts of the public-domain novel 三國演義 fetched from
zh.wikisource, so the tests exercise real Traditional Chinese prose instead of
invented strings.

`sample_book.txt` — chapters 1 to 3 as the wiki stores them: paragraph per line,
no chapter headings (the wiki page titles carry those), 46 585 bytes and 15 635
UTF-16 code units, 74 lines.

| Page | Revision | URL |
|---|---|---|
| 三國演義/第001回 | 2583915 | <https://zh.wikisource.org/wiki/%E4%B8%89%E5%9C%8B%E6%BC%94%E7%BE%A9/%E7%AC%AC001%E5%9B%9E> |
| 三國演義/第002回 | 8185068 | <https://zh.wikisource.org/wiki/%E4%B8%89%E5%9C%8B%E6%BC%94%E7%BE%A9/%E7%AC%AC002%E5%9B%9E> |
| 三國演義/第003回 | 2567965 | <https://zh.wikisource.org/wiki/%E4%B8%89%E5%9C%8B%E6%BC%94%E7%BE%A9/%E7%AC%AC003%E5%9B%9E> |

The text is fetched, not copied by hand, with
`tool/text_engine_prototype/fetch_corpus.py` (which records the same revision
ids in `corpus-manifest.json`).

`chaptered_book.txt` — 18 paragraphs of the same excerpt plus the three chapter
titles 三國演義 is known by (第一章/第二章/第三章), which the fetched text does
not contain. The titles are the only part of the file that is written rather
than fetched, and they are there because the frozen reader's default TXT chapter
rules match 章-style headings, not the wiki's page structure. 14 095 bytes,
4 731 code units, 23 lines.

Chapters in `chaptered_book.txt`:

| Title | Line | Byte offset | Code-unit offset |
|---|---|---|---|
| 第一章 宴桃園豪傑三結義　斬黃巾英雄首立功 | 0 | 0 | 0 |
| 第二章 張翼德怒鞭督郵　何國舅謀誅宦豎 | 8 | 7 598 | 2 544 |
| 第三章 議溫明董卓叱丁原　饋金珠李肅說呂布 | 16 | 9 521 | 3 197 |
