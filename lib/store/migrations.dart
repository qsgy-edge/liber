import 'package:drift/drift.dart';

import 'progress.dart';
import 'schema_versions.dart';

/// Data work for a schema step. A step's own change happens in the generated
/// `schema_versions.dart`; work like this runs first, while the old shape and
/// the rows that violate the new one are still in place.
///
/// v1 → v2 makes the natural keys real: at most one `books` row per
/// `(sourceRef, sourceBookUrl)` and per `(rootId, relativePath)`. Those are the
/// keys import and re-search match on, and a v1 database written before the
/// constraints existed could hold two rows for one book — each with its own
/// chapters, memberships and progress, which is the split the constraint
/// exists to prevent. The duplicates are merged here, so the unique indexes can
/// be created afterwards.
Future<void> mergeDuplicateNaturalKeys(Migrator m) async {
  final database = m.database;
  for (final group
      in await database
          .customSelect(
            'SELECT source_ref AS first_key, source_book_url AS second_key FROM books '
            "WHERE kind = 'network' AND source_ref IS NOT NULL "
            'AND source_book_url IS NOT NULL '
            'GROUP BY source_ref, source_book_url HAVING COUNT(*) > 1',
          )
          .get()) {
    await _merge(
      database,
      await _duplicateIds(
        database,
        "kind = 'network' AND source_ref = ? AND source_book_url = ?",
        [group.data['first_key'], group.data['second_key']],
      ),
    );
  }
  for (final group
      in await database
          .customSelect(
            'SELECT root_id AS first_key, relative_path AS second_key FROM books '
            "WHERE kind = 'local' AND root_id IS NOT NULL "
            'AND relative_path IS NOT NULL '
            'GROUP BY root_id, relative_path HAVING COUNT(*) > 1',
          )
          .get()) {
    await _merge(
      database,
      await _duplicateIds(
        database,
        "kind = 'local' AND root_id = ? AND relative_path = ?",
        [group.data['first_key'], group.data['second_key']],
      ),
    );
  }
}

Future<List<String>> _duplicateIds(
  GeneratedDatabase database,
  String where,
  List<Object?> keys,
) async {
  final rows = await database
      .customSelect(
        'SELECT id FROM books WHERE $where ORDER BY rowid',
        variables: keys.map(Variable.new).toList(),
      )
      .get();
  return rows.map((row) => row.read<String>('id')).toList();
}

/// Keeps the earliest row and folds the later ones into it: memberships union,
/// the TOC of whichever row has one, and the most advanced position.
Future<void> _merge(GeneratedDatabase database, List<String> ids) async {
  if (ids.length < 2) return;
  final winner = ids.first;
  for (final loser in ids.skip(1)) {
    await database.customStatement(
      'INSERT OR IGNORE INTO book_groups (book_id, group_id) '
      'SELECT ?, group_id FROM book_groups WHERE book_id = ?',
      [winner, loser],
    );
    await database.customStatement(
      'DELETE FROM book_groups WHERE book_id = ?',
      [loser],
    );

    final winnerChapters = await database
        .customSelect(
          'SELECT COUNT(*) AS n FROM chapters WHERE book_id = ?',
          variables: [Variable(winner)],
        )
        .getSingle();
    if (winnerChapters.read<int>('n') == 0) {
      await database.customStatement(
        'INSERT OR IGNORE INTO chapters '
        '(book_id, chapter_key, name, url, chapter_index, variable) '
        'SELECT ?, chapter_key, name, url, chapter_index, variable '
        'FROM chapters WHERE book_id = ?',
        [winner, loser],
      );
    }
    await database.customStatement('DELETE FROM chapters WHERE book_id = ?', [
      loser,
    ]);

    await _mergeProgress(database, winner, loser);

    await database.customStatement(
      'UPDATE OR IGNORE local_files SET book_id = ? WHERE book_id = ?',
      [winner, loser],
    );
    await database.customStatement('DELETE FROM books WHERE id = ?', [loser]);
  }
}

