// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'library_files.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$LibraryFileError {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is LibraryFileError);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'LibraryFileError()';
  }
}

/// @nodoc
class $LibraryFileErrorCopyWith<$Res> {
  $LibraryFileErrorCopyWith(
      LibraryFileError _, $Res Function(LibraryFileError) __);
}

/// Adds pattern-matching-related methods to [LibraryFileError].
extension LibraryFileErrorPatterns on LibraryFileError {
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
    TResult Function(LibraryFileError_Cancelled value)? cancelled,
    TResult Function(LibraryFileError_AlreadyExists value)? alreadyExists,
    TResult Function(LibraryFileError_VerificationFailed value)?
        verificationFailed,
    TResult Function(LibraryFileError_Io value)? io,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case LibraryFileError_Cancelled() when cancelled != null:
        return cancelled(_that);
      case LibraryFileError_AlreadyExists() when alreadyExists != null:
        return alreadyExists(_that);
      case LibraryFileError_VerificationFailed()
          when verificationFailed != null:
        return verificationFailed(_that);
      case LibraryFileError_Io() when io != null:
        return io(_that);
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
    required TResult Function(LibraryFileError_Cancelled value) cancelled,
    required TResult Function(LibraryFileError_AlreadyExists value)
        alreadyExists,
    required TResult Function(LibraryFileError_VerificationFailed value)
        verificationFailed,
    required TResult Function(LibraryFileError_Io value) io,
  }) {
    final _that = this;
    switch (_that) {
      case LibraryFileError_Cancelled():
        return cancelled(_that);
      case LibraryFileError_AlreadyExists():
        return alreadyExists(_that);
      case LibraryFileError_VerificationFailed():
        return verificationFailed(_that);
      case LibraryFileError_Io():
        return io(_that);
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
    TResult? Function(LibraryFileError_Cancelled value)? cancelled,
    TResult? Function(LibraryFileError_AlreadyExists value)? alreadyExists,
    TResult? Function(LibraryFileError_VerificationFailed value)?
        verificationFailed,
    TResult? Function(LibraryFileError_Io value)? io,
  }) {
    final _that = this;
    switch (_that) {
      case LibraryFileError_Cancelled() when cancelled != null:
        return cancelled(_that);
      case LibraryFileError_AlreadyExists() when alreadyExists != null:
        return alreadyExists(_that);
      case LibraryFileError_VerificationFailed()
          when verificationFailed != null:
        return verificationFailed(_that);
      case LibraryFileError_Io() when io != null:
        return io(_that);
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
    TResult Function()? cancelled,
    TResult Function()? alreadyExists,
    TResult Function()? verificationFailed,
    TResult Function(String field0)? io,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case LibraryFileError_Cancelled() when cancelled != null:
        return cancelled();
      case LibraryFileError_AlreadyExists() when alreadyExists != null:
        return alreadyExists();
      case LibraryFileError_VerificationFailed()
          when verificationFailed != null:
        return verificationFailed();
      case LibraryFileError_Io() when io != null:
        return io(_that.field0);
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
    required TResult Function() cancelled,
    required TResult Function() alreadyExists,
    required TResult Function() verificationFailed,
    required TResult Function(String field0) io,
  }) {
    final _that = this;
    switch (_that) {
      case LibraryFileError_Cancelled():
        return cancelled();
      case LibraryFileError_AlreadyExists():
        return alreadyExists();
      case LibraryFileError_VerificationFailed():
        return verificationFailed();
      case LibraryFileError_Io():
        return io(_that.field0);
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
    TResult? Function()? cancelled,
    TResult? Function()? alreadyExists,
    TResult? Function()? verificationFailed,
    TResult? Function(String field0)? io,
  }) {
    final _that = this;
    switch (_that) {
      case LibraryFileError_Cancelled() when cancelled != null:
        return cancelled();
      case LibraryFileError_AlreadyExists() when alreadyExists != null:
        return alreadyExists();
      case LibraryFileError_VerificationFailed()
          when verificationFailed != null:
        return verificationFailed();
      case LibraryFileError_Io() when io != null:
        return io(_that.field0);
      case _:
        return null;
    }
  }
}

/// @nodoc

class LibraryFileError_Cancelled extends LibraryFileError {
  const LibraryFileError_Cancelled() : super._();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is LibraryFileError_Cancelled);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'LibraryFileError.cancelled()';
  }
}

/// @nodoc

class LibraryFileError_AlreadyExists extends LibraryFileError {
  const LibraryFileError_AlreadyExists() : super._();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is LibraryFileError_AlreadyExists);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'LibraryFileError.alreadyExists()';
  }
}

/// @nodoc

class LibraryFileError_VerificationFailed extends LibraryFileError {
  const LibraryFileError_VerificationFailed() : super._();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is LibraryFileError_VerificationFailed);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'LibraryFileError.verificationFailed()';
  }
}

/// @nodoc

class LibraryFileError_Io extends LibraryFileError {
  const LibraryFileError_Io(this.field0) : super._();

  final String field0;

  /// Create a copy of LibraryFileError
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $LibraryFileError_IoCopyWith<LibraryFileError_Io> get copyWith =>
      _$LibraryFileError_IoCopyWithImpl<LibraryFileError_Io>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is LibraryFileError_Io &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'LibraryFileError.io(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $LibraryFileError_IoCopyWith<$Res>
    implements $LibraryFileErrorCopyWith<$Res> {
  factory $LibraryFileError_IoCopyWith(
          LibraryFileError_Io value, $Res Function(LibraryFileError_Io) _then) =
      _$LibraryFileError_IoCopyWithImpl;
  @useResult
  $Res call({String field0});
}

/// @nodoc
class _$LibraryFileError_IoCopyWithImpl<$Res>
    implements $LibraryFileError_IoCopyWith<$Res> {
  _$LibraryFileError_IoCopyWithImpl(this._self, this._then);

  final LibraryFileError_Io _self;
  final $Res Function(LibraryFileError_Io) _then;

  /// Create a copy of LibraryFileError
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(LibraryFileError_Io(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

// dart format on
