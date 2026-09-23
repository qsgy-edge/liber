import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../domain/contracts.dart';
import 'js_source_runtime.dart';
import 'source_host_dispatcher.dart';
import 'source_host_state.dart';

/// One row of a source's `loginUi` form, as the frozen `RowUi` reads it
/// (`data/entities/rule/RowUi.kt`): a field the user fills, or a button whose
/// `action` is a script.
///
/// `type` is `text`, `password` or `button`; an absent `type` is the `RowUi`
/// field's own default of `text`, and the frozen dialog's `when` renders nothing
/// for any other value — including an explicit null — so a caller renders only
/// these three.
class SourceLoginRow {
  const SourceLoginRow({
    required this.name,
    required this.type,
    this.action,
  });

  /// The row's label and the key its value is collected under (`RowUi.name`).
  final String name;

  /// `text`, `password` or `button` (`RowUi.Type`), or a value the frozen dialog
  /// does not render.
  final String? type;

  /// A button's `action` (`RowUi.action`): an absolute URL or a script.
  final String? action;

  bool get isField => type == 'text' || type == 'password';
  bool get isButton => type == 'button';
}

/// The rows of one source's `loginUi` field — the frozen `BaseSource.loginUi()`
/// (`BaseSource.kt:64-70`), which parses the field with Gson into `List<RowUi>`
/// and leaves a field that does not parse as no form at all.
///
/// The whole field fails together there, so it does here: a value that is not a
/// JSON array of objects, or one row whose `name`/`type`/`action` is not the
/// type Gson reads into `String?`, is the failure Gson reports and the form is
/// empty rather than half-built.
List<SourceLoginRow> sourceLoginRows(Object? loginUi) {
  if (loginUi is! String || loginUi.trim().isEmpty) return const [];
  final Object? decoded;
  try {
    decoded = jsonDecode(loginUi);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];
  final rows = <SourceLoginRow>[];
  for (final value in decoded) {
    if (value is! Map) return const [];
    final name = value['name'];
    final type = value.containsKey('type') ? value['type'] : 'text';
    final action = value['action'];
    if (name is! String) return const [];
    if (type is! String?) return const [];
    if (action is! String?) return const [];
    rows.add(SourceLoginRow(name: name, type: type, action: action));
  }
  return rows;
}

