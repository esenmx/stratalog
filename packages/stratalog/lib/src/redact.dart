import 'dart:typed_data';

import 'package:stratalog/src/elide.dart';

/// Default header/metadata allowlist shared across network taps.
///
/// Only listed headers are logged verbatim; unlisted headers are dropped so a
/// tap never leaks bespoke tokens or drowns records in transport noise.
const Set<String> defaultHeaderAllowlist = {
  'content-type',
  'accept',
  'accept-language',
  'content-language',
  'x-request-id',
};

/// Default sensitive header/metadata names shared across network taps.
///
/// Logged presence-only as [redactedMask] unless `maskSensitiveValues: false`
/// is passed for local debugging.
const Set<String> defaultSensitiveHeaders = {
  'authorization',
  'cookie',
  'x-api-key',
};

/// Default normalized credential-bearing keys masked by [redactData] and
/// [redactUri].
///
/// Generic names (`number`, `code`, `token`) are intentionally omitted so
/// ordinary payloads stay readable; cover endpoint-specific secrets with
/// `redactBodyPaths` or a custom `redactKeys` set.
const Set<String> defaultRedactKeys = {
  'password',
  'newpassword',
  'oldpassword',
  'currentpassword',
  'passwordconfirmation',
  'cvv',
  'cvc',
  'pin',
  'otp',
  'secret',
  'clientsecret',
  'apikey',
  'accesstoken',
  'refreshtoken',
  'idtoken',
  'authorization',
  'cardnumber',
  'pan',
};

/// Replacement marker for redacted header, query, URI userinfo, and body leaf
/// values.
const String redactedMask = '***';

/// Replacement marker for bodies dropped wholesale via `redactBodyPaths`.
const String redactedBodyPlaceholder = '*** redacted body ***';

/// Default recursion limit for [redactData] so pathological structures degrade
/// to `'<max depth>'` instead of overflowing the call stack inside a tap.
const int defaultMaxRedactDepth = 64;

/// Default character cap for [scrubErrorLine] and [describeErrorFirstLine].
const int defaultMaxErrorChars = 256;

const int _maxScrubInputChars = 4096;

final RegExp _keySeparators = RegExp('[_-]');
final RegExp _indexBrackets = RegExp(r'\[\d*\]');
final RegExp _keyBrackets = RegExp(r'[\[\]]');

// Ends at whitespace only: a query value may hold `,`, `)` or quotes. The
// scheme is bounded: unbounded, a long scheme-character run without `://`
// backtracks quadratically.
// FIXME(P3, stratalog): a second URL glued to the first with no whitespace
// (`[https://a/x,https://u:p@b/y]`) parses as one URI, so its userinfo and
// query pass unredacted.
final RegExp _inlineUrl = RegExp(r'[a-zA-Z][a-zA-Z\d+.-]{0,31}://\S+');

/// Normalizes a [redactData] / [redactUri] key for comparison: lowercases,
/// strips `_` and `-`, collapses empty or numeric list-index brackets, and
/// canonicalizes multi-segment bracket paths as `[seg1][seg2]` so
/// `filter[ssn]`, `filter[0][ssn]`, and `filter[][ssn]` all normalize to
/// `[filter][ssn]`.
String normalizeRedactKey(String key) {
  final stripped = key
      .toLowerCase()
      .replaceAll(_keySeparators, '')
      .replaceAll(_indexBrackets, '');
  if (!stripped.contains('[')) return stripped;
  final segments = [
    for (final s in stripped.split(_keyBrackets))
      if (s.isNotEmpty) '[$s]',
  ];
  return segments.length == 1
      ? segments.single.substring(1, segments.single.length - 1)
      : segments.join();
}

/// Reports whether [key] matches [normalizedRedactKeys] as an exact key/path,
/// as a trailing bracketed subpath (`[outer][filter][ssn]` ends with
/// `[filter][ssn]`), or on any bracketed segment (`auth[password]`).
bool isRedactedKey(String key, Set<String> normalizedRedactKeys) {
  if (normalizedRedactKeys.isEmpty) return false;
  final normalized = normalizeRedactKey(key);
  if (normalizedRedactKeys.contains(normalized)) return true;
  if (!normalized.startsWith('[')) return false;
  if (normalized
      .split(_keyBrackets)
      .any((s) => s.isNotEmpty && normalizedRedactKeys.contains(s))) {
    return true;
  }
  return normalizedRedactKeys.any(
    (rk) => rk.startsWith('[') && normalized.endsWith(rk),
  );
}

