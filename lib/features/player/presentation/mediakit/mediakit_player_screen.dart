import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../domain/playback_progress.dart';
import '../../domain/playback_tracker.dart';
import '../../domain/stream_resolver.dart';
import '../vlc/player_startup_view.dart';

/// High-Performance Desktop Player Engine powered by `media_kit` (libmpv).
///
/// Provides zero-copy Direct3D 11 GPU surface sharing, native hardware decoding
/// (D3D11VA/DXVA2), and HDR tone mapping on Windows with near-zero CPU overhead.
class MediaKitPlayerScreen extends ConsumerStatefulWidget {
  final MultimediaItem item;
  final String videoUrl;
  final Episode? episode;
  final List<StreamResult>? preloadedStreams;

  const MediaKitPlayerScreen({
    super.key,
    required this.item,
    required this.videoUrl,
    this.episode,
    this.preloadedStreams,
  });

  @override
  ConsumerState<MediaKitPlayerScreen> createState() => _MediaKitPlayerScreenState();
}

class _MediaKitPlayerScreenState extends ConsumerState<MediaKitPlayerScreen> {
  late final Player _player;
  late final VideoController _videoController;

  bool _disposed = false;
  bool _isLoading = true;
  String _error = '';
  List<StreamResult> _candidates = const [];
  ResolvedPlayback? _resolved;
  int _attemptIndex = 0;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _playing = false;
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;
  double _playbackSpeed = 1.0;
  bool _isFullscreen = false;

  PlaybackProgressRecorder? _recorder;
  PlaybackTracker? _tracker;
  int _token = 0;
  DateTime _lastProgressSave = DateTime.now();

  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();

    _player = Player(
      configuration: PlayerConfiguration(
        title: 'SkyStream Desktop',
        bufferSize: 64 * 1024 * 1024, // 64 MB ring buffer
        logLevel: MPVLogLevel.error,
      ),
    );

