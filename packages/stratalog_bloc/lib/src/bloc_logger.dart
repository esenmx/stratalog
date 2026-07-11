import 'package:bloc/bloc.dart';
import 'package:stratalog/stratalog.dart';

/// Central bloc observability — mirrors `stratalog_riverpod`'s format:
///
/// ```dart
/// Bloc.observer = const BlocLogger(LogLayer.state);
/// ```
final class BlocLogger extends BlocObserver {
  /// Logs observer events to [logger], typically `LogLayer.state`.
  const BlocLogger(this.logger, {this.maxValueLength = 800});

  /// Destination layer.
  final LogLayer logger;

  /// State/event `toString()`s beyond this length are ellipsized — a fat
  /// entity list rebuilding every frame must not drown the console. Set
  /// `null` to disable.
  final int? maxValueLength;

  @override
  void onCreate(BlocBase<dynamic> bloc) {
    logger.trace('+ ${bloc.runtimeType} | initial: ${_short(bloc.state)}');
    super.onCreate(bloc);
  }

  @override
  void onEvent(Bloc<dynamic, dynamic> bloc, Object? event) {
    logger.trace('⚡ ${bloc.runtimeType} | event: ${_short(event)}');
    super.onEvent(bloc, event);
  }

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    // Blocs log richer transitions (with the event) via [onTransition];
    // logging both would duplicate every state change.
    if (bloc is! Bloc) {
      logger.trace(
        '~ ${bloc.runtimeType} | '
        '${_short(change.currentState)} ➔ ${_short(change.nextState)}',
      );
    }
    super.onChange(bloc, change);
  }

  @override
  void onTransition(
    Bloc<dynamic, dynamic> bloc,
    Transition<dynamic, dynamic> transition,
  ) {
    logger.trace(
      '~ ${bloc.runtimeType} | ${_short(transition.event)}: '
      '${_short(transition.currentState)} ➔ ${_short(transition.nextState)}',
    );
    super.onTransition(bloc, transition);
  }

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    // Exception = expected/recoverable -> warning; Error = programming bug.
    if (error is Exception) {
      logger.warning(
        '✗ ${bloc.runtimeType}',
        error: error,
        stackTrace: stackTrace,
      );
    } else {
      logger.error(
        '✗ ${bloc.runtimeType}',
        error: error,
        stackTrace: stackTrace,
      );
    }
    super.onError(bloc, error, stackTrace);
  }

  @override
  void onClose(BlocBase<dynamic> bloc) {
    logger.trace('- ${bloc.runtimeType}');
    super.onClose(bloc);
  }

  String _short(Object? value) {
    final max = maxValueLength;
    final s = '$value';
    return max == null ? s : clipString(s, max);
  }
}
