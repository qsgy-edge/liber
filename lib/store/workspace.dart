import 'dart:convert';
import 'dart:io';

import 'database.dart';
import 'manifest.dart';
import 'space_store.dart';

/// The installation-level layout under `%APPDATA%\Liber`:
///
/// ```
/// manifest.json             # space registry, format/version, UI preferences
/// spaces\<spaceId>\data.db  # everything the space owns
/// ```
///
/// Opening a space creates its directory and database on first use; reopening
/// the workspace reopens the same files, which is what makes a space an
/// isolated unit (`docs/user-data-contract.md` D5, D9).
class Workspace {
  Workspace._(this.root, this.manifest);

  static const defaultSpaceId = WorkspaceManifest.defaultSpaceId;
  static const manifestFileName = 'manifest.json';
  static const spacesFolderName = 'spaces';
  static const databaseFileName = 'data.db';

  final Directory root;
  WorkspaceManifest manifest;
  final List<SpaceStore> _openStores = <SpaceStore>[];

  /// The product's own directory; `APPDATA` is where the three JSON stores this
  /// one succeeds live today.
  static Directory defaultRoot() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) throw StateError('APPDATA is unavailable');
    return Directory('$appData${Platform.pathSeparator}Liber');
  }

  /// Opens the workspace under [root] (the default directory when omitted),
  /// creating the manifest on first run.
  static Future<Workspace> open({Directory? root}) async {
    final directory = root ?? defaultRoot();
    await directory.create(recursive: true);
    final file = File(_join(directory.path, manifestFileName));
    if (!await file.exists()) {
      final workspace = Workspace._(directory, WorkspaceManifest.initial());
      await workspace._saveManifest();
      return workspace;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('manifest.json 格式错误');
    }
    return Workspace._(directory, WorkspaceManifest.fromJson(decoded));
  }

  File get manifestFile => File(_join(root.path, manifestFileName));

  Directory spaceDirectory(String id) =>
      Directory(_join(root.path, spacesFolderName, id));

  /// The space's database file, whether or not the space exists yet.
  File databaseFile(String id) =>
      File(_join(spaceDirectory(id).path, databaseFileName));

  /// Opens the active space by default. A space that is not in the registry yet
  /// is registered and created empty (D1: a new space starts empty).
  Future<SpaceStore> openSpace([String? id]) async {
    final spaceId = id ?? manifest.activeSpace;
    if (manifest.space(spaceId) == null) {
      manifest = manifest.withSpace(
        SpaceDescriptor(
          id: spaceId,
          name: spaceId,
          createdAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      await _saveManifest();
    }
    final directory = spaceDirectory(spaceId);
    await directory.create(recursive: true);
    final store = SpaceStore(
      SpaceDatabase.file(databaseFile(spaceId)),
      spaceId: spaceId,
    );
    _openStores.add(store);
    return store;
  }

  Future<void> setActiveSpace(String id) async {
    if (manifest.space(id) == null) {
      throw StateError('空间不存在：$id');
    }
    manifest = WorkspaceManifest(
      activeSpace: id,
      spaces: manifest.spaces,
      preferences: manifest.preferences,
    );
    await _saveManifest();
  }

  /// UI-level preferences (theme, language) are installation level; everything
  /// a space owns stays in its database.
  Future<void> setPreference(String key, Object? value) async {
    manifest = manifest.withPreference(key, value);
    await _saveManifest();
  }

  Future<void> _saveManifest() async {
    await root.create(recursive: true);
    final temp = File('${manifestFile.path}.tmp');
    await temp.writeAsString(manifest.encode(), flush: true);
    await temp.rename(manifestFile.path);
  }

  Future<void> close() async {
    for (final store in _openStores) {
      await store.close();
    }
    _openStores.clear();
  }

  static String _join(String first, String second, [String? third]) =>
      third == null
      ? '$first${Platform.pathSeparator}$second'
      : '$first${Platform.pathSeparator}$second${Platform.pathSeparator}$third';
}
