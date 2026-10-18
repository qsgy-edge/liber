import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/space_store.dart';
import 'package:liber/store/workspace.dart';

import 'temp_directory.dart';

/// A space in a temporary directory, opened the way the app opens it, so a test
/// can close it and reopen the same file — a restart.
class TestSpace {
  TestSpace(this.directory, this.store);

  final Directory directory;
  SpaceStore store;

  /// Creates the directory and opens the default space inside it.
  static Future<TestSpace> create() async {
    final directory = await Directory.systemTemp.createTemp('liber-space-');
    return TestSpace(directory, await _open(directory));
  }

  /// Closes the database and opens the same file again.
  Future<SpaceStore> reopen() async {
    await store.close();
    return store = await _open(directory);
  }

  Future<void> delete() async {
    await store.close();
    await deleteTempDirectory(directory);
  }

  /// The file a space's database lives in, for the assertions that care about
  /// what is on disk.
  File file(String name) => File('${directory.path}/$name');

  static Future<SpaceStore> _open(Directory directory) async {
    final workspace = await Workspace.open(root: directory);
    return workspace.openSpace(Workspace.defaultSpaceId);
  }
}

/// A space store in memory whose publication transaction can be held open and
/// whose book write can be observed — the two cancellation windows a switch has
/// to survive (#132): a publication still queued behind its transaction, and a
/// cancellation that lands while the transaction is already writing.
///
/// The rows themselves are the ordinary in-memory store's, so a test asserts
/// over real rows; only the two timing hooks are added.
class GateableSpaceStore extends SpaceStore {
  /// A store over [database], or a fresh in-memory one when the caller has none.
  /// A test whose own space is already open passes that space's database, so
  /// only one is ever open at a time.
  GateableSpaceStore({SpaceDatabase? database})
    : super(database ?? SpaceDatabase(NativeDatabase.memory()));

  /// Holds the next [transaction] open: [entered] completes when it is reached
  /// and its action runs once [release] completes.
  bool holdNextTransaction = false;
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  /// Runs after every book write, so a test can cancel while the transaction
  /// that made the write is still open.
  void Function()? afterBookWrite;

  @override
  Future<T> transaction<T>(Future<T> Function() action) async {
    if (holdNextTransaction) {
      holdNextTransaction = false;
      entered.complete();
      await release.future;
    }
    return super.transaction(action);
  }

  @override
  Future<String> putBook(BooksCompanion book) async {
    final id = await super.putBook(book);
    afterBookWrite?.call();
    return id;
  }
}
