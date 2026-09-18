// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $SourcesTable extends Sources with TableInfo<$SourcesTable, BookSource> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SourcesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookSourceUrlMeta = const VerificationMeta(
    'bookSourceUrl',
  );
  @override
  late final GeneratedColumn<String> bookSourceUrl = GeneratedColumn<String>(
    'book_source_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _groupNamesMeta = const VerificationMeta(
    'groupNames',
  );
  @override
  late final GeneratedColumn<String> groupNames = GeneratedColumn<String>(
    'group_names',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<int> type = GeneratedColumn<int>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _customOrderMeta = const VerificationMeta(
    'customOrder',
  );
  @override
  late final GeneratedColumn<int> customOrder = GeneratedColumn<int>(
    'custom_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _enabledMeta = const VerificationMeta(
    'enabled',
  );
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
    'enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _enabledExploreMeta = const VerificationMeta(
    'enabledExplore',
  );
  @override
  late final GeneratedColumn<bool> enabledExplore = GeneratedColumn<bool>(
    'enabled_explore',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enabled_explore" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _lastUpdateTimeMeta = const VerificationMeta(
    'lastUpdateTime',
  );
  @override
  late final GeneratedColumn<int> lastUpdateTime = GeneratedColumn<int>(
    'last_update_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _rawMeta = const VerificationMeta('raw');
  @override
  late final GeneratedColumn<String> raw = GeneratedColumn<String>(
    'raw',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    bookSourceUrl,
    name,
    groupNames,
    type,
    customOrder,
    enabled,
    enabledExplore,
    lastUpdateTime,
    raw,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sources';
  @override
  VerificationContext validateIntegrity(
    Insertable<BookSource> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_source_url')) {
      context.handle(
        _bookSourceUrlMeta,
        bookSourceUrl.isAcceptableOrUnknown(
          data['book_source_url']!,
          _bookSourceUrlMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_bookSourceUrlMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('group_names')) {
      context.handle(
        _groupNamesMeta,
        groupNames.isAcceptableOrUnknown(data['group_names']!, _groupNamesMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('custom_order')) {
      context.handle(
        _customOrderMeta,
        customOrder.isAcceptableOrUnknown(
          data['custom_order']!,
          _customOrderMeta,
        ),
      );
    }
    if (data.containsKey('enabled')) {
      context.handle(
        _enabledMeta,
        enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta),
      );
    }
    if (data.containsKey('enabled_explore')) {
      context.handle(
        _enabledExploreMeta,
        enabledExplore.isAcceptableOrUnknown(
          data['enabled_explore']!,
          _enabledExploreMeta,
        ),
      );
    }
    if (data.containsKey('last_update_time')) {
      context.handle(
        _lastUpdateTimeMeta,
        lastUpdateTime.isAcceptableOrUnknown(
          data['last_update_time']!,
          _lastUpdateTimeMeta,
        ),
      );
    }
    if (data.containsKey('raw')) {
      context.handle(
        _rawMeta,
        raw.isAcceptableOrUnknown(data['raw']!, _rawMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookSourceUrl};
  @override
  BookSource map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookSource(
      bookSourceUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_source_url'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      groupNames: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_names'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}type'],
      )!,
      customOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}custom_order'],
      )!,
      enabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enabled'],
      )!,
      enabledExplore: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enabled_explore'],
      )!,
      lastUpdateTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_update_time'],
      )!,
      raw: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}raw'],
      ),
    );
  }

  @override
  $SourcesTable createAlias(String alias) {
    return $SourcesTable(attachedDatabase, alias);
  }
}

class BookSource extends DataClass implements Insertable<BookSource> {
  /// Legado's own primary key, and the space-local key a book's `sourceRef`
  /// resolves against (`docs/user-data-contract.md` D7).
  final String bookSourceUrl;
  final String name;

  /// Legado keeps this as a comma-joined `HashSet`, so order is not meaningful
  /// and this is a JSON array of names.
  final String groupNames;
  final int type;
  final int customOrder;
  final bool enabled;
  final bool enabledExplore;
  final int lastUpdateTime;

  /// The imported object as it arrived, unknown fields included.
  final String? raw;
  const BookSource({
    required this.bookSourceUrl,
    required this.name,
    required this.groupNames,
    required this.type,
    required this.customOrder,
    required this.enabled,
    required this.enabledExplore,
    required this.lastUpdateTime,
    this.raw,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_source_url'] = Variable<String>(bookSourceUrl);
    map['name'] = Variable<String>(name);
    map['group_names'] = Variable<String>(groupNames);
    map['type'] = Variable<int>(type);
    map['custom_order'] = Variable<int>(customOrder);
    map['enabled'] = Variable<bool>(enabled);
    map['enabled_explore'] = Variable<bool>(enabledExplore);
    map['last_update_time'] = Variable<int>(lastUpdateTime);
    if (!nullToAbsent || raw != null) {
      map['raw'] = Variable<String>(raw);
    }
    return map;
  }

  SourcesCompanion toCompanion(bool nullToAbsent) {
    return SourcesCompanion(
      bookSourceUrl: Value(bookSourceUrl),
      name: Value(name),
      groupNames: Value(groupNames),
      type: Value(type),
      customOrder: Value(customOrder),
      enabled: Value(enabled),
      enabledExplore: Value(enabledExplore),
      lastUpdateTime: Value(lastUpdateTime),
      raw: raw == null && nullToAbsent ? const Value.absent() : Value(raw),
    );
  }

  factory BookSource.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookSource(
      bookSourceUrl: serializer.fromJson<String>(json['bookSourceUrl']),
      name: serializer.fromJson<String>(json['name']),
      groupNames: serializer.fromJson<String>(json['groupNames']),
      type: serializer.fromJson<int>(json['type']),
      customOrder: serializer.fromJson<int>(json['customOrder']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      enabledExplore: serializer.fromJson<bool>(json['enabledExplore']),
      lastUpdateTime: serializer.fromJson<int>(json['lastUpdateTime']),
      raw: serializer.fromJson<String?>(json['raw']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookSourceUrl': serializer.toJson<String>(bookSourceUrl),
      'name': serializer.toJson<String>(name),
      'groupNames': serializer.toJson<String>(groupNames),
      'type': serializer.toJson<int>(type),
      'customOrder': serializer.toJson<int>(customOrder),
      'enabled': serializer.toJson<bool>(enabled),
      'enabledExplore': serializer.toJson<bool>(enabledExplore),
      'lastUpdateTime': serializer.toJson<int>(lastUpdateTime),
      'raw': serializer.toJson<String?>(raw),
    };
  }

  BookSource copyWith({
    String? bookSourceUrl,
    String? name,
    String? groupNames,
    int? type,
    int? customOrder,
    bool? enabled,
    bool? enabledExplore,
    int? lastUpdateTime,
    Value<String?> raw = const Value.absent(),
  }) => BookSource(
    bookSourceUrl: bookSourceUrl ?? this.bookSourceUrl,
    name: name ?? this.name,
    groupNames: groupNames ?? this.groupNames,
    type: type ?? this.type,
    customOrder: customOrder ?? this.customOrder,
    enabled: enabled ?? this.enabled,
    enabledExplore: enabledExplore ?? this.enabledExplore,
    lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
    raw: raw.present ? raw.value : this.raw,
  );
  BookSource copyWithCompanion(SourcesCompanion data) {
    return BookSource(
      bookSourceUrl: data.bookSourceUrl.present
          ? data.bookSourceUrl.value
          : this.bookSourceUrl,
      name: data.name.present ? data.name.value : this.name,
      groupNames: data.groupNames.present
          ? data.groupNames.value
          : this.groupNames,
      type: data.type.present ? data.type.value : this.type,
      customOrder: data.customOrder.present
          ? data.customOrder.value
          : this.customOrder,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      enabledExplore: data.enabledExplore.present
          ? data.enabledExplore.value
          : this.enabledExplore,
      lastUpdateTime: data.lastUpdateTime.present
          ? data.lastUpdateTime.value
          : this.lastUpdateTime,
      raw: data.raw.present ? data.raw.value : this.raw,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookSource(')
          ..write('bookSourceUrl: $bookSourceUrl, ')
          ..write('name: $name, ')
          ..write('groupNames: $groupNames, ')
          ..write('type: $type, ')
          ..write('customOrder: $customOrder, ')
          ..write('enabled: $enabled, ')
          ..write('enabledExplore: $enabledExplore, ')
          ..write('lastUpdateTime: $lastUpdateTime, ')
          ..write('raw: $raw')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    bookSourceUrl,
    name,
    groupNames,
    type,
    customOrder,
    enabled,
    enabledExplore,
    lastUpdateTime,
    raw,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookSource &&
          other.bookSourceUrl == this.bookSourceUrl &&
          other.name == this.name &&
          other.groupNames == this.groupNames &&
          other.type == this.type &&
          other.customOrder == this.customOrder &&
          other.enabled == this.enabled &&
          other.enabledExplore == this.enabledExplore &&
          other.lastUpdateTime == this.lastUpdateTime &&
          other.raw == this.raw);
}

class SourcesCompanion extends UpdateCompanion<BookSource> {
  final Value<String> bookSourceUrl;
  final Value<String> name;
  final Value<String> groupNames;
  final Value<int> type;
  final Value<int> customOrder;
  final Value<bool> enabled;
  final Value<bool> enabledExplore;
  final Value<int> lastUpdateTime;
  final Value<String?> raw;
  final Value<int> rowid;
  const SourcesCompanion({
    this.bookSourceUrl = const Value.absent(),
    this.name = const Value.absent(),
    this.groupNames = const Value.absent(),
    this.type = const Value.absent(),
    this.customOrder = const Value.absent(),
    this.enabled = const Value.absent(),
    this.enabledExplore = const Value.absent(),
    this.lastUpdateTime = const Value.absent(),
    this.raw = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SourcesCompanion.insert({
    required String bookSourceUrl,
    required String name,
    this.groupNames = const Value.absent(),
    this.type = const Value.absent(),
    this.customOrder = const Value.absent(),
    this.enabled = const Value.absent(),
    this.enabledExplore = const Value.absent(),
    this.lastUpdateTime = const Value.absent(),
    this.raw = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : bookSourceUrl = Value(bookSourceUrl),
       name = Value(name);
  static Insertable<BookSource> custom({
    Expression<String>? bookSourceUrl,
    Expression<String>? name,
    Expression<String>? groupNames,
    Expression<int>? type,
    Expression<int>? customOrder,
    Expression<bool>? enabled,
    Expression<bool>? enabledExplore,
    Expression<int>? lastUpdateTime,
    Expression<String>? raw,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookSourceUrl != null) 'book_source_url': bookSourceUrl,
      if (name != null) 'name': name,
      if (groupNames != null) 'group_names': groupNames,
      if (type != null) 'type': type,
      if (customOrder != null) 'custom_order': customOrder,
      if (enabled != null) 'enabled': enabled,
      if (enabledExplore != null) 'enabled_explore': enabledExplore,
      if (lastUpdateTime != null) 'last_update_time': lastUpdateTime,
      if (raw != null) 'raw': raw,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SourcesCompanion copyWith({
    Value<String>? bookSourceUrl,
    Value<String>? name,
    Value<String>? groupNames,
    Value<int>? type,
    Value<int>? customOrder,
    Value<bool>? enabled,
    Value<bool>? enabledExplore,
    Value<int>? lastUpdateTime,
    Value<String?>? raw,
    Value<int>? rowid,
  }) {
    return SourcesCompanion(
      bookSourceUrl: bookSourceUrl ?? this.bookSourceUrl,
      name: name ?? this.name,
      groupNames: groupNames ?? this.groupNames,
      type: type ?? this.type,
      customOrder: customOrder ?? this.customOrder,
      enabled: enabled ?? this.enabled,
      enabledExplore: enabledExplore ?? this.enabledExplore,
      lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
      raw: raw ?? this.raw,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookSourceUrl.present) {
      map['book_source_url'] = Variable<String>(bookSourceUrl.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (groupNames.present) {
      map['group_names'] = Variable<String>(groupNames.value);
    }
    if (type.present) {
      map['type'] = Variable<int>(type.value);
    }
    if (customOrder.present) {
      map['custom_order'] = Variable<int>(customOrder.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (enabledExplore.present) {
      map['enabled_explore'] = Variable<bool>(enabledExplore.value);
    }
    if (lastUpdateTime.present) {
      map['last_update_time'] = Variable<int>(lastUpdateTime.value);
    }
    if (raw.present) {
      map['raw'] = Variable<String>(raw.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SourcesCompanion(')
          ..write('bookSourceUrl: $bookSourceUrl, ')
          ..write('name: $name, ')
          ..write('groupNames: $groupNames, ')
          ..write('type: $type, ')
          ..write('customOrder: $customOrder, ')
          ..write('enabled: $enabled, ')
          ..write('enabledExplore: $enabledExplore, ')
          ..write('lastUpdateTime: $lastUpdateTime, ')
          ..write('raw: $raw, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BooksTable extends Books with TableInfo<$BooksTable, ShelfBook> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('network'),
  );
  static const VerificationMeta _sourceRefMeta = const VerificationMeta(
    'sourceRef',
  );
  @override
  late final GeneratedColumn<String> sourceRef = GeneratedColumn<String>(
    'source_ref',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceBookUrlMeta = const VerificationMeta(
    'sourceBookUrl',
  );
  @override
  late final GeneratedColumn<String> sourceBookUrl = GeneratedColumn<String>(
    'source_book_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _authorMeta = const VerificationMeta('author');
  @override
  late final GeneratedColumn<String> author = GeneratedColumn<String>(
    'author',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _originNameMeta = const VerificationMeta(
    'originName',
  );
  @override
  late final GeneratedColumn<String> originName = GeneratedColumn<String>(
    'origin_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<int> type = GeneratedColumn<int>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _customTagMeta = const VerificationMeta(
    'customTag',
  );
  @override
  late final GeneratedColumn<String> customTag = GeneratedColumn<String>(
    'custom_tag',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _coverUrlMeta = const VerificationMeta(
    'coverUrl',
  );
  @override
  late final GeneratedColumn<String> coverUrl = GeneratedColumn<String>(
    'cover_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _customCoverUrlMeta = const VerificationMeta(
    'customCoverUrl',
  );
  @override
  late final GeneratedColumn<String> customCoverUrl = GeneratedColumn<String>(
    'custom_cover_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _introMeta = const VerificationMeta('intro');
  @override
  late final GeneratedColumn<String> intro = GeneratedColumn<String>(
    'intro',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _customIntroMeta = const VerificationMeta(
    'customIntro',
  );
  @override
  late final GeneratedColumn<String> customIntro = GeneratedColumn<String>(
    'custom_intro',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _charsetMeta = const VerificationMeta(
    'charset',
  );
  @override
  late final GeneratedColumn<String> charset = GeneratedColumn<String>(
    'charset',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _latestChapterTitleMeta =
      const VerificationMeta('latestChapterTitle');
  @override
  late final GeneratedColumn<String> latestChapterTitle =
      GeneratedColumn<String>(
        'latest_chapter_title',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant(''),
      );
  static const VerificationMeta _latestChapterTimeMeta = const VerificationMeta(
    'latestChapterTime',
  );
  @override
  late final GeneratedColumn<int> latestChapterTime = GeneratedColumn<int>(
    'latest_chapter_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _totalChapterNumMeta = const VerificationMeta(
    'totalChapterNum',
  );
  @override
  late final GeneratedColumn<int> totalChapterNum = GeneratedColumn<int>(
    'total_chapter_num',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _canUpdateMeta = const VerificationMeta(
    'canUpdate',
  );
  @override
  late final GeneratedColumn<bool> canUpdate = GeneratedColumn<bool>(
    'can_update',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("can_update" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _lastCheckTimeMeta = const VerificationMeta(
    'lastCheckTime',
  );
  @override
  late final GeneratedColumn<int> lastCheckTime = GeneratedColumn<int>(
    'last_check_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastCheckCountMeta = const VerificationMeta(
    'lastCheckCount',
  );
  @override
  late final GeneratedColumn<int> lastCheckCount = GeneratedColumn<int>(
    'last_check_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _bookOrderMeta = const VerificationMeta(
    'bookOrder',
  );
  @override
  late final GeneratedColumn<int> bookOrder = GeneratedColumn<int>(
    'book_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _variableMeta = const VerificationMeta(
    'variable',
  );
  @override
  late final GeneratedColumn<String> variable = GeneratedColumn<String>(
    'variable',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _shelvedMeta = const VerificationMeta(
    'shelved',
  );
  @override
  late final GeneratedColumn<bool> shelved = GeneratedColumn<bool>(
    'shelved',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("shelved" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _rootIdMeta = const VerificationMeta('rootId');
  @override
  late final GeneratedColumn<String> rootId = GeneratedColumn<String>(
    'root_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _relativePathMeta = const VerificationMeta(
    'relativePath',
  );
  @override
  late final GeneratedColumn<String> relativePath = GeneratedColumn<String>(
    'relative_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _formatMeta = const VerificationMeta('format');
  @override
  late final GeneratedColumn<String> format = GeneratedColumn<String>(
    'format',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _needsRelinkMeta = const VerificationMeta(
    'needsRelink',
  );
  @override
  late final GeneratedColumn<bool> needsRelink = GeneratedColumn<bool>(
    'needs_relink',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("needs_relink" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _rawMeta = const VerificationMeta('raw');
  @override
  late final GeneratedColumn<String> raw = GeneratedColumn<String>(
    'raw',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    sourceRef,
    sourceBookUrl,
    title,
    author,
    originName,
    type,
    customTag,
    coverUrl,
    customCoverUrl,
    intro,
    customIntro,
    charset,
    latestChapterTitle,
    latestChapterTime,
    totalChapterNum,
    canUpdate,
    lastCheckTime,
    lastCheckCount,
    bookOrder,
    variable,
    shelved,
    rootId,
    relativePath,
    format,
    needsRelink,
    raw,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'books';
  @override
  VerificationContext validateIntegrity(
    Insertable<ShelfBook> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    }
    if (data.containsKey('source_ref')) {
      context.handle(
        _sourceRefMeta,
        sourceRef.isAcceptableOrUnknown(data['source_ref']!, _sourceRefMeta),
      );
    }
    if (data.containsKey('source_book_url')) {
      context.handle(
        _sourceBookUrlMeta,
        sourceBookUrl.isAcceptableOrUnknown(
          data['source_book_url']!,
          _sourceBookUrlMeta,
        ),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('author')) {
      context.handle(
        _authorMeta,
        author.isAcceptableOrUnknown(data['author']!, _authorMeta),
      );
    }
    if (data.containsKey('origin_name')) {
      context.handle(
        _originNameMeta,
        originName.isAcceptableOrUnknown(data['origin_name']!, _originNameMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('custom_tag')) {
      context.handle(
        _customTagMeta,
        customTag.isAcceptableOrUnknown(data['custom_tag']!, _customTagMeta),
      );
    }
    if (data.containsKey('cover_url')) {
      context.handle(
        _coverUrlMeta,
        coverUrl.isAcceptableOrUnknown(data['cover_url']!, _coverUrlMeta),
      );
    }
    if (data.containsKey('custom_cover_url')) {
      context.handle(
        _customCoverUrlMeta,
        customCoverUrl.isAcceptableOrUnknown(
          data['custom_cover_url']!,
          _customCoverUrlMeta,
        ),
      );
    }
    if (data.containsKey('intro')) {
      context.handle(
        _introMeta,
        intro.isAcceptableOrUnknown(data['intro']!, _introMeta),
      );
    }
    if (data.containsKey('custom_intro')) {
      context.handle(
        _customIntroMeta,
        customIntro.isAcceptableOrUnknown(
          data['custom_intro']!,
          _customIntroMeta,
        ),
      );
    }
    if (data.containsKey('charset')) {
      context.handle(
        _charsetMeta,
        charset.isAcceptableOrUnknown(data['charset']!, _charsetMeta),
      );
    }
    if (data.containsKey('latest_chapter_title')) {
      context.handle(
        _latestChapterTitleMeta,
        latestChapterTitle.isAcceptableOrUnknown(
          data['latest_chapter_title']!,
          _latestChapterTitleMeta,
        ),
      );
    }
    if (data.containsKey('latest_chapter_time')) {
      context.handle(
        _latestChapterTimeMeta,
        latestChapterTime.isAcceptableOrUnknown(
          data['latest_chapter_time']!,
          _latestChapterTimeMeta,
        ),
      );
    }
    if (data.containsKey('total_chapter_num')) {
      context.handle(
        _totalChapterNumMeta,
        totalChapterNum.isAcceptableOrUnknown(
          data['total_chapter_num']!,
          _totalChapterNumMeta,
        ),
      );
    }
    if (data.containsKey('can_update')) {
      context.handle(
        _canUpdateMeta,
        canUpdate.isAcceptableOrUnknown(data['can_update']!, _canUpdateMeta),
      );
    }
    if (data.containsKey('last_check_time')) {
      context.handle(
        _lastCheckTimeMeta,
        lastCheckTime.isAcceptableOrUnknown(
          data['last_check_time']!,
          _lastCheckTimeMeta,
        ),
      );
    }
    if (data.containsKey('last_check_count')) {
      context.handle(
        _lastCheckCountMeta,
        lastCheckCount.isAcceptableOrUnknown(
          data['last_check_count']!,
          _lastCheckCountMeta,
        ),
      );
    }
    if (data.containsKey('book_order')) {
      context.handle(
        _bookOrderMeta,
        bookOrder.isAcceptableOrUnknown(data['book_order']!, _bookOrderMeta),
      );
    }
    if (data.containsKey('variable')) {
      context.handle(
        _variableMeta,
        variable.isAcceptableOrUnknown(data['variable']!, _variableMeta),
      );
    }
    if (data.containsKey('shelved')) {
      context.handle(
        _shelvedMeta,
        shelved.isAcceptableOrUnknown(data['shelved']!, _shelvedMeta),
      );
    }
    if (data.containsKey('root_id')) {
      context.handle(
        _rootIdMeta,
        rootId.isAcceptableOrUnknown(data['root_id']!, _rootIdMeta),
      );
    }
    if (data.containsKey('relative_path')) {
      context.handle(
        _relativePathMeta,
        relativePath.isAcceptableOrUnknown(
          data['relative_path']!,
          _relativePathMeta,
        ),
      );
    }
    if (data.containsKey('format')) {
      context.handle(
        _formatMeta,
        format.isAcceptableOrUnknown(data['format']!, _formatMeta),
      );
    }
    if (data.containsKey('needs_relink')) {
      context.handle(
        _needsRelinkMeta,
        needsRelink.isAcceptableOrUnknown(
          data['needs_relink']!,
          _needsRelinkMeta,
        ),
      );
    }
    if (data.containsKey('raw')) {
      context.handle(
        _rawMeta,
        raw.isAcceptableOrUnknown(data['raw']!, _rawMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ShelfBook map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ShelfBook(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      sourceRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_ref'],
      ),
      sourceBookUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_book_url'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      author: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}author'],
      )!,
      originName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}origin_name'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}type'],
      )!,
      customTag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}custom_tag'],
      )!,
      coverUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_url'],
      )!,
      customCoverUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}custom_cover_url'],
      )!,
      intro: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}intro'],
      )!,
      customIntro: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}custom_intro'],
      )!,
      charset: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}charset'],
      )!,
      latestChapterTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}latest_chapter_title'],
      )!,
      latestChapterTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}latest_chapter_time'],
      )!,
      totalChapterNum: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_chapter_num'],
      )!,
      canUpdate: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}can_update'],
      )!,
      lastCheckTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_check_time'],
      )!,
      lastCheckCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_check_count'],
      )!,
      bookOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}book_order'],
      )!,
      variable: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}variable'],
      ),
      shelved: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}shelved'],
      )!,
      rootId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}root_id'],
      ),
      relativePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}relative_path'],
      ),
      format: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}format'],
      ),
      needsRelink: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}needs_relink'],
      )!,
      raw: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}raw'],
      ),
    );
  }

  @override
  $BooksTable createAlias(String alias) {
    return $BooksTable(attachedDatabase, alias);
  }
}

class ShelfBook extends DataClass implements Insertable<ShelfBook> {
  /// Minted space-local id: the primary key, so a source change does not
  /// rewrite a book's identity (D2).
  final String id;

  /// `network` or `local`. The frozen baseline overloads `Book.origin` with
  /// `loc_book`; this is explicit instead (D2).
  final String kind;

  /// The space-local Book Source key; null for a book whose source is unknown.
  final String? sourceRef;

  /// With `sourceRef`, the natural key import and re-search match on. Null for
  /// local books, whose natural key is `rootId` + `relativePath`.
  final String? sourceBookUrl;
  final String title;
  final String author;

  /// Denormalized so a deleted or renamed source does not blank the shelf.
  final String originName;

  /// Legado's book type flags.
  final int type;
  final String customTag;
  final String coverUrl;
  final String customCoverUrl;
  final String intro;
  final String customIntro;
  final String charset;
  final String latestChapterTitle;
  final int latestChapterTime;
  final int totalChapterNum;
  final bool canUpdate;
  final int lastCheckTime;
  final int lastCheckCount;

  /// One int per book per space; the shelf's order (D3).
  final int bookOrder;

  /// Opaque per-book variables.
  final String? variable;

  /// Shelf membership. Removing a book keeps its row, its chapters and its
  /// progress — the product's behavior today — so membership has to be a flag
  /// rather than a deletion.
  final bool shelved;
  final String? rootId;
  final String? relativePath;
  final String? format;
  final bool needsRelink;

  /// The imported object as it arrived, unknown fields included.
  final String? raw;
  const ShelfBook({
    required this.id,
    required this.kind,
    this.sourceRef,
    this.sourceBookUrl,
    required this.title,
    required this.author,
    required this.originName,
    required this.type,
    required this.customTag,
    required this.coverUrl,
    required this.customCoverUrl,
    required this.intro,
    required this.customIntro,
    required this.charset,
    required this.latestChapterTitle,
    required this.latestChapterTime,
    required this.totalChapterNum,
    required this.canUpdate,
    required this.lastCheckTime,
    required this.lastCheckCount,
    required this.bookOrder,
    this.variable,
    required this.shelved,
    this.rootId,
    this.relativePath,
    this.format,
    required this.needsRelink,
    this.raw,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || sourceRef != null) {
      map['source_ref'] = Variable<String>(sourceRef);
    }
    if (!nullToAbsent || sourceBookUrl != null) {
      map['source_book_url'] = Variable<String>(sourceBookUrl);
    }
    map['title'] = Variable<String>(title);
    map['author'] = Variable<String>(author);
    map['origin_name'] = Variable<String>(originName);
    map['type'] = Variable<int>(type);
    map['custom_tag'] = Variable<String>(customTag);
    map['cover_url'] = Variable<String>(coverUrl);
    map['custom_cover_url'] = Variable<String>(customCoverUrl);
    map['intro'] = Variable<String>(intro);
    map['custom_intro'] = Variable<String>(customIntro);
    map['charset'] = Variable<String>(charset);
    map['latest_chapter_title'] = Variable<String>(latestChapterTitle);
    map['latest_chapter_time'] = Variable<int>(latestChapterTime);
    map['total_chapter_num'] = Variable<int>(totalChapterNum);
    map['can_update'] = Variable<bool>(canUpdate);
    map['last_check_time'] = Variable<int>(lastCheckTime);
    map['last_check_count'] = Variable<int>(lastCheckCount);
    map['book_order'] = Variable<int>(bookOrder);
    if (!nullToAbsent || variable != null) {
      map['variable'] = Variable<String>(variable);
    }
    map['shelved'] = Variable<bool>(shelved);
    if (!nullToAbsent || rootId != null) {
      map['root_id'] = Variable<String>(rootId);
    }
    if (!nullToAbsent || relativePath != null) {
      map['relative_path'] = Variable<String>(relativePath);
    }
    if (!nullToAbsent || format != null) {
      map['format'] = Variable<String>(format);
    }
    map['needs_relink'] = Variable<bool>(needsRelink);
    if (!nullToAbsent || raw != null) {
      map['raw'] = Variable<String>(raw);
    }
    return map;
  }