/// Frozen `String?.isAbsUrl()` (`utils/StringExtensions.kt:36`): the button
/// `action` the frozen dialog opens in the system browser.
bool isAbsoluteSourceUrl(String? action) {
  if (action == null) return false;
  final lower = action.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

/// The frozen `BaseSource.getLoginJs()` (`BaseSource.kt:72-79`): the `loginUrl`
/// field's script after the `@js:` prefix or the `<js>…</js>` wrapper is
/// stripped off. `null` when the source declares no `loginUrl`; a bare URL is
/// returned as it is, which is what the frozen app then evaluates — and fails
/// on with `Function login not implements!!!`, because it defines no `login`.
///
/// A `<js>` field with no closing marker is the frozen
/// `substring(4, lastIndexOf('<'))` out-of-range failure; this names it instead,
/// as the source `header` rule's own marker failure does.
String? sourceLoginJs(String? loginUrl) {
  final js = loginUrl;
  if (js == null) return null;
  if (js.startsWith('@js:')) return js.substring(4);
  if (js.startsWith('<js>')) {
    final end = js.lastIndexOf('<');
    if (end <= 4) throw const FormatException('书源 loginUrl 的 <js> 规则缺少结束标记');
    return js.substring(4, end);
  }
  return js;
}

/// The frozen `BaseSource.login()` body (`BaseSource.kt:84-96`): the source's
/// login script followed by the call that requires a `login` function, whose
/// absence throws the frozen `Function login not implements!!!`.
String sourceLoginScript(String loginJs) =>
    "$loginJs\n"
    "if(typeof login=='function'){login.apply(this);} "
    "else {throw('Function login not implements!!!')}";

/// The frozen `SourceLoginDialog.handleButtonClick` script
/// (`ui/login/SourceLoginDialog.kt:133-136`): the source's login script followed
/// by the button's own `action`, which the dialog evaluates with the collected
/// login data bound as `result`.
String sourceLoginButtonScript(String loginJs, String action) =>
    '$loginJs\n$action';

/// The login header one source stores, under the frozen
/// `loginHeader_${getKey()}` key (`BaseSource.kt:132-134`).
String sourceLoginHeaderKey(String sourceRef) => 'loginHeader_$sourceRef';

/// The login information one source stores, under the frozen
/// `userInfo_${getKey()}` key (`BaseSource.kt:160-162`).
String sourceLoginInfoKey(String sourceRef) => 'userInfo_$sourceRef';

/// The frozen `GSON.fromJsonObject<Map<String, String>>` read of a stored login
/// header or login information: a JSON object of string values, and null for
/// anything else — including the malformed text `putLoginHeader` still stores.
Map<String, String>? sourceLoginMap(Object? stored) {
  if (stored is! String) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(stored);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final map = <String, String>{};
  for (final entry in decoded.entries) {
    final value = entry.value;
    if (entry.key is! String || value is! String) return null;
    map['${entry.key}'] = value;
  }
  return map;
}

/// The key the frozen `AppConst.androidId.encodeToByteArray(0, 16)` produces
/// (`BaseSource.kt:161,180`, ADR 0011 §6): the first 16 UTF-8 bytes of the
/// installation's opaque id, which is the AES-128 key.
///
/// Null when the id cannot carry it — shorter than 16 characters, as the frozen
/// `encodeToByteArray(0, 16)` bound rejects, or not exactly 16 bytes of UTF-8,
/// which is the key length every hutool `AES` rejects with a
/// `CryptoException`. The frozen `putLoginInfo` answers `false` for those, and
/// `getLoginInfo` answers null; neither invents a format.
Uint8List? sourceLoginInfoKeyBytes(String androidId) {
  if (androidId.length < 16) return null;
  final key = utf8.encode(androidId.substring(0, 16));
  return key.length == 16 ? Uint8List.fromList(key) : null;
}

/// The frozen `putLoginInfo(info)` value (`BaseSource.kt:179-192`): the JSON text
/// sealed by `SymmetricCryptoAndroid("AES", key).encryptBase64`, which is
/// AES-128 in ECB mode with PKCS5 padding — hutool's `AES` default mode and
/// padding — and the Android `Base64.NO_WRAP` alphabet.
///
/// Null when the installation id cannot carry the key ([sourceLoginInfoKeyBytes])
/// or the input cannot be sealed; the caller reports `false`, as the frozen
/// method's own `try`/`catch` does.
String? sealSourceLoginInfo(String info, String androidId) {
  final key = sourceLoginInfoKeyBytes(androidId);
  if (key == null) return null;
  try {
    final padded = _pkcs7Pad(utf8.encode(info));
    return base64.encode(_aesEcb(key, padded, encrypt: true));
  } on Object {
    return null;
  }
}

/// The frozen `getLoginInfo()` value (`BaseSource.kt:164-172`): the stored text
/// opened with the same key. Null for an entry that is absent, malformed, or was
/// written under another installation id — the frozen `try`/`catch` answer.
String? openSourceLoginInfo(String sealed, String androidId) {
  final key = sourceLoginInfoKeyBytes(androidId);
  if (key == null) return null;
  try {
    final output = _aesEcb(key, base64.decode(sealed), encrypt: false);
    final padding = _pkcs7Padding(output);
    if (padding == null) return null;
    return utf8.decode(output.sublist(0, output.length - padding));
  } on Object {
    return null;
  }
}

Uint8List _pkcs7Pad(List<int> input) {
  final padding = 16 - input.length % 16;
  return Uint8List.fromList([...input, ...List.filled(padding, padding)]);
}

int? _pkcs7Padding(Uint8List output) {
  if (output.isEmpty) return null;
  final padding = output.last;
  if (padding < 1 || padding > 16 || padding > output.length) return null;
  for (var index = output.length - padding; index < output.length; index++) {
    if (output[index] != padding) return null;
  }
  return padding;
}

Uint8List _aesEcb(Uint8List key, Uint8List input, {required bool encrypt}) {
  if (input.isEmpty || input.length % 16 != 0) {
    throw const FormatException('AES input is not a whole number of blocks');
  }
  final cipher = ECBBlockCipher(AESEngine())..init(encrypt, KeyParameter(key));
  final output = Uint8List(input.length);
  for (var offset = 0; offset < input.length; offset += cipher.blockSize) {
    cipher.processBlock(input, offset, output, offset);
  }
  return output;
}

// --- The frozen `BaseSource` login members over one source's host state ------
//
// The JavaScript `source.getLoginHeader()`/`putLoginHeader()` family and the
// login form read and write the same entries; both go through these functions
// so a form that stores a header and a script that reads it cannot disagree
// about the key or the shape.

/// Frozen `BaseSource.getLoginHeader()` (`BaseSource.kt:132-134`).
Future<String?> getSourceLoginHeader(
  SourceHostState state,
  String sourceRef,
) async {
  final stored = await state.entry(sourceRef, sourceLoginHeaderKey(sourceRef));
  return stored is String ? stored : null;
}

/// Frozen `BaseSource.getLoginHeaderMap()` (`BaseSource.kt:136-139`).
Future<Map<String, String>?> getSourceLoginHeaderMap(
  SourceHostState state,
  String sourceRef,
) async => sourceLoginMap(await getSourceLoginHeader(state, sourceRef));

/// The same map over what the state has already loaded, with no `await`:
/// [SourceHostDispatcher] merges it into every outbound request, and a request
/// that waited on a microtask would start a turn later than it does now. Its
/// caller awaits [SourceHostState.ready] first when the state is not loaded
/// (`SourceHostDispatcher._send` does).
Map<String, String>? loadedSourceLoginHeaderMap(
  SourceHostState state,
  String sourceRef,
) => sourceLoginMap(
  state.entryIfLoaded(sourceRef, sourceLoginHeaderKey(sourceRef)),
);

/// Frozen `BaseSource.putLoginHeader(header)` (`BaseSource.kt:141-150`): the
/// map's `Cookie`/`cookie` entry replaces the source's cookie-jar entry for its
/// own site, and the text is stored as it was given — so a header that does not
/// parse is still stored, and reads back as no header.
Future<void> putSourceLoginHeader(
  SourceHostState state,
  String sourceRef,
  String header,
  SourceCookieJar jar,
) async {
  final map = sourceLoginMap(header);
  final cookie = map?['Cookie'] ?? map?['cookie'];
  if (cookie != null) await jar.replace(sourceRef, cookie);
  await state.putEntry(sourceRef, sourceLoginHeaderKey(sourceRef), header);
}

/// Frozen `BaseSource.removeLoginHeader()` (`BaseSource.kt:152-155`): the stored
/// header goes, and with it the cookie-jar entry for the source's own site.
Future<void> removeSourceLoginHeader(
  SourceHostState state,
  String sourceRef,
  SourceCookieJar jar,
) async {
  await state.deleteEntry(sourceRef, sourceLoginHeaderKey(sourceRef));
  await jar.remove(sourceRef);
}

/// Frozen `BaseSource.getLoginInfo()` (`BaseSource.kt:164-172`).
Future<String?> getSourceLoginInfo(
  SourceHostState state,
  String sourceRef,
  String androidId,
) async {
  final stored = await state.entry(sourceRef, sourceLoginInfoKey(sourceRef));
  return stored is String ? openSourceLoginInfo(stored, androidId) : null;
}

/// Frozen `BaseSource.getLoginInfoMap()` (`BaseSource.kt:174-176`): the stored
/// login information as the form's field values.
Future<Map<String, String>?> getSourceLoginInfoMap(
  SourceHostState state,
  String sourceRef,
  String androidId,
) async => sourceLoginMap(await getSourceLoginInfo(state, sourceRef, androidId));

/// Frozen `BaseSource.putLoginInfo(info)` (`BaseSource.kt:179-192`): the sealed
/// text is stored and the Boolean the frozen method returns says whether the
/// installation id could carry it.
Future<bool> putSourceLoginInfo(
  SourceHostState state,
  String sourceRef,
  String info,
  String androidId,
) async {
  final sealed = sealSourceLoginInfo(info, androidId);
  if (sealed == null) return false;
  await state.putEntry(sourceRef, sourceLoginInfoKey(sourceRef), sealed);
  return true;
}

/// Frozen `BaseSource.removeLoginInfo()` (`BaseSource.kt:194-196`).
Future<void> removeSourceLoginInfo(
  SourceHostState state,
  String sourceRef,
) => state.deleteEntry(sourceRef, sourceLoginInfoKey(sourceRef));

/// One source's login session: the frozen `BaseSource` login members over the
/// source's own host state ([SourceHostState]) plus the script runtime its
/// `loginUrl` and `loginUi` buttons run on.
///
/// This is the object the frozen `SourceLoginDialog` holds as its
/// `SourceLoginViewModel`'s source: the form renders [rows], OK runs [submit],
/// a button row runs [runButton], and the two header menu items read and remove
/// what the source stored. A page hands it the space's host state, so a login
/// header a script stores here is the one the next stage's requests carry.
class SourceLoginSession {
  factory SourceLoginSession({
    required Map<String, dynamic> source,
    required SourceHostState hostState,
    String androidId = '',
    SourceHttpTransport? transport,
    SourceScriptRuntime? runtime,
    void Function(SourceHostMessage message)? onMessage,
  }) {
    final sourceRef = sourceRefOf(source);
    // The frozen `AnalyzeUrl` a `java.*` call of a login script builds: the
    // source's own rate and cookie-jar flags, over the same jar and cache the
    // stages use. A caller with no transport (a test that only drives the form)
    // gets a runtime without one, and its requests refuse as unavailable.
    final host = transport == null
        ? null
        : SourceHostDispatcher(
            transport: transport,
            hostState: hostState,
            sourceRef: sourceRef,
            concurrentRate: '${source['concurrentRate'] ?? ''}',
            enabledCookieJar: source['enabledCookieJar'] == true,
          );
    return SourceLoginSession._(
      source,
      hostState,
      sourceRef,
      androidId,
      runtime ??
          InProcessSourceScriptRuntime(
            dispatcher: host,
            hostState: hostState,
            jsLib: source['jsLib'] as String? ?? '',
            androidId: androidId,
            onMessage: onMessage,
          ),
    );
  }

  SourceLoginSession._(
    this.source,
    this.hostState,
    this.sourceRef,
    this.androidId,
    this._runtime,
  );

  /// The imported source object, as the pipelines hold it.
  final Map<String, dynamic> source;

  /// The space's host surface, where the login header and the login information
  /// live next to the source's cookies and variables (ADR 0011 §3).
  final SourceHostState hostState;

  /// The source this session speaks for: its `bookSourceUrl`, the frozen
  /// `getKey()` every login entry is keyed by.
  final String sourceRef;

  /// The installation's opaque id the login information is sealed with
  /// (ADR 0011 §6).
  final String androidId;

  final SourceScriptRuntime _runtime;

  /// How long one login script may run, the pipeline's own script budget.
  static const loginTimeout = Duration(seconds: 30);

  /// The frozen `BaseSource.loginUi()` form.
  List<SourceLoginRow> get rows => sourceLoginRows(source['loginUi']);

  /// The frozen `BaseSource.getLoginJs()`. A `loginUrl` that is not a string is
  /// no script: the field is a `String?` whose text is the script.
  String? get loginJs {
    final value = source['loginUrl'];
    return sourceLoginJs(value is String ? value : null);
  }

  /// Frozen `getLoginInfoMap()`: the field values the form opens with.
  Future<Map<String, String>?> loginInfo() =>
      getSourceLoginInfoMap(hostState, sourceRef, androidId);

  /// Frozen `getLoginHeader()`: the header text the "show login header" menu
  /// item shows.
  Future<String?> loginHeader() => getSourceLoginHeader(hostState, sourceRef);

  /// Frozen `removeLoginHeader()`, the "delete login header" menu item.
  Future<void> removeLoginHeader() =>
      removeSourceLoginHeader(hostState, sourceRef, _jar);

  /// The frozen dialog's OK (`SourceLoginDialog.kt:158-183`): a form that
  /// collected no field removes the stored login information and runs no login
  /// script; otherwise the collected map is stored and the source's `login()`
  /// runs. Returns whether the stored information changed — the `putLoginInfo`
  /// gate the dialog dismisses on, `false` when the installation id cannot
  /// carry the key. A login script that fails throws with its own error.
  Future<bool> submit(Map<String, String> loginData) async {
    if (loginData.isEmpty) {
      await removeSourceLoginInfo(hostState, sourceRef);
      return true;
    }
    if (!await putSourceLoginInfo(
      hostState,
      sourceRef,
      jsonEncode(loginData),
      androidId,
    )) {
      return false;
    }
    final js = loginJs;
    // Frozen `BaseSource.login()`: a blank or absent `loginUrl` runs nothing.
    if (js != null && js.trim().isNotEmpty) {
      await _runtime.evaluateLogin(
        script: sourceLoginScript(js),
        input: _scriptInput(null),
        timeout: loginTimeout,
      );
    }
    return true;
  }

  /// The frozen dialog's button action (`SourceLoginDialog.kt:126-153`): an
  /// absolute-URL `action` is the user-confirmed in-app page there and here
  /// ([sourceLoginButtonUrlPolicy] is gone with the system-browser refusal it
  /// named); any other action is the source's login script followed by the
  /// action, with the form's data bound as `result`.
  Future<void> runButton(
    SourceLoginRow row,
    Map<String, String> loginData,
  ) async {
    final action = row.action;
    if (action == null) return;
    if (isAbsoluteSourceUrl(action)) {
      // The frozen `handleButtonClick` hands an absolute-URL action to the
      // system browser (`SourceLoginDialog.kt:128-130`); this product has no
      // external-opening path, so the action is the same confirmation and page
      // `java.openUrl` shows (ADR 0011 §4, ticket #32). A refusal shows nothing
      // and the form stays open, as the frozen dialog's confirm does.
      await _runtime.evaluateLogin(
        script: 'java.openUrl(${jsonEncode(action)})',
        input: _scriptInput(null),
        timeout: loginTimeout,
      );
      return;
    }
    final js = loginJs;
    if (js == null) return;
    await _runtime.evaluateLogin(
      script: sourceLoginButtonScript(js, action),
      input: _scriptInput(loginData),
      timeout: loginTimeout,
    );
  }

  /// The jar the login header's `Cookie` entry replaces a pair in, and the one
  /// `removeLoginHeader` clears for the source's own site.
  SourceCookieJar get _jar => hostState.cookiesFor(sourceRef);

  /// The bindings the frozen `BaseSource.evalJS` gives a login script
  /// (`BaseSource.kt:236-243`): `java`, `source`, `baseUrl` — the source key —
  /// `cookie`, `cache`, and, for a button action, the form's data as `result`.
  /// `key`/`page` are the null value bindings every evaluation in this product
  /// carries; the frozen login bindings do not name them at all.
  Map<String, Object?> _scriptInput(Object? result) => {
    'sourceKey': sourceRef,
    'source': source,
    'baseUrl': sourceRef,
    'key': null,
    'page': null,
    'result': result,
    'headers': const <String, String>{},
  };
}

/// The source key one source's login session and scripts speak for: its
/// `bookSourceUrl`, as the pipelines read it.
String sourceRefOf(Map<String, dynamic> source) =>
    '${source['bookSourceUrl'] ?? ''}';

