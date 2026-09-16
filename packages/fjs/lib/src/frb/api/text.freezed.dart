// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'text.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$TextEngineError {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is TextEngineError);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'TextEngineError()';
  }
}

/// @nodoc
class $TextEngineErrorCopyWith<$Res> {
  $TextEngineErrorCopyWith(
      TextEngineError _, $Res Function(TextEngineError) __);
}

/// Adds pattern-matching-related methods to [TextEngineError].
extension TextEngineErrorPatterns on TextEngineError {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(TextEngineError_Io value)? io,
    TResult Function(TextEngineError_UnknownEncoding value)? unknownEncoding,
    TResult Function(TextEngineError_UnsupportedEncoding value)?
        unsupportedEncoding,
    TResult Function(TextEngineError_AnchorTooFar value)? anchorTooFar,
    TResult Function(TextEngineError_OffsetOutOfRange value)? offsetOutOfRange,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case TextEngineError_Io() when io != null:
        return io(_that);
      case TextEngineError_UnknownEncoding() when unknownEncoding != null:
        return unknownEncoding(_that);
      case TextEngineError_UnsupportedEncoding()
          when unsupportedEncoding != null:
        return unsupportedEncoding(_that);
      case TextEngineError_AnchorTooFar() when anchorTooFar != null:
        return anchorTooFar(_that);
      case TextEngineError_OffsetOutOfRange() when offsetOutOfRange != null:
        return offsetOutOfRange(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(TextEngineError_Io value) io,
    required TResult Function(TextEngineError_UnknownEncoding value)
        unknownEncoding,
    required TResult Function(TextEngineError_UnsupportedEncoding value)
        unsupportedEncoding,
    required TResult Function(TextEngineError_AnchorTooFar value) anchorTooFar,
    required TResult Function(TextEngineError_OffsetOutOfRange value)
        offsetOutOfRange,
  }) {
    final _that = this;
    switch (_that) {
      case TextEngineError_Io():
        return io(_that);
      case TextEngineError_UnknownEncoding():
        return unknownEncoding(_that);
      case TextEngineError_UnsupportedEncoding():
        return unsupportedEncoding(_that);
      case TextEngineError_AnchorTooFar():
        return anchorTooFar(_that);
      case TextEngineError_OffsetOutOfRange():
        return offsetOutOfRange(_that);
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(TextEngineError_Io value)? io,
    TResult? Function(TextEngineError_UnknownEncoding value)? unknownEncoding,
    TResult? Function(TextEngineError_UnsupportedEncoding value)?
        unsupportedEncoding,
    TResult? Function(TextEngineError_AnchorTooFar value)? anchorTooFar,
    TResult? Function(TextEngineError_OffsetOutOfRange value)? offsetOutOfRange,
  }) {
    final _that = this;
    switch (_that) {
      case TextEngineError_Io() when io != null:
        return io(_that);
      case TextEngineError_UnknownEncoding() when unknownEncoding != null:
        return unknownEncoding(_that);
      case TextEngineError_UnsupportedEncoding()
          when unsupportedEncoding != null:
        return unsupportedEncoding(_that);
      case TextEngineError_AnchorTooFar() when anchorTooFar != null:
        return anchorTooFar(_that);
      case TextEngineError_OffsetOutOfRange() when offsetOutOfRange != null:
        return offsetOutOfRange(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String field0)? io,
    TResult Function(String field0)? unknownEncoding,
    TResult Function(String field0)? unsupportedEncoding,
    TResult Function(PlatformInt64 scannedBytes, PlatformInt64 limit)?
        anchorTooFar,
    TResult Function(PlatformInt64 offset, PlatformInt64 codeUnitLength)?
        offsetOutOfRange,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case TextEngineError_Io() when io != null:
        return io(_that.field0);
      case TextEngineError_UnknownEncoding() when unknownEncoding != null:
        return unknownEncoding(_that.field0);
      case TextEngineError_UnsupportedEncoding()
          when unsupportedEncoding != null:
        return unsupportedEncoding(_that.field0);
      case TextEngineError_AnchorTooFar() when anchorTooFar != null:
        return anchorTooFar(_that.scannedBytes, _that.limit);
      case TextEngineError_OffsetOutOfRange() when offsetOutOfRange != null:
        return offsetOutOfRange(_that.offset, _that.codeUnitLength);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String field0) io,
    required TResult Function(String field0) unknownEncoding,
    required TResult Function(String field0) unsupportedEncoding,
    required TResult Function(PlatformInt64 scannedBytes, PlatformInt64 limit)
        anchorTooFar,
    required TResult Function(
            PlatformInt64 offset, PlatformInt64 codeUnitLength)
        offsetOutOfRange,
  }) {
    final _that = this;
    switch (_that) {
      case TextEngineError_Io():
        return io(_that.field0);
      case TextEngineError_UnknownEncoding():
        return unknownEncoding(_that.field0);
      case TextEngineError_UnsupportedEncoding():
        return unsupportedEncoding(_that.field0);
      case TextEngineError_AnchorTooFar():
        return anchorTooFar(_that.scannedBytes, _that.limit);
      case TextEngineError_OffsetOutOfRange():
        return offsetOutOfRange(_that.offset, _that.codeUnitLength);
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String field0)? io,
    TResult? Function(String field0)? unknownEncoding,
    TResult? Function(String field0)? unsupportedEncoding,
    TResult? Function(PlatformInt64 scannedBytes, PlatformInt64 limit)?
        anchorTooFar,
    TResult? Function(PlatformInt64 offset, PlatformInt64 codeUnitLength)?
        offsetOutOfRange,
  }) {
    final _that = this;
    switch (_that) {
      case TextEngineError_Io() when io != null:
        return io(_that.field0);
      case TextEngineError_UnknownEncoding() when unknownEncoding != null:
        return unknownEncoding(_that.field0);
      case TextEngineError_UnsupportedEncoding()
          when unsupportedEncoding != null:
        return unsupportedEncoding(_that.field0);
      case TextEngineError_AnchorTooFar() when anchorTooFar != null:
        return anchorTooFar(_that.scannedBytes, _that.limit);
      case TextEngineError_OffsetOutOfRange() when offsetOutOfRange != null:
        return offsetOutOfRange(_that.offset, _that.codeUnitLength);
      case _:
        return null;
    }
  }
}

