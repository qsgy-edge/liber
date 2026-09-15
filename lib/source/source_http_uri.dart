/// URI parsing for the frozen OkHttp request-target convention: literal square
/// brackets in paths/queries stay literal; explicitly escaped brackets stay
/// escaped. All other parsing, validation and resolution uses Dart's Uri.
class SourceHttpUri implements Uri {
  SourceHttpUri._(this._standard, this.path, this.query);

  factory SourceHttpUri.parse(String text) {
    final standard = Uri.parse(text);
    final token = _token([text]);
    final protected = Uri.parse(_protect(text, token));
    return SourceHttpUri._(
      standard,
      _restore(protected.path, token),
      _restore(protected.query, token),
    );
  }

  final Uri _standard;
  @override
  final String path;
  @override
  final String query;

  static String _token(List<String> values) {
    final text = values
        .expand((value) => [value, Uri.parse(value).toString()])
        .join('\n');
    final occupied = RegExp(
      r'liberBracket[0-9]*',
    ).allMatches(text).map((match) => match.group(0)).toSet();
    var index = 0;
    while (occupied.contains('liberBracket$index')) {
      index++;
    }
    return 'liberBracket$index';
  }

  static String _protect(String text, String token) {
    // Leave the authority (especially IPv6 brackets) and fragment untouched.
    final prefix =
        RegExp(
          r'^(?:[a-zA-Z][a-zA-Z0-9+.-]*:)?//[^/?#]*',
        ).firstMatch(text)?.end ??
        0;
    final fragment = text.indexOf('#', prefix);
    final end = fragment < 0 ? text.length : fragment;
    return text.substring(0, prefix) +
        text
            .substring(prefix, end)
            .replaceAll('[', '${token}L')
            .replaceAll(']', '${token}R') +
        text.substring(end);
  }

  static String _restore(String text, String token) =>
      text.replaceAll('${token}L', '[').replaceAll('${token}R', ']');

  @override
  String toString() =>
      '${hasScheme ? '$scheme:' : ''}${hasAuthority ? '//$authority' : ''}$path${hasQuery ? '?$query' : ''}${hasFragment ? '#$fragment' : ''}';
  @override
  Uri resolve(String reference) {
    final token = _token([toString(), reference]);
    final base = Uri.parse(_protect(toString(), token));
    return SourceHttpUri.parse(
      _restore(base.resolve(_protect(reference, token)).toString(), token),
    );
  }

  @override
  Uri resolveUri(Uri reference) => resolve(reference.toString());
  @override
  Uri removeFragment() =>
      SourceHttpUri._(_standard.removeFragment(), path, query);
  @override
  Uri normalizePath() => this;
  @override
  Uri replace({
    String? scheme,
    String? userInfo,
    String? host,
    int? port,
    String? path,
    Iterable<String>? pathSegments,
    String? query,
    Map<String, dynamic>? queryParameters,
    String? fragment,
  }) {
    final next = _standard.replace(
      scheme: scheme,
      userInfo: userInfo,
      host: host,
      port: port,
      path: path,
      pathSegments: pathSegments,
      query: query,
      queryParameters: queryParameters,
      fragment: fragment,
    );
    final token = _token([toString(), next.toString()]);
    final protected = Uri.parse(_protect(toString(), token));
    final replaced = protected.replace(
      scheme: scheme,
      userInfo: userInfo,
      host: host,
      port: port,
      path: path,
      pathSegments: pathSegments,
      query: query,
      queryParameters: queryParameters,
      fragment: fragment,
    );
    return SourceHttpUri.parse(_restore(replaced.toString(), token));
  }

  @override
  String get scheme => _standard.scheme;
  @override
  String get authority => _standard.authority;
  @override
  String get userInfo => _standard.userInfo;
  @override
  String get host => _standard.host;
  @override
  int get port => _standard.port;
  @override
  String get fragment => _standard.fragment;
  @override
  List<String> get pathSegments => _standard.pathSegments;
  @override
  Map<String, String> get queryParameters => _standard.queryParameters;
  @override
  Map<String, List<String>> get queryParametersAll =>
      _standard.queryParametersAll;
  @override
  bool get isAbsolute => _standard.isAbsolute;
  @override
  bool get hasScheme => _standard.hasScheme;
  @override
  bool get hasAuthority => _standard.hasAuthority;
  @override
  bool get hasPort => _standard.hasPort;
  @override
  bool get hasQuery => _standard.hasQuery;
  @override
  bool get hasFragment => _standard.hasFragment;
  @override
  bool get hasEmptyPath => path.isEmpty;
  @override
  bool get hasAbsolutePath => _standard.hasAbsolutePath;
  @override
  String get origin => _standard.origin;
  @override
  bool isScheme(String scheme) => _standard.isScheme(scheme);
  @override
  String toFilePath({bool? windows}) => _standard.toFilePath(windows: windows);
  @override
  UriData? get data => _standard.data;
  @override
  int get hashCode => toString().hashCode;
  @override
  bool operator ==(Object other) =>
      other is Uri && toString() == other.toString();
}