    _videoController = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    _applyMpvOptimizations();
    _listenPlayerStreams();
    _startPlayback();
    _startControlsTimer();
  }

  Future<void> _applyMpvOptimizations() async {
    if (_player.platform is NativePlayer) {
      final native = _player.platform as NativePlayer;
      try {
        await native.setProperty('hwdec', 'auto-safe');
        await native.setProperty('vo', 'gpu-next');
        await native.setProperty('demuxer-max-bytes', '67108864');
        await native.setProperty('demuxer-readahead-secs', '15');
        await native.setProperty('audio-pitch-correction', 'yes');
      } catch (e) {
        if (kDebugMode) debugPrint('[MediaKit] Error configuring mpv properties: $e');
      }
    }
  }

  void _listenPlayerStreams() {
    _player.stream.position.listen((pos) {
      if (_disposed || !mounted) return;
      setState(() => _position = pos);
      _maybeRecordProgress(pos);
    });

    _player.stream.duration.listen((dur) {
      if (_disposed || !mounted) return;
      setState(() => _duration = dur);
    });

    _player.stream.buffer.listen((buf) {
      if (_disposed || !mounted) return;
      setState(() => _buffer = buf);
    });

    _player.stream.playing.listen((isPlaying) {
      if (_disposed || !mounted) return;
      setState(() {
        _playing = isPlaying;
        if (isPlaying) _isLoading = false;
      });
    });

    _player.stream.completed.listen((completed) {
      if (_disposed || !mounted) return;
      if (completed) {
        // Auto-save completion
        _recordFinalProgress();
      }
    });

    _player.stream.error.listen((err) {
      if (_disposed || !mounted) return;
      if (kDebugMode) debugPrint('[MediaKit] Player Error: $err');
      _failoverNext();
    });
  }

  Future<void> _startPlayback() async {
    setState(() {
      _isLoading = true;
      _error = '';
    });

    try {
      final resumeLookup = resolveResumePoint(
        read: ref.read,
        item: widget.item,
        episode: widget.episode,
        videoUrl: widget.videoUrl,
      );

      final localResume = resumePointFor(
        read: ref.read,
        item: widget.item,
        episode: widget.episode,
        videoUrl: widget.videoUrl,
      );

      ResumePoint? resumePoint = localResume;
      try {
        resumePoint = await resumeLookup.timeout(
          const Duration(milliseconds: 300),
          onTimeout: () => localResume,
        );
      } catch (_) {
        resumePoint = localResume;
      }

      final resolved = await resolvePlayback(
        read: ref.read,
        item: widget.item,
        videoUrl: widget.videoUrl,
        preloadedStreams: widget.preloadedStreams,
        probeCandidates: 1,
        probeBudget: const Duration(milliseconds: 1200),
        isCancelled: () => _disposed,
        onCandidates: (streams) {
          if (mounted) setState(() => _candidates = streams);
        },
      );

      if (_disposed) return;
      _resolved = resolved;
      _candidates = resolved.streams;
      _attemptIndex = resolved.index;

      _token++;
      _recorder = PlaybackProgressRecorder(
        read: ref.read,
        item: widget.item,
        episode: widget.episode,
        videoUrl: widget.videoUrl,
        token: _token,
      );

      _tracker = PlaybackTracker(
        read: ref.read,
        item: widget.item,
        episode: widget.episode,
        videoUrl: widget.videoUrl,
        token: _token,
      );

      final startPosition = resumePoint?.position ?? Duration.zero;
      await _openCandidate(_attemptIndex, startAt: startPosition);
    } catch (e) {
      if (_disposed || !mounted) return;
      setState(() {
        _isLoading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _openCandidate(int index, {Duration startAt = Duration.zero}) async {
    final streams = _resolved?.streams ?? _candidates;
    if (index >= streams.length) {
      setState(() {
        _isLoading = false;
        _error = 'All available sources failed to play.';
      });
      return;
    }

    _attemptIndex = index;
    final stream = streams[index];

    try {
      final media = Media(
        stream.url,
        httpHeaders: (stream.headers != null && stream.headers!.isNotEmpty)
            ? stream.headers
            : null,
        start: startAt > Duration.zero ? startAt : null,
      );

      await _player.open(media);
      if (_disposed || !mounted) return;

      setState(() => _isLoading = false);
    } catch (e) {
      if (kDebugMode) debugPrint('[MediaKit] Failed to open stream $index: $e');
      _failoverNext();
    }
  }

  void _failoverNext() {
    final streams = _resolved?.streams ?? _candidates;
    if (_attemptIndex + 1 < streams.length) {
      _openCandidate(_attemptIndex + 1, startAt: _position);
    } else {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Playback failed. No more available streams.';
        });
      }
    }
  }

  void _maybeRecordProgress(Duration pos) {
    final now = DateTime.now();
    if (now.difference(_lastProgressSave).inSeconds >= 5) {
      _lastProgressSave = now;
      final dur = _duration;
      if (dur > Duration.zero) {
        final sample = ProgressSample(
          position: pos,
          duration: dur,
          token: _token,
        );
        final streams = _resolved?.streams ?? _candidates;
        final currentUrl = streams.isNotEmpty ? streams[_attemptIndex].url : null;
        _recorder?.record(sample, lastStreamUrl: currentUrl);
        _tracker?.onPlaying(sample);
      }
    }
  }

  void _recordFinalProgress() {
    final dur = _duration;
    if (dur > Duration.zero) {
      final sample = ProgressSample(
        position: _position,
        duration: dur,
        token: _token,
      );
      final streams = _resolved?.streams ?? _candidates;
      final currentUrl = streams.isNotEmpty ? streams[_attemptIndex].url : null;
      _recorder?.record(sample, lastStreamUrl: currentUrl, force: true);
      _tracker?.finish();
    }
  }

  void _startControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _onUserActivity() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _startControlsTimer();
  }

  void _togglePlayPause() {
    _onUserActivity();
    _player.playOrPause();
  }

  void _seekRelative(int seconds) {
    _onUserActivity();
    final newPos = _position + Duration(seconds: seconds);
    final clamped = newPos < Duration.zero
        ? Duration.zero
        : (newPos > _duration ? _duration : newPos);
    _player.seek(clamped);
  }

  Future<void> _toggleFullscreen() async {
    _onUserActivity();
    final isFull = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!isFull);
    if (mounted) {
      setState(() => _isFullscreen = !isFull);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _hideControlsTimer?.cancel();
    _recordFinalProgress();
    _tracker?.finish();
    _player.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.space) {
      _togglePlayPause();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _seekRelative(10);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _seekRelative(-10);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_isFullscreen) {
        _toggleFullscreen();
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final playerSettings = ref.watch(playerSettingsProvider).asData?.value;
    final stremioTheme = playerSettings?.stremioLoadScreen ?? true;
    final seamlessMode = playerSettings?.seamlessPlayback ?? true;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: MouseRegion(
          onHover: (_) => _onUserActivity(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _togglePlayPause,
            onDoubleTap: _toggleFullscreen,
            child: Stack(
              children: [
                // Zero-Copy Direct3D 11 Video Texture
                Center(
                  child: Video(
                    controller: _videoController,
                    fit: BoxFit.contain,
                    controls: NoVideoControls,
                  ),
                ),

                // Seamless / Stremio Startup Overlay
                if (_isLoading || _error.isNotEmpty)
                  PlayerStartupView(
                    title: widget.item.title,
                    onPick: (index) => _openCandidate(index),
                    episodeLine: widget.episode != null
                        ? 'S${widget.episode!.season} E${widget.episode!.episode} - ${widget.episode!.name}'
                        : null,
                    logoUrl: widget.item.logoUrl,
                    backdropUrl: widget.item.backdropImageUrl,
                    sourceName: _candidates.isNotEmpty
                        ? _candidates[_attemptIndex].source
                        : null,
                    status: _isLoading ? 'Loading high-performance stream…' : null,
                    reason: _error.isNotEmpty ? _error : null,
                    failed: _error.isNotEmpty,
                    attempt: _candidates.isNotEmpty
                        ? (index: _attemptIndex + 1, total: _candidates.length)
                        : null,
                    onBack: () => Navigator.of(context).maybePop(),
                    onRetry: _startPlayback,
                    stremioTheme: stremioTheme,
                    seamlessMode: seamlessMode,
                  ),

                // Desktop Controls Layer
                if (!_isLoading && _error.isEmpty)
                  AnimatedOpacity(
                    opacity: _controlsVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: Stack(
                        children: [
                          _buildTopBar(),
                          _buildBottomBar(),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.8),
              Colors.transparent,
            ],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.item.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (widget.episode != null)
                    Text(
                      'S${widget.episode!.season} E${widget.episode!.episode} — ${widget.episode!.name}',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'Direct3D 11 GPU',
                style: TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final posText = _formatDuration(_position);
    final durText = _formatDuration(_duration);

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withValues(alpha: 0.85),
              Colors.transparent,
            ],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Seek bar
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: Theme.of(context).colorScheme.primary,
                inactiveTrackColor: Colors.white24,
                thumbColor: Theme.of(context).colorScheme.primary,
              ),
              child: Slider(
                value: _duration.inMilliseconds > 0
                    ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
                    : 0.0,
                onChanged: (val) {
                  _onUserActivity();
                  final target = Duration(
                    milliseconds: (val * _duration.inMilliseconds).toInt(),
                  );
                  _player.seek(target);
                },
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                  onPressed: _togglePlayPause,
                ),
                IconButton(
                  icon: const Icon(Icons.replay_10_rounded, color: Colors.white70, size: 26),
                  onPressed: () => _seekRelative(-10),
                ),
                IconButton(
                  icon: const Icon(Icons.forward_10_rounded, color: Colors.white70, size: 26),
                  onPressed: () => _seekRelative(10),
                ),
                const SizedBox(width: 12),
                Text(
                  '$posText / $durText',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const Spacer(),
                TextButton(
                  child: Text(
                    '${_playbackSpeed}x',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  onPressed: () {
                    _onUserActivity();
                    final speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
                    final idx = speeds.indexOf(_playbackSpeed);
                    final next = speeds[(idx + 1) % speeds.length];
                    setState(() => _playbackSpeed = next);
                    _player.setRate(next);
                  },
                ),
                IconButton(
                  icon: Icon(
                    _isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                  onPressed: _toggleFullscreen,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}
