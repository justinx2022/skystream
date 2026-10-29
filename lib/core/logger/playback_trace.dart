import 'app_logger.dart';

/// Wall-clock stage timings for one playback start.
///
/// The log history is the only diagnostic a release build ships (`/logs`), so
/// a start that feels slow can be read off the device instead of guessed at.
/// Every line begins with `[perf]` and the same `<label> · <stage>` shape, so
/// filtering the log screen for `[perf]` shows the stages in order.
///
/// Laps are absolute since the trace was created, not since the previous lap:
/// the gaps are what a slow start is made of, and a reader should not have to
/// subtract.
class PlaybackTrace {
  PlaybackTrace(this.label) : _watch = Stopwatch()..start();

  final String label;
  final Stopwatch _watch;

  int get elapsedMs => _watch.elapsedMilliseconds;

  /// Records [stage] as a milestone, e.g. resolution answering.
  void lap(String stage, [String detail = '']) {
    talker.info('[perf] $label · $stage ${elapsedMs}ms${_detail(detail)}');
  }

  /// Records [stage] as a problem: a retry, a failure, a failover.
  void warn(String stage, [String detail = '']) {
    talker.warning('[perf] $label · $stage ${elapsedMs}ms${_detail(detail)}');
  }

  String _detail(String detail) => detail.isEmpty ? '' : ' · $detail';
}