  BooksCompanion toCompanion(bool nullToAbsent) {
    return BooksCompanion(
      id: Value(id),
      kind: Value(kind),
      sourceRef: sourceRef == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceRef),
      sourceBookUrl: sourceBookUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceBookUrl),
      title: Value(title),
      author: Value(author),
      originName: Value(originName),
      type: Value(type),
      customTag: Value(customTag),
      coverUrl: Value(coverUrl),
      customCoverUrl: Value(customCoverUrl),
      intro: Value(intro),
      customIntro: Value(customIntro),
      charset: Value(charset),
      latestChapterTitle: Value(latestChapterTitle),
      latestChapterTime: Value(latestChapterTime),
      totalChapterNum: Value(totalChapterNum),
      canUpdate: Value(canUpdate),
      lastCheckTime: Value(lastCheckTime),
      lastCheckCount: Value(lastCheckCount),
      bookOrder: Value(bookOrder),
      variable: variable == null && nullToAbsent
          ? const Value.absent()
          : Value(variable),
      shelved: Value(shelved),
      rootId: rootId == null && nullToAbsent
          ? const Value.absent()
          : Value(rootId),
      relativePath: relativePath == null && nullToAbsent
          ? const Value.absent()
          : Value(relativePath),
      format: format == null && nullToAbsent
          ? const Value.absent()
          : Value(format),
      needsRelink: Value(needsRelink),
      raw: raw == null && nullToAbsent ? const Value.absent() : Value(raw),
    );
  }

  factory ShelfBook.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ShelfBook(
      id: serializer.fromJson<String>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      sourceRef: serializer.fromJson<String?>(json['sourceRef']),
      sourceBookUrl: serializer.fromJson<String?>(json['sourceBookUrl']),
      title: serializer.fromJson<String>(json['title']),
      author: serializer.fromJson<String>(json['author']),
      originName: serializer.fromJson<String>(json['originName']),
      type: serializer.fromJson<int>(json['type']),
      customTag: serializer.fromJson<String>(json['customTag']),
      coverUrl: serializer.fromJson<String>(json['coverUrl']),
      customCoverUrl: serializer.fromJson<String>(json['customCoverUrl']),
      intro: serializer.fromJson<String>(json['intro']),
      customIntro: serializer.fromJson<String>(json['customIntro']),
      charset: serializer.fromJson<String>(json['charset']),
      latestChapterTitle: serializer.fromJson<String>(
        json['latestChapterTitle'],
      ),
      latestChapterTime: serializer.fromJson<int>(json['latestChapterTime']),
      totalChapterNum: serializer.fromJson<int>(json['totalChapterNum']),
      canUpdate: serializer.fromJson<bool>(json['canUpdate']),
      lastCheckTime: serializer.fromJson<int>(json['lastCheckTime']),
      lastCheckCount: serializer.fromJson<int>(json['lastCheckCount']),
      bookOrder: serializer.fromJson<int>(json['bookOrder']),
      variable: serializer.fromJson<String?>(json['variable']),
      shelved: serializer.fromJson<bool>(json['shelved']),
      rootId: serializer.fromJson<String?>(json['rootId']),
      relativePath: serializer.fromJson<String?>(json['relativePath']),
      format: serializer.fromJson<String?>(json['format']),
      needsRelink: serializer.fromJson<bool>(json['needsRelink']),
      raw: serializer.fromJson<String?>(json['raw']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(kind),
      'sourceRef': serializer.toJson<String?>(sourceRef),
      'sourceBookUrl': serializer.toJson<String?>(sourceBookUrl),
      'title': serializer.toJson<String>(title),
      'author': serializer.toJson<String>(author),
      'originName': serializer.toJson<String>(originName),
      'type': serializer.toJson<int>(type),
      'customTag': serializer.toJson<String>(customTag),
      'coverUrl': serializer.toJson<String>(coverUrl),
      'customCoverUrl': serializer.toJson<String>(customCoverUrl),
      'intro': serializer.toJson<String>(intro),
      'customIntro': serializer.toJson<String>(customIntro),
      'charset': serializer.toJson<String>(charset),
      'latestChapterTitle': serializer.toJson<String>(latestChapterTitle),
      'latestChapterTime': serializer.toJson<int>(latestChapterTime),
      'totalChapterNum': serializer.toJson<int>(totalChapterNum),
      'canUpdate': serializer.toJson<bool>(canUpdate),
      'lastCheckTime': serializer.toJson<int>(lastCheckTime),
      'lastCheckCount': serializer.toJson<int>(lastCheckCount),
      'bookOrder': serializer.toJson<int>(bookOrder),
      'variable': serializer.toJson<String?>(variable),
      'shelved': serializer.toJson<bool>(shelved),
      'rootId': serializer.toJson<String?>(rootId),
      'relativePath': serializer.toJson<String?>(relativePath),
      'format': serializer.toJson<String?>(format),
      'needsRelink': serializer.toJson<bool>(needsRelink),
      'raw': serializer.toJson<String?>(raw),
    };
  }

  ShelfBook copyWith({
    String? id,
    String? kind,
    Value<String?> sourceRef = const Value.absent(),
    Value<String?> sourceBookUrl = const Value.absent(),
    String? title,
    String? author,
    String? originName,
    int? type,
    String? customTag,
    String? coverUrl,
    String? customCoverUrl,
    String? intro,
    String? customIntro,
    String? charset,
    String? latestChapterTitle,
    int? latestChapterTime,
    int? totalChapterNum,
    bool? canUpdate,
    int? lastCheckTime,
    int? lastCheckCount,
    int? bookOrder,
    Value<String?> variable = const Value.absent(),
    bool? shelved,
    Value<String?> rootId = const Value.absent(),
    Value<String?> relativePath = const Value.absent(),
    Value<String?> format = const Value.absent(),
    bool? needsRelink,
    Value<String?> raw = const Value.absent(),
  }) => ShelfBook(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    sourceRef: sourceRef.present ? sourceRef.value : this.sourceRef,
    sourceBookUrl: sourceBookUrl.present
        ? sourceBookUrl.value
        : this.sourceBookUrl,
    title: title ?? this.title,
    author: author ?? this.author,
    originName: originName ?? this.originName,
    type: type ?? this.type,
    customTag: customTag ?? this.customTag,
    coverUrl: coverUrl ?? this.coverUrl,
    customCoverUrl: customCoverUrl ?? this.customCoverUrl,
    intro: intro ?? this.intro,
    customIntro: customIntro ?? this.customIntro,
    charset: charset ?? this.charset,
    latestChapterTitle: latestChapterTitle ?? this.latestChapterTitle,
    latestChapterTime: latestChapterTime ?? this.latestChapterTime,
    totalChapterNum: totalChapterNum ?? this.totalChapterNum,
    canUpdate: canUpdate ?? this.canUpdate,
    lastCheckTime: lastCheckTime ?? this.lastCheckTime,
    lastCheckCount: lastCheckCount ?? this.lastCheckCount,
    bookOrder: bookOrder ?? this.bookOrder,
    variable: variable.present ? variable.value : this.variable,
    shelved: shelved ?? this.shelved,
    rootId: rootId.present ? rootId.value : this.rootId,
    relativePath: relativePath.present ? relativePath.value : this.relativePath,
    format: format.present ? format.value : this.format,
    needsRelink: needsRelink ?? this.needsRelink,
    raw: raw.present ? raw.value : this.raw,
  );
  ShelfBook copyWithCompanion(BooksCompanion data) {
    return ShelfBook(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      sourceRef: data.sourceRef.present ? data.sourceRef.value : this.sourceRef,
      sourceBookUrl: data.sourceBookUrl.present
          ? data.sourceBookUrl.value
          : this.sourceBookUrl,
      title: data.title.present ? data.title.value : this.title,
      author: data.author.present ? data.author.value : this.author,
      originName: data.originName.present
          ? data.originName.value
          : this.originName,
      type: data.type.present ? data.type.value : this.type,
      customTag: data.customTag.present ? data.customTag.value : this.customTag,
      coverUrl: data.coverUrl.present ? data.coverUrl.value : this.coverUrl,
      customCoverUrl: data.customCoverUrl.present
          ? data.customCoverUrl.value
          : this.customCoverUrl,
      intro: data.intro.present ? data.intro.value : this.intro,
      customIntro: data.customIntro.present
          ? data.customIntro.value
          : this.customIntro,
      charset: data.charset.present ? data.charset.value : this.charset,
      latestChapterTitle: data.latestChapterTitle.present
          ? data.latestChapterTitle.value
          : this.latestChapterTitle,
      latestChapterTime: data.latestChapterTime.present
          ? data.latestChapterTime.value
          : this.latestChapterTime,
      totalChapterNum: data.totalChapterNum.present
          ? data.totalChapterNum.value
          : this.totalChapterNum,
      canUpdate: data.canUpdate.present ? data.canUpdate.value : this.canUpdate,
      lastCheckTime: data.lastCheckTime.present
          ? data.lastCheckTime.value
          : this.lastCheckTime,
      lastCheckCount: data.lastCheckCount.present
          ? data.lastCheckCount.value
          : this.lastCheckCount,
      bookOrder: data.bookOrder.present ? data.bookOrder.value : this.bookOrder,
      variable: data.variable.present ? data.variable.value : this.variable,
      shelved: data.shelved.present ? data.shelved.value : this.shelved,
      rootId: data.rootId.present ? data.rootId.value : this.rootId,
      relativePath: data.relativePath.present
          ? data.relativePath.value
          : this.relativePath,
      format: data.format.present ? data.format.value : this.format,
      needsRelink: data.needsRelink.present
          ? data.needsRelink.value
          : this.needsRelink,
      raw: data.raw.present ? data.raw.value : this.raw,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ShelfBook(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('sourceBookUrl: $sourceBookUrl, ')
          ..write('title: $title, ')
          ..write('author: $author, ')
          ..write('originName: $originName, ')
          ..write('type: $type, ')
          ..write('customTag: $customTag, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('customCoverUrl: $customCoverUrl, ')
          ..write('intro: $intro, ')
          ..write('customIntro: $customIntro, ')
          ..write('charset: $charset, ')
          ..write('latestChapterTitle: $latestChapterTitle, ')
          ..write('latestChapterTime: $latestChapterTime, ')
          ..write('totalChapterNum: $totalChapterNum, ')
          ..write('canUpdate: $canUpdate, ')
          ..write('lastCheckTime: $lastCheckTime, ')
          ..write('lastCheckCount: $lastCheckCount, ')
          ..write('bookOrder: $bookOrder, ')
          ..write('variable: $variable, ')
          ..write('shelved: $shelved, ')
          ..write('rootId: $rootId, ')
          ..write('relativePath: $relativePath, ')
          ..write('format: $format, ')
          ..write('needsRelink: $needsRelink, ')
          ..write('raw: $raw')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    kind,
    sourceRef,
    sourceBookUrl,
    title,
    author,
    originName,
    type,
    customTag,
    coverUrl,
    customCoverUrl,
    intro,
    customIntro,
    charset,
    latestChapterTitle,
    latestChapterTime,
    totalChapterNum,
    canUpdate,
    lastCheckTime,
    lastCheckCount,
    bookOrder,
    variable,
    shelved,
    rootId,
    relativePath,
    format,
    needsRelink,
    raw,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ShelfBook &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.sourceRef == this.sourceRef &&
          other.sourceBookUrl == this.sourceBookUrl &&
          other.title == this.title &&
          other.author == this.author &&
          other.originName == this.originName &&
          other.type == this.type &&
          other.customTag == this.customTag &&
          other.coverUrl == this.coverUrl &&
          other.customCoverUrl == this.customCoverUrl &&
          other.intro == this.intro &&
          other.customIntro == this.customIntro &&
          other.charset == this.charset &&
          other.latestChapterTitle == this.latestChapterTitle &&
          other.latestChapterTime == this.latestChapterTime &&
          other.totalChapterNum == this.totalChapterNum &&
          other.canUpdate == this.canUpdate &&
          other.lastCheckTime == this.lastCheckTime &&
          other.lastCheckCount == this.lastCheckCount &&
          other.bookOrder == this.bookOrder &&
          other.variable == this.variable &&
          other.shelved == this.shelved &&
          other.rootId == this.rootId &&
          other.relativePath == this.relativePath &&
          other.format == this.format &&
          other.needsRelink == this.needsRelink &&
          other.raw == this.raw);
}

class BooksCompanion extends UpdateCompanion<ShelfBook> {
  final Value<String> id;
  final Value<String> kind;
  final Value<String?> sourceRef;
  final Value<String?> sourceBookUrl;
  final Value<String> title;
  final Value<String> author;
  final Value<String> originName;
  final Value<int> type;
  final Value<String> customTag;
  final Value<String> coverUrl;
  final Value<String> customCoverUrl;
  final Value<String> intro;
  final Value<String> customIntro;
  final Value<String> charset;
  final Value<String> latestChapterTitle;
  final Value<int> latestChapterTime;
  final Value<int> totalChapterNum;
  final Value<bool> canUpdate;
  final Value<int> lastCheckTime;
  final Value<int> lastCheckCount;
  final Value<int> bookOrder;
  final Value<String?> variable;
  final Value<bool> shelved;
  final Value<String?> rootId;
  final Value<String?> relativePath;
  final Value<String?> format;
  final Value<bool> needsRelink;
  final Value<String?> raw;
  final Value<int> rowid;
  const BooksCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.sourceRef = const Value.absent(),
    this.sourceBookUrl = const Value.absent(),
    this.title = const Value.absent(),
    this.author = const Value.absent(),
    this.originName = const Value.absent(),
    this.type = const Value.absent(),
    this.customTag = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.customCoverUrl = const Value.absent(),
    this.intro = const Value.absent(),
    this.customIntro = const Value.absent(),
    this.charset = const Value.absent(),
    this.latestChapterTitle = const Value.absent(),
    this.latestChapterTime = const Value.absent(),
    this.totalChapterNum = const Value.absent(),
    this.canUpdate = const Value.absent(),
    this.lastCheckTime = const Value.absent(),
    this.lastCheckCount = const Value.absent(),
    this.bookOrder = const Value.absent(),
    this.variable = const Value.absent(),
    this.shelved = const Value.absent(),
    this.rootId = const Value.absent(),
    this.relativePath = const Value.absent(),
    this.format = const Value.absent(),
    this.needsRelink = const Value.absent(),
    this.raw = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BooksCompanion.insert({
    required String id,
    this.kind = const Value.absent(),
    this.sourceRef = const Value.absent(),
    this.sourceBookUrl = const Value.absent(),
    required String title,
    this.author = const Value.absent(),
    this.originName = const Value.absent(),
    this.type = const Value.absent(),
    this.customTag = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.customCoverUrl = const Value.absent(),
    this.intro = const Value.absent(),
    this.customIntro = const Value.absent(),
    this.charset = const Value.absent(),
    this.latestChapterTitle = const Value.absent(),
    this.latestChapterTime = const Value.absent(),
    this.totalChapterNum = const Value.absent(),
    this.canUpdate = const Value.absent(),
    this.lastCheckTime = const Value.absent(),
    this.lastCheckCount = const Value.absent(),
    this.bookOrder = const Value.absent(),
    this.variable = const Value.absent(),
    this.shelved = const Value.absent(),
    this.rootId = const Value.absent(),
    this.relativePath = const Value.absent(),
    this.format = const Value.absent(),
    this.needsRelink = const Value.absent(),
    this.raw = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title);
  static Insertable<ShelfBook> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<String>? sourceRef,
    Expression<String>? sourceBookUrl,
    Expression<String>? title,
    Expression<String>? author,
    Expression<String>? originName,
    Expression<int>? type,
    Expression<String>? customTag,
    Expression<String>? coverUrl,
    Expression<String>? customCoverUrl,
    Expression<String>? intro,
    Expression<String>? customIntro,
    Expression<String>? charset,
    Expression<String>? latestChapterTitle,
    Expression<int>? latestChapterTime,
    Expression<int>? totalChapterNum,
    Expression<bool>? canUpdate,
    Expression<int>? lastCheckTime,
    Expression<int>? lastCheckCount,
    Expression<int>? bookOrder,
    Expression<String>? variable,
    Expression<bool>? shelved,
    Expression<String>? rootId,
    Expression<String>? relativePath,
    Expression<String>? format,
    Expression<bool>? needsRelink,
    Expression<String>? raw,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (sourceRef != null) 'source_ref': sourceRef,
      if (sourceBookUrl != null) 'source_book_url': sourceBookUrl,
      if (title != null) 'title': title,
      if (author != null) 'author': author,
      if (originName != null) 'origin_name': originName,
      if (type != null) 'type': type,
      if (customTag != null) 'custom_tag': customTag,
      if (coverUrl != null) 'cover_url': coverUrl,
      if (customCoverUrl != null) 'custom_cover_url': customCoverUrl,
      if (intro != null) 'intro': intro,
      if (customIntro != null) 'custom_intro': customIntro,
      if (charset != null) 'charset': charset,
      if (latestChapterTitle != null)
        'latest_chapter_title': latestChapterTitle,
      if (latestChapterTime != null) 'latest_chapter_time': latestChapterTime,
      if (totalChapterNum != null) 'total_chapter_num': totalChapterNum,
      if (canUpdate != null) 'can_update': canUpdate,
      if (lastCheckTime != null) 'last_check_time': lastCheckTime,
      if (lastCheckCount != null) 'last_check_count': lastCheckCount,
      if (bookOrder != null) 'book_order': bookOrder,
      if (variable != null) 'variable': variable,
      if (shelved != null) 'shelved': shelved,
      if (rootId != null) 'root_id': rootId,
      if (relativePath != null) 'relative_path': relativePath,
      if (format != null) 'format': format,
      if (needsRelink != null) 'needs_relink': needsRelink,
      if (raw != null) 'raw': raw,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BooksCompanion copyWith({
    Value<String>? id,
    Value<String>? kind,
    Value<String?>? sourceRef,
    Value<String?>? sourceBookUrl,
    Value<String>? title,
    Value<String>? author,
    Value<String>? originName,
    Value<int>? type,
    Value<String>? customTag,
    Value<String>? coverUrl,
    Value<String>? customCoverUrl,
    Value<String>? intro,
    Value<String>? customIntro,
    Value<String>? charset,
    Value<String>? latestChapterTitle,
    Value<int>? latestChapterTime,
    Value<int>? totalChapterNum,
    Value<bool>? canUpdate,
    Value<int>? lastCheckTime,
    Value<int>? lastCheckCount,
    Value<int>? bookOrder,
    Value<String?>? variable,
    Value<bool>? shelved,
    Value<String?>? rootId,
    Value<String?>? relativePath,
    Value<String?>? format,
    Value<bool>? needsRelink,
    Value<String?>? raw,
    Value<int>? rowid,
  }) {
    return BooksCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      sourceRef: sourceRef ?? this.sourceRef,
      sourceBookUrl: sourceBookUrl ?? this.sourceBookUrl,
      title: title ?? this.title,
      author: author ?? this.author,
      originName: originName ?? this.originName,
      type: type ?? this.type,
      customTag: customTag ?? this.customTag,
      coverUrl: coverUrl ?? this.coverUrl,
      customCoverUrl: customCoverUrl ?? this.customCoverUrl,
      intro: intro ?? this.intro,
      customIntro: customIntro ?? this.customIntro,
      charset: charset ?? this.charset,
      latestChapterTitle: latestChapterTitle ?? this.latestChapterTitle,
      latestChapterTime: latestChapterTime ?? this.latestChapterTime,
      totalChapterNum: totalChapterNum ?? this.totalChapterNum,
      canUpdate: canUpdate ?? this.canUpdate,
      lastCheckTime: lastCheckTime ?? this.lastCheckTime,
      lastCheckCount: lastCheckCount ?? this.lastCheckCount,
      bookOrder: bookOrder ?? this.bookOrder,
      variable: variable ?? this.variable,
      shelved: shelved ?? this.shelved,
      rootId: rootId ?? this.rootId,
      relativePath: relativePath ?? this.relativePath,
      format: format ?? this.format,
      needsRelink: needsRelink ?? this.needsRelink,
      raw: raw ?? this.raw,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (sourceRef.present) {
      map['source_ref'] = Variable<String>(sourceRef.value);
    }
    if (sourceBookUrl.present) {
      map['source_book_url'] = Variable<String>(sourceBookUrl.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (author.present) {
      map['author'] = Variable<String>(author.value);
    }
    if (originName.present) {
      map['origin_name'] = Variable<String>(originName.value);
    }
    if (type.present) {
      map['type'] = Variable<int>(type.value);
    }
    if (customTag.present) {
      map['custom_tag'] = Variable<String>(customTag.value);
    }
    if (coverUrl.present) {
      map['cover_url'] = Variable<String>(coverUrl.value);
    }
    if (customCoverUrl.present) {
      map['custom_cover_url'] = Variable<String>(customCoverUrl.value);
    }
    if (intro.present) {
      map['intro'] = Variable<String>(intro.value);
    }
    if (customIntro.present) {
      map['custom_intro'] = Variable<String>(customIntro.value);
    }
    if (charset.present) {
      map['charset'] = Variable<String>(charset.value);
    }
    if (latestChapterTitle.present) {
      map['latest_chapter_title'] = Variable<String>(latestChapterTitle.value);
    }
    if (latestChapterTime.present) {
      map['latest_chapter_time'] = Variable<int>(latestChapterTime.value);
    }
    if (totalChapterNum.present) {
      map['total_chapter_num'] = Variable<int>(totalChapterNum.value);
    }
    if (canUpdate.present) {
      map['can_update'] = Variable<bool>(canUpdate.value);
    }
    if (lastCheckTime.present) {
      map['last_check_time'] = Variable<int>(lastCheckTime.value);
    }
    if (lastCheckCount.present) {
      map['last_check_count'] = Variable<int>(lastCheckCount.value);
    }
    if (bookOrder.present) {
      map['book_order'] = Variable<int>(bookOrder.value);
    }
    if (variable.present) {
      map['variable'] = Variable<String>(variable.value);
    }
    if (shelved.present) {
      map['shelved'] = Variable<bool>(shelved.value);
    }
    if (rootId.present) {
      map['root_id'] = Variable<String>(rootId.value);
    }
    if (relativePath.present) {
      map['relative_path'] = Variable<String>(relativePath.value);
    }
    if (format.present) {
      map['format'] = Variable<String>(format.value);
    }
    if (needsRelink.present) {
      map['needs_relink'] = Variable<bool>(needsRelink.value);
    }
    if (raw.present) {
      map['raw'] = Variable<String>(raw.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BooksCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('sourceBookUrl: $sourceBookUrl, ')
          ..write('title: $title, ')
          ..write('author: $author, ')
          ..write('originName: $originName, ')
          ..write('type: $type, ')
          ..write('customTag: $customTag, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('customCoverUrl: $customCoverUrl, ')
          ..write('intro: $intro, ')
          ..write('customIntro: $customIntro, ')
          ..write('charset: $charset, ')
          ..write('latestChapterTitle: $latestChapterTitle, ')
          ..write('latestChapterTime: $latestChapterTime, ')
          ..write('totalChapterNum: $totalChapterNum, ')
          ..write('canUpdate: $canUpdate, ')
          ..write('lastCheckTime: $lastCheckTime, ')
          ..write('lastCheckCount: $lastCheckCount, ')
          ..write('bookOrder: $bookOrder, ')
          ..write('variable: $variable, ')
          ..write('shelved: $shelved, ')
          ..write('rootId: $rootId, ')
          ..write('relativePath: $relativePath, ')
          ..write('format: $format, ')
          ..write('needsRelink: $needsRelink, ')
          ..write('raw: $raw, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GroupsTable extends Groups with TableInfo<$GroupsTable, ShelfGroup> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GroupsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _coverMeta = const VerificationMeta('cover');
  @override
  late final GeneratedColumn<String> cover = GeneratedColumn<String>(
    'cover',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _groupOrderMeta = const VerificationMeta(
    'groupOrder',
  );
  @override
  late final GeneratedColumn<int> groupOrder = GeneratedColumn<int>(
    'group_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _enableRefreshMeta = const VerificationMeta(
    'enableRefresh',
  );
  @override
  late final GeneratedColumn<bool> enableRefresh = GeneratedColumn<bool>(
    'enable_refresh',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enable_refresh" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _showMeta = const VerificationMeta('show');
  @override
  late final GeneratedColumn<bool> show = GeneratedColumn<bool>(
    'show',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("show" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _bookSortMeta = const VerificationMeta(
    'bookSort',
  );
  @override
  late final GeneratedColumn<int> bookSort = GeneratedColumn<int>(
    'book_sort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    cover,
    groupOrder,
    enableRefresh,
    show,
    bookSort,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'groups';
  @override
  VerificationContext validateIntegrity(
    Insertable<ShelfGroup> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('cover')) {
      context.handle(
        _coverMeta,
        cover.isAcceptableOrUnknown(data['cover']!, _coverMeta),
      );
    }
    if (data.containsKey('group_order')) {
      context.handle(
        _groupOrderMeta,
        groupOrder.isAcceptableOrUnknown(data['group_order']!, _groupOrderMeta),
      );
    }
    if (data.containsKey('enable_refresh')) {
      context.handle(
        _enableRefreshMeta,
        enableRefresh.isAcceptableOrUnknown(
          data['enable_refresh']!,
          _enableRefreshMeta,
        ),
      );
    }
    if (data.containsKey('show')) {
      context.handle(
        _showMeta,
        show.isAcceptableOrUnknown(data['show']!, _showMeta),
      );
    }
    if (data.containsKey('book_sort')) {
      context.handle(
        _bookSortMeta,
        bookSort.isAcceptableOrUnknown(data['book_sort']!, _bookSortMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ShelfGroup map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ShelfGroup(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      cover: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover'],
      )!,
      groupOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}group_order'],
      )!,
      enableRefresh: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enable_refresh'],
      )!,
      show: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}show'],
      )!,
      bookSort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}book_sort'],
      )!,
    );
  }

  @override
  $GroupsTable createAlias(String alias) {
    return $GroupsTable(attachedDatabase, alias);
  }
}

class ShelfGroup extends DataClass implements Insertable<ShelfGroup> {
  final String id;

  /// Trimmed, non-empty, and unique per space (D3).
  final String name;
  final String cover;
  final int groupOrder;
  final bool enableRefresh;
  final bool show;

  /// Sort mode; `-1` means "use the space default".
  final int bookSort;
  const ShelfGroup({
    required this.id,
    required this.name,
    required this.cover,
    required this.groupOrder,
    required this.enableRefresh,
    required this.show,
    required this.bookSort,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['cover'] = Variable<String>(cover);
    map['group_order'] = Variable<int>(groupOrder);
    map['enable_refresh'] = Variable<bool>(enableRefresh);
    map['show'] = Variable<bool>(show);
    map['book_sort'] = Variable<int>(bookSort);
    return map;
  }

  GroupsCompanion toCompanion(bool nullToAbsent) {
    return GroupsCompanion(
      id: Value(id),
      name: Value(name),
      cover: Value(cover),
      groupOrder: Value(groupOrder),
      enableRefresh: Value(enableRefresh),
      show: Value(show),
      bookSort: Value(bookSort),
    );
  }

  factory ShelfGroup.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ShelfGroup(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      cover: serializer.fromJson<String>(json['cover']),
      groupOrder: serializer.fromJson<int>(json['groupOrder']),
      enableRefresh: serializer.fromJson<bool>(json['enableRefresh']),
      show: serializer.fromJson<bool>(json['show']),
      bookSort: serializer.fromJson<int>(json['bookSort']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'cover': serializer.toJson<String>(cover),
      'groupOrder': serializer.toJson<int>(groupOrder),
      'enableRefresh': serializer.toJson<bool>(enableRefresh),
      'show': serializer.toJson<bool>(show),
      'bookSort': serializer.toJson<int>(bookSort),
    };
  }

  ShelfGroup copyWith({
    String? id,
    String? name,
    String? cover,
    int? groupOrder,
    bool? enableRefresh,
    bool? show,
    int? bookSort,
  }) => ShelfGroup(
    id: id ?? this.id,
    name: name ?? this.name,
    cover: cover ?? this.cover,
    groupOrder: groupOrder ?? this.groupOrder,
    enableRefresh: enableRefresh ?? this.enableRefresh,
    show: show ?? this.show,
    bookSort: bookSort ?? this.bookSort,
  );
  ShelfGroup copyWithCompanion(GroupsCompanion data) {
    return ShelfGroup(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      cover: data.cover.present ? data.cover.value : this.cover,
      groupOrder: data.groupOrder.present
          ? data.groupOrder.value
          : this.groupOrder,
      enableRefresh: data.enableRefresh.present
          ? data.enableRefresh.value
          : this.enableRefresh,
      show: data.show.present ? data.show.value : this.show,
      bookSort: data.bookSort.present ? data.bookSort.value : this.bookSort,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ShelfGroup(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('cover: $cover, ')
          ..write('groupOrder: $groupOrder, ')
          ..write('enableRefresh: $enableRefresh, ')
          ..write('show: $show, ')
          ..write('bookSort: $bookSort')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, cover, groupOrder, enableRefresh, show, bookSort);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ShelfGroup &&
          other.id == this.id &&
          other.name == this.name &&
          other.cover == this.cover &&
          other.groupOrder == this.groupOrder &&
          other.enableRefresh == this.enableRefresh &&
          other.show == this.show &&
          other.bookSort == this.bookSort);
}

class GroupsCompanion extends UpdateCompanion<ShelfGroup> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> cover;
  final Value<int> groupOrder;
  final Value<bool> enableRefresh;
  final Value<bool> show;
  final Value<int> bookSort;
  final Value<int> rowid;
  const GroupsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.cover = const Value.absent(),
    this.groupOrder = const Value.absent(),
    this.enableRefresh = const Value.absent(),
    this.show = const Value.absent(),
    this.bookSort = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GroupsCompanion.insert({
    required String id,
    required String name,
    this.cover = const Value.absent(),
    this.groupOrder = const Value.absent(),
    this.enableRefresh = const Value.absent(),
    this.show = const Value.absent(),
    this.bookSort = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name);
  static Insertable<ShelfGroup> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? cover,
    Expression<int>? groupOrder,
    Expression<bool>? enableRefresh,
    Expression<bool>? show,
    Expression<int>? bookSort,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (cover != null) 'cover': cover,
      if (groupOrder != null) 'group_order': groupOrder,
      if (enableRefresh != null) 'enable_refresh': enableRefresh,
      if (show != null) 'show': show,
      if (bookSort != null) 'book_sort': bookSort,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GroupsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? cover,
    Value<int>? groupOrder,
    Value<bool>? enableRefresh,
    Value<bool>? show,
    Value<int>? bookSort,
    Value<int>? rowid,
  }) {
    return GroupsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      cover: cover ?? this.cover,
      groupOrder: groupOrder ?? this.groupOrder,
      enableRefresh: enableRefresh ?? this.enableRefresh,
      show: show ?? this.show,
      bookSort: bookSort ?? this.bookSort,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (cover.present) {
      map['cover'] = Variable<String>(cover.value);
    }
    if (groupOrder.present) {
      map['group_order'] = Variable<int>(groupOrder.value);
    }
    if (enableRefresh.present) {
      map['enable_refresh'] = Variable<bool>(enableRefresh.value);
    }
    if (show.present) {
      map['show'] = Variable<bool>(show.value);
    }
    if (bookSort.present) {
      map['book_sort'] = Variable<int>(bookSort.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GroupsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('cover: $cover, ')
          ..write('groupOrder: $groupOrder, ')
          ..write('enableRefresh: $enableRefresh, ')
          ..write('show: $show, ')
          ..write('bookSort: $bookSort, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BookGroupsTable extends BookGroups
    with TableInfo<$BookGroupsTable, BookGroup> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BookGroupsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES books (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<String> groupId = GeneratedColumn<String>(
    'group_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES "groups" (id) ON DELETE CASCADE',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [bookId, groupId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'book_groups';
  @override
  VerificationContext validateIntegrity(
    Insertable<BookGroup> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    } else if (isInserting) {
      context.missing(_groupIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookId, groupId};
  @override
  BookGroup map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookGroup(
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_id'],
      )!,
    );
  }

  @override
  $BookGroupsTable createAlias(String alias) {
    return $BookGroupsTable(attachedDatabase, alias);
  }
}

class BookGroup extends DataClass implements Insertable<BookGroup> {
  final String bookId;
  final String groupId;
  const BookGroup({required this.bookId, required this.groupId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_id'] = Variable<String>(bookId);
    map['group_id'] = Variable<String>(groupId);
    return map;
  }

  BookGroupsCompanion toCompanion(bool nullToAbsent) {
    return BookGroupsCompanion(bookId: Value(bookId), groupId: Value(groupId));
  }

  factory BookGroup.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookGroup(
      bookId: serializer.fromJson<String>(json['bookId']),
      groupId: serializer.fromJson<String>(json['groupId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookId': serializer.toJson<String>(bookId),
      'groupId': serializer.toJson<String>(groupId),
    };
  }

  BookGroup copyWith({String? bookId, String? groupId}) => BookGroup(
    bookId: bookId ?? this.bookId,
    groupId: groupId ?? this.groupId,
  );
  BookGroup copyWithCompanion(BookGroupsCompanion data) {
    return BookGroup(
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookGroup(')
          ..write('bookId: $bookId, ')
          ..write('groupId: $groupId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(bookId, groupId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookGroup &&
          other.bookId == this.bookId &&
          other.groupId == this.groupId);
}

class BookGroupsCompanion extends UpdateCompanion<BookGroup> {
  final Value<String> bookId;
  final Value<String> groupId;
  final Value<int> rowid;
  const BookGroupsCompanion({
    this.bookId = const Value.absent(),
    this.groupId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BookGroupsCompanion.insert({
    required String bookId,
    required String groupId,
    this.rowid = const Value.absent(),
  }) : bookId = Value(bookId),
       groupId = Value(groupId);
  static Insertable<BookGroup> custom({
    Expression<String>? bookId,
    Expression<String>? groupId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookId != null) 'book_id': bookId,
      if (groupId != null) 'group_id': groupId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BookGroupsCompanion copyWith({
    Value<String>? bookId,
    Value<String>? groupId,
    Value<int>? rowid,
  }) {
    return BookGroupsCompanion(
      bookId: bookId ?? this.bookId,
      groupId: groupId ?? this.groupId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<String>(groupId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BookGroupsCompanion(')
          ..write('bookId: $bookId, ')
          ..write('groupId: $groupId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ChaptersTable extends Chapters
    with TableInfo<$ChaptersTable, BookChapter> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChaptersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES books (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _chapterKeyMeta = const VerificationMeta(
    'chapterKey',
  );
  @override
  late final GeneratedColumn<String> chapterKey = GeneratedColumn<String>(
    'chapter_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
    'url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _chapterIndexMeta = const VerificationMeta(
    'chapterIndex',
  );
  @override
  late final GeneratedColumn<int> chapterIndex = GeneratedColumn<int>(
    'chapter_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _variableMeta = const VerificationMeta(
    'variable',
  );
  @override
  late final GeneratedColumn<String> variable = GeneratedColumn<String>(
    'variable',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    bookId,
    chapterKey,
    name,
    url,
    chapterIndex,
    variable,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chapters';
  @override
  VerificationContext validateIntegrity(
    Insertable<BookChapter> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('chapter_key')) {
      context.handle(
        _chapterKeyMeta,
        chapterKey.isAcceptableOrUnknown(data['chapter_key']!, _chapterKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_chapterKeyMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('url')) {
      context.handle(
        _urlMeta,
        url.isAcceptableOrUnknown(data['url']!, _urlMeta),
      );
    }
    if (data.containsKey('chapter_index')) {
      context.handle(
        _chapterIndexMeta,
        chapterIndex.isAcceptableOrUnknown(
          data['chapter_index']!,
          _chapterIndexMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_chapterIndexMeta);
    }
    if (data.containsKey('variable')) {
      context.handle(
        _variableMeta,
        variable.isAcceptableOrUnknown(data['variable']!, _variableMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookId, chapterKey};
  @override
  BookChapter map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookChapter(
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      )!,
      chapterKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chapter_key'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      url: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}url'],
      ),
      chapterIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}chapter_index'],
      )!,
      variable: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}variable'],
      ),
    );
  }

  @override
  $ChaptersTable createAlias(String alias) {
    return $ChaptersTable(attachedDatabase, alias);
  }
}

class BookChapter extends DataClass implements Insertable<BookChapter> {
  final String bookId;

  /// Stable per book: a network chapter's URL, or a local chapter's start
  /// offset. Progress refers to this rather than to a position in the TOC,
  /// which drifts when the TOC changes (D4).
  final String chapterKey;
  final String name;
  final String? url;
  final int chapterIndex;

  /// Opaque per-chapter variables.
  final String? variable;
  const BookChapter({
    required this.bookId,
    required this.chapterKey,
    required this.name,
    this.url,
    required this.chapterIndex,
    this.variable,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_id'] = Variable<String>(bookId);
    map['chapter_key'] = Variable<String>(chapterKey);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || url != null) {
      map['url'] = Variable<String>(url);
    }
    map['chapter_index'] = Variable<int>(chapterIndex);
    if (!nullToAbsent || variable != null) {
      map['variable'] = Variable<String>(variable);
    }
    return map;
  }

  ChaptersCompanion toCompanion(bool nullToAbsent) {
    return ChaptersCompanion(
      bookId: Value(bookId),
      chapterKey: Value(chapterKey),
      name: Value(name),
      url: url == null && nullToAbsent ? const Value.absent() : Value(url),
      chapterIndex: Value(chapterIndex),
      variable: variable == null && nullToAbsent
          ? const Value.absent()
          : Value(variable),
    );
  }

  factory BookChapter.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookChapter(
      bookId: serializer.fromJson<String>(json['bookId']),
      chapterKey: serializer.fromJson<String>(json['chapterKey']),
      name: serializer.fromJson<String>(json['name']),
      url: serializer.fromJson<String?>(json['url']),
      chapterIndex: serializer.fromJson<int>(json['chapterIndex']),
      variable: serializer.fromJson<String?>(json['variable']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookId': serializer.toJson<String>(bookId),
      'chapterKey': serializer.toJson<String>(chapterKey),
      'name': serializer.toJson<String>(name),
      'url': serializer.toJson<String?>(url),
      'chapterIndex': serializer.toJson<int>(chapterIndex),
      'variable': serializer.toJson<String?>(variable),
    };
  }

  BookChapter copyWith({
    String? bookId,
    String? chapterKey,
    String? name,
    Value<String?> url = const Value.absent(),
    int? chapterIndex,
    Value<String?> variable = const Value.absent(),
  }) => BookChapter(
    bookId: bookId ?? this.bookId,
    chapterKey: chapterKey ?? this.chapterKey,
    name: name ?? this.name,
    url: url.present ? url.value : this.url,
    chapterIndex: chapterIndex ?? this.chapterIndex,
    variable: variable.present ? variable.value : this.variable,
  );
  BookChapter copyWithCompanion(ChaptersCompanion data) {
    return BookChapter(
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      chapterKey: data.chapterKey.present
          ? data.chapterKey.value
          : this.chapterKey,
      name: data.name.present ? data.name.value : this.name,
      url: data.url.present ? data.url.value : this.url,
      chapterIndex: data.chapterIndex.present
          ? data.chapterIndex.value
          : this.chapterIndex,
      variable: data.variable.present ? data.variable.value : this.variable,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookChapter(')
          ..write('bookId: $bookId, ')
          ..write('chapterKey: $chapterKey, ')
          ..write('name: $name, ')
          ..write('url: $url, ')
          ..write('chapterIndex: $chapterIndex, ')
          ..write('variable: $variable')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(bookId, chapterKey, name, url, chapterIndex, variable);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookChapter &&
          other.bookId == this.bookId &&
          other.chapterKey == this.chapterKey &&
          other.name == this.name &&
          other.url == this.url &&
          other.chapterIndex == this.chapterIndex &&
          other.variable == this.variable);
}

class ChaptersCompanion extends UpdateCompanion<BookChapter> {
  final Value<String> bookId;
  final Value<String> chapterKey;
  final Value<String> name;
  final Value<String?> url;
  final Value<int> chapterIndex;
  final Value<String?> variable;
  final Value<int> rowid;
  const ChaptersCompanion({
    this.bookId = const Value.absent(),
    this.chapterKey = const Value.absent(),
    this.name = const Value.absent(),
    this.url = const Value.absent(),
    this.chapterIndex = const Value.absent(),
    this.variable = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChaptersCompanion.insert({
    required String bookId,
    required String chapterKey,
    required String name,
    this.url = const Value.absent(),
    required int chapterIndex,
    this.variable = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : bookId = Value(bookId),
       chapterKey = Value(chapterKey),
       name = Value(name),
       chapterIndex = Value(chapterIndex);
  static Insertable<BookChapter> custom({
    Expression<String>? bookId,
    Expression<String>? chapterKey,
    Expression<String>? name,
    Expression<String>? url,
    Expression<int>? chapterIndex,
    Expression<String>? variable,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookId != null) 'book_id': bookId,
      if (chapterKey != null) 'chapter_key': chapterKey,
      if (name != null) 'name': name,
      if (url != null) 'url': url,
      if (chapterIndex != null) 'chapter_index': chapterIndex,
      if (variable != null) 'variable': variable,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChaptersCompanion copyWith({
    Value<String>? bookId,
    Value<String>? chapterKey,
    Value<String>? name,
    Value<String?>? url,
    Value<int>? chapterIndex,
    Value<String?>? variable,
    Value<int>? rowid,
  }) {
    return ChaptersCompanion(
      bookId: bookId ?? this.bookId,
      chapterKey: chapterKey ?? this.chapterKey,
      name: name ?? this.name,
      url: url ?? this.url,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      variable: variable ?? this.variable,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (chapterKey.present) {
      map['chapter_key'] = Variable<String>(chapterKey.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (url.present) {
      map['url'] = Variable<String>(url.value);
    }
    if (chapterIndex.present) {
      map['chapter_index'] = Variable<int>(chapterIndex.value);
    }
    if (variable.present) {
      map['variable'] = Variable<String>(variable.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChaptersCompanion(')
          ..write('bookId: $bookId, ')
          ..write('chapterKey: $chapterKey, ')
          ..write('name: $name, ')
          ..write('url: $url, ')
          ..write('chapterIndex: $chapterIndex, ')
          ..write('variable: $variable, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalRootsTable extends LocalRoots
    with TableInfo<$LocalRootsTable, LocalRoot> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalRootsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _needsRelinkMeta = const VerificationMeta(
    'needsRelink',
  );
  @override
  late final GeneratedColumn<bool> needsRelink = GeneratedColumn<bool>(
    'needs_relink',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("needs_relink" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [id, displayName, needsRelink];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_roots';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalRoot> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('needs_relink')) {
      context.handle(
        _needsRelinkMeta,
        needsRelink.isAcceptableOrUnknown(
          data['needs_relink']!,
          _needsRelinkMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LocalRoot map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalRoot(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      needsRelink: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}needs_relink'],
      )!,
    );
  }

  @override
  $LocalRootsTable createAlias(String alias) {
    return $LocalRootsTable(attachedDatabase, alias);
  }
}

class LocalRoot extends DataClass implements Insertable<LocalRoot> {
  /// Stable: the lowercased absolute path, so re-authorizing the same root
  /// keeps the shelf and the progress (ADR 0006).
  final String id;
  final String displayName;
  final bool needsRelink;
  const LocalRoot({
    required this.id,
    required this.displayName,
    required this.needsRelink,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['display_name'] = Variable<String>(displayName);
    map['needs_relink'] = Variable<bool>(needsRelink);
    return map;
  }

  LocalRootsCompanion toCompanion(bool nullToAbsent) {
    return LocalRootsCompanion(
      id: Value(id),
      displayName: Value(displayName),
      needsRelink: Value(needsRelink),
    );
  }

  factory LocalRoot.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalRoot(
      id: serializer.fromJson<String>(json['id']),
      displayName: serializer.fromJson<String>(json['displayName']),
      needsRelink: serializer.fromJson<bool>(json['needsRelink']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'displayName': serializer.toJson<String>(displayName),
      'needsRelink': serializer.toJson<bool>(needsRelink),
    };
  }

  LocalRoot copyWith({String? id, String? displayName, bool? needsRelink}) =>
      LocalRoot(
        id: id ?? this.id,
        displayName: displayName ?? this.displayName,
        needsRelink: needsRelink ?? this.needsRelink,
      );
  LocalRoot copyWithCompanion(LocalRootsCompanion data) {
    return LocalRoot(
      id: data.id.present ? data.id.value : this.id,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      needsRelink: data.needsRelink.present
          ? data.needsRelink.value
          : this.needsRelink,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalRoot(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('needsRelink: $needsRelink')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, displayName, needsRelink);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalRoot &&
          other.id == this.id &&
          other.displayName == this.displayName &&
          other.needsRelink == this.needsRelink);
}

class LocalRootsCompanion extends UpdateCompanion<LocalRoot> {
  final Value<String> id;
  final Value<String> displayName;
  final Value<bool> needsRelink;
  final Value<int> rowid;
  const LocalRootsCompanion({
    this.id = const Value.absent(),
    this.displayName = const Value.absent(),
    this.needsRelink = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalRootsCompanion.insert({
    required String id,
    required String displayName,
    this.needsRelink = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       displayName = Value(displayName);
  static Insertable<LocalRoot> custom({
    Expression<String>? id,
    Expression<String>? displayName,
    Expression<bool>? needsRelink,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (displayName != null) 'display_name': displayName,
      if (needsRelink != null) 'needs_relink': needsRelink,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalRootsCompanion copyWith({
    Value<String>? id,
    Value<String>? displayName,
    Value<bool>? needsRelink,
    Value<int>? rowid,
  }) {
    return LocalRootsCompanion(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      needsRelink: needsRelink ?? this.needsRelink,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (needsRelink.present) {
      map['needs_relink'] = Variable<bool>(needsRelink.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalRootsCompanion(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('needsRelink: $needsRelink, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalFilesTable extends LocalFiles
    with TableInfo<$LocalFilesTable, LocalFile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalFilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _rootIdMeta = const VerificationMeta('rootId');
  @override
  late final GeneratedColumn<String> rootId = GeneratedColumn<String>(
    'root_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_roots (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _relativePathMeta = const VerificationMeta(
    'relativePath',
  );
  @override
  late final GeneratedColumn<String> relativePath = GeneratedColumn<String>(
    'relative_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _formatMeta = const VerificationMeta('format');
  @override
  late final GeneratedColumn<String> format = GeneratedColumn<String>(
    'format',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('txt'),
  );
  static const VerificationMeta _textLengthMeta = const VerificationMeta(
    'textLength',
  );
  @override
  late final GeneratedColumn<int> textLength = GeneratedColumn<int>(
    'text_length',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _modifiedAtMeta = const VerificationMeta(
    'modifiedAt',
  );
  @override
  late final GeneratedColumn<int> modifiedAt = GeneratedColumn<int>(
    'modified_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _needsRelinkMeta = const VerificationMeta(
    'needsRelink',
  );
  @override
  late final GeneratedColumn<bool> needsRelink = GeneratedColumn<bool>(
    'needs_relink',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("needs_relink" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES books (id) ON DELETE SET NULL',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [
    rootId,
    relativePath,
    format,
    textLength,
    modifiedAt,
    needsRelink,
    bookId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_files';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalFile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('root_id')) {
      context.handle(
        _rootIdMeta,
        rootId.isAcceptableOrUnknown(data['root_id']!, _rootIdMeta),
      );
    } else if (isInserting) {
      context.missing(_rootIdMeta);
    }
    if (data.containsKey('relative_path')) {
      context.handle(
        _relativePathMeta,
        relativePath.isAcceptableOrUnknown(
          data['relative_path']!,
          _relativePathMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_relativePathMeta);
    }
    if (data.containsKey('format')) {
      context.handle(
        _formatMeta,
        format.isAcceptableOrUnknown(data['format']!, _formatMeta),
      );
    }
    if (data.containsKey('text_length')) {
      context.handle(
        _textLengthMeta,
        textLength.isAcceptableOrUnknown(data['text_length']!, _textLengthMeta),
      );
    }
    if (data.containsKey('modified_at')) {
      context.handle(
        _modifiedAtMeta,
        modifiedAt.isAcceptableOrUnknown(data['modified_at']!, _modifiedAtMeta),
      );
    }
    if (data.containsKey('needs_relink')) {
      context.handle(
        _needsRelinkMeta,
        needsRelink.isAcceptableOrUnknown(
          data['needs_relink']!,
          _needsRelinkMeta,
        ),
      );
    }
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {rootId, relativePath};
  @override
  LocalFile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalFile(
      rootId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}root_id'],
      )!,
      relativePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}relative_path'],
      )!,
      format: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}format'],
      )!,
      textLength: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}text_length'],
      ),
      modifiedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}modified_at'],
      ),
      needsRelink: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}needs_relink'],
      )!,
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      ),
    );
  }

  @override
  $LocalFilesTable createAlias(String alias) {
    return $LocalFilesTable(attachedDatabase, alias);
  }
}

class LocalFile extends DataClass implements Insertable<LocalFile> {
  final String rootId;
  final String relativePath;
  final String format;

  /// Cached decoded length: nothing reads a whole file to clamp an offset (D4).
  final int? textLength;

  /// Cached modification time; with `textLength` it decides whether the file is
  /// unchanged, edited in place, or replaced.
  final int? modifiedAt;
  final bool needsRelink;

  /// The shelf book this file is admitted as, when it is on the shelf.
  final String? bookId;
  const LocalFile({
    required this.rootId,
    required this.relativePath,
    required this.format,
    this.textLength,
    this.modifiedAt,
    required this.needsRelink,
    this.bookId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['root_id'] = Variable<String>(rootId);
    map['relative_path'] = Variable<String>(relativePath);
    map['format'] = Variable<String>(format);
    if (!nullToAbsent || textLength != null) {
      map['text_length'] = Variable<int>(textLength);
    }
    if (!nullToAbsent || modifiedAt != null) {
      map['modified_at'] = Variable<int>(modifiedAt);
    }
    map['needs_relink'] = Variable<bool>(needsRelink);
    if (!nullToAbsent || bookId != null) {
      map['book_id'] = Variable<String>(bookId);
    }
    return map;
  }

  LocalFilesCompanion toCompanion(bool nullToAbsent) {
    return LocalFilesCompanion(
      rootId: Value(rootId),
      relativePath: Value(relativePath),
      format: Value(format),
      textLength: textLength == null && nullToAbsent
          ? const Value.absent()
          : Value(textLength),
      modifiedAt: modifiedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(modifiedAt),
      needsRelink: Value(needsRelink),
      bookId: bookId == null && nullToAbsent
          ? const Value.absent()
          : Value(bookId),
    );
  }

  factory LocalFile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalFile(
      rootId: serializer.fromJson<String>(json['rootId']),
      relativePath: serializer.fromJson<String>(json['relativePath']),
      format: serializer.fromJson<String>(json['format']),
      textLength: serializer.fromJson<int?>(json['textLength']),
      modifiedAt: serializer.fromJson<int?>(json['modifiedAt']),
      needsRelink: serializer.fromJson<bool>(json['needsRelink']),
      bookId: serializer.fromJson<String?>(json['bookId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'rootId': serializer.toJson<String>(rootId),
      'relativePath': serializer.toJson<String>(relativePath),
      'format': serializer.toJson<String>(format),
      'textLength': serializer.toJson<int?>(textLength),
      'modifiedAt': serializer.toJson<int?>(modifiedAt),
      'needsRelink': serializer.toJson<bool>(needsRelink),
      'bookId': serializer.toJson<String?>(bookId),
    };
  }

  LocalFile copyWith({
    String? rootId,
    String? relativePath,
    String? format,
    Value<int?> textLength = const Value.absent(),
    Value<int?> modifiedAt = const Value.absent(),
    bool? needsRelink,
    Value<String?> bookId = const Value.absent(),
  }) => LocalFile(
    rootId: rootId ?? this.rootId,
    relativePath: relativePath ?? this.relativePath,
    format: format ?? this.format,
    textLength: textLength.present ? textLength.value : this.textLength,
    modifiedAt: modifiedAt.present ? modifiedAt.value : this.modifiedAt,
    needsRelink: needsRelink ?? this.needsRelink,
    bookId: bookId.present ? bookId.value : this.bookId,
  );
  LocalFile copyWithCompanion(LocalFilesCompanion data) {
    return LocalFile(
      rootId: data.rootId.present ? data.rootId.value : this.rootId,
      relativePath: data.relativePath.present
          ? data.relativePath.value
          : this.relativePath,
      format: data.format.present ? data.format.value : this.format,
      textLength: data.textLength.present
          ? data.textLength.value
          : this.textLength,
      modifiedAt: data.modifiedAt.present
          ? data.modifiedAt.value
          : this.modifiedAt,
      needsRelink: data.needsRelink.present
          ? data.needsRelink.value
          : this.needsRelink,
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalFile(')
          ..write('rootId: $rootId, ')
          ..write('relativePath: $relativePath, ')
          ..write('format: $format, ')
          ..write('textLength: $textLength, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('needsRelink: $needsRelink, ')
          ..write('bookId: $bookId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    rootId,
    relativePath,
    format,
    textLength,
    modifiedAt,
    needsRelink,
    bookId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalFile &&
          other.rootId == this.rootId &&
          other.relativePath == this.relativePath &&
          other.format == this.format &&
          other.textLength == this.textLength &&
          other.modifiedAt == this.modifiedAt &&
          other.needsRelink == this.needsRelink &&
          other.bookId == this.bookId);
}

class LocalFilesCompanion extends UpdateCompanion<LocalFile> {
  final Value<String> rootId;
  final Value<String> relativePath;
  final Value<String> format;
  final Value<int?> textLength;
  final Value<int?> modifiedAt;
  final Value<bool> needsRelink;
  final Value<String?> bookId;
  final Value<int> rowid;
  const LocalFilesCompanion({
    this.rootId = const Value.absent(),
    this.relativePath = const Value.absent(),
    this.format = const Value.absent(),
    this.textLength = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.needsRelink = const Value.absent(),
    this.bookId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalFilesCompanion.insert({
    required String rootId,
    required String relativePath,
    this.format = const Value.absent(),
    this.textLength = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.needsRelink = const Value.absent(),
    this.bookId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : rootId = Value(rootId),
       relativePath = Value(relativePath);
  static Insertable<LocalFile> custom({
    Expression<String>? rootId,
    Expression<String>? relativePath,
    Expression<String>? format,
    Expression<int>? textLength,
    Expression<int>? modifiedAt,
    Expression<bool>? needsRelink,
    Expression<String>? bookId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (rootId != null) 'root_id': rootId,
      if (relativePath != null) 'relative_path': relativePath,
      if (format != null) 'format': format,
      if (textLength != null) 'text_length': textLength,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (needsRelink != null) 'needs_relink': needsRelink,
      if (bookId != null) 'book_id': bookId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalFilesCompanion copyWith({
    Value<String>? rootId,
    Value<String>? relativePath,
    Value<String>? format,
    Value<int?>? textLength,
    Value<int?>? modifiedAt,
    Value<bool>? needsRelink,
    Value<String?>? bookId,
    Value<int>? rowid,
  }) {
    return LocalFilesCompanion(
      rootId: rootId ?? this.rootId,
      relativePath: relativePath ?? this.relativePath,
      format: format ?? this.format,
      textLength: textLength ?? this.textLength,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      needsRelink: needsRelink ?? this.needsRelink,
      bookId: bookId ?? this.bookId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (rootId.present) {
      map['root_id'] = Variable<String>(rootId.value);
    }
    if (relativePath.present) {
      map['relative_path'] = Variable<String>(relativePath.value);
    }
    if (format.present) {
      map['format'] = Variable<String>(format.value);
    }
    if (textLength.present) {
      map['text_length'] = Variable<int>(textLength.value);
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<int>(modifiedAt.value);
    }
    if (needsRelink.present) {
      map['needs_relink'] = Variable<bool>(needsRelink.value);
    }
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalFilesCompanion(')
          ..write('rootId: $rootId, ')
          ..write('relativePath: $relativePath, ')
          ..write('format: $format, ')
          ..write('textLength: $textLength, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('needsRelink: $needsRelink, ')
          ..write('bookId: $bookId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TextIndexTable extends TextIndex
    with TableInfo<$TextIndexTable, TextIndexEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TextIndexTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _rootIdMeta = const VerificationMeta('rootId');
  @override
  late final GeneratedColumn<String> rootId = GeneratedColumn<String>(
    'root_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_roots (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _relativePathMeta = const VerificationMeta(
    'relativePath',
  );
  @override
  late final GeneratedColumn<String> relativePath = GeneratedColumn<String>(
    'relative_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _byteOffsetMeta = const VerificationMeta(
    'byteOffset',
  );
  @override
  late final GeneratedColumn<int> byteOffset = GeneratedColumn<int>(
    'byte_offset',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _codeUnitOffsetMeta = const VerificationMeta(
    'codeUnitOffset',
  );
  @override
  late final GeneratedColumn<int> codeUnitOffset = GeneratedColumn<int>(
    'code_unit_offset',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lineIndexMeta = const VerificationMeta(
    'lineIndex',
  );
  @override
  late final GeneratedColumn<int> lineIndex = GeneratedColumn<int>(
    'line_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    rootId,
    relativePath,
    byteOffset,
    codeUnitOffset,
    lineIndex,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'text_index';
  @override
  VerificationContext validateIntegrity(
    Insertable<TextIndexEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('root_id')) {
      context.handle(
        _rootIdMeta,
        rootId.isAcceptableOrUnknown(data['root_id']!, _rootIdMeta),
      );
    } else if (isInserting) {
      context.missing(_rootIdMeta);
    }
    if (data.containsKey('relative_path')) {
      context.handle(
        _relativePathMeta,
        relativePath.isAcceptableOrUnknown(
          data['relative_path']!,
          _relativePathMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_relativePathMeta);
    }
    if (data.containsKey('byte_offset')) {
      context.handle(
        _byteOffsetMeta,
        byteOffset.isAcceptableOrUnknown(data['byte_offset']!, _byteOffsetMeta),
      );
    } else if (isInserting) {
      context.missing(_byteOffsetMeta);
    }
    if (data.containsKey('code_unit_offset')) {
      context.handle(
        _codeUnitOffsetMeta,
        codeUnitOffset.isAcceptableOrUnknown(
          data['code_unit_offset']!,
          _codeUnitOffsetMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_codeUnitOffsetMeta);
    }
    if (data.containsKey('line_index')) {
      context.handle(
        _lineIndexMeta,
        lineIndex.isAcceptableOrUnknown(data['line_index']!, _lineIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_lineIndexMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {rootId, relativePath, byteOffset};
  @override
  TextIndexEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TextIndexEntry(
      rootId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}root_id'],
      )!,
      relativePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}relative_path'],
      )!,
      byteOffset: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}byte_offset'],
      )!,
      codeUnitOffset: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}code_unit_offset'],
      )!,
      lineIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}line_index'],
      )!,
    );
  }

  @override
  $TextIndexTable createAlias(String alias) {
    return $TextIndexTable(attachedDatabase, alias);
  }
}

class TextIndexEntry extends DataClass implements Insertable<TextIndexEntry> {
  final String rootId;
  final String relativePath;
  final int byteOffset;
  final int codeUnitOffset;
  final int lineIndex;
  const TextIndexEntry({
    required this.rootId,
    required this.relativePath,
    required this.byteOffset,
    required this.codeUnitOffset,
    required this.lineIndex,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['root_id'] = Variable<String>(rootId);
    map['relative_path'] = Variable<String>(relativePath);
    map['byte_offset'] = Variable<int>(byteOffset);
    map['code_unit_offset'] = Variable<int>(codeUnitOffset);
    map['line_index'] = Variable<int>(lineIndex);
    return map;
  }

  TextIndexCompanion toCompanion(bool nullToAbsent) {
    return TextIndexCompanion(
      rootId: Value(rootId),
      relativePath: Value(relativePath),
      byteOffset: Value(byteOffset),
      codeUnitOffset: Value(codeUnitOffset),
      lineIndex: Value(lineIndex),
    );
  }

  factory TextIndexEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TextIndexEntry(
      rootId: serializer.fromJson<String>(json['rootId']),
      relativePath: serializer.fromJson<String>(json['relativePath']),
      byteOffset: serializer.fromJson<int>(json['byteOffset']),
      codeUnitOffset: serializer.fromJson<int>(json['codeUnitOffset']),
      lineIndex: serializer.fromJson<int>(json['lineIndex']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'rootId': serializer.toJson<String>(rootId),
      'relativePath': serializer.toJson<String>(relativePath),
      'byteOffset': serializer.toJson<int>(byteOffset),
      'codeUnitOffset': serializer.toJson<int>(codeUnitOffset),
      'lineIndex': serializer.toJson<int>(lineIndex),
    };
  }

  TextIndexEntry copyWith({
    String? rootId,
    String? relativePath,
    int? byteOffset,
    int? codeUnitOffset,
    int? lineIndex,
  }) => TextIndexEntry(
    rootId: rootId ?? this.rootId,
    relativePath: relativePath ?? this.relativePath,
    byteOffset: byteOffset ?? this.byteOffset,
    codeUnitOffset: codeUnitOffset ?? this.codeUnitOffset,
    lineIndex: lineIndex ?? this.lineIndex,
  );
  TextIndexEntry copyWithCompanion(TextIndexCompanion data) {
    return TextIndexEntry(
      rootId: data.rootId.present ? data.rootId.value : this.rootId,
      relativePath: data.relativePath.present
          ? data.relativePath.value
          : this.relativePath,
      byteOffset: data.byteOffset.present
          ? data.byteOffset.value
          : this.byteOffset,
      codeUnitOffset: data.codeUnitOffset.present
          ? data.codeUnitOffset.value
          : this.codeUnitOffset,
      lineIndex: data.lineIndex.present ? data.lineIndex.value : this.lineIndex,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TextIndexEntry(')
          ..write('rootId: $rootId, ')
          ..write('relativePath: $relativePath, ')
          ..write('byteOffset: $byteOffset, ')
          ..write('codeUnitOffset: $codeUnitOffset, ')
          ..write('lineIndex: $lineIndex')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(rootId, relativePath, byteOffset, codeUnitOffset, lineIndex);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TextIndexEntry &&
          other.rootId == this.rootId &&
          other.relativePath == this.relativePath &&
          other.byteOffset == this.byteOffset &&
          other.codeUnitOffset == this.codeUnitOffset &&
          other.lineIndex == this.lineIndex);
}

class TextIndexCompanion extends UpdateCompanion<TextIndexEntry> {
  final Value<String> rootId;
  final Value<String> relativePath;
  final Value<int> byteOffset;
  final Value<int> codeUnitOffset;
  final Value<int> lineIndex;
  final Value<int> rowid;
  const TextIndexCompanion({
    this.rootId = const Value.absent(),
    this.relativePath = const Value.absent(),
    this.byteOffset = const Value.absent(),
    this.codeUnitOffset = const Value.absent(),
    this.lineIndex = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TextIndexCompanion.insert({
    required String rootId,
    required String relativePath,
    required int byteOffset,
    required int codeUnitOffset,
    required int lineIndex,
    this.rowid = const Value.absent(),
  }) : rootId = Value(rootId),
       relativePath = Value(relativePath),
       byteOffset = Value(byteOffset),
       codeUnitOffset = Value(codeUnitOffset),
       lineIndex = Value(lineIndex);
  static Insertable<TextIndexEntry> custom({
    Expression<String>? rootId,
    Expression<String>? relativePath,
    Expression<int>? byteOffset,
    Expression<int>? codeUnitOffset,
    Expression<int>? lineIndex,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (rootId != null) 'root_id': rootId,
      if (relativePath != null) 'relative_path': relativePath,
      if (byteOffset != null) 'byte_offset': byteOffset,
      if (codeUnitOffset != null) 'code_unit_offset': codeUnitOffset,
      if (lineIndex != null) 'line_index': lineIndex,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TextIndexCompanion copyWith({
    Value<String>? rootId,
    Value<String>? relativePath,
    Value<int>? byteOffset,
    Value<int>? codeUnitOffset,
    Value<int>? lineIndex,
    Value<int>? rowid,
  }) {
    return TextIndexCompanion(
      rootId: rootId ?? this.rootId,
      relativePath: relativePath ?? this.relativePath,
      byteOffset: byteOffset ?? this.byteOffset,
      codeUnitOffset: codeUnitOffset ?? this.codeUnitOffset,
      lineIndex: lineIndex ?? this.lineIndex,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (rootId.present) {
      map['root_id'] = Variable<String>(rootId.value);
    }
    if (relativePath.present) {
      map['relative_path'] = Variable<String>(relativePath.value);
    }
    if (byteOffset.present) {
      map['byte_offset'] = Variable<int>(byteOffset.value);
    }
    if (codeUnitOffset.present) {
      map['code_unit_offset'] = Variable<int>(codeUnitOffset.value);
    }
    if (lineIndex.present) {
      map['line_index'] = Variable<int>(lineIndex.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TextIndexCompanion(')
          ..write('rootId: $rootId, ')
          ..write('relativePath: $relativePath, ')
          ..write('byteOffset: $byteOffset, ')
          ..write('codeUnitOffset: $codeUnitOffset, ')
          ..write('lineIndex: $lineIndex, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ProgressTable extends Progress
    with TableInfo<$ProgressTable, ReadingProgress> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProgressTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES books (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _textOffsetMeta = const VerificationMeta(
    'textOffset',
  );
  @override
  late final GeneratedColumn<int> textOffset = GeneratedColumn<int>(
    'text_offset',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lineIndexMeta = const VerificationMeta(
    'lineIndex',
  );
  @override
  late final GeneratedColumn<int> lineIndex = GeneratedColumn<int>(
    'line_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _offsetInLineMeta = const VerificationMeta(
    'offsetInLine',
  );
  @override
  late final GeneratedColumn<int> offsetInLine = GeneratedColumn<int>(
    'offset_in_line',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _textLengthMeta = const VerificationMeta(
    'textLength',
  );
  @override
  late final GeneratedColumn<int> textLength = GeneratedColumn<int>(
    'text_length',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _chapterKeyMeta = const VerificationMeta(
    'chapterKey',
  );
  @override
  late final GeneratedColumn<String> chapterKey = GeneratedColumn<String>(
    'chapter_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _chapterIndexMeta = const VerificationMeta(
    'chapterIndex',
  );
  @override
  late final GeneratedColumn<int> chapterIndex = GeneratedColumn<int>(
    'chapter_index',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _anchorMeta = const VerificationMeta('anchor');
  @override
  late final GeneratedColumn<String> anchor = GeneratedColumn<String>(
    'anchor',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    bookId,
    textOffset,
    lineIndex,
    offsetInLine,
    textLength,
    chapterKey,
    chapterIndex,
    anchor,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'progress';
  @override
  VerificationContext validateIntegrity(
    Insertable<ReadingProgress> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('text_offset')) {
      context.handle(
        _textOffsetMeta,
        textOffset.isAcceptableOrUnknown(data['text_offset']!, _textOffsetMeta),
      );
    }
    if (data.containsKey('line_index')) {
      context.handle(
        _lineIndexMeta,
        lineIndex.isAcceptableOrUnknown(data['line_index']!, _lineIndexMeta),
      );
    }
    if (data.containsKey('offset_in_line')) {
      context.handle(
        _offsetInLineMeta,
        offsetInLine.isAcceptableOrUnknown(
          data['offset_in_line']!,
          _offsetInLineMeta,
        ),
      );
    }
    if (data.containsKey('text_length')) {
      context.handle(
        _textLengthMeta,
        textLength.isAcceptableOrUnknown(data['text_length']!, _textLengthMeta),
      );
    }
    if (data.containsKey('chapter_key')) {
      context.handle(
        _chapterKeyMeta,
        chapterKey.isAcceptableOrUnknown(data['chapter_key']!, _chapterKeyMeta),
      );
    }
    if (data.containsKey('chapter_index')) {
      context.handle(
        _chapterIndexMeta,
        chapterIndex.isAcceptableOrUnknown(
          data['chapter_index']!,
          _chapterIndexMeta,
        ),
      );
    }
    if (data.containsKey('anchor')) {
      context.handle(
        _anchorMeta,
        anchor.isAcceptableOrUnknown(data['anchor']!, _anchorMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookId};
  @override
  ReadingProgress map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReadingProgress(
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      )!,
      textOffset: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}text_offset'],
      )!,
      lineIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}line_index'],
      )!,
      offsetInLine: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}offset_in_line'],
      )!,
      textLength: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}text_length'],
      )!,
      chapterKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chapter_key'],
      ),
      chapterIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}chapter_index'],
      ),
      anchor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}anchor'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $ProgressTable createAlias(String alias) {
    return $ProgressTable(attachedDatabase, alias);
  }
}

class ReadingProgress extends DataClass implements Insertable<ReadingProgress> {
  final String bookId;

  /// The authoritative absolute code-unit offset.
  final int textOffset;

  /// Display and tolerant restore; the sparse index is anchored at line starts
  /// already, so these cost nothing extra.
  final int lineIndex;
  final int offsetInLine;

  /// The file length the offset was written against; the percentage fallback.
  final int textLength;

  /// TOC navigation and migration alignment, when the book is chaptered.
  final String? chapterKey;
  final int? chapterIndex;

  /// The first code units of the current line, kept verbatim so the tolerant
  /// restore tiers can compare, relocate and search for it.
  final String? anchor;
  final int updatedAt;
  const ReadingProgress({
    required this.bookId,
    required this.textOffset,
    required this.lineIndex,
    required this.offsetInLine,
    required this.textLength,
    this.chapterKey,
    this.chapterIndex,
    this.anchor,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_id'] = Variable<String>(bookId);
    map['text_offset'] = Variable<int>(textOffset);
    map['line_index'] = Variable<int>(lineIndex);
    map['offset_in_line'] = Variable<int>(offsetInLine);
    map['text_length'] = Variable<int>(textLength);
    if (!nullToAbsent || chapterKey != null) {
      map['chapter_key'] = Variable<String>(chapterKey);
    }
    if (!nullToAbsent || chapterIndex != null) {
      map['chapter_index'] = Variable<int>(chapterIndex);
    }
    if (!nullToAbsent || anchor != null) {
      map['anchor'] = Variable<String>(anchor);
    }
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  ProgressCompanion toCompanion(bool nullToAbsent) {
    return ProgressCompanion(
      bookId: Value(bookId),
      textOffset: Value(textOffset),
      lineIndex: Value(lineIndex),
      offsetInLine: Value(offsetInLine),
      textLength: Value(textLength),
      chapterKey: chapterKey == null && nullToAbsent
          ? const Value.absent()
          : Value(chapterKey),
      chapterIndex: chapterIndex == null && nullToAbsent
          ? const Value.absent()
          : Value(chapterIndex),
      anchor: anchor == null && nullToAbsent
          ? const Value.absent()
          : Value(anchor),
      updatedAt: Value(updatedAt),
    );
  }

  factory ReadingProgress.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReadingProgress(
      bookId: serializer.fromJson<String>(json['bookId']),
      textOffset: serializer.fromJson<int>(json['textOffset']),
      lineIndex: serializer.fromJson<int>(json['lineIndex']),
      offsetInLine: serializer.fromJson<int>(json['offsetInLine']),
      textLength: serializer.fromJson<int>(json['textLength']),
      chapterKey: serializer.fromJson<String?>(json['chapterKey']),
      chapterIndex: serializer.fromJson<int?>(json['chapterIndex']),
      anchor: serializer.fromJson<String?>(json['anchor']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookId': serializer.toJson<String>(bookId),
      'textOffset': serializer.toJson<int>(textOffset),
      'lineIndex': serializer.toJson<int>(lineIndex),
      'offsetInLine': serializer.toJson<int>(offsetInLine),
      'textLength': serializer.toJson<int>(textLength),
      'chapterKey': serializer.toJson<String?>(chapterKey),
      'chapterIndex': serializer.toJson<int?>(chapterIndex),
      'anchor': serializer.toJson<String?>(anchor),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  ReadingProgress copyWith({
    String? bookId,
    int? textOffset,
    int? lineIndex,
    int? offsetInLine,
    int? textLength,
    Value<String?> chapterKey = const Value.absent(),
    Value<int?> chapterIndex = const Value.absent(),
    Value<String?> anchor = const Value.absent(),
    int? updatedAt,
  }) => ReadingProgress(
    bookId: bookId ?? this.bookId,
    textOffset: textOffset ?? this.textOffset,
    lineIndex: lineIndex ?? this.lineIndex,
    offsetInLine: offsetInLine ?? this.offsetInLine,
    textLength: textLength ?? this.textLength,
    chapterKey: chapterKey.present ? chapterKey.value : this.chapterKey,
    chapterIndex: chapterIndex.present ? chapterIndex.value : this.chapterIndex,
    anchor: anchor.present ? anchor.value : this.anchor,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ReadingProgress copyWithCompanion(ProgressCompanion data) {
    return ReadingProgress(
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      textOffset: data.textOffset.present
          ? data.textOffset.value
          : this.textOffset,
      lineIndex: data.lineIndex.present ? data.lineIndex.value : this.lineIndex,
      offsetInLine: data.offsetInLine.present
          ? data.offsetInLine.value
          : this.offsetInLine,
      textLength: data.textLength.present
          ? data.textLength.value
          : this.textLength,
      chapterKey: data.chapterKey.present
          ? data.chapterKey.value
          : this.chapterKey,
      chapterIndex: data.chapterIndex.present
          ? data.chapterIndex.value
          : this.chapterIndex,
      anchor: data.anchor.present ? data.anchor.value : this.anchor,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReadingProgress(')
          ..write('bookId: $bookId, ')
          ..write('textOffset: $textOffset, ')
          ..write('lineIndex: $lineIndex, ')
          ..write('offsetInLine: $offsetInLine, ')
          ..write('textLength: $textLength, ')
          ..write('chapterKey: $chapterKey, ')
          ..write('chapterIndex: $chapterIndex, ')
          ..write('anchor: $anchor, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    bookId,
    textOffset,
    lineIndex,
    offsetInLine,
    textLength,
    chapterKey,
    chapterIndex,
    anchor,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReadingProgress &&
          other.bookId == this.bookId &&
          other.textOffset == this.textOffset &&
          other.lineIndex == this.lineIndex &&
          other.offsetInLine == this.offsetInLine &&
          other.textLength == this.textLength &&
          other.chapterKey == this.chapterKey &&
          other.chapterIndex == this.chapterIndex &&
          other.anchor == this.anchor &&
          other.updatedAt == this.updatedAt);
}

class ProgressCompanion extends UpdateCompanion<ReadingProgress> {
  final Value<String> bookId;
  final Value<int> textOffset;
  final Value<int> lineIndex;
  final Value<int> offsetInLine;
  final Value<int> textLength;
  final Value<String?> chapterKey;
  final Value<int?> chapterIndex;
  final Value<String?> anchor;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const ProgressCompanion({
    this.bookId = const Value.absent(),
    this.textOffset = const Value.absent(),
    this.lineIndex = const Value.absent(),
    this.offsetInLine = const Value.absent(),
    this.textLength = const Value.absent(),
    this.chapterKey = const Value.absent(),
    this.chapterIndex = const Value.absent(),
    this.anchor = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProgressCompanion.insert({
    required String bookId,
    this.textOffset = const Value.absent(),
    this.lineIndex = const Value.absent(),
    this.offsetInLine = const Value.absent(),
    this.textLength = const Value.absent(),
    this.chapterKey = const Value.absent(),
    this.chapterIndex = const Value.absent(),
    this.anchor = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : bookId = Value(bookId);
  static Insertable<ReadingProgress> custom({
    Expression<String>? bookId,
    Expression<int>? textOffset,
    Expression<int>? lineIndex,
    Expression<int>? offsetInLine,
    Expression<int>? textLength,
    Expression<String>? chapterKey,
    Expression<int>? chapterIndex,
    Expression<String>? anchor,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookId != null) 'book_id': bookId,
      if (textOffset != null) 'text_offset': textOffset,
      if (lineIndex != null) 'line_index': lineIndex,
      if (offsetInLine != null) 'offset_in_line': offsetInLine,
      if (textLength != null) 'text_length': textLength,
      if (chapterKey != null) 'chapter_key': chapterKey,
      if (chapterIndex != null) 'chapter_index': chapterIndex,
      if (anchor != null) 'anchor': anchor,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProgressCompanion copyWith({
    Value<String>? bookId,
    Value<int>? textOffset,
    Value<int>? lineIndex,
    Value<int>? offsetInLine,
    Value<int>? textLength,
    Value<String?>? chapterKey,
    Value<int?>? chapterIndex,
    Value<String?>? anchor,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return ProgressCompanion(
      bookId: bookId ?? this.bookId,
      textOffset: textOffset ?? this.textOffset,
      lineIndex: lineIndex ?? this.lineIndex,
      offsetInLine: offsetInLine ?? this.offsetInLine,
      textLength: textLength ?? this.textLength,
      chapterKey: chapterKey ?? this.chapterKey,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      anchor: anchor ?? this.anchor,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (textOffset.present) {
      map['text_offset'] = Variable<int>(textOffset.value);
    }
    if (lineIndex.present) {
      map['line_index'] = Variable<int>(lineIndex.value);
    }
    if (offsetInLine.present) {
      map['offset_in_line'] = Variable<int>(offsetInLine.value);
    }
    if (textLength.present) {
      map['text_length'] = Variable<int>(textLength.value);
    }
    if (chapterKey.present) {
      map['chapter_key'] = Variable<String>(chapterKey.value);
    }
    if (chapterIndex.present) {
      map['chapter_index'] = Variable<int>(chapterIndex.value);
    }
    if (anchor.present) {
      map['anchor'] = Variable<String>(anchor.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProgressCompanion(')
          ..write('bookId: $bookId, ')
          ..write('textOffset: $textOffset, ')
          ..write('lineIndex: $lineIndex, ')
          ..write('offsetInLine: $offsetInLine, ')
          ..write('textLength: $textLength, ')
          ..write('chapterKey: $chapterKey, ')
          ..write('chapterIndex: $chapterIndex, ')
          ..write('anchor: $anchor, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ReplaceRulesTable extends ReplaceRules
    with TableInfo<$ReplaceRulesTable, ReplaceRule> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReplaceRulesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _groupNameMeta = const VerificationMeta(
    'groupName',
  );
  @override
  late final GeneratedColumn<String> groupName = GeneratedColumn<String>(
    'group_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _patternMeta = const VerificationMeta(
    'pattern',
  );
  @override
  late final GeneratedColumn<String> pattern = GeneratedColumn<String>(
    'pattern',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _replacementMeta = const VerificationMeta(
    'replacement',
  );
  @override
  late final GeneratedColumn<String> replacement = GeneratedColumn<String>(
    'replacement',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _scopeMeta = const VerificationMeta('scope');
  @override
  late final GeneratedColumn<String> scope = GeneratedColumn<String>(
    'scope',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _excludeScopeMeta = const VerificationMeta(
    'excludeScope',
  );
  @override
  late final GeneratedColumn<String> excludeScope = GeneratedColumn<String>(
    'exclude_scope',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _scopeTitleMeta = const VerificationMeta(
    'scopeTitle',
  );
  @override
  late final GeneratedColumn<bool> scopeTitle = GeneratedColumn<bool>(
    'scope_title',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("scope_title" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _scopeContentMeta = const VerificationMeta(
    'scopeContent',
  );
  @override
  late final GeneratedColumn<bool> scopeContent = GeneratedColumn<bool>(
    'scope_content',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("scope_content" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _isEnabledMeta = const VerificationMeta(
    'isEnabled',
  );
  @override
  late final GeneratedColumn<bool> isEnabled = GeneratedColumn<bool>(
    'is_enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _isRegexMeta = const VerificationMeta(
    'isRegex',
  );
  @override
  late final GeneratedColumn<bool> isRegex = GeneratedColumn<bool>(
    'is_regex',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_regex" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _timeoutMillisecondMeta =
      const VerificationMeta('timeoutMillisecond');
  @override
  late final GeneratedColumn<int> timeoutMillisecond = GeneratedColumn<int>(
    'timeout_millisecond',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _ruleOrderMeta = const VerificationMeta(
    'ruleOrder',
  );
  @override
  late final GeneratedColumn<int> ruleOrder = GeneratedColumn<int>(
    'rule_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _rawMeta = const VerificationMeta('raw');
  @override
  late final GeneratedColumn<String> raw = GeneratedColumn<String>(
    'raw',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    groupName,
    pattern,
    replacement,
    scope,
    excludeScope,
    scopeTitle,
    scopeContent,
    isEnabled,
    isRegex,
    timeoutMillisecond,
    ruleOrder,
    raw,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'replace_rules';
  @override
  VerificationContext validateIntegrity(
    Insertable<ReplaceRule> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('group_name')) {
      context.handle(
        _groupNameMeta,
        groupName.isAcceptableOrUnknown(data['group_name']!, _groupNameMeta),
      );
    }
    if (data.containsKey('pattern')) {
      context.handle(
        _patternMeta,
        pattern.isAcceptableOrUnknown(data['pattern']!, _patternMeta),
      );
    } else if (isInserting) {
      context.missing(_patternMeta);
    }
    if (data.containsKey('replacement')) {
      context.handle(
        _replacementMeta,
        replacement.isAcceptableOrUnknown(
          data['replacement']!,
          _replacementMeta,
        ),
      );
    }
    if (data.containsKey('scope')) {
      context.handle(
        _scopeMeta,
        scope.isAcceptableOrUnknown(data['scope']!, _scopeMeta),
      );
    }
    if (data.containsKey('exclude_scope')) {
      context.handle(
        _excludeScopeMeta,
        excludeScope.isAcceptableOrUnknown(
          data['exclude_scope']!,
          _excludeScopeMeta,
        ),
      );
    }
    if (data.containsKey('scope_title')) {
      context.handle(
        _scopeTitleMeta,
        scopeTitle.isAcceptableOrUnknown(data['scope_title']!, _scopeTitleMeta),
      );
    }
    if (data.containsKey('scope_content')) {
      context.handle(
        _scopeContentMeta,
        scopeContent.isAcceptableOrUnknown(
          data['scope_content']!,
          _scopeContentMeta,
        ),
      );
    }
    if (data.containsKey('is_enabled')) {
      context.handle(
        _isEnabledMeta,
        isEnabled.isAcceptableOrUnknown(data['is_enabled']!, _isEnabledMeta),
      );
    }
    if (data.containsKey('is_regex')) {
      context.handle(
        _isRegexMeta,
        isRegex.isAcceptableOrUnknown(data['is_regex']!, _isRegexMeta),
      );
    }
    if (data.containsKey('timeout_millisecond')) {
      context.handle(
        _timeoutMillisecondMeta,
        timeoutMillisecond.isAcceptableOrUnknown(
          data['timeout_millisecond']!,
          _timeoutMillisecondMeta,
        ),
      );
    }
    if (data.containsKey('rule_order')) {
      context.handle(
        _ruleOrderMeta,
        ruleOrder.isAcceptableOrUnknown(data['rule_order']!, _ruleOrderMeta),
      );
    }
    if (data.containsKey('raw')) {
      context.handle(
        _rawMeta,
        raw.isAcceptableOrUnknown(data['raw']!, _rawMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ReplaceRule map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReplaceRule(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      groupName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_name'],
      )!,
      pattern: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pattern'],
      )!,
      replacement: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}replacement'],
      )!,
      scope: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope'],
      ),
      excludeScope: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}exclude_scope'],
      ),
      scopeTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}scope_title'],
      )!,
      scopeContent: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}scope_content'],
      )!,
      isEnabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_enabled'],
      )!,
      isRegex: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_regex'],
      )!,
      timeoutMillisecond: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}timeout_millisecond'],
      )!,
      ruleOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}rule_order'],
      )!,
      raw: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}raw'],
      ),
    );
  }

  @override
  $ReplaceRulesTable createAlias(String alias) {
    return $ReplaceRulesTable(attachedDatabase, alias);
  }
}

class ReplaceRule extends DataClass implements Insertable<ReplaceRule> {
  final String id;
  final String name;

  /// Legado's `group` field: the single group name a rule belongs to.
  final String groupName;
  final String pattern;
  final String replacement;
  final String? scope;
  final String? excludeScope;
  final bool scopeTitle;
  final bool scopeContent;
  final bool isEnabled;
  final bool isRegex;
  final int timeoutMillisecond;
  final int ruleOrder;

  /// The imported object as it arrived, unknown fields included.
  final String? raw;
  const ReplaceRule({
    required this.id,
    required this.name,
    required this.groupName,
    required this.pattern,
    required this.replacement,
    this.scope,
    this.excludeScope,
    required this.scopeTitle,
    required this.scopeContent,
    required this.isEnabled,
    required this.isRegex,
    required this.timeoutMillisecond,
    required this.ruleOrder,
    this.raw,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['group_name'] = Variable<String>(groupName);
    map['pattern'] = Variable<String>(pattern);
    map['replacement'] = Variable<String>(replacement);
    if (!nullToAbsent || scope != null) {
      map['scope'] = Variable<String>(scope);
    }
    if (!nullToAbsent || excludeScope != null) {
      map['exclude_scope'] = Variable<String>(excludeScope);
    }
    map['scope_title'] = Variable<bool>(scopeTitle);
    map['scope_content'] = Variable<bool>(scopeContent);
    map['is_enabled'] = Variable<bool>(isEnabled);
    map['is_regex'] = Variable<bool>(isRegex);
    map['timeout_millisecond'] = Variable<int>(timeoutMillisecond);
    map['rule_order'] = Variable<int>(ruleOrder);
    if (!nullToAbsent || raw != null) {
      map['raw'] = Variable<String>(raw);
    }
    return map;
  }

  ReplaceRulesCompanion toCompanion(bool nullToAbsent) {
    return ReplaceRulesCompanion(
      id: Value(id),
      name: Value(name),
      groupName: Value(groupName),
      pattern: Value(pattern),
      replacement: Value(replacement),
      scope: scope == null && nullToAbsent
          ? const Value.absent()
          : Value(scope),
      excludeScope: excludeScope == null && nullToAbsent
          ? const Value.absent()
          : Value(excludeScope),
      scopeTitle: Value(scopeTitle),
      scopeContent: Value(scopeContent),
      isEnabled: Value(isEnabled),
      isRegex: Value(isRegex),
      timeoutMillisecond: Value(timeoutMillisecond),
      ruleOrder: Value(ruleOrder),
      raw: raw == null && nullToAbsent ? const Value.absent() : Value(raw),
    );
  }

  factory ReplaceRule.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReplaceRule(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      groupName: serializer.fromJson<String>(json['groupName']),
      pattern: serializer.fromJson<String>(json['pattern']),
      replacement: serializer.fromJson<String>(json['replacement']),
      scope: serializer.fromJson<String?>(json['scope']),
      excludeScope: serializer.fromJson<String?>(json['excludeScope']),
      scopeTitle: serializer.fromJson<bool>(json['scopeTitle']),
      scopeContent: serializer.fromJson<bool>(json['scopeContent']),
      isEnabled: serializer.fromJson<bool>(json['isEnabled']),
      isRegex: serializer.fromJson<bool>(json['isRegex']),
      timeoutMillisecond: serializer.fromJson<int>(json['timeoutMillisecond']),
      ruleOrder: serializer.fromJson<int>(json['ruleOrder']),
      raw: serializer.fromJson<String?>(json['raw']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'groupName': serializer.toJson<String>(groupName),
      'pattern': serializer.toJson<String>(pattern),
      'replacement': serializer.toJson<String>(replacement),
      'scope': serializer.toJson<String?>(scope),
      'excludeScope': serializer.toJson<String?>(excludeScope),
      'scopeTitle': serializer.toJson<bool>(scopeTitle),
      'scopeContent': serializer.toJson<bool>(scopeContent),
      'isEnabled': serializer.toJson<bool>(isEnabled),
      'isRegex': serializer.toJson<bool>(isRegex),
      'timeoutMillisecond': serializer.toJson<int>(timeoutMillisecond),
      'ruleOrder': serializer.toJson<int>(ruleOrder),
      'raw': serializer.toJson<String?>(raw),
    };
  }

  ReplaceRule copyWith({
    String? id,
    String? name,
    String? groupName,
    String? pattern,
    String? replacement,
    Value<String?> scope = const Value.absent(),
    Value<String?> excludeScope = const Value.absent(),
    bool? scopeTitle,
    bool? scopeContent,
    bool? isEnabled,
    bool? isRegex,
    int? timeoutMillisecond,
    int? ruleOrder,
    Value<String?> raw = const Value.absent(),
  }) => ReplaceRule(
    id: id ?? this.id,
    name: name ?? this.name,
    groupName: groupName ?? this.groupName,
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    scope: scope.present ? scope.value : this.scope,
    excludeScope: excludeScope.present ? excludeScope.value : this.excludeScope,
    scopeTitle: scopeTitle ?? this.scopeTitle,
    scopeContent: scopeContent ?? this.scopeContent,
    isEnabled: isEnabled ?? this.isEnabled,
    isRegex: isRegex ?? this.isRegex,
    timeoutMillisecond: timeoutMillisecond ?? this.timeoutMillisecond,
    ruleOrder: ruleOrder ?? this.ruleOrder,
    raw: raw.present ? raw.value : this.raw,
  );
  ReplaceRule copyWithCompanion(ReplaceRulesCompanion data) {
    return ReplaceRule(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      groupName: data.groupName.present ? data.groupName.value : this.groupName,
      pattern: data.pattern.present ? data.pattern.value : this.pattern,
      replacement: data.replacement.present
          ? data.replacement.value
          : this.replacement,
      scope: data.scope.present ? data.scope.value : this.scope,
      excludeScope: data.excludeScope.present
          ? data.excludeScope.value
          : this.excludeScope,
      scopeTitle: data.scopeTitle.present
          ? data.scopeTitle.value
          : this.scopeTitle,
      scopeContent: data.scopeContent.present
          ? data.scopeContent.value
          : this.scopeContent,
      isEnabled: data.isEnabled.present ? data.isEnabled.value : this.isEnabled,
      isRegex: data.isRegex.present ? data.isRegex.value : this.isRegex,
      timeoutMillisecond: data.timeoutMillisecond.present
          ? data.timeoutMillisecond.value
          : this.timeoutMillisecond,
      ruleOrder: data.ruleOrder.present ? data.ruleOrder.value : this.ruleOrder,
      raw: data.raw.present ? data.raw.value : this.raw,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReplaceRule(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('groupName: $groupName, ')
          ..write('pattern: $pattern, ')
          ..write('replacement: $replacement, ')
          ..write('scope: $scope, ')
          ..write('excludeScope: $excludeScope, ')
          ..write('scopeTitle: $scopeTitle, ')
          ..write('scopeContent: $scopeContent, ')
          ..write('isEnabled: $isEnabled, ')
          ..write('isRegex: $isRegex, ')
          ..write('timeoutMillisecond: $timeoutMillisecond, ')
          ..write('ruleOrder: $ruleOrder, ')
          ..write('raw: $raw')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    groupName,
    pattern,
    replacement,
    scope,
    excludeScope,
    scopeTitle,
    scopeContent,
    isEnabled,
    isRegex,
    timeoutMillisecond,
    ruleOrder,
    raw,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReplaceRule &&
          other.id == this.id &&
          other.name == this.name &&
          other.groupName == this.groupName &&
          other.pattern == this.pattern &&
          other.replacement == this.replacement &&
          other.scope == this.scope &&
          other.excludeScope == this.excludeScope &&
          other.scopeTitle == this.scopeTitle &&
          other.scopeContent == this.scopeContent &&
          other.isEnabled == this.isEnabled &&
          other.isRegex == this.isRegex &&
          other.timeoutMillisecond == this.timeoutMillisecond &&
          other.ruleOrder == this.ruleOrder &&
          other.raw == this.raw);
}

class ReplaceRulesCompanion extends UpdateCompanion<ReplaceRule> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> groupName;
  final Value<String> pattern;
  final Value<String> replacement;
  final Value<String?> scope;
  final Value<String?> excludeScope;
  final Value<bool> scopeTitle;
  final Value<bool> scopeContent;
  final Value<bool> isEnabled;
  final Value<bool> isRegex;
  final Value<int> timeoutMillisecond;
  final Value<int> ruleOrder;
  final Value<String?> raw;
  final Value<int> rowid;
  const ReplaceRulesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.groupName = const Value.absent(),
    this.pattern = const Value.absent(),
    this.replacement = const Value.absent(),
    this.scope = const Value.absent(),
    this.excludeScope = const Value.absent(),
    this.scopeTitle = const Value.absent(),
    this.scopeContent = const Value.absent(),
    this.isEnabled = const Value.absent(),
    this.isRegex = const Value.absent(),
    this.timeoutMillisecond = const Value.absent(),
    this.ruleOrder = const Value.absent(),
    this.raw = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReplaceRulesCompanion.insert({
    required String id,
    required String name,
    this.groupName = const Value.absent(),
    required String pattern,
    this.replacement = const Value.absent(),
    this.scope = const Value.absent(),
    this.excludeScope = const Value.absent(),
    this.scopeTitle = const Value.absent(),
    this.scopeContent = const Value.absent(),
    this.isEnabled = const Value.absent(),
    this.isRegex = const Value.absent(),
    this.timeoutMillisecond = const Value.absent(),
    this.ruleOrder = const Value.absent(),
    this.raw = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       pattern = Value(pattern);
  static Insertable<ReplaceRule> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? groupName,
    Expression<String>? pattern,
    Expression<String>? replacement,
    Expression<String>? scope,
    Expression<String>? excludeScope,
    Expression<bool>? scopeTitle,
    Expression<bool>? scopeContent,
    Expression<bool>? isEnabled,
    Expression<bool>? isRegex,
    Expression<int>? timeoutMillisecond,
    Expression<int>? ruleOrder,
    Expression<String>? raw,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (groupName != null) 'group_name': groupName,
      if (pattern != null) 'pattern': pattern,
      if (replacement != null) 'replacement': replacement,
      if (scope != null) 'scope': scope,
      if (excludeScope != null) 'exclude_scope': excludeScope,
      if (scopeTitle != null) 'scope_title': scopeTitle,
      if (scopeContent != null) 'scope_content': scopeContent,
      if (isEnabled != null) 'is_enabled': isEnabled,
      if (isRegex != null) 'is_regex': isRegex,
      if (timeoutMillisecond != null) 'timeout_millisecond': timeoutMillisecond,
      if (ruleOrder != null) 'rule_order': ruleOrder,
      if (raw != null) 'raw': raw,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReplaceRulesCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? groupName,
    Value<String>? pattern,
    Value<String>? replacement,
    Value<String?>? scope,
    Value<String?>? excludeScope,
    Value<bool>? scopeTitle,
    Value<bool>? scopeContent,
    Value<bool>? isEnabled,
    Value<bool>? isRegex,
    Value<int>? timeoutMillisecond,
    Value<int>? ruleOrder,
    Value<String?>? raw,
    Value<int>? rowid,
  }) {
    return ReplaceRulesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      groupName: groupName ?? this.groupName,
      pattern: pattern ?? this.pattern,
      replacement: replacement ?? this.replacement,
      scope: scope ?? this.scope,
      excludeScope: excludeScope ?? this.excludeScope,
      scopeTitle: scopeTitle ?? this.scopeTitle,
      scopeContent: scopeContent ?? this.scopeContent,
      isEnabled: isEnabled ?? this.isEnabled,
      isRegex: isRegex ?? this.isRegex,
      timeoutMillisecond: timeoutMillisecond ?? this.timeoutMillisecond,
      ruleOrder: ruleOrder ?? this.ruleOrder,
      raw: raw ?? this.raw,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (groupName.present) {
      map['group_name'] = Variable<String>(groupName.value);
    }
    if (pattern.present) {
      map['pattern'] = Variable<String>(pattern.value);
    }
    if (replacement.present) {
      map['replacement'] = Variable<String>(replacement.value);
    }
    if (scope.present) {
      map['scope'] = Variable<String>(scope.value);
    }
    if (excludeScope.present) {
      map['exclude_scope'] = Variable<String>(excludeScope.value);
    }
    if (scopeTitle.present) {
      map['scope_title'] = Variable<bool>(scopeTitle.value);
    }
    if (scopeContent.present) {
      map['scope_content'] = Variable<bool>(scopeContent.value);
    }
    if (isEnabled.present) {
      map['is_enabled'] = Variable<bool>(isEnabled.value);
    }
    if (isRegex.present) {
      map['is_regex'] = Variable<bool>(isRegex.value);
    }
    if (timeoutMillisecond.present) {
      map['timeout_millisecond'] = Variable<int>(timeoutMillisecond.value);
    }
    if (ruleOrder.present) {
      map['rule_order'] = Variable<int>(ruleOrder.value);
    }
    if (raw.present) {
      map['raw'] = Variable<String>(raw.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReplaceRulesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('groupName: $groupName, ')
          ..write('pattern: $pattern, ')
          ..write('replacement: $replacement, ')
          ..write('scope: $scope, ')
          ..write('excludeScope: $excludeScope, ')
          ..write('scopeTitle: $scopeTitle, ')
          ..write('scopeContent: $scopeContent, ')
          ..write('isEnabled: $isEnabled, ')
          ..write('isRegex: $isRegex, ')
          ..write('timeoutMillisecond: $timeoutMillisecond, ')
          ..write('ruleOrder: $ruleOrder, ')
          ..write('raw: $raw, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SettingsTable extends Settings
    with TableInfo<$SettingsTable, SpaceSetting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [bookId, key, value, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<SpaceSetting> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    }
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookId, key};
  @override
  SpaceSetting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SpaceSetting(
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      )!,
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $SettingsTable createAlias(String alias) {
    return $SettingsTable(attachedDatabase, alias);
  }
}

class SpaceSetting extends DataClass implements Insertable<SpaceSetting> {
  final String bookId;
  final String key;
  final String value;
  final int updatedAt;
  const SpaceSetting({
    required this.bookId,
    required this.key,
    required this.value,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_id'] = Variable<String>(bookId);
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  SettingsCompanion toCompanion(bool nullToAbsent) {
    return SettingsCompanion(
      bookId: Value(bookId),
      key: Value(key),
      value: Value(value),
      updatedAt: Value(updatedAt),
    );
  }

  factory SpaceSetting.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SpaceSetting(
      bookId: serializer.fromJson<String>(json['bookId']),
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookId': serializer.toJson<String>(bookId),
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  SpaceSetting copyWith({
    String? bookId,
    String? key,
    String? value,
    int? updatedAt,
  }) => SpaceSetting(
    bookId: bookId ?? this.bookId,
    key: key ?? this.key,
    value: value ?? this.value,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  SpaceSetting copyWithCompanion(SettingsCompanion data) {
    return SpaceSetting(
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SpaceSetting(')
          ..write('bookId: $bookId, ')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(bookId, key, value, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SpaceSetting &&
          other.bookId == this.bookId &&
          other.key == this.key &&
          other.value == this.value &&
          other.updatedAt == this.updatedAt);
}

class SettingsCompanion extends UpdateCompanion<SpaceSetting> {
  final Value<String> bookId;
  final Value<String> key;
  final Value<String> value;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const SettingsCompanion({
    this.bookId = const Value.absent(),
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SettingsCompanion.insert({
    this.bookId = const Value.absent(),
    required String key,
    required String value,
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<SpaceSetting> custom({
    Expression<String>? bookId,
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookId != null) 'book_id': bookId,
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SettingsCompanion copyWith({
    Value<String>? bookId,
    Value<String>? key,
    Value<String>? value,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return SettingsCompanion(
      bookId: bookId ?? this.bookId,
      key: key ?? this.key,
      value: value ?? this.value,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsCompanion(')
          ..write('bookId: $bookId, ')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SourceCookiesTable extends SourceCookies
    with TableInfo<$SourceCookiesTable, StoredCookie> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SourceCookiesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _domainMeta = const VerificationMeta('domain');
  @override
  late final GeneratedColumn<String> domain = GeneratedColumn<String>(
    'domain',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _writerRefMeta = const VerificationMeta(
    'writerRef',
  );
  @override
  late final GeneratedColumn<String> writerRef = GeneratedColumn<String>(
    'writer_ref',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [domain, name, value, writerRef];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'source_cookies';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredCookie> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('domain')) {
      context.handle(
        _domainMeta,
        domain.isAcceptableOrUnknown(data['domain']!, _domainMeta),
      );
    } else if (isInserting) {
      context.missing(_domainMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    if (data.containsKey('writer_ref')) {
      context.handle(
        _writerRefMeta,
        writerRef.isAcceptableOrUnknown(data['writer_ref']!, _writerRefMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {domain, name};
  @override
  StoredCookie map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredCookie(
      domain: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}domain'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
      writerRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}writer_ref'],
      ),
    );
  }

  @override
  $SourceCookiesTable createAlias(String alias) {
    return $SourceCookiesTable(attachedDatabase, alias);
  }
}

class StoredCookie extends DataClass implements Insertable<StoredCookie> {
  final String domain;
  final String name;
  final String value;
  final String? writerRef;
  const StoredCookie({
    required this.domain,
    required this.name,
    required this.value,
    this.writerRef,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['domain'] = Variable<String>(domain);
    map['name'] = Variable<String>(name);
    map['value'] = Variable<String>(value);
    if (!nullToAbsent || writerRef != null) {
      map['writer_ref'] = Variable<String>(writerRef);
    }
    return map;
  }

  SourceCookiesCompanion toCompanion(bool nullToAbsent) {
    return SourceCookiesCompanion(
      domain: Value(domain),
      name: Value(name),
      value: Value(value),
      writerRef: writerRef == null && nullToAbsent
          ? const Value.absent()
          : Value(writerRef),
    );
  }

  factory StoredCookie.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredCookie(
      domain: serializer.fromJson<String>(json['domain']),
      name: serializer.fromJson<String>(json['name']),
      value: serializer.fromJson<String>(json['value']),
      writerRef: serializer.fromJson<String?>(json['writerRef']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'domain': serializer.toJson<String>(domain),
      'name': serializer.toJson<String>(name),
      'value': serializer.toJson<String>(value),
      'writerRef': serializer.toJson<String?>(writerRef),
    };
  }

  StoredCookie copyWith({
    String? domain,
    String? name,
    String? value,
    Value<String?> writerRef = const Value.absent(),
  }) => StoredCookie(
    domain: domain ?? this.domain,
    name: name ?? this.name,
    value: value ?? this.value,
    writerRef: writerRef.present ? writerRef.value : this.writerRef,
  );
  StoredCookie copyWithCompanion(SourceCookiesCompanion data) {
    return StoredCookie(
      domain: data.domain.present ? data.domain.value : this.domain,
      name: data.name.present ? data.name.value : this.name,
      value: data.value.present ? data.value.value : this.value,
      writerRef: data.writerRef.present ? data.writerRef.value : this.writerRef,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredCookie(')
          ..write('domain: $domain, ')
          ..write('name: $name, ')
          ..write('value: $value, ')
          ..write('writerRef: $writerRef')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(domain, name, value, writerRef);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredCookie &&
          other.domain == this.domain &&
          other.name == this.name &&
          other.value == this.value &&
          other.writerRef == this.writerRef);
}

class SourceCookiesCompanion extends UpdateCompanion<StoredCookie> {
  final Value<String> domain;
  final Value<String> name;
  final Value<String> value;
  final Value<String?> writerRef;
  final Value<int> rowid;
  const SourceCookiesCompanion({
    this.domain = const Value.absent(),
    this.name = const Value.absent(),
    this.value = const Value.absent(),
    this.writerRef = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SourceCookiesCompanion.insert({
    required String domain,
    required String name,
    required String value,
    this.writerRef = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : domain = Value(domain),
       name = Value(name),
       value = Value(value);
  static Insertable<StoredCookie> custom({
    Expression<String>? domain,
    Expression<String>? name,
    Expression<String>? value,
    Expression<String>? writerRef,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (domain != null) 'domain': domain,
      if (name != null) 'name': name,
      if (value != null) 'value': value,
      if (writerRef != null) 'writer_ref': writerRef,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SourceCookiesCompanion copyWith({
    Value<String>? domain,
    Value<String>? name,
    Value<String>? value,
    Value<String?>? writerRef,
    Value<int>? rowid,
  }) {
    return SourceCookiesCompanion(
      domain: domain ?? this.domain,
      name: name ?? this.name,
      value: value ?? this.value,
      writerRef: writerRef ?? this.writerRef,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (domain.present) {
      map['domain'] = Variable<String>(domain.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (writerRef.present) {
      map['writer_ref'] = Variable<String>(writerRef.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SourceCookiesCompanion(')
          ..write('domain: $domain, ')
          ..write('name: $name, ')
          ..write('value: $value, ')
          ..write('writerRef: $writerRef, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SourceEntriesTable extends SourceEntries
    with TableInfo<$SourceEntriesTable, StoredSourceEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SourceEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceRefMeta = const VerificationMeta(
    'sourceRef',
  );
  @override
  late final GeneratedColumn<String> sourceRef = GeneratedColumn<String>(
    'source_ref',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<int> expiresAt = GeneratedColumn<int>(
    'expires_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _writtenAtMeta = const VerificationMeta(
    'writtenAt',
  );
  @override
  late final GeneratedColumn<int> writtenAt = GeneratedColumn<int>(
    'written_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    sourceRef,
    key,
    value,
    expiresAt,
    writtenAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'source_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredSourceEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source_ref')) {
      context.handle(
        _sourceRefMeta,
        sourceRef.isAcceptableOrUnknown(data['source_ref']!, _sourceRefMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceRefMeta);
    }
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    }
    if (data.containsKey('written_at')) {
      context.handle(
        _writtenAtMeta,
        writtenAt.isAcceptableOrUnknown(data['written_at']!, _writtenAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sourceRef, key};
  @override
  StoredSourceEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredSourceEntry(
      sourceRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_ref'],
      )!,
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      ),
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}expires_at'],
      )!,
      writtenAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}written_at'],
      )!,
    );
  }

  @override
  $SourceEntriesTable createAlias(String alias) {
    return $SourceEntriesTable(attachedDatabase, alias);
  }
}

class StoredSourceEntry extends DataClass
    implements Insertable<StoredSourceEntry> {
  final String sourceRef;
  final String key;
  final String? value;
  final int expiresAt;

  /// The instant this row was last written (milliseconds since the epoch).
  /// A v4 row has no instant and defaults to 0, which sorts before any v5
  /// write, so it is the first evicted.
  final int writtenAt;
  const StoredSourceEntry({
    required this.sourceRef,
    required this.key,
    this.value,
    required this.expiresAt,
    required this.writtenAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source_ref'] = Variable<String>(sourceRef);
    map['key'] = Variable<String>(key);
    if (!nullToAbsent || value != null) {
      map['value'] = Variable<String>(value);
    }
    map['expires_at'] = Variable<int>(expiresAt);
    map['written_at'] = Variable<int>(writtenAt);
    return map;
  }

  SourceEntriesCompanion toCompanion(bool nullToAbsent) {
    return SourceEntriesCompanion(
      sourceRef: Value(sourceRef),
      key: Value(key),
      value: value == null && nullToAbsent
          ? const Value.absent()
          : Value(value),
      expiresAt: Value(expiresAt),
      writtenAt: Value(writtenAt),
    );
  }

  factory StoredSourceEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredSourceEntry(
      sourceRef: serializer.fromJson<String>(json['sourceRef']),
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String?>(json['value']),
      expiresAt: serializer.fromJson<int>(json['expiresAt']),
      writtenAt: serializer.fromJson<int>(json['writtenAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sourceRef': serializer.toJson<String>(sourceRef),
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String?>(value),
      'expiresAt': serializer.toJson<int>(expiresAt),
      'writtenAt': serializer.toJson<int>(writtenAt),
    };
  }

  StoredSourceEntry copyWith({
    String? sourceRef,
    String? key,
    Value<String?> value = const Value.absent(),
    int? expiresAt,
    int? writtenAt,
  }) => StoredSourceEntry(
    sourceRef: sourceRef ?? this.sourceRef,
    key: key ?? this.key,
    value: value.present ? value.value : this.value,
    expiresAt: expiresAt ?? this.expiresAt,
    writtenAt: writtenAt ?? this.writtenAt,
  );
  StoredSourceEntry copyWithCompanion(SourceEntriesCompanion data) {
    return StoredSourceEntry(
      sourceRef: data.sourceRef.present ? data.sourceRef.value : this.sourceRef,
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
      writtenAt: data.writtenAt.present ? data.writtenAt.value : this.writtenAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredSourceEntry(')
          ..write('sourceRef: $sourceRef, ')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('writtenAt: $writtenAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(sourceRef, key, value, expiresAt, writtenAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredSourceEntry &&
          other.sourceRef == this.sourceRef &&
          other.key == this.key &&
          other.value == this.value &&
          other.expiresAt == this.expiresAt &&
          other.writtenAt == this.writtenAt);
}

class SourceEntriesCompanion extends UpdateCompanion<StoredSourceEntry> {
  final Value<String> sourceRef;
  final Value<String> key;
  final Value<String?> value;
  final Value<int> expiresAt;
  final Value<int> writtenAt;
  final Value<int> rowid;
  const SourceEntriesCompanion({
    this.sourceRef = const Value.absent(),
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.writtenAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SourceEntriesCompanion.insert({
    required String sourceRef,
    required String key,
    this.value = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.writtenAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : sourceRef = Value(sourceRef),
       key = Value(key);
  static Insertable<StoredSourceEntry> custom({
    Expression<String>? sourceRef,
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? expiresAt,
    Expression<int>? writtenAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sourceRef != null) 'source_ref': sourceRef,
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (writtenAt != null) 'written_at': writtenAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SourceEntriesCompanion copyWith({
    Value<String>? sourceRef,
    Value<String>? key,
    Value<String?>? value,
    Value<int>? expiresAt,
    Value<int>? writtenAt,
    Value<int>? rowid,
  }) {
    return SourceEntriesCompanion(
      sourceRef: sourceRef ?? this.sourceRef,
      key: key ?? this.key,
      value: value ?? this.value,
      expiresAt: expiresAt ?? this.expiresAt,
      writtenAt: writtenAt ?? this.writtenAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sourceRef.present) {
      map['source_ref'] = Variable<String>(sourceRef.value);
    }
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<int>(expiresAt.value);
    }
    if (writtenAt.present) {
      map['written_at'] = Variable<int>(writtenAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SourceEntriesCompanion(')
          ..write('sourceRef: $sourceRef, ')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('writtenAt: $writtenAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SourceTlsExceptionsTable extends SourceTlsExceptions
    with TableInfo<$SourceTlsExceptionsTable, StoredTlsException> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SourceTlsExceptionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceRefMeta = const VerificationMeta(
    'sourceRef',
  );
  @override
  late final GeneratedColumn<String> sourceRef = GeneratedColumn<String>(
    'source_ref',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hostMeta = const VerificationMeta('host');
  @override
  late final GeneratedColumn<String> host = GeneratedColumn<String>(
    'host',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [sourceRef, host];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'source_tls_exceptions';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredTlsException> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source_ref')) {
      context.handle(
        _sourceRefMeta,
        sourceRef.isAcceptableOrUnknown(data['source_ref']!, _sourceRefMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceRefMeta);
    }
    if (data.containsKey('host')) {
      context.handle(
        _hostMeta,
        host.isAcceptableOrUnknown(data['host']!, _hostMeta),
      );
    } else if (isInserting) {
      context.missing(_hostMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sourceRef, host};
  @override
  StoredTlsException map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredTlsException(
      sourceRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_ref'],
      )!,
      host: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}host'],
      )!,
    );
  }

  @override
  $SourceTlsExceptionsTable createAlias(String alias) {
    return $SourceTlsExceptionsTable(attachedDatabase, alias);
  }
}

class StoredTlsException extends DataClass
    implements Insertable<StoredTlsException> {
  final String sourceRef;
  final String host;
  const StoredTlsException({required this.sourceRef, required this.host});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source_ref'] = Variable<String>(sourceRef);
    map['host'] = Variable<String>(host);
    return map;
  }

  SourceTlsExceptionsCompanion toCompanion(bool nullToAbsent) {
    return SourceTlsExceptionsCompanion(
      sourceRef: Value(sourceRef),
      host: Value(host),
    );
  }

  factory StoredTlsException.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredTlsException(
      sourceRef: serializer.fromJson<String>(json['sourceRef']),
      host: serializer.fromJson<String>(json['host']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sourceRef': serializer.toJson<String>(sourceRef),
      'host': serializer.toJson<String>(host),
    };
  }

  StoredTlsException copyWith({String? sourceRef, String? host}) =>
      StoredTlsException(
        sourceRef: sourceRef ?? this.sourceRef,
        host: host ?? this.host,
      );
  StoredTlsException copyWithCompanion(SourceTlsExceptionsCompanion data) {
    return StoredTlsException(
      sourceRef: data.sourceRef.present ? data.sourceRef.value : this.sourceRef,
      host: data.host.present ? data.host.value : this.host,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredTlsException(')
          ..write('sourceRef: $sourceRef, ')
          ..write('host: $host')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(sourceRef, host);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredTlsException &&
          other.sourceRef == this.sourceRef &&
          other.host == this.host);
}

class SourceTlsExceptionsCompanion extends UpdateCompanion<StoredTlsException> {
  final Value<String> sourceRef;
  final Value<String> host;
  final Value<int> rowid;
  const SourceTlsExceptionsCompanion({
    this.sourceRef = const Value.absent(),
    this.host = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SourceTlsExceptionsCompanion.insert({
    required String sourceRef,
    required String host,
    this.rowid = const Value.absent(),
  }) : sourceRef = Value(sourceRef),
       host = Value(host);
  static Insertable<StoredTlsException> custom({
    Expression<String>? sourceRef,
    Expression<String>? host,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sourceRef != null) 'source_ref': sourceRef,
      if (host != null) 'host': host,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SourceTlsExceptionsCompanion copyWith({
    Value<String>? sourceRef,
    Value<String>? host,
    Value<int>? rowid,
  }) {
    return SourceTlsExceptionsCompanion(
      sourceRef: sourceRef ?? this.sourceRef,
      host: host ?? this.host,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sourceRef.present) {
      map['source_ref'] = Variable<String>(sourceRef.value);
    }
    if (host.present) {
      map['host'] = Variable<String>(host.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SourceTlsExceptionsCompanion(')
          ..write('sourceRef: $sourceRef, ')
          ..write('host: $host, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$SpaceDatabase extends GeneratedDatabase {
  _$SpaceDatabase(QueryExecutor e) : super(e);
  $SpaceDatabaseManager get managers => $SpaceDatabaseManager(this);
  late final $SourcesTable sources = $SourcesTable(this);
  late final $BooksTable books = $BooksTable(this);
  late final $GroupsTable groups = $GroupsTable(this);
  late final $BookGroupsTable bookGroups = $BookGroupsTable(this);
  late final $ChaptersTable chapters = $ChaptersTable(this);
  late final $LocalRootsTable localRoots = $LocalRootsTable(this);
  late final $LocalFilesTable localFiles = $LocalFilesTable(this);
  late final $TextIndexTable textIndex = $TextIndexTable(this);
  late final $ProgressTable progress = $ProgressTable(this);
  late final $ReplaceRulesTable replaceRules = $ReplaceRulesTable(this);
  late final $SettingsTable settings = $SettingsTable(this);
  late final $SourceCookiesTable sourceCookies = $SourceCookiesTable(this);
  late final $SourceEntriesTable sourceEntries = $SourceEntriesTable(this);
  late final $SourceTlsExceptionsTable sourceTlsExceptions =
      $SourceTlsExceptionsTable(this);
  late final Index booksNaturalKey = Index(
    'books_natural_key',
    'CREATE UNIQUE INDEX books_natural_key ON books (source_ref, source_book_url)',
  );
  late final Index booksLocalKey = Index(
    'books_local_key',
    'CREATE UNIQUE INDEX books_local_key ON books (root_id, relative_path)',
  );
  late final Index booksShelfOrder = Index(
    'books_shelf_order',
    'CREATE INDEX books_shelf_order ON books (shelved, kind, book_order)',
  );
  late final Index groupsName = Index(
    'groups_name',
    'CREATE UNIQUE INDEX groups_name ON "groups" (name)',
  );
  late final Index bookGroupsGroup = Index(
    'book_groups_group',
    'CREATE INDEX book_groups_group ON book_groups (group_id, book_id)',
  );
  late final Index chaptersTocOrder = Index(
    'chapters_toc_order',
    'CREATE INDEX chapters_toc_order ON chapters (book_id, chapter_index)',
  );
  late final Index replaceRulesMergeKey = Index(
    'replace_rules_merge_key',
    'CREATE UNIQUE INDEX replace_rules_merge_key ON replace_rules (name, pattern, replacement)',
  );
  late final Index replaceRulesOrder = Index(
    'replace_rules_order',
    'CREATE INDEX replace_rules_order ON replace_rules (rule_order)',
  );
  late final Index localFilesBook = Index(
    'local_files_book',
    'CREATE INDEX local_files_book ON local_files (book_id)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    sources,
    books,
    groups,
    bookGroups,
    chapters,
    localRoots,
    localFiles,
    textIndex,
    progress,
    replaceRules,
    settings,
    sourceCookies,
    sourceEntries,
    sourceTlsExceptions,
    booksNaturalKey,
    booksLocalKey,
    booksShelfOrder,
    groupsName,
    bookGroupsGroup,
    chaptersTocOrder,
    replaceRulesMergeKey,
    replaceRulesOrder,
    localFilesBook,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'books',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('book_groups', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'groups',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('book_groups', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'books',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('chapters', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_roots',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('local_files', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'books',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('local_files', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'local_roots',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('text_index', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'books',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('progress', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$SourcesTableCreateCompanionBuilder =
    SourcesCompanion Function({
      required String bookSourceUrl,
      required String name,
      Value<String> groupNames,
      Value<int> type,
      Value<int> customOrder,
      Value<bool> enabled,
      Value<bool> enabledExplore,
      Value<int> lastUpdateTime,
      Value<String?> raw,
      Value<int> rowid,
    });
typedef $$SourcesTableUpdateCompanionBuilder =
    SourcesCompanion Function({
      Value<String> bookSourceUrl,
      Value<String> name,
      Value<String> groupNames,
      Value<int> type,
      Value<int> customOrder,
      Value<bool> enabled,
      Value<bool> enabledExplore,
      Value<int> lastUpdateTime,
      Value<String?> raw,
      Value<int> rowid,
    });

class $$SourcesTableFilterComposer
    extends Composer<_$SpaceDatabase, $SourcesTable> {
  $$SourcesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get bookSourceUrl => $composableBuilder(
    column: $table.bookSourceUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groupNames => $composableBuilder(
    column: $table.groupNames,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get customOrder => $composableBuilder(
    column: $table.customOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enabledExplore => $composableBuilder(
    column: $table.enabledExplore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastUpdateTime => $composableBuilder(
    column: $table.lastUpdateTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get raw => $composableBuilder(
    column: $table.raw,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SourcesTableOrderingComposer
    extends Composer<_$SpaceDatabase, $SourcesTable> {
  $$SourcesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get bookSourceUrl => $composableBuilder(
    column: $table.bookSourceUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groupNames => $composableBuilder(
    column: $table.groupNames,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get customOrder => $composableBuilder(
    column: $table.customOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enabledExplore => $composableBuilder(
    column: $table.enabledExplore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastUpdateTime => $composableBuilder(
    column: $table.lastUpdateTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get raw => $composableBuilder(
    column: $table.raw,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SourcesTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $SourcesTable> {
  $$SourcesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get bookSourceUrl => $composableBuilder(
    column: $table.bookSourceUrl,
    builder: (column) => column,
  );

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get groupNames => $composableBuilder(
    column: $table.groupNames,
    builder: (column) => column,
  );

  GeneratedColumn<int> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<int> get customOrder => $composableBuilder(
    column: $table.customOrder,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<bool> get enabledExplore => $composableBuilder(
    column: $table.enabledExplore,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastUpdateTime => $composableBuilder(
    column: $table.lastUpdateTime,
    builder: (column) => column,
  );

  GeneratedColumn<String> get raw =>
      $composableBuilder(column: $table.raw, builder: (column) => column);
}

class $$SourcesTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $SourcesTable,
          BookSource,
          $$SourcesTableFilterComposer,
          $$SourcesTableOrderingComposer,
          $$SourcesTableAnnotationComposer,
          $$SourcesTableCreateCompanionBuilder,
          $$SourcesTableUpdateCompanionBuilder,
          (
            BookSource,
            BaseReferences<_$SpaceDatabase, $SourcesTable, BookSource>,
          ),
          BookSource,
          PrefetchHooks Function()
        > {
  $$SourcesTableTableManager(_$SpaceDatabase db, $SourcesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SourcesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SourcesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SourcesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bookSourceUrl = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> groupNames = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<int> customOrder = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<bool> enabledExplore = const Value.absent(),
                Value<int> lastUpdateTime = const Value.absent(),
                Value<String?> raw = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SourcesCompanion(
                bookSourceUrl: bookSourceUrl,
                name: name,
                groupNames: groupNames,
                type: type,
                customOrder: customOrder,
                enabled: enabled,
                enabledExplore: enabledExplore,
                lastUpdateTime: lastUpdateTime,
                raw: raw,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String bookSourceUrl,
                required String name,
                Value<String> groupNames = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<int> customOrder = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<bool> enabledExplore = const Value.absent(),
                Value<int> lastUpdateTime = const Value.absent(),
                Value<String?> raw = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SourcesCompanion.insert(
                bookSourceUrl: bookSourceUrl,
                name: name,
                groupNames: groupNames,
                type: type,
                customOrder: customOrder,
                enabled: enabled,
                enabledExplore: enabledExplore,
                lastUpdateTime: lastUpdateTime,
                raw: raw,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SourcesTable, BookSource>(table),
                  BaseReferences<_$SpaceDatabase, $SourcesTable, BookSource>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SourcesTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $SourcesTable,
      BookSource,
      $$SourcesTableFilterComposer,
      $$SourcesTableOrderingComposer,
      $$SourcesTableAnnotationComposer,
      $$SourcesTableCreateCompanionBuilder,
      $$SourcesTableUpdateCompanionBuilder,
      (BookSource, BaseReferences<_$SpaceDatabase, $SourcesTable, BookSource>),
      BookSource,
      PrefetchHooks Function()
    >;
typedef $$BooksTableCreateCompanionBuilder =
    BooksCompanion Function({
      required String id,
      Value<String> kind,
      Value<String?> sourceRef,
      Value<String?> sourceBookUrl,
      required String title,
      Value<String> author,
      Value<String> originName,
      Value<int> type,
      Value<String> customTag,
      Value<String> coverUrl,
      Value<String> customCoverUrl,
      Value<String> intro,
      Value<String> customIntro,
      Value<String> charset,
      Value<String> latestChapterTitle,
      Value<int> latestChapterTime,
      Value<int> totalChapterNum,
      Value<bool> canUpdate,
      Value<int> lastCheckTime,
      Value<int> lastCheckCount,
      Value<int> bookOrder,
      Value<String?> variable,
      Value<bool> shelved,
      Value<String?> rootId,
      Value<String?> relativePath,
      Value<String?> format,
      Value<bool> needsRelink,
      Value<String?> raw,
      Value<int> rowid,
    });
typedef $$BooksTableUpdateCompanionBuilder =
    BooksCompanion Function({
      Value<String> id,
      Value<String> kind,
      Value<String?> sourceRef,
      Value<String?> sourceBookUrl,
      Value<String> title,
      Value<String> author,
      Value<String> originName,
      Value<int> type,
      Value<String> customTag,
      Value<String> coverUrl,
      Value<String> customCoverUrl,
      Value<String> intro,
      Value<String> customIntro,
      Value<String> charset,
      Value<String> latestChapterTitle,
      Value<int> latestChapterTime,
      Value<int> totalChapterNum,
      Value<bool> canUpdate,
      Value<int> lastCheckTime,
      Value<int> lastCheckCount,
      Value<int> bookOrder,
      Value<String?> variable,
      Value<bool> shelved,
      Value<String?> rootId,
      Value<String?> relativePath,
      Value<String?> format,
      Value<bool> needsRelink,
      Value<String?> raw,
      Value<int> rowid,
    });

final class $$BooksTableReferences
    extends BaseReferences<_$SpaceDatabase, $BooksTable, ShelfBook> {
  $$BooksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$BookGroupsTable, List<BookGroup>>
  _bookGroupsRefsTable(_$SpaceDatabase db) => MultiTypedResultKey.fromTable(
    db.bookGroups,
    aliasName: 'books__id__book_groups__book_id',
  );

  $$BookGroupsTableProcessedTableManager get bookGroupsRefs {
    final manager = $$BookGroupsTableTableManager(
      $_db,
      $_db.bookGroups,
    ).filter((f) => f.bookId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_bookGroupsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ChaptersTable, List<BookChapter>>
  _chaptersRefsTable(_$SpaceDatabase db) => MultiTypedResultKey.fromTable(
    db.chapters,
    aliasName: 'books__id__chapters__book_id',
  );

  $$ChaptersTableProcessedTableManager get chaptersRefs {
    final manager = $$ChaptersTableTableManager(
      $_db,
      $_db.chapters,
    ).filter((f) => f.bookId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_chaptersRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$LocalFilesTable, List<LocalFile>>
  _localFilesRefsTable(_$SpaceDatabase db) => MultiTypedResultKey.fromTable(
    db.localFiles,
    aliasName: 'books__id__local_files__book_id',
  );

  $$LocalFilesTableProcessedTableManager get localFilesRefs {
    final manager = $$LocalFilesTableTableManager(
      $_db,
      $_db.localFiles,
    ).filter((f) => f.bookId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_localFilesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ProgressTable, List<ReadingProgress>>
  _progressRefsTable(_$SpaceDatabase db) => MultiTypedResultKey.fromTable(
    db.progress,
    aliasName: 'books__id__progress__book_id',
  );

  $$ProgressTableProcessedTableManager get progressRefs {
    final manager = $$ProgressTableTableManager(
      $_db,
      $_db.progress,
    ).filter((f) => f.bookId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_progressRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$BooksTableFilterComposer
    extends Composer<_$SpaceDatabase, $BooksTable> {
  $$BooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceBookUrl => $composableBuilder(
    column: $table.sourceBookUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get author => $composableBuilder(
    column: $table.author,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get originName => $composableBuilder(
    column: $table.originName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customTag => $composableBuilder(
    column: $table.customTag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverUrl => $composableBuilder(
    column: $table.coverUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customCoverUrl => $composableBuilder(
    column: $table.customCoverUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get intro => $composableBuilder(
    column: $table.intro,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customIntro => $composableBuilder(
    column: $table.customIntro,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get charset => $composableBuilder(
    column: $table.charset,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get latestChapterTitle => $composableBuilder(
    column: $table.latestChapterTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get latestChapterTime => $composableBuilder(
    column: $table.latestChapterTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalChapterNum => $composableBuilder(
    column: $table.totalChapterNum,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get canUpdate => $composableBuilder(
    column: $table.canUpdate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastCheckTime => $composableBuilder(
    column: $table.lastCheckTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastCheckCount => $composableBuilder(
    column: $table.lastCheckCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bookOrder => $composableBuilder(
    column: $table.bookOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get variable => $composableBuilder(
    column: $table.variable,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get shelved => $composableBuilder(
    column: $table.shelved,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rootId => $composableBuilder(
    column: $table.rootId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get needsRelink => $composableBuilder(
    column: $table.needsRelink,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get raw => $composableBuilder(
    column: $table.raw,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> bookGroupsRefs(
    Expression<bool> Function($$BookGroupsTableFilterComposer f) f,
  ) {
    final $$BookGroupsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.bookGroups,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BookGroupsTableFilterComposer(
            $db: $db,
            $table: $db.bookGroups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> chaptersRefs(
    Expression<bool> Function($$ChaptersTableFilterComposer f) f,
  ) {
    final $$ChaptersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.chapters,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ChaptersTableFilterComposer(
            $db: $db,
            $table: $db.chapters,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> localFilesRefs(
    Expression<bool> Function($$LocalFilesTableFilterComposer f) f,
  ) {
    final $$LocalFilesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.localFiles,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalFilesTableFilterComposer(
            $db: $db,
            $table: $db.localFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> progressRefs(
    Expression<bool> Function($$ProgressTableFilterComposer f) f,
  ) {
    final $$ProgressTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.progress,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProgressTableFilterComposer(
            $db: $db,
            $table: $db.progress,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BooksTableOrderingComposer
    extends Composer<_$SpaceDatabase, $BooksTable> {
  $$BooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceBookUrl => $composableBuilder(
    column: $table.sourceBookUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get author => $composableBuilder(
    column: $table.author,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get originName => $composableBuilder(
    column: $table.originName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customTag => $composableBuilder(
    column: $table.customTag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverUrl => $composableBuilder(
    column: $table.coverUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customCoverUrl => $composableBuilder(
    column: $table.customCoverUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get intro => $composableBuilder(
    column: $table.intro,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customIntro => $composableBuilder(
    column: $table.customIntro,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get charset => $composableBuilder(
    column: $table.charset,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get latestChapterTitle => $composableBuilder(
    column: $table.latestChapterTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get latestChapterTime => $composableBuilder(
    column: $table.latestChapterTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalChapterNum => $composableBuilder(
    column: $table.totalChapterNum,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get canUpdate => $composableBuilder(
    column: $table.canUpdate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastCheckTime => $composableBuilder(
    column: $table.lastCheckTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastCheckCount => $composableBuilder(
    column: $table.lastCheckCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bookOrder => $composableBuilder(
    column: $table.bookOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get variable => $composableBuilder(
    column: $table.variable,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get shelved => $composableBuilder(
    column: $table.shelved,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rootId => $composableBuilder(
    column: $table.rootId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get needsRelink => $composableBuilder(
    column: $table.needsRelink,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get raw => $composableBuilder(
    column: $table.raw,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BooksTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $BooksTable> {
  $$BooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get sourceRef =>
      $composableBuilder(column: $table.sourceRef, builder: (column) => column);

  GeneratedColumn<String> get sourceBookUrl => $composableBuilder(
    column: $table.sourceBookUrl,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get author =>
      $composableBuilder(column: $table.author, builder: (column) => column);

  GeneratedColumn<String> get originName => $composableBuilder(
    column: $table.originName,
    builder: (column) => column,
  );

  GeneratedColumn<int> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get customTag =>
      $composableBuilder(column: $table.customTag, builder: (column) => column);

  GeneratedColumn<String> get coverUrl =>
      $composableBuilder(column: $table.coverUrl, builder: (column) => column);

  GeneratedColumn<String> get customCoverUrl => $composableBuilder(
    column: $table.customCoverUrl,
    builder: (column) => column,
  );

  GeneratedColumn<String> get intro =>
      $composableBuilder(column: $table.intro, builder: (column) => column);

  GeneratedColumn<String> get customIntro => $composableBuilder(
    column: $table.customIntro,
    builder: (column) => column,
  );

  GeneratedColumn<String> get charset =>
      $composableBuilder(column: $table.charset, builder: (column) => column);

  GeneratedColumn<String> get latestChapterTitle => $composableBuilder(
    column: $table.latestChapterTitle,
    builder: (column) => column,
  );

  GeneratedColumn<int> get latestChapterTime => $composableBuilder(
    column: $table.latestChapterTime,
    builder: (column) => column,
  );

  GeneratedColumn<int> get totalChapterNum => $composableBuilder(
    column: $table.totalChapterNum,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get canUpdate =>
      $composableBuilder(column: $table.canUpdate, builder: (column) => column);

  GeneratedColumn<int> get lastCheckTime => $composableBuilder(
    column: $table.lastCheckTime,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastCheckCount => $composableBuilder(
    column: $table.lastCheckCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get bookOrder =>
      $composableBuilder(column: $table.bookOrder, builder: (column) => column);

  GeneratedColumn<String> get variable =>
      $composableBuilder(column: $table.variable, builder: (column) => column);

  GeneratedColumn<bool> get shelved =>
      $composableBuilder(column: $table.shelved, builder: (column) => column);

  GeneratedColumn<String> get rootId =>
      $composableBuilder(column: $table.rootId, builder: (column) => column);

  GeneratedColumn<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get format =>
      $composableBuilder(column: $table.format, builder: (column) => column);

  GeneratedColumn<bool> get needsRelink => $composableBuilder(
    column: $table.needsRelink,
    builder: (column) => column,
  );

  GeneratedColumn<String> get raw =>
      $composableBuilder(column: $table.raw, builder: (column) => column);

  Expression<T> bookGroupsRefs<T extends Object>(
    Expression<T> Function($$BookGroupsTableAnnotationComposer a) f,
  ) {
    final $$BookGroupsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.bookGroups,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BookGroupsTableAnnotationComposer(
            $db: $db,
            $table: $db.bookGroups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> chaptersRefs<T extends Object>(
    Expression<T> Function($$ChaptersTableAnnotationComposer a) f,
  ) {
    final $$ChaptersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.chapters,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ChaptersTableAnnotationComposer(
            $db: $db,
            $table: $db.chapters,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> localFilesRefs<T extends Object>(
    Expression<T> Function($$LocalFilesTableAnnotationComposer a) f,
  ) {
    final $$LocalFilesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.localFiles,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalFilesTableAnnotationComposer(
            $db: $db,
            $table: $db.localFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> progressRefs<T extends Object>(
    Expression<T> Function($$ProgressTableAnnotationComposer a) f,
  ) {
    final $$ProgressTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.progress,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProgressTableAnnotationComposer(
            $db: $db,
            $table: $db.progress,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BooksTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $BooksTable,
          ShelfBook,
          $$BooksTableFilterComposer,
          $$BooksTableOrderingComposer,
          $$BooksTableAnnotationComposer,
          $$BooksTableCreateCompanionBuilder,
          $$BooksTableUpdateCompanionBuilder,
          (ShelfBook, $$BooksTableReferences),
          ShelfBook,
          PrefetchHooks Function({
            bool bookGroupsRefs,
            bool chaptersRefs,
            bool localFilesRefs,
            bool progressRefs,
          })
        > {
  $$BooksTableTableManager(_$SpaceDatabase db, $BooksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String?> sourceRef = const Value.absent(),
                Value<String?> sourceBookUrl = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> author = const Value.absent(),
                Value<String> originName = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<String> customTag = const Value.absent(),
                Value<String> coverUrl = const Value.absent(),
                Value<String> customCoverUrl = const Value.absent(),
                Value<String> intro = const Value.absent(),
                Value<String> customIntro = const Value.absent(),
                Value<String> charset = const Value.absent(),
                Value<String> latestChapterTitle = const Value.absent(),
                Value<int> latestChapterTime = const Value.absent(),
                Value<int> totalChapterNum = const Value.absent(),
                Value<bool> canUpdate = const Value.absent(),
                Value<int> lastCheckTime = const Value.absent(),
                Value<int> lastCheckCount = const Value.absent(),
                Value<int> bookOrder = const Value.absent(),
                Value<String?> variable = const Value.absent(),
                Value<bool> shelved = const Value.absent(),
                Value<String?> rootId = const Value.absent(),
                Value<String?> relativePath = const Value.absent(),
                Value<String?> format = const Value.absent(),
                Value<bool> needsRelink = const Value.absent(),
                Value<String?> raw = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BooksCompanion(
                id: id,
                kind: kind,
                sourceRef: sourceRef,
                sourceBookUrl: sourceBookUrl,
                title: title,
                author: author,
                originName: originName,
                type: type,
                customTag: customTag,
                coverUrl: coverUrl,
                customCoverUrl: customCoverUrl,
                intro: intro,
                customIntro: customIntro,
                charset: charset,
                latestChapterTitle: latestChapterTitle,
                latestChapterTime: latestChapterTime,
                totalChapterNum: totalChapterNum,
                canUpdate: canUpdate,
                lastCheckTime: lastCheckTime,
                lastCheckCount: lastCheckCount,
                bookOrder: bookOrder,
                variable: variable,
                shelved: shelved,
                rootId: rootId,
                relativePath: relativePath,
                format: format,
                needsRelink: needsRelink,
                raw: raw,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String> kind = const Value.absent(),
                Value<String?> sourceRef = const Value.absent(),
                Value<String?> sourceBookUrl = const Value.absent(),
                required String title,
                Value<String> author = const Value.absent(),
                Value<String> originName = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<String> customTag = const Value.absent(),
                Value<String> coverUrl = const Value.absent(),
                Value<String> customCoverUrl = const Value.absent(),
                Value<String> intro = const Value.absent(),
                Value<String> customIntro = const Value.absent(),
                Value<String> charset = const Value.absent(),
                Value<String> latestChapterTitle = const Value.absent(),
                Value<int> latestChapterTime = const Value.absent(),
                Value<int> totalChapterNum = const Value.absent(),
                Value<bool> canUpdate = const Value.absent(),
                Value<int> lastCheckTime = const Value.absent(),
                Value<int> lastCheckCount = const Value.absent(),
                Value<int> bookOrder = const Value.absent(),
                Value<String?> variable = const Value.absent(),
                Value<bool> shelved = const Value.absent(),
                Value<String?> rootId = const Value.absent(),
                Value<String?> relativePath = const Value.absent(),
                Value<String?> format = const Value.absent(),
                Value<bool> needsRelink = const Value.absent(),
                Value<String?> raw = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BooksCompanion.insert(
                id: id,
                kind: kind,
                sourceRef: sourceRef,
                sourceBookUrl: sourceBookUrl,
                title: title,
                author: author,
                originName: originName,
                type: type,
                customTag: customTag,
                coverUrl: coverUrl,
                customCoverUrl: customCoverUrl,
                intro: intro,
                customIntro: customIntro,
                charset: charset,
                latestChapterTitle: latestChapterTitle,
                latestChapterTime: latestChapterTime,
                totalChapterNum: totalChapterNum,
                canUpdate: canUpdate,
                lastCheckTime: lastCheckTime,
                lastCheckCount: lastCheckCount,
                bookOrder: bookOrder,
                variable: variable,
                shelved: shelved,
                rootId: rootId,
                relativePath: relativePath,
                format: format,
                needsRelink: needsRelink,
                raw: raw,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BooksTable, ShelfBook>(table),
                  $$BooksTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                bookGroupsRefs = false,
                chaptersRefs = false,
                localFilesRefs = false,
                progressRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (bookGroupsRefs) db.bookGroups,
                    if (chaptersRefs) db.chapters,
                    if (localFilesRefs) db.localFiles,
                    if (progressRefs) db.progress,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (bookGroupsRefs)
                        await $_getPrefetchedData<
                          ShelfBook,
                          $BooksTable,
                          BookGroup
                        >(
                          currentTable: table,
                          referencedTable: $$BooksTableReferences
                              ._bookGroupsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$BooksTableReferences(
                                db,
                                table,
                                p0,
                              ).bookGroupsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.bookId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (chaptersRefs)
                        await $_getPrefetchedData<
                          ShelfBook,
                          $BooksTable,
                          BookChapter
                        >(
                          currentTable: table,
                          referencedTable: $$BooksTableReferences
                              ._chaptersRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$BooksTableReferences(
                                db,
                                table,
                                p0,
                              ).chaptersRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.bookId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (localFilesRefs)
                        await $_getPrefetchedData<
                          ShelfBook,
                          $BooksTable,
                          LocalFile
                        >(
                          currentTable: table,
                          referencedTable: $$BooksTableReferences
                              ._localFilesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$BooksTableReferences(
                                db,
                                table,
                                p0,
                              ).localFilesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.bookId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (progressRefs)
                        await $_getPrefetchedData<
                          ShelfBook,
                          $BooksTable,
                          ReadingProgress
                        >(
                          currentTable: table,
                          referencedTable: $$BooksTableReferences
                              ._progressRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$BooksTableReferences(
                                db,
                                table,
                                p0,
                              ).progressRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.bookId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$BooksTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $BooksTable,
      ShelfBook,
      $$BooksTableFilterComposer,
      $$BooksTableOrderingComposer,
      $$BooksTableAnnotationComposer,
      $$BooksTableCreateCompanionBuilder,
      $$BooksTableUpdateCompanionBuilder,
      (ShelfBook, $$BooksTableReferences),
      ShelfBook,
      PrefetchHooks Function({
        bool bookGroupsRefs,
        bool chaptersRefs,
        bool localFilesRefs,
        bool progressRefs,
      })
    >;
typedef $$GroupsTableCreateCompanionBuilder =
    GroupsCompanion Function({
      required String id,
      required String name,
      Value<String> cover,
      Value<int> groupOrder,
      Value<bool> enableRefresh,
      Value<bool> show,
      Value<int> bookSort,
      Value<int> rowid,
    });
typedef $$GroupsTableUpdateCompanionBuilder =
    GroupsCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> cover,
      Value<int> groupOrder,
      Value<bool> enableRefresh,
      Value<bool> show,
      Value<int> bookSort,
      Value<int> rowid,
    });

final class $$GroupsTableReferences
    extends BaseReferences<_$SpaceDatabase, $GroupsTable, ShelfGroup> {
  $$GroupsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$BookGroupsTable, List<BookGroup>>
  _bookGroupsRefsTable(_$SpaceDatabase db) => MultiTypedResultKey.fromTable(
    db.bookGroups,
    aliasName: 'groups__id__book_groups__group_id',
  );

  $$BookGroupsTableProcessedTableManager get bookGroupsRefs {
    final manager = $$BookGroupsTableTableManager(
      $_db,
      $_db.bookGroups,
    ).filter((f) => f.groupId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_bookGroupsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$GroupsTableFilterComposer
    extends Composer<_$SpaceDatabase, $GroupsTable> {
  $$GroupsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cover => $composableBuilder(
    column: $table.cover,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get groupOrder => $composableBuilder(
    column: $table.groupOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enableRefresh => $composableBuilder(
    column: $table.enableRefresh,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get show => $composableBuilder(
    column: $table.show,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bookSort => $composableBuilder(
    column: $table.bookSort,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> bookGroupsRefs(
    Expression<bool> Function($$BookGroupsTableFilterComposer f) f,
  ) {
    final $$BookGroupsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.bookGroups,
      getReferencedColumn: (t) => t.groupId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BookGroupsTableFilterComposer(
            $db: $db,
            $table: $db.bookGroups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$GroupsTableOrderingComposer
    extends Composer<_$SpaceDatabase, $GroupsTable> {
  $$GroupsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cover => $composableBuilder(
    column: $table.cover,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get groupOrder => $composableBuilder(
    column: $table.groupOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enableRefresh => $composableBuilder(
    column: $table.enableRefresh,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get show => $composableBuilder(
    column: $table.show,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bookSort => $composableBuilder(
    column: $table.bookSort,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$GroupsTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $GroupsTable> {
  $$GroupsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get cover =>
      $composableBuilder(column: $table.cover, builder: (column) => column);

  GeneratedColumn<int> get groupOrder => $composableBuilder(
    column: $table.groupOrder,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get enableRefresh => $composableBuilder(
    column: $table.enableRefresh,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get show =>
      $composableBuilder(column: $table.show, builder: (column) => column);

  GeneratedColumn<int> get bookSort =>
      $composableBuilder(column: $table.bookSort, builder: (column) => column);

  Expression<T> bookGroupsRefs<T extends Object>(
    Expression<T> Function($$BookGroupsTableAnnotationComposer a) f,
  ) {
    final $$BookGroupsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.bookGroups,
      getReferencedColumn: (t) => t.groupId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BookGroupsTableAnnotationComposer(
            $db: $db,
            $table: $db.bookGroups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$GroupsTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $GroupsTable,
          ShelfGroup,
          $$GroupsTableFilterComposer,
          $$GroupsTableOrderingComposer,
          $$GroupsTableAnnotationComposer,
          $$GroupsTableCreateCompanionBuilder,
          $$GroupsTableUpdateCompanionBuilder,
          (ShelfGroup, $$GroupsTableReferences),
          ShelfGroup,
          PrefetchHooks Function({bool bookGroupsRefs})
        > {
  $$GroupsTableTableManager(_$SpaceDatabase db, $GroupsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GroupsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GroupsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GroupsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> cover = const Value.absent(),
                Value<int> groupOrder = const Value.absent(),
                Value<bool> enableRefresh = const Value.absent(),
                Value<bool> show = const Value.absent(),
                Value<int> bookSort = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GroupsCompanion(
                id: id,
                name: name,
                cover: cover,
                groupOrder: groupOrder,
                enableRefresh: enableRefresh,
                show: show,
                bookSort: bookSort,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<String> cover = const Value.absent(),
                Value<int> groupOrder = const Value.absent(),
                Value<bool> enableRefresh = const Value.absent(),
                Value<bool> show = const Value.absent(),
                Value<int> bookSort = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GroupsCompanion.insert(
                id: id,
                name: name,
                cover: cover,
                groupOrder: groupOrder,
                enableRefresh: enableRefresh,
                show: show,
                bookSort: bookSort,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$GroupsTable, ShelfGroup>(table),
                  $$GroupsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({bookGroupsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (bookGroupsRefs) db.bookGroups],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (bookGroupsRefs)
                    await $_getPrefetchedData<
                      ShelfGroup,
                      $GroupsTable,
                      BookGroup
                    >(
                      currentTable: table,
                      referencedTable: $$GroupsTableReferences
                          ._bookGroupsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$GroupsTableReferences(db, table, p0).bookGroupsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.groupId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$GroupsTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $GroupsTable,
      ShelfGroup,
      $$GroupsTableFilterComposer,
      $$GroupsTableOrderingComposer,
      $$GroupsTableAnnotationComposer,
      $$GroupsTableCreateCompanionBuilder,
      $$GroupsTableUpdateCompanionBuilder,
      (ShelfGroup, $$GroupsTableReferences),
      ShelfGroup,
      PrefetchHooks Function({bool bookGroupsRefs})
    >;
typedef $$BookGroupsTableCreateCompanionBuilder =
    BookGroupsCompanion Function({
      required String bookId,
      required String groupId,
      Value<int> rowid,
    });
typedef $$BookGroupsTableUpdateCompanionBuilder =
    BookGroupsCompanion Function({
      Value<String> bookId,
      Value<String> groupId,
      Value<int> rowid,
    });

final class $$BookGroupsTableReferences
    extends BaseReferences<_$SpaceDatabase, $BookGroupsTable, BookGroup> {
  $$BookGroupsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $BooksTable _bookIdTable(_$SpaceDatabase db) =>
      db.books.createAlias('book_groups__book_id__books__id');

  $$BooksTableProcessedTableManager get bookId {
    final $_column = $_itemColumn<String>('book_id')!;

    final manager = $$BooksTableTableManager(
      $_db,
      $_db.books,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_bookIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $GroupsTable _groupIdTable(_$SpaceDatabase db) =>
      db.groups.createAlias('book_groups__group_id__groups__id');

  $$GroupsTableProcessedTableManager get groupId {
    final $_column = $_itemColumn<String>('group_id')!;

    final manager = $$GroupsTableTableManager(
      $_db,
      $_db.groups,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_groupIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$BookGroupsTableFilterComposer
    extends Composer<_$SpaceDatabase, $BookGroupsTable> {
  $$BookGroupsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  $$BooksTableFilterComposer get bookId {
    final $$BooksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableFilterComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$GroupsTableFilterComposer get groupId {
    final $$GroupsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.groupId,
      referencedTable: $db.groups,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupsTableFilterComposer(
            $db: $db,
            $table: $db.groups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$BookGroupsTableOrderingComposer
    extends Composer<_$SpaceDatabase, $BookGroupsTable> {
  $$BookGroupsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  $$BooksTableOrderingComposer get bookId {
    final $$BooksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableOrderingComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$GroupsTableOrderingComposer get groupId {
    final $$GroupsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.groupId,
      referencedTable: $db.groups,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupsTableOrderingComposer(
            $db: $db,
            $table: $db.groups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$BookGroupsTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $BookGroupsTable> {
  $$BookGroupsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  $$BooksTableAnnotationComposer get bookId {
    final $$BooksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableAnnotationComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$GroupsTableAnnotationComposer get groupId {
    final $$GroupsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.groupId,
      referencedTable: $db.groups,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupsTableAnnotationComposer(
            $db: $db,
            $table: $db.groups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$BookGroupsTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $BookGroupsTable,
          BookGroup,
          $$BookGroupsTableFilterComposer,
          $$BookGroupsTableOrderingComposer,
          $$BookGroupsTableAnnotationComposer,
          $$BookGroupsTableCreateCompanionBuilder,
          $$BookGroupsTableUpdateCompanionBuilder,
          (BookGroup, $$BookGroupsTableReferences),
          BookGroup,
          PrefetchHooks Function({bool bookId, bool groupId})
        > {
  $$BookGroupsTableTableManager(_$SpaceDatabase db, $BookGroupsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BookGroupsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BookGroupsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BookGroupsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bookId = const Value.absent(),
                Value<String> groupId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BookGroupsCompanion(
                bookId: bookId,
                groupId: groupId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String bookId,
                required String groupId,
                Value<int> rowid = const Value.absent(),
              }) => BookGroupsCompanion.insert(
                bookId: bookId,
                groupId: groupId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BookGroupsTable, BookGroup>(table),
                  $$BookGroupsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({bookId = false, groupId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (bookId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.bookId,
                                referencedTable: $$BookGroupsTableReferences
                                    ._bookIdTable(db),
                                referencedColumn: $$BookGroupsTableReferences
                                    ._bookIdTable(db)
                                    .id,
                              )
                              as T;
                    }
                    if (groupId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.groupId,
                                referencedTable: $$BookGroupsTableReferences
                                    ._groupIdTable(db),
                                referencedColumn: $$BookGroupsTableReferences
                                    ._groupIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$BookGroupsTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $BookGroupsTable,
      BookGroup,
      $$BookGroupsTableFilterComposer,
      $$BookGroupsTableOrderingComposer,
      $$BookGroupsTableAnnotationComposer,
      $$BookGroupsTableCreateCompanionBuilder,
      $$BookGroupsTableUpdateCompanionBuilder,
      (BookGroup, $$BookGroupsTableReferences),
      BookGroup,
      PrefetchHooks Function({bool bookId, bool groupId})
    >;
typedef $$ChaptersTableCreateCompanionBuilder =
    ChaptersCompanion Function({
      required String bookId,
      required String chapterKey,
      required String name,
      Value<String?> url,
      required int chapterIndex,
      Value<String?> variable,
      Value<int> rowid,
    });
typedef $$ChaptersTableUpdateCompanionBuilder =
    ChaptersCompanion Function({
      Value<String> bookId,
      Value<String> chapterKey,
      Value<String> name,
      Value<String?> url,
      Value<int> chapterIndex,
      Value<String?> variable,
      Value<int> rowid,
    });

final class $$ChaptersTableReferences
    extends BaseReferences<_$SpaceDatabase, $ChaptersTable, BookChapter> {
  $$ChaptersTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $BooksTable _bookIdTable(_$SpaceDatabase db) =>
      db.books.createAlias('chapters__book_id__books__id');

  $$BooksTableProcessedTableManager get bookId {
    final $_column = $_itemColumn<String>('book_id')!;

    final manager = $$BooksTableTableManager(
      $_db,
      $_db.books,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_bookIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ChaptersTableFilterComposer
    extends Composer<_$SpaceDatabase, $ChaptersTable> {
  $$ChaptersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get chapterKey => $composableBuilder(
    column: $table.chapterKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get chapterIndex => $composableBuilder(
    column: $table.chapterIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get variable => $composableBuilder(
    column: $table.variable,
    builder: (column) => ColumnFilters(column),
  );

  $$BooksTableFilterComposer get bookId {
    final $$BooksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableFilterComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ChaptersTableOrderingComposer
    extends Composer<_$SpaceDatabase, $ChaptersTable> {
  $$ChaptersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get chapterKey => $composableBuilder(
    column: $table.chapterKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get chapterIndex => $composableBuilder(
    column: $table.chapterIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get variable => $composableBuilder(
    column: $table.variable,
    builder: (column) => ColumnOrderings(column),
  );

  $$BooksTableOrderingComposer get bookId {
    final $$BooksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableOrderingComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ChaptersTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $ChaptersTable> {
  $$ChaptersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get chapterKey => $composableBuilder(
    column: $table.chapterKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get url =>
      $composableBuilder(column: $table.url, builder: (column) => column);

  GeneratedColumn<int> get chapterIndex => $composableBuilder(
    column: $table.chapterIndex,
    builder: (column) => column,
  );

  GeneratedColumn<String> get variable =>
      $composableBuilder(column: $table.variable, builder: (column) => column);

  $$BooksTableAnnotationComposer get bookId {
    final $$BooksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableAnnotationComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ChaptersTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $ChaptersTable,
          BookChapter,
          $$ChaptersTableFilterComposer,
          $$ChaptersTableOrderingComposer,
          $$ChaptersTableAnnotationComposer,
          $$ChaptersTableCreateCompanionBuilder,
          $$ChaptersTableUpdateCompanionBuilder,
          (BookChapter, $$ChaptersTableReferences),
          BookChapter,
          PrefetchHooks Function({bool bookId})
        > {
  $$ChaptersTableTableManager(_$SpaceDatabase db, $ChaptersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChaptersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChaptersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChaptersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bookId = const Value.absent(),
                Value<String> chapterKey = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> url = const Value.absent(),
                Value<int> chapterIndex = const Value.absent(),
                Value<String?> variable = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChaptersCompanion(
                bookId: bookId,
                chapterKey: chapterKey,
                name: name,
                url: url,
                chapterIndex: chapterIndex,
                variable: variable,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String bookId,
                required String chapterKey,
                required String name,
                Value<String?> url = const Value.absent(),
                required int chapterIndex,
                Value<String?> variable = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChaptersCompanion.insert(
                bookId: bookId,
                chapterKey: chapterKey,
                name: name,
                url: url,
                chapterIndex: chapterIndex,
                variable: variable,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ChaptersTable, BookChapter>(table),
                  $$ChaptersTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({bookId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (bookId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.bookId,
                                referencedTable: $$ChaptersTableReferences
                                    ._bookIdTable(db),
                                referencedColumn: $$ChaptersTableReferences
                                    ._bookIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ChaptersTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $ChaptersTable,
      BookChapter,
      $$ChaptersTableFilterComposer,
      $$ChaptersTableOrderingComposer,
      $$ChaptersTableAnnotationComposer,
      $$ChaptersTableCreateCompanionBuilder,
      $$ChaptersTableUpdateCompanionBuilder,
      (BookChapter, $$ChaptersTableReferences),
      BookChapter,
      PrefetchHooks Function({bool bookId})
    >;
typedef $$LocalRootsTableCreateCompanionBuilder =
    LocalRootsCompanion Function({
      required String id,
      required String displayName,
      Value<bool> needsRelink,
      Value<int> rowid,
    });
typedef $$LocalRootsTableUpdateCompanionBuilder =
    LocalRootsCompanion Function({
      Value<String> id,
      Value<String> displayName,
      Value<bool> needsRelink,
      Value<int> rowid,
    });

final class $$LocalRootsTableReferences
    extends BaseReferences<_$SpaceDatabase, $LocalRootsTable, LocalRoot> {
  $$LocalRootsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$LocalFilesTable, List<LocalFile>>
  _localFilesRefsTable(_$SpaceDatabase db) => MultiTypedResultKey.fromTable(
    db.localFiles,
    aliasName: 'local_roots__id__local_files__root_id',
  );

  $$LocalFilesTableProcessedTableManager get localFilesRefs {
    final manager = $$LocalFilesTableTableManager(
      $_db,
      $_db.localFiles,
    ).filter((f) => f.rootId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_localFilesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$TextIndexTable, List<TextIndexEntry>>
  _textIndexRefsTable(_$SpaceDatabase db) => MultiTypedResultKey.fromTable(
    db.textIndex,
    aliasName: 'local_roots__id__text_index__root_id',
  );

  $$TextIndexTableProcessedTableManager get textIndexRefs {
    final manager = $$TextIndexTableTableManager(
      $_db,
      $_db.textIndex,
    ).filter((f) => f.rootId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_textIndexRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$LocalRootsTableFilterComposer
    extends Composer<_$SpaceDatabase, $LocalRootsTable> {
  $$LocalRootsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get needsRelink => $composableBuilder(
    column: $table.needsRelink,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> localFilesRefs(
    Expression<bool> Function($$LocalFilesTableFilterComposer f) f,
  ) {
    final $$LocalFilesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.localFiles,
      getReferencedColumn: (t) => t.rootId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalFilesTableFilterComposer(
            $db: $db,
            $table: $db.localFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> textIndexRefs(
    Expression<bool> Function($$TextIndexTableFilterComposer f) f,
  ) {
    final $$TextIndexTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.textIndex,
      getReferencedColumn: (t) => t.rootId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TextIndexTableFilterComposer(
            $db: $db,
            $table: $db.textIndex,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LocalRootsTableOrderingComposer
    extends Composer<_$SpaceDatabase, $LocalRootsTable> {
  $$LocalRootsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get needsRelink => $composableBuilder(
    column: $table.needsRelink,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalRootsTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $LocalRootsTable> {
  $$LocalRootsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get needsRelink => $composableBuilder(
    column: $table.needsRelink,
    builder: (column) => column,
  );

  Expression<T> localFilesRefs<T extends Object>(
    Expression<T> Function($$LocalFilesTableAnnotationComposer a) f,
  ) {
    final $$LocalFilesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.localFiles,
      getReferencedColumn: (t) => t.rootId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalFilesTableAnnotationComposer(
            $db: $db,
            $table: $db.localFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> textIndexRefs<T extends Object>(
    Expression<T> Function($$TextIndexTableAnnotationComposer a) f,
  ) {
    final $$TextIndexTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.textIndex,
      getReferencedColumn: (t) => t.rootId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TextIndexTableAnnotationComposer(
            $db: $db,
            $table: $db.textIndex,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LocalRootsTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $LocalRootsTable,
          LocalRoot,
          $$LocalRootsTableFilterComposer,
          $$LocalRootsTableOrderingComposer,
          $$LocalRootsTableAnnotationComposer,
          $$LocalRootsTableCreateCompanionBuilder,
          $$LocalRootsTableUpdateCompanionBuilder,
          (LocalRoot, $$LocalRootsTableReferences),
          LocalRoot,
          PrefetchHooks Function({bool localFilesRefs, bool textIndexRefs})
        > {
  $$LocalRootsTableTableManager(_$SpaceDatabase db, $LocalRootsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalRootsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalRootsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalRootsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<bool> needsRelink = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalRootsCompanion(
                id: id,
                displayName: displayName,
                needsRelink: needsRelink,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String displayName,
                Value<bool> needsRelink = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalRootsCompanion.insert(
                id: id,
                displayName: displayName,
                needsRelink: needsRelink,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalRootsTable, LocalRoot>(table),
                  $$LocalRootsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({localFilesRefs = false, textIndexRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (localFilesRefs) db.localFiles,
                    if (textIndexRefs) db.textIndex,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (localFilesRefs)
                        await $_getPrefetchedData<
                          LocalRoot,
                          $LocalRootsTable,
                          LocalFile
                        >(
                          currentTable: table,
                          referencedTable: $$LocalRootsTableReferences
                              ._localFilesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalRootsTableReferences(
                                db,
                                table,
                                p0,
                              ).localFilesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.rootId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (textIndexRefs)
                        await $_getPrefetchedData<
                          LocalRoot,
                          $LocalRootsTable,
                          TextIndexEntry
                        >(
                          currentTable: table,
                          referencedTable: $$LocalRootsTableReferences
                              ._textIndexRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalRootsTableReferences(
                                db,
                                table,
                                p0,
                              ).textIndexRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.rootId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$LocalRootsTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $LocalRootsTable,
      LocalRoot,
      $$LocalRootsTableFilterComposer,
      $$LocalRootsTableOrderingComposer,
      $$LocalRootsTableAnnotationComposer,
      $$LocalRootsTableCreateCompanionBuilder,
      $$LocalRootsTableUpdateCompanionBuilder,
      (LocalRoot, $$LocalRootsTableReferences),
      LocalRoot,
      PrefetchHooks Function({bool localFilesRefs, bool textIndexRefs})
    >;
typedef $$LocalFilesTableCreateCompanionBuilder =
    LocalFilesCompanion Function({
      required String rootId,
      required String relativePath,
      Value<String> format,
      Value<int?> textLength,
      Value<int?> modifiedAt,
      Value<bool> needsRelink,
      Value<String?> bookId,
      Value<int> rowid,
    });
typedef $$LocalFilesTableUpdateCompanionBuilder =
    LocalFilesCompanion Function({
      Value<String> rootId,
      Value<String> relativePath,
      Value<String> format,
      Value<int?> textLength,
      Value<int?> modifiedAt,
      Value<bool> needsRelink,
      Value<String?> bookId,
      Value<int> rowid,
    });

final class $$LocalFilesTableReferences
    extends BaseReferences<_$SpaceDatabase, $LocalFilesTable, LocalFile> {
  $$LocalFilesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalRootsTable _rootIdTable(_$SpaceDatabase db) =>
      db.localRoots.createAlias('local_files__root_id__local_roots__id');

  $$LocalRootsTableProcessedTableManager get rootId {
    final $_column = $_itemColumn<String>('root_id')!;

    final manager = $$LocalRootsTableTableManager(
      $_db,
      $_db.localRoots,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_rootIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $BooksTable _bookIdTable(_$SpaceDatabase db) =>
      db.books.createAlias('local_files__book_id__books__id');

  $$BooksTableProcessedTableManager? get bookId {
    final $_column = $_itemColumn<String>('book_id');
    if ($_column == null) return null;
    final manager = $$BooksTableTableManager(
      $_db,
      $_db.books,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_bookIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LocalFilesTableFilterComposer
    extends Composer<_$SpaceDatabase, $LocalFilesTable> {
  $$LocalFilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get textLength => $composableBuilder(
    column: $table.textLength,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get modifiedAt => $composableBuilder(
    column: $table.modifiedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get needsRelink => $composableBuilder(
    column: $table.needsRelink,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalRootsTableFilterComposer get rootId {
    final $$LocalRootsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rootId,
      referencedTable: $db.localRoots,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalRootsTableFilterComposer(
            $db: $db,
            $table: $db.localRoots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$BooksTableFilterComposer get bookId {
    final $$BooksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableFilterComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LocalFilesTableOrderingComposer
    extends Composer<_$SpaceDatabase, $LocalFilesTable> {
  $$LocalFilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get textLength => $composableBuilder(
    column: $table.textLength,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get modifiedAt => $composableBuilder(
    column: $table.modifiedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get needsRelink => $composableBuilder(
    column: $table.needsRelink,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalRootsTableOrderingComposer get rootId {
    final $$LocalRootsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rootId,
      referencedTable: $db.localRoots,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalRootsTableOrderingComposer(
            $db: $db,
            $table: $db.localRoots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$BooksTableOrderingComposer get bookId {
    final $$BooksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableOrderingComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LocalFilesTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $LocalFilesTable> {
  $$LocalFilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get format =>
      $composableBuilder(column: $table.format, builder: (column) => column);

  GeneratedColumn<int> get textLength => $composableBuilder(
    column: $table.textLength,
    builder: (column) => column,
  );

  GeneratedColumn<int> get modifiedAt => $composableBuilder(
    column: $table.modifiedAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get needsRelink => $composableBuilder(
    column: $table.needsRelink,
    builder: (column) => column,
  );

  $$LocalRootsTableAnnotationComposer get rootId {
    final $$LocalRootsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rootId,
      referencedTable: $db.localRoots,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalRootsTableAnnotationComposer(
            $db: $db,
            $table: $db.localRoots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$BooksTableAnnotationComposer get bookId {
    final $$BooksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableAnnotationComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LocalFilesTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $LocalFilesTable,
          LocalFile,
          $$LocalFilesTableFilterComposer,
          $$LocalFilesTableOrderingComposer,
          $$LocalFilesTableAnnotationComposer,
          $$LocalFilesTableCreateCompanionBuilder,
          $$LocalFilesTableUpdateCompanionBuilder,
          (LocalFile, $$LocalFilesTableReferences),
          LocalFile,
          PrefetchHooks Function({bool rootId, bool bookId})
        > {
  $$LocalFilesTableTableManager(_$SpaceDatabase db, $LocalFilesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalFilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalFilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalFilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> rootId = const Value.absent(),
                Value<String> relativePath = const Value.absent(),
                Value<String> format = const Value.absent(),
                Value<int?> textLength = const Value.absent(),
                Value<int?> modifiedAt = const Value.absent(),
                Value<bool> needsRelink = const Value.absent(),
                Value<String?> bookId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalFilesCompanion(
                rootId: rootId,
                relativePath: relativePath,
                format: format,
                textLength: textLength,
                modifiedAt: modifiedAt,
                needsRelink: needsRelink,
                bookId: bookId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String rootId,
                required String relativePath,
                Value<String> format = const Value.absent(),
                Value<int?> textLength = const Value.absent(),
                Value<int?> modifiedAt = const Value.absent(),
                Value<bool> needsRelink = const Value.absent(),
                Value<String?> bookId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalFilesCompanion.insert(
                rootId: rootId,
                relativePath: relativePath,
                format: format,
                textLength: textLength,
                modifiedAt: modifiedAt,
                needsRelink: needsRelink,
                bookId: bookId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalFilesTable, LocalFile>(table),
                  $$LocalFilesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({rootId = false, bookId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (rootId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.rootId,
                                referencedTable: $$LocalFilesTableReferences
                                    ._rootIdTable(db),
                                referencedColumn: $$LocalFilesTableReferences
                                    ._rootIdTable(db)
                                    .id,
                              )
                              as T;
                    }
                    if (bookId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.bookId,
                                referencedTable: $$LocalFilesTableReferences
                                    ._bookIdTable(db),
                                referencedColumn: $$LocalFilesTableReferences
                                    ._bookIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$LocalFilesTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $LocalFilesTable,
      LocalFile,
      $$LocalFilesTableFilterComposer,
      $$LocalFilesTableOrderingComposer,
      $$LocalFilesTableAnnotationComposer,
      $$LocalFilesTableCreateCompanionBuilder,
      $$LocalFilesTableUpdateCompanionBuilder,
      (LocalFile, $$LocalFilesTableReferences),
      LocalFile,
      PrefetchHooks Function({bool rootId, bool bookId})
    >;
typedef $$TextIndexTableCreateCompanionBuilder =
    TextIndexCompanion Function({
      required String rootId,
      required String relativePath,
      required int byteOffset,
      required int codeUnitOffset,
      required int lineIndex,
      Value<int> rowid,
    });
typedef $$TextIndexTableUpdateCompanionBuilder =
    TextIndexCompanion Function({
      Value<String> rootId,
      Value<String> relativePath,
      Value<int> byteOffset,
      Value<int> codeUnitOffset,
      Value<int> lineIndex,
      Value<int> rowid,
    });

final class $$TextIndexTableReferences
    extends BaseReferences<_$SpaceDatabase, $TextIndexTable, TextIndexEntry> {
  $$TextIndexTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalRootsTable _rootIdTable(_$SpaceDatabase db) =>
      db.localRoots.createAlias('text_index__root_id__local_roots__id');

  $$LocalRootsTableProcessedTableManager get rootId {
    final $_column = $_itemColumn<String>('root_id')!;

    final manager = $$LocalRootsTableTableManager(
      $_db,
      $_db.localRoots,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_rootIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$TextIndexTableFilterComposer
    extends Composer<_$SpaceDatabase, $TextIndexTable> {
  $$TextIndexTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get byteOffset => $composableBuilder(
    column: $table.byteOffset,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get codeUnitOffset => $composableBuilder(
    column: $table.codeUnitOffset,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lineIndex => $composableBuilder(
    column: $table.lineIndex,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalRootsTableFilterComposer get rootId {
    final $$LocalRootsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rootId,
      referencedTable: $db.localRoots,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalRootsTableFilterComposer(
            $db: $db,
            $table: $db.localRoots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TextIndexTableOrderingComposer
    extends Composer<_$SpaceDatabase, $TextIndexTable> {
  $$TextIndexTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get byteOffset => $composableBuilder(
    column: $table.byteOffset,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get codeUnitOffset => $composableBuilder(
    column: $table.codeUnitOffset,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lineIndex => $composableBuilder(
    column: $table.lineIndex,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalRootsTableOrderingComposer get rootId {
    final $$LocalRootsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rootId,
      referencedTable: $db.localRoots,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalRootsTableOrderingComposer(
            $db: $db,
            $table: $db.localRoots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TextIndexTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $TextIndexTable> {
  $$TextIndexTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => column,
  );

  GeneratedColumn<int> get byteOffset => $composableBuilder(
    column: $table.byteOffset,
    builder: (column) => column,
  );

  GeneratedColumn<int> get codeUnitOffset => $composableBuilder(
    column: $table.codeUnitOffset,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lineIndex =>
      $composableBuilder(column: $table.lineIndex, builder: (column) => column);

  $$LocalRootsTableAnnotationComposer get rootId {
    final $$LocalRootsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.rootId,
      referencedTable: $db.localRoots,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalRootsTableAnnotationComposer(
            $db: $db,
            $table: $db.localRoots,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TextIndexTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $TextIndexTable,
          TextIndexEntry,
          $$TextIndexTableFilterComposer,
          $$TextIndexTableOrderingComposer,
          $$TextIndexTableAnnotationComposer,
          $$TextIndexTableCreateCompanionBuilder,
          $$TextIndexTableUpdateCompanionBuilder,
          (TextIndexEntry, $$TextIndexTableReferences),
          TextIndexEntry,
          PrefetchHooks Function({bool rootId})
        > {
  $$TextIndexTableTableManager(_$SpaceDatabase db, $TextIndexTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TextIndexTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TextIndexTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TextIndexTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> rootId = const Value.absent(),
                Value<String> relativePath = const Value.absent(),
                Value<int> byteOffset = const Value.absent(),
                Value<int> codeUnitOffset = const Value.absent(),
                Value<int> lineIndex = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TextIndexCompanion(
                rootId: rootId,
                relativePath: relativePath,
                byteOffset: byteOffset,
                codeUnitOffset: codeUnitOffset,
                lineIndex: lineIndex,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String rootId,
                required String relativePath,
                required int byteOffset,
                required int codeUnitOffset,
                required int lineIndex,
                Value<int> rowid = const Value.absent(),
              }) => TextIndexCompanion.insert(
                rootId: rootId,
                relativePath: relativePath,
                byteOffset: byteOffset,
                codeUnitOffset: codeUnitOffset,
                lineIndex: lineIndex,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TextIndexTable, TextIndexEntry>(table),
                  $$TextIndexTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({rootId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (rootId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.rootId,
                                referencedTable: $$TextIndexTableReferences
                                    ._rootIdTable(db),
                                referencedColumn: $$TextIndexTableReferences
                                    ._rootIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$TextIndexTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $TextIndexTable,
      TextIndexEntry,
      $$TextIndexTableFilterComposer,
      $$TextIndexTableOrderingComposer,
      $$TextIndexTableAnnotationComposer,
      $$TextIndexTableCreateCompanionBuilder,
      $$TextIndexTableUpdateCompanionBuilder,
      (TextIndexEntry, $$TextIndexTableReferences),
      TextIndexEntry,
      PrefetchHooks Function({bool rootId})
    >;
typedef $$ProgressTableCreateCompanionBuilder =
    ProgressCompanion Function({
      required String bookId,
      Value<int> textOffset,
      Value<int> lineIndex,
      Value<int> offsetInLine,
      Value<int> textLength,
      Value<String?> chapterKey,
      Value<int?> chapterIndex,
      Value<String?> anchor,
      Value<int> updatedAt,
      Value<int> rowid,
    });
typedef $$ProgressTableUpdateCompanionBuilder =
    ProgressCompanion Function({
      Value<String> bookId,
      Value<int> textOffset,
      Value<int> lineIndex,
      Value<int> offsetInLine,
      Value<int> textLength,
      Value<String?> chapterKey,
      Value<int?> chapterIndex,
      Value<String?> anchor,
      Value<int> updatedAt,
      Value<int> rowid,
    });

final class $$ProgressTableReferences
    extends BaseReferences<_$SpaceDatabase, $ProgressTable, ReadingProgress> {
  $$ProgressTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $BooksTable _bookIdTable(_$SpaceDatabase db) =>
      db.books.createAlias('progress__book_id__books__id');

  $$BooksTableProcessedTableManager get bookId {
    final $_column = $_itemColumn<String>('book_id')!;

    final manager = $$BooksTableTableManager(
      $_db,
      $_db.books,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_bookIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ProgressTableFilterComposer
    extends Composer<_$SpaceDatabase, $ProgressTable> {
  $$ProgressTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get textOffset => $composableBuilder(
    column: $table.textOffset,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lineIndex => $composableBuilder(
    column: $table.lineIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get offsetInLine => $composableBuilder(
    column: $table.offsetInLine,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get textLength => $composableBuilder(
    column: $table.textLength,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get chapterKey => $composableBuilder(
    column: $table.chapterKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get chapterIndex => $composableBuilder(
    column: $table.chapterIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get anchor => $composableBuilder(
    column: $table.anchor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$BooksTableFilterComposer get bookId {
    final $$BooksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableFilterComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProgressTableOrderingComposer
    extends Composer<_$SpaceDatabase, $ProgressTable> {
  $$ProgressTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get textOffset => $composableBuilder(
    column: $table.textOffset,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lineIndex => $composableBuilder(
    column: $table.lineIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get offsetInLine => $composableBuilder(
    column: $table.offsetInLine,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get textLength => $composableBuilder(
    column: $table.textLength,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get chapterKey => $composableBuilder(
    column: $table.chapterKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get chapterIndex => $composableBuilder(
    column: $table.chapterIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get anchor => $composableBuilder(
    column: $table.anchor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$BooksTableOrderingComposer get bookId {
    final $$BooksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableOrderingComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProgressTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $ProgressTable> {
  $$ProgressTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get textOffset => $composableBuilder(
    column: $table.textOffset,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lineIndex =>
      $composableBuilder(column: $table.lineIndex, builder: (column) => column);

  GeneratedColumn<int> get offsetInLine => $composableBuilder(
    column: $table.offsetInLine,
    builder: (column) => column,
  );

  GeneratedColumn<int> get textLength => $composableBuilder(
    column: $table.textLength,
    builder: (column) => column,
  );

  GeneratedColumn<String> get chapterKey => $composableBuilder(
    column: $table.chapterKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get chapterIndex => $composableBuilder(
    column: $table.chapterIndex,
    builder: (column) => column,
  );

  GeneratedColumn<String> get anchor =>
      $composableBuilder(column: $table.anchor, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$BooksTableAnnotationComposer get bookId {
    final $$BooksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableAnnotationComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProgressTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $ProgressTable,
          ReadingProgress,
          $$ProgressTableFilterComposer,
          $$ProgressTableOrderingComposer,
          $$ProgressTableAnnotationComposer,
          $$ProgressTableCreateCompanionBuilder,
          $$ProgressTableUpdateCompanionBuilder,
          (ReadingProgress, $$ProgressTableReferences),
          ReadingProgress,
          PrefetchHooks Function({bool bookId})
        > {
  $$ProgressTableTableManager(_$SpaceDatabase db, $ProgressTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProgressTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProgressTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProgressTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bookId = const Value.absent(),
                Value<int> textOffset = const Value.absent(),
                Value<int> lineIndex = const Value.absent(),
                Value<int> offsetInLine = const Value.absent(),
                Value<int> textLength = const Value.absent(),
                Value<String?> chapterKey = const Value.absent(),
                Value<int?> chapterIndex = const Value.absent(),
                Value<String?> anchor = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProgressCompanion(
                bookId: bookId,
                textOffset: textOffset,
                lineIndex: lineIndex,
                offsetInLine: offsetInLine,
                textLength: textLength,
                chapterKey: chapterKey,
                chapterIndex: chapterIndex,
                anchor: anchor,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String bookId,
                Value<int> textOffset = const Value.absent(),
                Value<int> lineIndex = const Value.absent(),
                Value<int> offsetInLine = const Value.absent(),
                Value<int> textLength = const Value.absent(),
                Value<String?> chapterKey = const Value.absent(),
                Value<int?> chapterIndex = const Value.absent(),
                Value<String?> anchor = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProgressCompanion.insert(
                bookId: bookId,
                textOffset: textOffset,
                lineIndex: lineIndex,
                offsetInLine: offsetInLine,
                textLength: textLength,
                chapterKey: chapterKey,
                chapterIndex: chapterIndex,
                anchor: anchor,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ProgressTable, ReadingProgress>(table),
                  $$ProgressTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({bookId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (bookId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.bookId,
                                referencedTable: $$ProgressTableReferences
                                    ._bookIdTable(db),
                                referencedColumn: $$ProgressTableReferences
                                    ._bookIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ProgressTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $ProgressTable,
      ReadingProgress,
      $$ProgressTableFilterComposer,
      $$ProgressTableOrderingComposer,
      $$ProgressTableAnnotationComposer,
      $$ProgressTableCreateCompanionBuilder,
      $$ProgressTableUpdateCompanionBuilder,
      (ReadingProgress, $$ProgressTableReferences),
      ReadingProgress,
      PrefetchHooks Function({bool bookId})
    >;
typedef $$ReplaceRulesTableCreateCompanionBuilder =
    ReplaceRulesCompanion Function({
      required String id,
      required String name,
      Value<String> groupName,
      required String pattern,
      Value<String> replacement,
      Value<String?> scope,
      Value<String?> excludeScope,
      Value<bool> scopeTitle,
      Value<bool> scopeContent,
      Value<bool> isEnabled,
      Value<bool> isRegex,
      Value<int> timeoutMillisecond,
      Value<int> ruleOrder,
      Value<String?> raw,
      Value<int> rowid,
    });
typedef $$ReplaceRulesTableUpdateCompanionBuilder =
    ReplaceRulesCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> groupName,
      Value<String> pattern,
      Value<String> replacement,
      Value<String?> scope,
      Value<String?> excludeScope,
      Value<bool> scopeTitle,
      Value<bool> scopeContent,
      Value<bool> isEnabled,
      Value<bool> isRegex,
      Value<int> timeoutMillisecond,
      Value<int> ruleOrder,
      Value<String?> raw,
      Value<int> rowid,
    });

class $$ReplaceRulesTableFilterComposer
    extends Composer<_$SpaceDatabase, $ReplaceRulesTable> {
  $$ReplaceRulesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groupName => $composableBuilder(
    column: $table.groupName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pattern => $composableBuilder(
    column: $table.pattern,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replacement => $composableBuilder(
    column: $table.replacement,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scope => $composableBuilder(
    column: $table.scope,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get excludeScope => $composableBuilder(
    column: $table.excludeScope,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get scopeTitle => $composableBuilder(
    column: $table.scopeTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get scopeContent => $composableBuilder(
    column: $table.scopeContent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isEnabled => $composableBuilder(
    column: $table.isEnabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isRegex => $composableBuilder(
    column: $table.isRegex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get timeoutMillisecond => $composableBuilder(
    column: $table.timeoutMillisecond,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ruleOrder => $composableBuilder(
    column: $table.ruleOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get raw => $composableBuilder(
    column: $table.raw,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReplaceRulesTableOrderingComposer
    extends Composer<_$SpaceDatabase, $ReplaceRulesTable> {
  $$ReplaceRulesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groupName => $composableBuilder(
    column: $table.groupName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pattern => $composableBuilder(
    column: $table.pattern,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replacement => $composableBuilder(
    column: $table.replacement,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scope => $composableBuilder(
    column: $table.scope,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get excludeScope => $composableBuilder(
    column: $table.excludeScope,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get scopeTitle => $composableBuilder(
    column: $table.scopeTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get scopeContent => $composableBuilder(
    column: $table.scopeContent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isEnabled => $composableBuilder(
    column: $table.isEnabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isRegex => $composableBuilder(
    column: $table.isRegex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get timeoutMillisecond => $composableBuilder(
    column: $table.timeoutMillisecond,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ruleOrder => $composableBuilder(
    column: $table.ruleOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get raw => $composableBuilder(
    column: $table.raw,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReplaceRulesTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $ReplaceRulesTable> {
  $$ReplaceRulesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get groupName =>
      $composableBuilder(column: $table.groupName, builder: (column) => column);

  GeneratedColumn<String> get pattern =>
      $composableBuilder(column: $table.pattern, builder: (column) => column);

  GeneratedColumn<String> get replacement => $composableBuilder(
    column: $table.replacement,
    builder: (column) => column,
  );

  GeneratedColumn<String> get scope =>
      $composableBuilder(column: $table.scope, builder: (column) => column);

  GeneratedColumn<String> get excludeScope => $composableBuilder(
    column: $table.excludeScope,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get scopeTitle => $composableBuilder(
    column: $table.scopeTitle,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get scopeContent => $composableBuilder(
    column: $table.scopeContent,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isEnabled =>
      $composableBuilder(column: $table.isEnabled, builder: (column) => column);

  GeneratedColumn<bool> get isRegex =>
      $composableBuilder(column: $table.isRegex, builder: (column) => column);

  GeneratedColumn<int> get timeoutMillisecond => $composableBuilder(
    column: $table.timeoutMillisecond,
    builder: (column) => column,
  );

  GeneratedColumn<int> get ruleOrder =>
      $composableBuilder(column: $table.ruleOrder, builder: (column) => column);

  GeneratedColumn<String> get raw =>
      $composableBuilder(column: $table.raw, builder: (column) => column);
}

class $$ReplaceRulesTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $ReplaceRulesTable,
          ReplaceRule,
          $$ReplaceRulesTableFilterComposer,
          $$ReplaceRulesTableOrderingComposer,
          $$ReplaceRulesTableAnnotationComposer,
          $$ReplaceRulesTableCreateCompanionBuilder,
          $$ReplaceRulesTableUpdateCompanionBuilder,
          (
            ReplaceRule,
            BaseReferences<_$SpaceDatabase, $ReplaceRulesTable, ReplaceRule>,
          ),
          ReplaceRule,
          PrefetchHooks Function()
        > {
  $$ReplaceRulesTableTableManager(_$SpaceDatabase db, $ReplaceRulesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReplaceRulesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReplaceRulesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReplaceRulesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> groupName = const Value.absent(),
                Value<String> pattern = const Value.absent(),
                Value<String> replacement = const Value.absent(),
                Value<String?> scope = const Value.absent(),
                Value<String?> excludeScope = const Value.absent(),
                Value<bool> scopeTitle = const Value.absent(),
                Value<bool> scopeContent = const Value.absent(),
                Value<bool> isEnabled = const Value.absent(),
                Value<bool> isRegex = const Value.absent(),
                Value<int> timeoutMillisecond = const Value.absent(),
                Value<int> ruleOrder = const Value.absent(),
                Value<String?> raw = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReplaceRulesCompanion(
                id: id,
                name: name,
                groupName: groupName,
                pattern: pattern,
                replacement: replacement,
                scope: scope,
                excludeScope: excludeScope,
                scopeTitle: scopeTitle,
                scopeContent: scopeContent,
                isEnabled: isEnabled,
                isRegex: isRegex,
                timeoutMillisecond: timeoutMillisecond,
                ruleOrder: ruleOrder,
                raw: raw,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<String> groupName = const Value.absent(),
                required String pattern,
                Value<String> replacement = const Value.absent(),
                Value<String?> scope = const Value.absent(),
                Value<String?> excludeScope = const Value.absent(),
                Value<bool> scopeTitle = const Value.absent(),
                Value<bool> scopeContent = const Value.absent(),
                Value<bool> isEnabled = const Value.absent(),
                Value<bool> isRegex = const Value.absent(),
                Value<int> timeoutMillisecond = const Value.absent(),
                Value<int> ruleOrder = const Value.absent(),
                Value<String?> raw = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReplaceRulesCompanion.insert(
                id: id,
                name: name,
                groupName: groupName,
                pattern: pattern,
                replacement: replacement,
                scope: scope,
                excludeScope: excludeScope,
                scopeTitle: scopeTitle,
                scopeContent: scopeContent,
                isEnabled: isEnabled,
                isRegex: isRegex,
                timeoutMillisecond: timeoutMillisecond,
                ruleOrder: ruleOrder,
                raw: raw,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReplaceRulesTable, ReplaceRule>(table),
                  BaseReferences<
                    _$SpaceDatabase,
                    $ReplaceRulesTable,
                    ReplaceRule
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReplaceRulesTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $ReplaceRulesTable,
      ReplaceRule,
      $$ReplaceRulesTableFilterComposer,
      $$ReplaceRulesTableOrderingComposer,
      $$ReplaceRulesTableAnnotationComposer,
      $$ReplaceRulesTableCreateCompanionBuilder,
      $$ReplaceRulesTableUpdateCompanionBuilder,
      (
        ReplaceRule,
        BaseReferences<_$SpaceDatabase, $ReplaceRulesTable, ReplaceRule>,
      ),
      ReplaceRule,
      PrefetchHooks Function()
    >;
typedef $$SettingsTableCreateCompanionBuilder =
    SettingsCompanion Function({
      Value<String> bookId,
      required String key,
      required String value,
      Value<int> updatedAt,
      Value<int> rowid,
    });
typedef $$SettingsTableUpdateCompanionBuilder =
    SettingsCompanion Function({
      Value<String> bookId,
      Value<String> key,
      Value<String> value,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$SettingsTableFilterComposer
    extends Composer<_$SpaceDatabase, $SettingsTable> {
  $$SettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SettingsTableOrderingComposer
    extends Composer<_$SpaceDatabase, $SettingsTable> {
  $$SettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SettingsTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $SettingsTable> {
  $$SettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$SettingsTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $SettingsTable,
          SpaceSetting,
          $$SettingsTableFilterComposer,
          $$SettingsTableOrderingComposer,
          $$SettingsTableAnnotationComposer,
          $$SettingsTableCreateCompanionBuilder,
          $$SettingsTableUpdateCompanionBuilder,
          (
            SpaceSetting,
            BaseReferences<_$SpaceDatabase, $SettingsTable, SpaceSetting>,
          ),
          SpaceSetting,
          PrefetchHooks Function()
        > {
  $$SettingsTableTableManager(_$SpaceDatabase db, $SettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bookId = const Value.absent(),
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SettingsCompanion(
                bookId: bookId,
                key: key,
                value: value,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String> bookId = const Value.absent(),
                required String key,
                required String value,
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SettingsCompanion.insert(
                bookId: bookId,
                key: key,
                value: value,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SettingsTable, SpaceSetting>(table),
                  BaseReferences<_$SpaceDatabase, $SettingsTable, SpaceSetting>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $SettingsTable,
      SpaceSetting,
      $$SettingsTableFilterComposer,
      $$SettingsTableOrderingComposer,
      $$SettingsTableAnnotationComposer,
      $$SettingsTableCreateCompanionBuilder,
      $$SettingsTableUpdateCompanionBuilder,
      (
        SpaceSetting,
        BaseReferences<_$SpaceDatabase, $SettingsTable, SpaceSetting>,
      ),
      SpaceSetting,
      PrefetchHooks Function()
    >;
typedef $$SourceCookiesTableCreateCompanionBuilder =
    SourceCookiesCompanion Function({
      required String domain,
      required String name,
      required String value,
      Value<String?> writerRef,
      Value<int> rowid,
    });
typedef $$SourceCookiesTableUpdateCompanionBuilder =
    SourceCookiesCompanion Function({
      Value<String> domain,
      Value<String> name,
      Value<String> value,
      Value<String?> writerRef,
      Value<int> rowid,
    });

class $$SourceCookiesTableFilterComposer
    extends Composer<_$SpaceDatabase, $SourceCookiesTable> {
  $$SourceCookiesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get domain => $composableBuilder(
    column: $table.domain,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get writerRef => $composableBuilder(
    column: $table.writerRef,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SourceCookiesTableOrderingComposer
    extends Composer<_$SpaceDatabase, $SourceCookiesTable> {
  $$SourceCookiesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get domain => $composableBuilder(
    column: $table.domain,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get writerRef => $composableBuilder(
    column: $table.writerRef,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SourceCookiesTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $SourceCookiesTable> {
  $$SourceCookiesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get domain =>
      $composableBuilder(column: $table.domain, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<String> get writerRef =>
      $composableBuilder(column: $table.writerRef, builder: (column) => column);
}

class $$SourceCookiesTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $SourceCookiesTable,
          StoredCookie,
          $$SourceCookiesTableFilterComposer,
          $$SourceCookiesTableOrderingComposer,
          $$SourceCookiesTableAnnotationComposer,
          $$SourceCookiesTableCreateCompanionBuilder,
          $$SourceCookiesTableUpdateCompanionBuilder,
          (
            StoredCookie,
            BaseReferences<_$SpaceDatabase, $SourceCookiesTable, StoredCookie>,
          ),
          StoredCookie,
          PrefetchHooks Function()
        > {
  $$SourceCookiesTableTableManager(
    _$SpaceDatabase db,
    $SourceCookiesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SourceCookiesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SourceCookiesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SourceCookiesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> domain = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<String?> writerRef = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SourceCookiesCompanion(
                domain: domain,
                name: name,
                value: value,
                writerRef: writerRef,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String domain,
                required String name,
                required String value,
                Value<String?> writerRef = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SourceCookiesCompanion.insert(
                domain: domain,
                name: name,
                value: value,
                writerRef: writerRef,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SourceCookiesTable, StoredCookie>(table),
                  BaseReferences<
                    _$SpaceDatabase,
                    $SourceCookiesTable,
                    StoredCookie
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SourceCookiesTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $SourceCookiesTable,
      StoredCookie,
      $$SourceCookiesTableFilterComposer,
      $$SourceCookiesTableOrderingComposer,
      $$SourceCookiesTableAnnotationComposer,
      $$SourceCookiesTableCreateCompanionBuilder,
      $$SourceCookiesTableUpdateCompanionBuilder,
      (
        StoredCookie,
        BaseReferences<_$SpaceDatabase, $SourceCookiesTable, StoredCookie>,
      ),
      StoredCookie,
      PrefetchHooks Function()
    >;
typedef $$SourceEntriesTableCreateCompanionBuilder =
    SourceEntriesCompanion Function({
      required String sourceRef,
      required String key,
      Value<String?> value,
      Value<int> expiresAt,
      Value<int> writtenAt,
      Value<int> rowid,
    });
typedef $$SourceEntriesTableUpdateCompanionBuilder =
    SourceEntriesCompanion Function({
      Value<String> sourceRef,
      Value<String> key,
      Value<String?> value,
      Value<int> expiresAt,
      Value<int> writtenAt,
      Value<int> rowid,
    });

class $$SourceEntriesTableFilterComposer
    extends Composer<_$SpaceDatabase, $SourceEntriesTable> {
  $$SourceEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get writtenAt => $composableBuilder(
    column: $table.writtenAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SourceEntriesTableOrderingComposer
    extends Composer<_$SpaceDatabase, $SourceEntriesTable> {
  $$SourceEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get writtenAt => $composableBuilder(
    column: $table.writtenAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SourceEntriesTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $SourceEntriesTable> {
  $$SourceEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sourceRef =>
      $composableBuilder(column: $table.sourceRef, builder: (column) => column);

  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<int> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  GeneratedColumn<int> get writtenAt =>
      $composableBuilder(column: $table.writtenAt, builder: (column) => column);
}

class $$SourceEntriesTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $SourceEntriesTable,
          StoredSourceEntry,
          $$SourceEntriesTableFilterComposer,
          $$SourceEntriesTableOrderingComposer,
          $$SourceEntriesTableAnnotationComposer,
          $$SourceEntriesTableCreateCompanionBuilder,
          $$SourceEntriesTableUpdateCompanionBuilder,
          (
            StoredSourceEntry,
            BaseReferences<
              _$SpaceDatabase,
              $SourceEntriesTable,
              StoredSourceEntry
            >,
          ),
          StoredSourceEntry,
          PrefetchHooks Function()
        > {
  $$SourceEntriesTableTableManager(
    _$SpaceDatabase db,
    $SourceEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SourceEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SourceEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SourceEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> sourceRef = const Value.absent(),
                Value<String> key = const Value.absent(),
                Value<String?> value = const Value.absent(),
                Value<int> expiresAt = const Value.absent(),
                Value<int> writtenAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SourceEntriesCompanion(
                sourceRef: sourceRef,
                key: key,
                value: value,
                expiresAt: expiresAt,
                writtenAt: writtenAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String sourceRef,
                required String key,
                Value<String?> value = const Value.absent(),
                Value<int> expiresAt = const Value.absent(),
                Value<int> writtenAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SourceEntriesCompanion.insert(
                sourceRef: sourceRef,
                key: key,
                value: value,
                expiresAt: expiresAt,
                writtenAt: writtenAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SourceEntriesTable, StoredSourceEntry>(table),
                  BaseReferences<
                    _$SpaceDatabase,
                    $SourceEntriesTable,
                    StoredSourceEntry
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SourceEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $SourceEntriesTable,
      StoredSourceEntry,
      $$SourceEntriesTableFilterComposer,
      $$SourceEntriesTableOrderingComposer,
      $$SourceEntriesTableAnnotationComposer,
      $$SourceEntriesTableCreateCompanionBuilder,
      $$SourceEntriesTableUpdateCompanionBuilder,
      (
        StoredSourceEntry,
        BaseReferences<_$SpaceDatabase, $SourceEntriesTable, StoredSourceEntry>,
      ),
      StoredSourceEntry,
      PrefetchHooks Function()
    >;
typedef $$SourceTlsExceptionsTableCreateCompanionBuilder =
    SourceTlsExceptionsCompanion Function({
      required String sourceRef,
      required String host,
      Value<int> rowid,
    });
typedef $$SourceTlsExceptionsTableUpdateCompanionBuilder =
    SourceTlsExceptionsCompanion Function({
      Value<String> sourceRef,
      Value<String> host,
      Value<int> rowid,
    });

class $$SourceTlsExceptionsTableFilterComposer
    extends Composer<_$SpaceDatabase, $SourceTlsExceptionsTable> {
  $$SourceTlsExceptionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SourceTlsExceptionsTableOrderingComposer
    extends Composer<_$SpaceDatabase, $SourceTlsExceptionsTable> {
  $$SourceTlsExceptionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SourceTlsExceptionsTableAnnotationComposer
    extends Composer<_$SpaceDatabase, $SourceTlsExceptionsTable> {
  $$SourceTlsExceptionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sourceRef =>
      $composableBuilder(column: $table.sourceRef, builder: (column) => column);

  GeneratedColumn<String> get host =>
      $composableBuilder(column: $table.host, builder: (column) => column);
}

class $$SourceTlsExceptionsTableTableManager
    extends
        RootTableManager<
          _$SpaceDatabase,
          $SourceTlsExceptionsTable,
          StoredTlsException,
          $$SourceTlsExceptionsTableFilterComposer,
          $$SourceTlsExceptionsTableOrderingComposer,
          $$SourceTlsExceptionsTableAnnotationComposer,
          $$SourceTlsExceptionsTableCreateCompanionBuilder,
          $$SourceTlsExceptionsTableUpdateCompanionBuilder,
          (
            StoredTlsException,
            BaseReferences<
              _$SpaceDatabase,
              $SourceTlsExceptionsTable,
              StoredTlsException
            >,
          ),
          StoredTlsException,
          PrefetchHooks Function()
        > {
  $$SourceTlsExceptionsTableTableManager(
    _$SpaceDatabase db,
    $SourceTlsExceptionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SourceTlsExceptionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SourceTlsExceptionsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$SourceTlsExceptionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> sourceRef = const Value.absent(),
                Value<String> host = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SourceTlsExceptionsCompanion(
                sourceRef: sourceRef,
                host: host,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String sourceRef,
                required String host,
                Value<int> rowid = const Value.absent(),
              }) => SourceTlsExceptionsCompanion.insert(
                sourceRef: sourceRef,
                host: host,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SourceTlsExceptionsTable, StoredTlsException>(
                    table,
                  ),
                  BaseReferences<
                    _$SpaceDatabase,
                    $SourceTlsExceptionsTable,
                    StoredTlsException
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SourceTlsExceptionsTableProcessedTableManager =
    ProcessedTableManager<
      _$SpaceDatabase,
      $SourceTlsExceptionsTable,
      StoredTlsException,
      $$SourceTlsExceptionsTableFilterComposer,
      $$SourceTlsExceptionsTableOrderingComposer,
      $$SourceTlsExceptionsTableAnnotationComposer,
      $$SourceTlsExceptionsTableCreateCompanionBuilder,
      $$SourceTlsExceptionsTableUpdateCompanionBuilder,
      (
        StoredTlsException,
        BaseReferences<
          _$SpaceDatabase,
          $SourceTlsExceptionsTable,
          StoredTlsException
        >,
      ),
      StoredTlsException,
      PrefetchHooks Function()
    >;

class $SpaceDatabaseManager {
  final _$SpaceDatabase _db;
  $SpaceDatabaseManager(this._db);
  $$SourcesTableTableManager get sources =>
      $$SourcesTableTableManager(_db, _db.sources);
  $$BooksTableTableManager get books =>
      $$BooksTableTableManager(_db, _db.books);
  $$GroupsTableTableManager get groups =>
      $$GroupsTableTableManager(_db, _db.groups);
  $$BookGroupsTableTableManager get bookGroups =>
      $$BookGroupsTableTableManager(_db, _db.bookGroups);
  $$ChaptersTableTableManager get chapters =>
      $$ChaptersTableTableManager(_db, _db.chapters);
  $$LocalRootsTableTableManager get localRoots =>
      $$LocalRootsTableTableManager(_db, _db.localRoots);
  $$LocalFilesTableTableManager get localFiles =>
      $$LocalFilesTableTableManager(_db, _db.localFiles);
  $$TextIndexTableTableManager get textIndex =>
      $$TextIndexTableTableManager(_db, _db.textIndex);
  $$ProgressTableTableManager get progress =>
      $$ProgressTableTableManager(_db, _db.progress);
  $$ReplaceRulesTableTableManager get replaceRules =>
      $$ReplaceRulesTableTableManager(_db, _db.replaceRules);
  $$SettingsTableTableManager get settings =>
      $$SettingsTableTableManager(_db, _db.settings);
  $$SourceCookiesTableTableManager get sourceCookies =>
      $$SourceCookiesTableTableManager(_db, _db.sourceCookies);
  $$SourceEntriesTableTableManager get sourceEntries =>
      $$SourceEntriesTableTableManager(_db, _db.sourceEntries);
  $$SourceTlsExceptionsTableTableManager get sourceTlsExceptions =>
      $$SourceTlsExceptionsTableTableManager(_db, _db.sourceTlsExceptions);
}
