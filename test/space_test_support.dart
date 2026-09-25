import 'dart:io';

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
