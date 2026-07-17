import 'package:chirp/chirp.dart';

/// Field names whose values [elideJson] / [elideData] keep verbatim — small,
/// vital identifiers you always want to read in full even when the payload
/// around them is elided. Override per call for your own domain keys.
///
/// Keys here bypass every cap, so reserve them for fields expected to be
/// short (ids, status codes) — not free-text that could itself be a blob.
const Set<String> defaultKeepKeys = {
  'id',
  'uuid',
  'guid',
  'name',
  'slug',
  'status',
  'state',
  'code',
  'type',
  'kind',
};

/// Shortens a scalar string for log display — head kept, dropped remainder
/// noted as `…(+N chars)`. The single home for the truncation idiom every
/// adapter used to copy-paste.
///
/// Won't sever a UTF-16 surrogate pair: a lone high surrogate at the cut
/// renders as a replacement glyph, so the cut backs off one code unit.
String clipString(String s, int max) {
  if (s.length <= max || max <= 0) return s;
  var end = max;
  final last = s.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end -= 1;
  return '${s.substring(0, end)}…(+${s.length - end} chars)';
}

/// Structure-preserving elision for decoded JSON (or any Map/List/scalar
/// tree). Recurses [value] and clips only oversized *leaves*, so every key
/// survives and a `JsonEncoder` still pretty-prints the result:
///
/// - long strings → [clipString] at [maxStringChars];
/// - base64/binary blobs → `<N-char blob elided>`, never dumped;
/// - lists longer than [maxArrayItems] → head + `…(+N more)`;
/// - keys in [keepKeys] → value kept verbatim.
///
/// Unlike a per-payload tail-chop, no single large leaf can evict its
/// siblings, and the field you opened the log for is always present.
Object? elideJson(
  Object? value, {
  int maxStringChars = _defaultMaxStringChars,
  int maxArrayItems = _defaultMaxArrayItems,
  Set<String> keepKeys = defaultKeepKeys,
}) {
  switch (value) {
    case final Map<Object?, Object?> map:
      return {
        for (final MapEntry(:key, :value) in map.entries)
          key: keepKeys.contains(key)
              ? value
              : elideJson(
                  value,
                  maxStringChars: maxStringChars,
                  maxArrayItems: maxArrayItems,
                  keepKeys: keepKeys,
                ),
      };
    case final Iterable<Object?> iterable:
      final out = <Object?>[
        for (final e in iterable.take(maxArrayItems))
          elideJson(
            e,
            maxStringChars: maxStringChars,
            maxArrayItems: maxArrayItems,
            keepKeys: keepKeys,
          ),
      ];
      if (iterable.length > maxArrayItems) {
        out.add('…(+${iterable.length - maxArrayItems} more)');
      }
      return out;
    case final String s when _looksBinary(s):
      return '<${s.length}-char blob elided>';
    case final String s:
      return clipString(s, maxStringChars);
    default:
      return value; // num, bool, null — cheap, keep verbatim
  }
}

/// [elideJson] specialised to a record's `data` map — returns a typed
/// `Map<String, Object?>` for [ChirpFormatter]s and the crash breadcrumb
/// path. Top-level [keepKeys] apply here too.
Map<String, Object?> elideData(
  Map<String, Object?> data, {
  int maxStringChars = _defaultMaxStringChars,
  int maxArrayItems = _defaultMaxArrayItems,
  Set<String> keepKeys = defaultKeepKeys,
}) {
  return {
    for (final MapEntry(:key, :value) in data.entries)
      key: keepKeys.contains(key)
          ? value
          : elideJson(
              value,
              maxStringChars: maxStringChars,
              maxArrayItems: maxArrayItems,
              keepKeys: keepKeys,
            ),
  };
}

