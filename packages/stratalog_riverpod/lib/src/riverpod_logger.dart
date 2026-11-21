import 'package:riverpod/experimental/mutation.dart';
import 'package:riverpod/riverpod.dart';
import 'package:stratalog/stratalog.dart';

/// Central Riverpod observability.
/// Implements all observer hooks, printing clear transitions and full
/// `Mutation` lifecycle events with structured properties.
///
/// ```dart
/// ProviderScope(observers: [RiverpodLogger()], child: app)
/// ```
final class const RiverpodLogger({
  /// Destination layer.
  final LogLayer logger = .state,

  /// State `toString()`s beyond this length are ellipsized — a fat entity
  /// list rebuilding every frame must not drown the console. Set `null` to
  /// disable.
  final int? maxValueLength = 800,
}) extends ProviderObserver {
  /// Logs observer events to [logger], typically `LogLayer.state`.
  this;

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    logger.trace('✚ add ${_name(context)} | initial: ${_short(value)}');
  }

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    logger.trace(
      '↻ update ${_name(context)} | '
      '${_short(previousValue)} ➔ ${_short(newValue)}',
    );
  }

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    logger.trace('⊘ dispose ${_name(context)}');
  }

  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    logger.log(
      '✗ ${_name(context)}',
      // Exception = expected/recoverable -> warning; Error = programming bug.
      level: error is Exception ? .warning : .error,
      error: error,
      stackTrace: stackTrace,
    );
  }

  @override
  void mutationStart(
    ProviderObserverContext context,
    Mutation<Object?> mutation,
  ) {
    logger.trace(
      '⚡ ${_name(context)} | mutation start: ${_describe(mutation)}',
    );
  }

  @override
  void mutationSuccess(
    ProviderObserverContext context,
    Mutation<Object?> mutation,
    Object? result,
  ) {
    logger.trace(
      '⚡ ${_name(context)} | mutation success: '
      '${_describe(mutation)} ➔ ${_short(result)}',
    );
  }

  @override
  void mutationError(
    ProviderObserverContext context,
    Mutation<Object?> mutation,
    Object error,
    StackTrace stackTrace,
  ) {
    logger.log(
      '⚡ ${_name(context)} | mutation error: ${_describe(mutation)}',
      level: error is Exception ? .warning : .error,
      error: error,
      stackTrace: stackTrace,
    );
  }

  @override
  void mutationReset(
    ProviderObserverContext context,
    Mutation<Object?> mutation,
  ) {
    logger.trace(
      '⚡ ${_name(context)} | mutation reset: ${_describe(mutation)}',
    );
  }

  static String _name(ProviderObserverContext context) =>
      context.provider.name ?? '${context.provider.runtimeType}';

  String _describe(Mutation<Object?> mutation) {
    final label = mutation.label ?? mutation.runtimeType;
    final key = mutation.key;
    return key != null ? '$label(key: $key)' : '$label';
  }

  String _short(Object? value) {
    final max = maxValueLength;
    final s = '$value';
    return max == null ? s : clipString(s, max);
  }
}
