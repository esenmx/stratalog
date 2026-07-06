import 'package:chirp/chirp.dart';
import 'package:riverpod/experimental/mutation.dart';
import 'package:riverpod/riverpod.dart';

/// Central Riverpod observability.
/// Implements all observer hooks, printing clear transitions and full
/// `Mutation` lifecycle events with structured properties.
///
/// ```dart
/// ProviderScope(observers: [RiverpodLogger(LogLayer.state)], child: app)
/// ```
final class RiverpodLogger extends ProviderObserver {
  /// Logs observer events to [logger], typically `LogLayer.state`.
  const RiverpodLogger(this.logger, {this.maxValueLength = 200});

  /// Destination layer logger.
  final ChirpLogger logger;

  /// State `toString()`s beyond this length are ellipsized — a fat entity
  /// list rebuilding every frame must not drown the console. Set `null` to
  /// disable.
  final int? maxValueLength;

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    logger.trace('+ ${context.name} | initial: ${_short(value)}');
  }

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    logger.trace(
      '~ ${context.name} | ${_short(previousValue)} ➔ ${_short(newValue)}',
    );
  }

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    logger.trace('- ${context.name}');
  }

  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    // Exception = expected/recoverable -> warning; Error = programming bug.
    if (error is Exception) {
      logger.warning('✗ ${context.name}', error: error, stackTrace: stackTrace);
    } else {
      logger.error('✗ ${context.name}', error: error, stackTrace: stackTrace);
    }
  }

  @override
  void mutationStart(
    ProviderObserverContext context,
    Mutation<Object?> mutation,
  ) {
    logger.trace('⚡ ${mutation.key} | mutation start: ${_describe(mutation)}');
  }

  @override
  void mutationSuccess(
    ProviderObserverContext context,
    Mutation<Object?> mutation,
    Object? result,
  ) {
    logger.trace(
      '⚡ ${mutation.key} | mutation success: '
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
    final desc = '⚡ ${mutation.key} | mutation error: ${_describe(mutation)}';
    if (error is Exception) {
      logger.warning(desc, error: error, stackTrace: stackTrace);
    } else {
      logger.error(desc, error: error, stackTrace: stackTrace);
    }
  }

  @override
  void mutationReset(
    ProviderObserverContext context,
    Mutation<Object?> mutation,
  ) {
    logger.trace('⚡ ${mutation.key} | mutation reset: ${_describe(mutation)}');
  }

  String _describe(Mutation<Object?> mutation) {
    final label = mutation.label ?? mutation.runtimeType;
    final key = mutation.key;
    return key != null ? '$label(key: $key)' : '$label';
  }

  String _short(Object? value) {
    final s = '$value';
    final max = maxValueLength;
    if (max == null || s.length <= max) return s;
    return '${s.substring(0, max)}…(+${s.length - max} chars)';
  }
}

extension on ProviderObserverContext {
  String get name => provider.name ?? '${provider.runtimeType}';
}
