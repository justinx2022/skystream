/// What an overlaid subtitle file times its lines off, whichever engine is
/// playing underneath.
///
/// SkyStream draws subtitle files itself (`subtitle_cues.dart` says why), so
/// the drawing code needs a clock and nothing else: where playback is, whether
/// it is running, how fast, and the delay the viewer set. libVLC reports those
/// through its controller and media_kit through its player state, so each
/// adapter in the presentation layer implements this and the renderer is
/// written once.
library;

import 'package:flutter/foundation.dart';

abstract interface class SubtitlePlayback implements Listenable {
  /// Where playback is, as the engine last reported it.
  Duration get position;

  /// Whether the picture is moving.
  bool get isPlaying;

  /// How fast it is moving, so the overlay can run on at the same rate between
  /// the engine's reports.
  double get speed;

  /// A positive delay shows every line later.
  Duration get delay;
}
