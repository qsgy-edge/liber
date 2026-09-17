import 'dart:convert';
import 'dart:math';

/// The manifest preference key holding the installation's `androidId`.
const manifestAndroidIdKey = 'androidId';

/// A fresh installation `androidId`: 16 lowercase hex characters, shaped like
/// Android's `Settings.Secure.ANDROID_ID` (`AppConst.kt:58-60`) so a source that
/// parses it is not surprised, but opaque and random so it is never a platform
/// identifier (ADR 0011 §6). Drawn from a CSPRNG.
String newAndroidId() {
  final random = Random.secure();
  const digits = '0123456789abcdef';
  return List.generate(16, (_) => digits[random.nextInt(16)]).join();
}

/// The installation-level `manifest.json`: the space registry, this format's
/// version, and UI-level preferences (theme, language).
///
/// Everything a space owns lives in that space's database
/// (`docs/user-data-contract.md` D5); this file holds only what is true for the
/// whole installation. A manifest written by a newer build is refused rather
/// than partially read (D6).
class WorkspaceManifest {
  const WorkspaceManifest({
    required this.activeSpace,
    required this.spaces,
    this.preferences = const <String, Object?>{},
  });

  /// The first space every installation has (D9: a space *is* a store).
  static const defaultSpaceId = 'default';

  /// A manifest of a fresh installation: one default space, no preferences.
  factory WorkspaceManifest.initial({DateTime? now}) {
    final createdAt = (now ?? DateTime.now()).toUtc().toIso8601String();
    return WorkspaceManifest(
      activeSpace: defaultSpaceId,
      spaces: [
        SpaceDescriptor(
          id: defaultSpaceId,
          name: defaultSpaceId,
          createdAt: createdAt,
        ),
      ],
    );
  }

  static const format = 'liber-workspace';
  static const version = 1;

  final String activeSpace;
  final List<SpaceDescriptor> spaces;
  final Map<String, Object?> preferences;

  SpaceDescriptor? space(String id) => spaces.where((s) => s.id == id).firstOrNull;

  WorkspaceManifest withSpace(SpaceDescriptor descriptor) => WorkspaceManifest(
    activeSpace: activeSpace,
    spaces: [...spaces.where((s) => s.id != descriptor.id), descriptor],
    preferences: preferences,
  );

  WorkspaceManifest withPreference(String key, Object? value) =>
      WorkspaceManifest(
        activeSpace: activeSpace,
        spaces: spaces,
        preferences: {...preferences, key: value},
      );

  /// Parses a manifest and refuses one written by a newer build.
  factory WorkspaceManifest.fromJson(Map<String, Object?> json) {
    if (json['format'] != format) {
      throw const FormatException('manifest.json 的 format 不是 liber-workspace');
    }
    final version = json['version'];
    if (version is! int) {
      throw const FormatException('manifest.json 缺少整数 version');
    }
    if (version > WorkspaceManifest.version) {
      throw StateError(
        'manifest.json 版本 $version 高于本构建支持的 ${WorkspaceManifest.version}，拒绝读取',
      );
    }
    final spaces = <SpaceDescriptor>[];
    for (final entry in (json['spaces'] as List? ?? const <Object?>[])) {
      if (entry is Map) {
        spaces.add(SpaceDescriptor.fromJson(Map<String, Object?>.from(entry)));
      }
    }
    final active = json['activeSpace'];
    if (spaces.isEmpty || active is! String || !spaces.any((s) => s.id == active)) {
      throw const FormatException('manifest.json 没有可用的空间注册表');
    }
    final preferences = json['preferences'];
    return WorkspaceManifest(
      activeSpace: active,
      spaces: spaces,
      preferences: preferences is Map
          ? Map<String, Object?>.from(preferences)
          : const <String, Object?>{},
    );
  }

  Map<String, Object?> toJson() => {
    'format': format,
    'version': version,
    'activeSpace': activeSpace,
    'spaces': spaces.map((s) => s.toJson()).toList(),
    'preferences': preferences,
  };

  String encode() => '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';
}

class SpaceDescriptor {
  const SpaceDescriptor({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String createdAt;

  factory SpaceDescriptor.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('空间注册表缺少 id');
    }
    return SpaceDescriptor(
      id: id,
      name: json['name'] as String? ?? id,
      createdAt: json['createdAt'] as String? ?? '',
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt,
  };
}
