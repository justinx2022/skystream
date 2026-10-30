/// The media_kit player as the overlaid subtitles' clock.
library;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../../domain/subtitle_playback.dart';

/// Reads the clock straight off the player's state, the way libVLC's adapter
/// reads its controller, and keeps the viewer's delay - which media_kit does
/// not hold for SkyStream's own files - beside it.
///
/// The screen ticks [tick] whenever the engine reports a new position or a
/// state change, so the overlay wakes when the picture does.
class MpvSubtitlePlayback extends ChangeNotifier implements SubtitlePlayback {
  MpvSubtitlePlayback(this._player);

  final Player _player;
  Duration _cachedPosition = Duration.zero;

  /// The delay on its own, for a reader that wants only the delay.
  ///
  /// The overlay has to wake several times a second because lines are timed to
  /// the picture, but the subtitles sheet is not: its rows and its stepper
  /// change only when the viewer changes them. This is the channel the sheet
  /// listens to, so an open sheet does not rebuild its whole list on every
  /// position tick.
  final ValueNotifier<Duration> delayListenable = ValueNotifier<Duration>(
    Duration.zero,
  );

  @override
  Duration get position =>
      _cachedPosition > Duration.zero ? _cachedPosition : _player.state.position;

  @override
  bool get isPlaying => _player.state.playing;

  @override
  double get speed => _player.state.rate;

  @override
  Duration get delay => delayListenable.value;

  /// Sets the delay for both the overlay and the tracks mpv draws itself: a
  /// positive delay shows every line later.
  void setDelay(Duration value) {
    if (value == delayListenable.value) return;
    delayListenable.value = value;
    notifyListeners();
  }

  /// The engine's clock moved, or its playing state did.
  void tick([Duration? currentPosition]) {
    if (currentPosition != null) {
      _cachedPosition = currentPosition;
    } else {
      _cachedPosition = _player.state.position;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    delayListenable.dispose();
    super.dispose();
  }
}