Future<void> _mergeProgress(
  GeneratedDatabase database,
  String winner,
  String loser,
) async {
  final rows = await database
      .customSelect(
        'SELECT book_id, text_offset, line_index, offset_in_line, text_length, '
        'chapter_key, chapter_index, anchor, updated_at FROM progress '
        'WHERE book_id IN (?, ?)',
        variables: [Variable(winner), Variable(loser)],
      )
      .get();
  Map<String, Object?>? winnerRow;
  Map<String, Object?>? loserRow;
  for (final row in rows) {
    if (row.data['book_id'] == winner) {
      winnerRow = row.data;
    } else {
      loserRow = row.data;
    }
  }
  if (loserRow == null) return;

  if (winnerRow == null) {
    await database.customStatement(
      'INSERT INTO progress (book_id, text_offset, line_index, offset_in_line, '
      'text_length, chapter_key, chapter_index, anchor, updated_at) '
      'SELECT ?, text_offset, line_index, offset_in_line, text_length, '
      'chapter_key, chapter_index, anchor, updated_at FROM progress '
      'WHERE book_id = ?',
      [winner, loser],
    );
  } else if (_position(loserRow).advancesFrom(_position(winnerRow))) {
    await database.customStatement(
      'UPDATE progress SET text_offset = ?, line_index = ?, offset_in_line = ?, '
      'text_length = ?, chapter_key = ?, chapter_index = ?, anchor = ?, '
      'updated_at = ? WHERE book_id = ?',
      [
        loserRow['text_offset'],
        loserRow['line_index'],
        loserRow['offset_in_line'],
        loserRow['text_length'],
        loserRow['chapter_key'],
        loserRow['chapter_index'],
        loserRow['anchor'],
        loserRow['updated_at'],
        winner,
      ],
    );
  }
  await database.customStatement('DELETE FROM progress WHERE book_id = ?', [
    loser,
  ]);
}

ProgressPosition _position(Map<String, Object?> row) => ProgressPosition(
  chapterIndex: row['chapter_index'] as int?,
  textOffset: (row['text_offset'] as int?) ?? 0,
  updatedAt: (row['updated_at'] as int?) ?? 0,
);

/// v1 → v2: the natural keys become constraints, and `text_index` describes a
/// local file rather than a shelf book.
///
/// v1's `books_natural_key` was an ordinary index and a local book had no key
/// index at all, so a database could hold two rows for one book.
/// [mergeDuplicateNaturalKeys] folds those duplicates together while the old
/// shape is still in place; only then can the index be recreated as `UNIQUE`
/// and the local key be added.
///
/// v1's `text_index` was keyed by book; a v1 database carries no index rows at
/// all today (nothing builds one yet), and an index row for a network book has
/// no file to belong to now, so those cannot be carried over.
Future<void> migrateToV2(Migrator m, Schema2 schema) async {
  await m.drop(schema.booksNaturalKey);
  await m.createIndex(schema.booksNaturalKey);
  await m.createIndex(schema.booksLocalKey);

  await m.database.customStatement(
    'ALTER TABLE text_index RENAME TO text_index_v1',
  );
  await m.createTable(schema.textIndex);
  await m.database.customStatement(
    'INSERT INTO text_index '
    '(root_id, relative_path, byte_offset, code_unit_offset, line_index) '
    'SELECT l.root_id, l.relative_path, t.byte_offset, t.code_unit_offset, '
    't.line_index FROM text_index_v1 t '
    'JOIN books b ON b.id = t.book_id '
    'JOIN local_files l ON l.root_id = b.root_id '
    'AND l.relative_path = b.relative_path',
  );
  await m.database.customStatement('DROP TABLE text_index_v1');
}

/// v2 → v3: the host surface's state gets its tables (ADR 0011 §3) — the cookie
/// jar and the per-source entries (`cache.*` values and the `java.put`/
/// `java.get` variables).
///
/// A v2 database holds no such state: the jar was process-lifetime and the
/// cache map was static, so there is nothing to carry over and the two tables
/// start empty. A source fills them as it runs, and a restart finds them.
Future<void> migrateToV3(Migrator m, Schema3 schema) async {
  await m.createTable(schema.sourceCookies);
  await m.createTable(schema.sourceEntries);
}

/// v3 → v4: the per-source TLS exception table gets its row (ADR 0011 §5).
///
/// No v3 database holds an exception — nothing consulted one — so the table
/// starts empty and a user's confirmation fills it as it is given.
Future<void> migrateToV4(Migrator m, Schema4 schema) async {
  await m.createTable(schema.sourceTlsExceptions);
}