/// Cheap heuristic: a long, near-pure base64/hex/data-URI run is a blob
/// (avatar, token, embedded file) that bloats logs and reads as noise.
/// Strings under [_blobMinChars] are always shown — normal prose has spaces
/// and punctuation, so it never crosses the threshold.
bool _looksBinary(String s) {
  if (s.startsWith('data:') && s.length > 64) return true;
  if (s.length < _blobMinChars) return false;
  final sample = s.length < 4096 ? s.length : 4096;
  var blobbish = 0;
  for (var i = 0; i < sample; i++) {
    final c = s.codeUnitAt(i);
    final isBlobChar =
        (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        (c >= 0x30 && c <= 0x39) || // 0-9
        c == 0x2B ||
        c == 0x2F ||
        c == 0x3D || // + / =
        c == 0x2D ||
        c == 0x5F; // - _  (url-safe base64)
    if (isBlobChar) blobbish++;
  }
  return blobbish / sample > 0.97;
}

const int _blobMinChars = 512;

// Single home for the default budget, shared by every ctor/signature above
// and below — the literals must never fork between entry points.
const int _defaultMaxStringChars = 1024;
const int _defaultMaxArrayItems = 32;

/// Elision budget shared by [ElidingFormatter] and `configureLogging`.
final class ElisionConfig {
  /// A budget; see [ElidingFormatter] for what each field caps.
  const ElisionConfig({
    this.maxStringChars = _defaultMaxStringChars,
    this.maxArrayItems = _defaultMaxArrayItems,
    this.keepKeys = defaultKeepKeys,
  }) : enabled = true;

  // Budget fields are never read when disabled — format() short-circuits on
  // `enabled` before touching them.
  const ElisionConfig._disabled()
    : enabled = false,
      maxStringChars = _defaultMaxStringChars,
      maxArrayItems = _defaultMaxArrayItems,
      keepKeys = defaultKeepKeys;

  /// Elision switched off entirely — the payload passes verbatim. For layers
  /// whose JSON is a copy-out artifact (network bodies, storage rows) where
  /// any `…(+N chars)` marker would corrupt the paste.
  static const ElisionConfig none = ._disabled();

  /// Tight budget for chatty layers: payloads clip hard to their vital
  /// fields — [defaultKeepKeys] stay verbatim, everything else shrinks.
  static const ElisionConfig vital = ElisionConfig(
    maxStringChars: 200,
    maxArrayItems: 8,
  );

  /// Whether elision runs at all; `false` forwards records untouched.
  final bool enabled;

  /// Per-leaf string cap passed to [clipString].
  final int maxStringChars;

  /// Lists longer than this keep their head plus a `…(+N more)` marker.
  final int maxArrayItems;

  /// Keys kept verbatim, exempt from every cap.
  final Set<String> keepKeys;
}

/// Per-layer elision defaults for `configureLogging`, keyed by
/// `record.loggerName` (precedent: `LogPalette.domains`): Network and Storage
/// payloads are copy-out artifacts — JSON you paste into tools — so they pass
/// verbatim; State is chatty, so it clips to vital fields.
const Map<String, ElisionConfig> defaultLayerElision = {
  'Network': .none,
  'Storage': .none,
  'State': .vital,
};

/// Wraps any [ChirpFormatter] to elide `record.data` before it renders — the
/// single place structure-aware truncation lives, composable over the
/// console, a release sink, or an in-app viewer.
///
/// Producers (e.g. the Dio interceptor) pass full payloads; each sink picks
/// its own budget, so a viewer can retain the full body while the console
/// stays lean — two-tier logging without the producer choosing for everyone.
final class ElidingFormatter extends ChirpFormatter {
  /// Elides `record.data` for [inner] using the given budget.
  ElidingFormatter(
    this.inner, {
    this.maxStringChars = _defaultMaxStringChars,
    this.maxArrayItems = _defaultMaxArrayItems,
    this.keepKeys = defaultKeepKeys,
    this.layerElision = const {},
  }) : enabled = true;

  /// Wraps [inner] with the budget carried by [config] — including its
  /// [ElisionConfig.enabled] flag, so `.of(inner, ElisionConfig.none)`
  /// passes every unlisted layer verbatim.
  ElidingFormatter.of(
    this.inner,
    ElisionConfig config, {
    this.layerElision = const {},
  }) : enabled = config.enabled,
       maxStringChars = config.maxStringChars,
       maxArrayItems = config.maxArrayItems,
       keepKeys = config.keepKeys;

  /// The formatter that renders the elided record.
  final ChirpFormatter inner;

  /// Whether the instance budget elides at all; a [layerElision] entry
  /// overrides this per layer in either direction.
  final bool enabled;

  /// Budget overrides keyed by `record.loggerName`. A listed layer uses its
  /// own budget — or, with [ElisionConfig.none], passes verbatim; unlisted
  /// layers fall back to the instance budget. See [defaultLayerElision].
  final Map<String, ElisionConfig> layerElision;

  /// Per-leaf string cap passed to [clipString].
  final int maxStringChars;

  /// Lists longer than this keep their head plus a `…(+N more)` marker.
  final int maxArrayItems;

  /// Keys kept verbatim, exempt from every cap.
  final Set<String> keepKeys;

  @override
  bool get requiresCallerInfo => inner.requiresCallerInfo;

  @override
  String get recordSeparator => inner.recordSeparator;

  @override
  void format(LogRecord record, MessageBuffer buffer) {
    if (record.data.isEmpty) {
      inner.format(record, buffer);
      return;
    }
    final config = layerElision[record.loggerName];
    if (!(config?.enabled ?? enabled)) {
      inner.format(record, buffer);
      return;
    }
    inner.format(
      record.copyWith(
        data: elideData(
          record.data,
          maxStringChars: config?.maxStringChars ?? maxStringChars,
          maxArrayItems: config?.maxArrayItems ?? maxArrayItems,
          keepKeys: config?.keepKeys ?? keepKeys,
        ),
      ),
      buffer,
    );
  }
}