/// Filters a single-valued header/metadata map against [allowlist] and
/// [sensitive] (both already lowercased).
Map<String, Object?> redactHeaderMap(
  Map<String, Object?>? headers, {
  required Set<String> allowlist,
  required Set<String> sensitive,
  required bool maskSensitiveValues,
}) {
  if (headers == null || headers.isEmpty) return const {};
  final safe = <String, Object?>{};
  headers.forEach((key, value) {
    final k = key.toLowerCase();
    if (sensitive.contains(k)) {
      safe[k] = maskSensitiveValues ? redactedMask : value;
    } else if (allowlist.contains(k)) {
      safe[k] = value;
    }
  });
  return safe;
}

/// Filters multi-valued `(name, value)` header pairs against [allowlist] and
/// [sensitive] (both already lowercased), joining repeated unmasked values
/// with `', '`.
Map<String, String> redactHeaderEntries(
  Iterable<(String, String)> entries, {
  required Set<String> allowlist,
  required Set<String> sensitive,
  required bool maskSensitiveValues,
}) {
  final safe = <String, String>{};
  for (final (name, value) in entries) {
    final k = name.toLowerCase();
    if (sensitive.contains(k)) {
      final existing = safe[k];
      final rendered = maskSensitiveValues ? redactedMask : value;
      safe[k] = maskSensitiveValues || existing == null
          ? rendered
          : '$existing, $rendered';
    } else if (allowlist.contains(k)) {
      final existing = safe[k];
      safe[k] = existing == null ? value : '$existing, $value';
    }
  }
  return safe;
}

/// Redacts `userInfo` and matching query parameters on [uri] (or strips the
/// entire query and fragment when [stripAllQueries] is `true`).
///
/// Returns [uri] unchanged when nothing requires redaction so wire-identical
/// query ordering and encoding are preserved on clean URLs.
Uri redactUri(
  Uri uri,
  Set<String> normalizedRedactKeys, {
  bool stripAllQueries = false,
}) {
  final safe = uri.userInfo.isEmpty ? uri : uri.replace(userInfo: redactedMask);
  if (stripAllQueries) {
    if (!safe.hasQuery && !safe.hasFragment) return safe;
    return Uri(
      scheme: safe.hasScheme ? safe.scheme : null,
      userInfo: safe.userInfo.isEmpty ? null : safe.userInfo,
      host: safe.hasAuthority ? safe.host : null,
      port: safe.hasPort ? safe.port : null,
      path: safe.path,
    );
  }
  if (!safe.hasQuery || normalizedRedactKeys.isEmpty) return safe;
  final Map<String, List<String>> query;
  try {
    query = safe.queryParametersAll;
  } on Object {
    return safe.replace(query: redactedMask);
  }
  if (!query.keys.any((k) => isRedactedKey(k, normalizedRedactKeys))) {
    return safe;
  }
  // Encoded by hand: `replace(queryParameters:)` would percent-encode the mask
  // into `%2A%2A%2A`.
  final parts = <String>[];
  query.forEach((key, values) {
    final encodedKey = Uri.encodeQueryComponent(key);
    if (isRedactedKey(key, normalizedRedactKeys)) {
      parts.add('$encodedKey=$redactedMask');
    } else {
      parts.addAll(
        values.map((value) => '$encodedKey=${Uri.encodeQueryComponent(value)}'),
      );
    }
  });
  return safe.replace(query: parts.join('&'));
}

/// Redacts a standalone URL string via [redactUri], keeping clean URLs
/// byte-identical and masking unparseable strings whole.
String redactUrlString(
  String url,
  Set<String> normalizedRedactKeys, {
  bool stripAllQueries = false,
}) {
  try {
    if (Uri.tryParse(url) case final uri?) {
      final safe = redactUri(
        uri,
        normalizedRedactKeys,
        stripAllQueries: stripAllQueries,
      );
      return identical(safe, uri) ? url : '$safe';
    }
  } on Object {
    return redactedMask;
  }
  return redactedMask;
}

/// Redacts every whitespace-delimited URL inside [text] via [redactUrlString].
String redactUrlsInText(
  String text,
  Set<String> normalizedRedactKeys, {
  bool stripAllQueries = false,
}) => text.replaceAllMapped(
  _inlineUrl,
  (match) => redactUrlString(
    match[0] ?? '',
    normalizedRedactKeys,
    stripAllQueries: stripAllQueries,
  ),
);

