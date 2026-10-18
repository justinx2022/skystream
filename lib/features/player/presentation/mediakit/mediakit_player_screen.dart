import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/network/http_defaults.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../domain/playback_progress.dart';
import '../../domain/playback_tracker.dart';
import '../../domain/stream_resolver.dart';
import '../../domain/episode_navigator.dart';
import '../vlc/next_episode_countdown.dart';
import '../vlc/player_startup_view.dart';
import '../widgets/player_stream_widgets.dart';

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

  late String _currentVideoUrl;
  Episode? _currentEpisode;
  Episode? _nextEpisodeOffer;
  bool _nextEpisodeDeclined = false;

  final List<StreamSubscription> _subscriptions = [];
  Timer? _bufferPollTimer;
  Duration? _dragPosition;
  bool _isDragging = false;

  bool _disposed = false;
  bool _isLoading = true;
  bool _isBuffering = false;
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
  BoxFit _fit = BoxFit.contain;

  PlaybackProgressRecorder? _recorder;
  PlaybackTracker? _tracker;
  int _token = 0;
  DateTime _lastProgressSave = DateTime.now();

  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();

    if (!kIsWeb && Platform.isAndroid) {
      try {
        WakelockPlus.enable();
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } catch (_) {}
    }

    _currentVideoUrl = widget.videoUrl;
    _currentEpisode = widget.episode;

    _player = Player(
      configuration: PlayerConfiguration(
        title: 'SkyStream',
        bufferSize: 64 * 1024 * 1024, // 64 MB ring buffer (fast & safe for mobile & desktop)
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

    _bufferPollTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => _updateBufferFromNative(),
    );
  }

  Future<void> _applyMpvOptimizations() async {
    if (_player.platform is NativePlayer) {
      final native = _player.platform as NativePlayer;
      try {
        await native.setProperty('hwdec', 'auto-safe');

        // Fast GPU Scaling & Low-Overhead Shaders (Optimized for Intel UHD & Mobile GPUs)
        await native.setProperty('scale', 'bilinear');
        await native.setProperty('dscale', 'bilinear');
        await native.setProperty('cscale', 'bilinear');
        await native.setProperty('correct-downscaling', 'no');
        await native.setProperty('linear-downscaling', 'no');
        await native.setProperty('sigmoid-upscaling', 'no');

        // Lightweight HDR Tone Mapping (Mobius curve, skip full-frame compute shader)
        await native.setProperty('tone-mapping', 'mobius');
        await native.setProperty('tone-mapping-compute-peak', 'no');

        // Direct Decoder Rendering into surface & Smart Frame Dropping
        await native.setProperty('vd-lavc-dr', 'yes');
        await native.setProperty('framedrop', 'vo');
        await native.setProperty('video-sync', 'audio');

        // Aggressive Cache & Demuxer tuning for high-speed streaming
        await native.setProperty('cache', 'yes');
        await native.setProperty('cache-secs', '60');
        await native.setProperty('demuxer-max-bytes', '67108864'); // 64 MB buffer
        await native.setProperty('demuxer-readahead-secs', '60');

        await native.setProperty('audio-pitch-correction', 'yes');
        await native.setProperty('user-agent', kDefaultBrowserUserAgent);
      } catch (e) {
        if (kDebugMode) debugPrint('[MediaKit] Error configuring mpv properties: $e');
      }
    }
  }

  Future<void> _updateBufferFromNative() async {
    if (_disposed || !mounted) return;
    if (_player.platform is NativePlayer) {
      final native = _player.platform as NativePlayer;
      try {
        final cacheSecStr = await native.getProperty('demuxer-cache-time');
        if (cacheSecStr != null) {
          final secs = double.tryParse(cacheSecStr.toString());
          if (secs != null && secs > 0) {
            final cacheDur = Duration(milliseconds: (secs * 1000).toInt());
            if (mounted && cacheDur != _buffer) {
              setState(() => _buffer = cacheDur);
            }
          }
        }
      } catch (_) {}
    }
  }

  Episode? get _nextEpisode {
    final lookup = nextEpisodeFor(
      item: widget.item,
      current: _currentEpisode,
      videoUrl: _currentVideoUrl,
    );
    return lookup.next;
  }

  Episode? get _previousEpisode {
    return previousEpisodeFor(
      item: widget.item,
      current: _currentEpisode,
      videoUrl: _currentVideoUrl,
    );
  }

  bool get _hasNextEpisode => _nextEpisode != null;
  bool get _hasPreviousEpisode => _previousEpisode != null;

  Future<void> _advance() async {
    final next = _nextEpisode;
    if (next == null) return;
    _tracker?.finish();
    rollForwardHistory(read: ref.read, item: widget.item, next: next);
    await _startEpisode(next);
  }

  Future<void> _startEpisode(Episode next) async {
    _recorder?.record(
      ProgressSample(position: _position, duration: _duration, token: _token),
      force: true,
    );
    _tracker?.finish();
    _player.stop();

    setState(() {
      _currentEpisode = next;
      _currentVideoUrl = next.url;
      _position = Duration.zero;
      _duration = Duration.zero;
      _buffer = Duration.zero;
      _isLoading = true;
      _error = '';
      _candidates = const [];
      _resolved = null;
      _attemptIndex = 0;
      _nextEpisodeOffer = null;
      _nextEpisodeDeclined = false;
    });

    await _startPlayback();
  }

  void _listenPlayerStreams() {
    _subscriptions.add(
      _player.stream.position.listen((pos) {
        if (_disposed || !mounted) return;
        setState(() => _position = pos);
        _maybeRecordProgress(pos);

        // Offer Next Episode in the final 35 seconds of the episode
        if (_hasNextEpisode && !_nextEpisodeDeclined && _duration > const Duration(minutes: 5)) {
          final remaining = _duration - pos;
          if (remaining > Duration.zero && remaining <= const Duration(seconds: 35)) {
            if (_nextEpisodeOffer == null) {
              setState(() => _nextEpisodeOffer = _nextEpisode);
            }
          }
        }
      }),
    );

    _subscriptions.add(
      _player.stream.duration.listen((dur) {
        if (_disposed || !mounted) return;
        setState(() => _duration = dur);
      }),
    );

    _subscriptions.add(
      _player.stream.buffer.listen((buf) {
        if (_disposed || !mounted) return;
        setState(() => _buffer = buf);
      }),
    );

    _subscriptions.add(
      _player.stream.playing.listen((isPlaying) {
        if (_disposed || !mounted) return;
        setState(() {
          _playing = isPlaying;
          if (isPlaying) {
            _isLoading = false;
            _isBuffering = false;
          }
        });
      }),
    );

    _subscriptions.add(
      _player.stream.buffering.listen((isBuffering) {
        if (_disposed || !mounted) return;
        setState(() => _isBuffering = isBuffering);
      }),
    );

    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (_disposed || !mounted) return;
        if (completed) {
          _recordFinalProgress();
          if (_hasNextEpisode && !_nextEpisodeDeclined) {
            _advance();
          }
        }
      }),
    );

    _subscriptions.add(
      _player.stream.error.listen((err) {
        if (_disposed || !mounted) return;
        if (kDebugMode) debugPrint('[MediaKit] Player Error: $err');
        _failoverNext();
      }),
    );
  }

  double get _bufferRatio {
    if (_duration.inMilliseconds <= 0) return 0.0;
    // mpv reports buffer either as forward duration ahead or absolute timestamp
    Duration bufferedEnd = _buffer;
    if (_buffer < _position) {
      bufferedEnd = _position + _buffer;
    }
    if (bufferedEnd < _position) {
      bufferedEnd = _position;
    }
    return (bufferedEnd.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
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
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
      );

      final localResume = resumePointFor(
        read: ref.read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
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
        videoUrl: _currentVideoUrl,
        preloadedStreams: _currentVideoUrl == widget.videoUrl ? widget.preloadedStreams : null,
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
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
        token: _token,
      );

      _tracker = PlaybackTracker(
        read: ref.read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
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
      final playable = await playableUrlFor(read: ref.read, stream: stream) ?? stream.url;
      final headers = playbackHeaders(stream);

      if (_player.platform is NativePlayer) {
        final native = _player.platform as NativePlayer;
        final referer = headers['Referer'] ?? headers['referer'];
        if (referer != null && referer.isNotEmpty) {
          await native.setProperty('referrer', referer);
        }
      }

      final media = Media(
        playable,
        httpHeaders: headers,
        start: startAt > Duration.zero ? startAt : null,
      );

      await _player.open(media, play: true);
      await _player.play();
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

  void _toggleControlsVisibility() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _startControlsTimer();
    } else {
      _hideControlsTimer?.cancel();
    }
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
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      final isFull = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!isFull);
      if (mounted) {
        setState(() => _isFullscreen = !isFull);
      }
    } else if (!kIsWeb && Platform.isAndroid) {
      final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
      if (isLandscape) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
      } else {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    }
  }

  void _toggleFit() {
    _onUserActivity();
    setState(() {
      if (_fit == BoxFit.contain) {
        _fit = BoxFit.cover;
      } else if (_fit == BoxFit.cover) {
        _fit = BoxFit.fill;
      } else {
        _fit = BoxFit.contain;
      }
    });
  }

  void _showAudioTrackDialog() {
    _onUserActivity();
    final audioTracks = _player.state.tracks.audio;
    final current = _player.state.track.audio;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Audio Tracks',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (audioTracks.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Default Audio', style: TextStyle(color: Colors.white70)),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: audioTracks.length,
                    itemBuilder: (context, i) {
                      final t = audioTracks[i];
                      final isSelected = t.id == current.id;
                      final label = t.title ?? t.language ?? 'Audio Track ${i + 1}';
                      return ListTile(
                        leading: Icon(
                          isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                          color: isSelected ? Theme.of(context).colorScheme.primary : Colors.white38,
                        ),
                        title: Text(label, style: const TextStyle(color: Colors.white)),
                        onTap: () {
                          _player.setAudioTrack(t);
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _showSubtitleTrackDialog() {
    _onUserActivity();
    final subTracks = _player.state.tracks.subtitle;
    final current = _player.state.track.subtitle;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Subtitles',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ListTile(
                leading: Icon(
                  current.id == 'no' || current.id == null
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked,
                  color: current.id == 'no' || current.id == null
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white38,
                ),
                title: const Text('Off', style: TextStyle(color: Colors.white)),
                onTap: () {
                  _player.setSubtitleTrack(SubtitleTrack.no());
                  Navigator.pop(context);
                },
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: subTracks.length,
                  itemBuilder: (context, i) {
                    final t = subTracks[i];
                    if (t.id == 'no') return const SizedBox.shrink();
                    final isSelected = t.id == current.id;
                    final label = t.title ?? t.language ?? 'Subtitle ${i + 1}';
                    return ListTile(
                      leading: Icon(
                        isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                        color: isSelected ? Theme.of(context).colorScheme.primary : Colors.white38,
                      ),
                      title: Text(label, style: const TextStyle(color: Colors.white)),
                      onTap: () {
                        _player.setSubtitleTrack(t);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSourcesDialog() {
    _onUserActivity();
    final streams = _resolved?.streams ?? _candidates;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Available Sources',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: streams.length,
                  itemBuilder: (context, i) {
                    final s = streams[i];
                    final isSelected = i == _attemptIndex;
                    return ListTile(
                      leading: Icon(
                        isSelected ? Icons.play_arrow_rounded : Icons.stream_rounded,
                        color: isSelected ? Theme.of(context).colorScheme.primary : Colors.white38,
                      ),
                      title: Text(
                        s.displaySource,
                        style: TextStyle(
                          color: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.white,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _openCandidate(i, startAt: _position);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _cleanupPlatformOnExit() {
    _player.stop();
    if (!kIsWeb && Platform.isAndroid) {
      try {
        WakelockPlus.disable();
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } catch (_) {}
    }
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      try {
        windowManager.isFullScreen().then((isFull) {
          if (isFull) windowManager.setFullScreen(false);
        }).catchError((_) {});
      } catch (_) {}
    }
  }

  Future<void> _exitPlayer() async {
    _cleanupPlatformOnExit();
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void deactivate() {
    _cleanupPlatformOnExit();
    super.deactivate();
  }

  @override
  void dispose() {
    _disposed = true;
    _hideControlsTimer?.cancel();
    _bufferPollTimer?.cancel();
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _recordFinalProgress();
    _tracker?.finish();
    _cleanupPlatformOnExit();
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
        _exitPlayer();
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

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        _cleanupPlatformOnExit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: MouseRegion(
            onHover: (_) => _onUserActivity(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControlsVisibility,
              onDoubleTapDown: (details) {
                if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
                  _toggleFullscreen();
                } else {
                  final screenWidth = MediaQuery.of(context).size.width;
                  if (details.localPosition.dx < screenWidth / 2) {
                    _seekRelative(-10);
                  } else {
                    _seekRelative(10);
                  }
                }
              },
              child: Stack(
                children: [
                  // Video Surface (Direct3D 11 / MediaCodec GPU)
                  Center(
                    child: Video(
                      controller: _videoController,
                      fit: _fit,
                      controls: NoVideoControls,
                    ),
                  ),

                  // Subtle Buffering Indicator
                  if (_isBuffering && !_isLoading && _error.isEmpty)
                    const Center(
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: Colors.white,
                        ),
                      ),
                    ),

                  // Seamless / Stremio Startup Overlay
                  if (_isLoading || _error.isNotEmpty)
                    PlayerStartupView(
                      title: widget.item.title,
                      onPick: (index) => _openCandidate(index),
                      episodeLine: _currentEpisode != null
                          ? 'S${_currentEpisode!.season} E${_currentEpisode!.episode} - ${_currentEpisode!.name}'
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
                      onBack: _exitPlayer,
                      onRetry: _startPlayback,
                      stremioTheme: stremioTheme,
                      seamlessMode: seamlessMode,
                    ),

                  // Up Next Episode Countdown Card
                  if (_nextEpisodeOffer != null && !_nextEpisodeDeclined)
                    Positioned(
                      bottom: 90,
                      right: 24,
                      child: NextEpisodeCountdown(
                        title: _nextEpisodeOffer!.name,
                        season: _nextEpisodeOffer!.season,
                        episode: _nextEpisodeOffer!.episode,
                        posterUrl: _nextEpisodeOffer!.posterUrl ?? widget.item.posterImageUrl,
                        rating: _nextEpisodeOffer!.rating,
                        runtime: _nextEpisodeOffer!.runtime != null
                            ? Duration(minutes: _nextEpisodeOffer!.runtime!)
                            : null,
                        description: _nextEpisodeOffer!.description,
                        countdown: const Duration(seconds: 15),
                        paused: !_playing,
                        onPlayNext: () {
                          setState(() => _nextEpisodeOffer = null);
                          _advance();
                        },
                        onCancel: () {
                          setState(() {
                            _nextEpisodeOffer = null;
                            _nextEpisodeDeclined = true;
                          });
                        },
                      ),
                    ),

                  // Center Quick Action Transport Controls (Touch & Remote)
                  if (_controlsVisible && !_isLoading && _error.isEmpty)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(40),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              iconSize: 36,
                              tooltip: 'Rewind 10s',
                              icon: const Icon(Icons.replay_10_rounded, color: Colors.white),
                              onPressed: () => _seekRelative(-10),
                            ),
                            const SizedBox(width: 16),
                            IconButton(
                              iconSize: 56,
                              tooltip: _playing ? 'Pause' : 'Play',
                              icon: Icon(
                                _playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                                color: Colors.white,
                              ),
                              onPressed: _togglePlayPause,
                            ),
                            const SizedBox(width: 16),
                            IconButton(
                              iconSize: 36,
                              tooltip: 'Forward 10s',
                              icon: const Icon(Icons.forward_10_rounded, color: Colors.white),
                              onPressed: () => _seekRelative(10),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Player Controls Layer (Top & Bottom Bars)
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
              onPressed: _exitPlayer,
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
                  if (_currentEpisode != null)
                    Text(
                      'S${_currentEpisode!.season} E${_currentEpisode!.episode} — ${_currentEpisode!.name}',
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
              child: Text(
                Platform.isAndroid ? 'Hardware GPU (MediaCodec)' : 'Direct3D 11 GPU',
                style: const TextStyle(
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
    final displayPos = _isDragging && _dragPosition != null ? _dragPosition! : _position;
    final posText = _formatDuration(displayPos);
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
            // Seek bar with real-time buffer progress line
            PlayerScrubber(
              position: displayPos,
              duration: _duration,
              hasDuration: _duration > Duration.zero,
              bufferRatio: _bufferRatio,
              canSeek: _duration > Duration.zero,
              onChangeStart: (ms) {
                _onUserActivity();
                setState(() {
                  _isDragging = true;
                  _dragPosition = Duration(milliseconds: ms.round());
                });
              },
              onChanged: (ms) {
                _onUserActivity();
                setState(() {
                  _dragPosition = Duration(milliseconds: ms.round());
                });
              },
              onChangeEnd: (ms) {
                _onUserActivity();
                final target = Duration(milliseconds: ms.round());
                setState(() {
                  _isDragging = false;
                  _dragPosition = null;
                });
                _player.seek(target);
              },
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
                if (_hasPreviousEpisode)
                  IconButton(
                    tooltip: 'Previous Episode',
                    icon: const Icon(Icons.skip_previous_rounded, color: Colors.white70, size: 28),
                    onPressed: () {
                      _onUserActivity();
                      final prev = _previousEpisode;
                      if (prev != null) _startEpisode(prev);
                    },
                  ),
                if (_hasNextEpisode)
                  IconButton(
                    tooltip: 'Next Episode',
                    icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 28),
                    onPressed: () {
                      _onUserActivity();
                      _advance();
                    },
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
                if (_candidates.length > 1)
                  IconButton(
                    tooltip: 'Sources',
                    icon: const Icon(Icons.layers_rounded, color: Colors.white, size: 24),
                    onPressed: _showSourcesDialog,
                  ),
                IconButton(
                  tooltip: 'Audio Tracks',
                  icon: const Icon(Icons.audiotrack_rounded, color: Colors.white, size: 24),
                  onPressed: _showAudioTrackDialog,
                ),
                IconButton(
                  tooltip: 'Subtitles',
                  icon: const Icon(Icons.subtitles_rounded, color: Colors.white, size: 24),
                  onPressed: _showSubtitleTrackDialog,
                ),
                IconButton(
                  tooltip: 'Fit Mode',
                  icon: const Icon(Icons.aspect_ratio_rounded, color: Colors.white, size: 24),
                  onPressed: _toggleFit,
                ),
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