/// @nodoc

class TextEngineError_Io extends TextEngineError {
  const TextEngineError_Io(this.field0) : super._();

  final String field0;

  /// Create a copy of TextEngineError
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $TextEngineError_IoCopyWith<TextEngineError_Io> get copyWith =>
      _$TextEngineError_IoCopyWithImpl<TextEngineError_Io>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is TextEngineError_Io &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'TextEngineError.io(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $TextEngineError_IoCopyWith<$Res>
    implements $TextEngineErrorCopyWith<$Res> {
  factory $TextEngineError_IoCopyWith(
          TextEngineError_Io value, $Res Function(TextEngineError_Io) _then) =
      _$TextEngineError_IoCopyWithImpl;
  @useResult
  $Res call({String field0});
}

/// @nodoc
class _$TextEngineError_IoCopyWithImpl<$Res>
    implements $TextEngineError_IoCopyWith<$Res> {
  _$TextEngineError_IoCopyWithImpl(this._self, this._then);

  final TextEngineError_Io _self;
  final $Res Function(TextEngineError_Io) _then;

  /// Create a copy of TextEngineError
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(TextEngineError_Io(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class TextEngineError_UnknownEncoding extends TextEngineError {
  const TextEngineError_UnknownEncoding(this.field0) : super._();

  final String field0;

  /// Create a copy of TextEngineError
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $TextEngineError_UnknownEncodingCopyWith<TextEngineError_UnknownEncoding>
      get copyWith => _$TextEngineError_UnknownEncodingCopyWithImpl<
          TextEngineError_UnknownEncoding>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is TextEngineError_UnknownEncoding &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'TextEngineError.unknownEncoding(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $TextEngineError_UnknownEncodingCopyWith<$Res>
    implements $TextEngineErrorCopyWith<$Res> {
  factory $TextEngineError_UnknownEncodingCopyWith(
          TextEngineError_UnknownEncoding value,
          $Res Function(TextEngineError_UnknownEncoding) _then) =
      _$TextEngineError_UnknownEncodingCopyWithImpl;
  @useResult
  $Res call({String field0});
}

/// @nodoc
class _$TextEngineError_UnknownEncodingCopyWithImpl<$Res>
    implements $TextEngineError_UnknownEncodingCopyWith<$Res> {
  _$TextEngineError_UnknownEncodingCopyWithImpl(this._self, this._then);

  final TextEngineError_UnknownEncoding _self;
  final $Res Function(TextEngineError_UnknownEncoding) _then;

  /// Create a copy of TextEngineError
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(TextEngineError_UnknownEncoding(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class TextEngineError_UnsupportedEncoding extends TextEngineError {
  const TextEngineError_UnsupportedEncoding(this.field0) : super._();

  final String field0;

  /// Create a copy of TextEngineError
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $TextEngineError_UnsupportedEncodingCopyWith<
          TextEngineError_UnsupportedEncoding>
      get copyWith => _$TextEngineError_UnsupportedEncodingCopyWithImpl<
          TextEngineError_UnsupportedEncoding>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is TextEngineError_UnsupportedEncoding &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'TextEngineError.unsupportedEncoding(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $TextEngineError_UnsupportedEncodingCopyWith<$Res>
    implements $TextEngineErrorCopyWith<$Res> {
  factory $TextEngineError_UnsupportedEncodingCopyWith(
          TextEngineError_UnsupportedEncoding value,
          $Res Function(TextEngineError_UnsupportedEncoding) _then) =
      _$TextEngineError_UnsupportedEncodingCopyWithImpl;
  @useResult
  $Res call({String field0});
}

/// @nodoc
class _$TextEngineError_UnsupportedEncodingCopyWithImpl<$Res>
    implements $TextEngineError_UnsupportedEncodingCopyWith<$Res> {
  _$TextEngineError_UnsupportedEncodingCopyWithImpl(this._self, this._then);

  final TextEngineError_UnsupportedEncoding _self;
  final $Res Function(TextEngineError_UnsupportedEncoding) _then;

  /// Create a copy of TextEngineError
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(TextEngineError_UnsupportedEncoding(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class TextEngineError_AnchorTooFar extends TextEngineError {
  const TextEngineError_AnchorTooFar(
      {required this.scannedBytes, required this.limit})
      : super._();

  /// Bytes scanned before giving up.
  final PlatformInt64 scannedBytes;

  /// The caller's limit.
  final PlatformInt64 limit;

  /// Create a copy of TextEngineError
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $TextEngineError_AnchorTooFarCopyWith<TextEngineError_AnchorTooFar>
      get copyWith => _$TextEngineError_AnchorTooFarCopyWithImpl<
          TextEngineError_AnchorTooFar>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is TextEngineError_AnchorTooFar &&
            (identical(other.scannedBytes, scannedBytes) ||
                other.scannedBytes == scannedBytes) &&
            (identical(other.limit, limit) || other.limit == limit));
  }

  @override
  int get hashCode => Object.hash(runtimeType, scannedBytes, limit);

  @override
  String toString() {
    return 'TextEngineError.anchorTooFar(scannedBytes: $scannedBytes, limit: $limit)';
  }
}

/// @nodoc
abstract mixin class $TextEngineError_AnchorTooFarCopyWith<$Res>
    implements $TextEngineErrorCopyWith<$Res> {
  factory $TextEngineError_AnchorTooFarCopyWith(
          TextEngineError_AnchorTooFar value,
          $Res Function(TextEngineError_AnchorTooFar) _then) =
      _$TextEngineError_AnchorTooFarCopyWithImpl;
  @useResult
  $Res call({PlatformInt64 scannedBytes, PlatformInt64 limit});
}

/// @nodoc
class _$TextEngineError_AnchorTooFarCopyWithImpl<$Res>
    implements $TextEngineError_AnchorTooFarCopyWith<$Res> {
  _$TextEngineError_AnchorTooFarCopyWithImpl(this._self, this._then);

  final TextEngineError_AnchorTooFar _self;
  final $Res Function(TextEngineError_AnchorTooFar) _then;

  /// Create a copy of TextEngineError
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? scannedBytes = null,
    Object? limit = null,
  }) {
    return _then(TextEngineError_AnchorTooFar(
      scannedBytes: null == scannedBytes
          ? _self.scannedBytes
          : scannedBytes // ignore: cast_nullable_to_non_nullable
              as PlatformInt64,
      limit: null == limit
          ? _self.limit
          : limit // ignore: cast_nullable_to_non_nullable
              as PlatformInt64,
    ));
  }
}

/// @nodoc

class TextEngineError_OffsetOutOfRange extends TextEngineError {
  const TextEngineError_OffsetOutOfRange(
      {required this.offset, required this.codeUnitLength})
      : super._();

  /// The requested code-unit offset.
  final PlatformInt64 offset;

  /// The file's code-unit length.
  final PlatformInt64 codeUnitLength;

  /// Create a copy of TextEngineError
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $TextEngineError_OffsetOutOfRangeCopyWith<TextEngineError_OffsetOutOfRange>
      get copyWith => _$TextEngineError_OffsetOutOfRangeCopyWithImpl<
          TextEngineError_OffsetOutOfRange>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is TextEngineError_OffsetOutOfRange &&
            (identical(other.offset, offset) || other.offset == offset) &&
            (identical(other.codeUnitLength, codeUnitLength) ||
                other.codeUnitLength == codeUnitLength));
  }

  @override
  int get hashCode => Object.hash(runtimeType, offset, codeUnitLength);

  @override
  String toString() {
    return 'TextEngineError.offsetOutOfRange(offset: $offset, codeUnitLength: $codeUnitLength)';
  }
}

/// @nodoc
abstract mixin class $TextEngineError_OffsetOutOfRangeCopyWith<$Res>
    implements $TextEngineErrorCopyWith<$Res> {
  factory $TextEngineError_OffsetOutOfRangeCopyWith(
          TextEngineError_OffsetOutOfRange value,
          $Res Function(TextEngineError_OffsetOutOfRange) _then) =
      _$TextEngineError_OffsetOutOfRangeCopyWithImpl;
  @useResult
  $Res call({PlatformInt64 offset, PlatformInt64 codeUnitLength});
}

/// @nodoc
class _$TextEngineError_OffsetOutOfRangeCopyWithImpl<$Res>
    implements $TextEngineError_OffsetOutOfRangeCopyWith<$Res> {
  _$TextEngineError_OffsetOutOfRangeCopyWithImpl(this._self, this._then);

  final TextEngineError_OffsetOutOfRange _self;
  final $Res Function(TextEngineError_OffsetOutOfRange) _then;

  /// Create a copy of TextEngineError
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? offset = null,
    Object? codeUnitLength = null,
  }) {
    return _then(TextEngineError_OffsetOutOfRange(
      offset: null == offset
          ? _self.offset
          : offset // ignore: cast_nullable_to_non_nullable
              as PlatformInt64,
      codeUnitLength: null == codeUnitLength
          ? _self.codeUnitLength
          : codeUnitLength // ignore: cast_nullable_to_non_nullable
              as PlatformInt64,
    ));
  }
}

// dart format on