/// Recursively copies [data] into a detached, string-keyed structure with keys
/// matching [normalizedRedactKeys] replaced by [redactedMask].
///
/// - Cycle-safe via path-based identity tracking (`'<cycle>'`).
/// - Depth-bounded at [maxDepth] (`'<max depth>'`) so pathological payloads
///   never overflow the stack.
/// - [TypedData] summarises as `'<N-byte body>'` before the [Iterable] arm so
///   binary payloads are never boxed byte-by-byte.
/// - Custom leaf objects delegate to [encodeCustomObject] when provided.
Object? redactData(
  Object? data,
  Set<String> normalizedRedactKeys, {
  bool stringifyPlatformLeaves = false,
  int maxDepth = defaultMaxRedactDepth,
  Object? Function(Object value, Object? Function(Object? nested) redactNested)?
  encodeCustomObject,
}) {
  final seen = Set<Object?>.identity();
  final matchesKeyPaths = normalizedRedactKeys.any((k) => k.startsWith('['));

  Object? walk(Object? node, String parent, int depth) {
    if (depth >= maxDepth) return '<max depth>';
    switch (node) {
      case final TypedData bytes:
        return '<${bytes.lengthInBytes}-byte body>';
      case final Map<Object?, Object?> map:
        if (!seen.add(map)) return '<cycle>';
        try {
          return <String, Object?>{
            for (final MapEntry(:key, :value) in map.entries)
              '$key': switch (matchesKeyPaths && parent.isNotEmpty
                  ? '$parent[$key]'
                  : '$key') {
                final name when isRedactedKey(name, normalizedRedactKeys) =>
                  redactedMask,
                final name => walk(value, name, depth + 1),
              },
          };
        } finally {
          seen.remove(map);
        }
      case final Iterable<Object?> iterable:
        if (!seen.add(iterable)) return '<cycle>';
        try {
          return [
            for (final element in iterable) walk(element, parent, depth + 1),
          ];
        } finally {
          seen.remove(iterable);
        }
      case null || bool() || num() || String():
        return node;
      case DateTime() || Enum() || BigInt() || Duration()
          when stringifyPlatformLeaves:
        return '$node';
      case final Uri uri when stringifyPlatformLeaves:
        return redactUrlString('$uri', normalizedRedactKeys);
      case final Object object when encodeCustomObject != null:
        return encodeCustomObject(
          object,
          (nested) => walk(nested, parent, depth + 1),
        );
      default:
        return node;
    }
  }

  return walk(data, '', 0);
}

/// Scrubs [text] down to its first line, bounded in time and surrogate-safe:
/// redacts inline URLs (userinfo + [normalizedRedactKeys] or all queries when
/// [stripAllUrlQueries] is `true`) and clips to [maxChars] via [clipString].
String scrubErrorLine(
  String text, {
  int maxChars = defaultMaxErrorChars,
  Set<String> normalizedRedactKeys = const {},
  bool stripAllUrlQueries = false,
}) {
  final lineEnd = text.indexOf('\n');
  var line = lineEnd < 0 ? text : text.substring(0, lineEnd);
  if (line.length > _maxScrubInputChars) {
    var cut = _maxScrubInputChars;
    final last = line.codeUnitAt(cut - 1);
    if (last >= 0xD800 && last <= 0xDBFF) cut--;
    line = line.substring(0, cut);
  }
  final scrubbed = line.contains('://')
      ? redactUrlsInText(
          line,
          normalizedRedactKeys,
          stripAllQueries: stripAllUrlQueries,
        )
      : line;
  return clipString(scrubbed, maxChars);
}

/// Renders [error] as a single safe line prefixed with its `runtimeType`
/// (`TypeName: first line`), falling back to `TypeName` alone if `toString()`
/// throws or yields an empty first line.
///
/// When [preScrub] is provided, it runs over the full `toString()` text before
/// newline cutting so multi-line secrets can be replaced whole first.
String describeErrorFirstLine(
  Object error, {
  int maxChars = defaultMaxErrorChars,
  Set<String> normalizedRedactKeys = const {},
  bool stripAllUrlQueries = false,
  String Function(String text)? preScrub,
}) {
  final type = '${error.runtimeType}';
  try {
    final raw = '$error';
    final line = scrubErrorLine(
      preScrub == null ? raw : preScrub(raw),
      maxChars: maxChars,
      normalizedRedactKeys: normalizedRedactKeys,
      stripAllUrlQueries: stripAllUrlQueries,
    );
    if (line.isEmpty) return type;
    return line.startsWith(type) ? line : '$type: $line';
  } on Object {
    return type;
  }
}
