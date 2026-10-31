import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart'
    show ProviderListenable;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/logger/playback_trace.dart';
import '../../../../core/network/http_defaults.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../core/services/local_proxy_service.dart';
import '../../../../core/services/provider_health_service.dart';
import '../../../../core/services/stream_prewarmer.dart';
import '../../../../core/services/neural_media_enhancer.dart';
import '../../../settings/presentation/ai_settings_provider.dart';
import '../../../../core/utils/app_utils.dart';
import '../../../../core/utils/stream_quality_sorter.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../details/presentation/details_controller.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../domain/episode_navigator.dart';
import '../../domain/hls_video_length.dart';
import '../../domain/network_buffer.dart';
import '../../domain/playback_progress.dart';
import '../../domain/playback_tracker.dart';
import '../../domain/side_car_subtitles.dart';
import '../../domain/stream_resolver.dart';
import '../../domain/subtitle_search_target.dart';
import '../player_platform_service.dart';
import '../subtitle_search_provider.dart' show subtitleLanguageProvider;
import '../vlc/next_episode_countdown.dart';
import '../vlc/panel/player_panel_metrics.dart';
import '../vlc/panel/player_panel_row.dart';
import '../vlc/panel/player_episodes_tab.dart';
import '../vlc/panel/player_subtitle_search_page.dart';
import '../vlc/player_startup_view.dart';
import '../vlc/side_car_fetch.dart';
import '../vlc/side_car_subtitle_view.dart';
import '../widgets/hotstar_player_style.dart';
import '../widgets/player_control_components.dart';
import '../widgets/player_sheet_header.dart';
import '../widgets/player_stream_widgets.dart';
import 'mediakit_more_sheet.dart';
import 'mediakit_subtitle_sheet.dart';
import 'mpv_subtitle_playback.dart';

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
  ConsumerState<MediaKitPlayerScreen> createState() =>
      _MediaKitPlayerScreenState();
}

class _MediaKitPlayerScreenState extends ConsumerState<MediaKitPlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _videoController;
  late final Future<void> _mpvConfig;

  late MultimediaItem _item;
  late String _currentVideoUrl;
  Episode? _currentEpisode;
  Episode? _nextEpisodeOffer;
  bool _nextEpisodeDeclined = false;
  bool _hasPrewarmedNextEpisode = false;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  Duration? _dragPosition;
  bool _isDragging = false;

  bool _disposed = false;
  bool _isLoading = true;
  bool _isBuffering = false;
  bool _isSwitching = false;
  bool _hasPlayedOnce = false;
  bool _advancing = false;
  String _error = '';
  String _lastEngineError = '';
  List<StreamResult> _candidates = const [];
  ResolvedPlayback? _resolved;
  int _attemptIndex = 0;
  int _openToken = 0;
  Timer? _errorRecoveryTimer;
  Timer? _trackSwitchWatchdog;
  DateTime? _trackSettlingUntil;
  Timer? _startupWatchdog;
  Timer? _midstreamStallWatchdog;
  DateTime? _attemptOpenedAt;
  Duration _attemptStartAt = Duration.zero;
  bool _attemptReachedPicture = false;
  String _attemptProviderId = '';

  /// Whether the current source has already been reopened through the local
  /// proxy after opening without drawing. One turn per source: a silent open
  /// is retried once through the proxy, never in a loop.
  bool _attemptTriedProxy = false;

  /// Whether the current source has already been reopened *without* the proxy
  /// after a silent open. The pair gives each source one turn on each path:
  /// a proxied open that never draws gets the direct URL, and vice versa.
  bool _attemptTriedDirect = false;

  /// "Failed to recognize file format" errors for the current attempt. mpv
  /// emits one per segment after it falls back to reading an unopenable
  /// playlist as plain text; three before a picture means the source is dead.
  int _unrecognizedFormatErrors = 0;

  /// The leash the current attempt was given, kept so the record made when it
  /// runs out can say how long the wait was.
  Duration _attemptWatchdogWait = _kSilentOpenWatchdog;

  /// How long a progressive source may open without drawing before the proxy
  /// gets its turn.
  ///
  /// Nine seconds without the clock moving is well past a cold start and far
  /// short of the engine's own patience; when another mirror exists, moving
  /// to it beats leaving the viewer on a spinner.
  static const Duration _kSilentOpenWatchdog = Duration(seconds: 14);

  /// The same leash for an HLS source.
  ///
  /// Multi-variant master playlists require resolving child variants (360p, 720p, 1080p)
  /// and downloading the first segment chunk over TLS. 12 seconds provides sufficient
  /// runway to prevent premature watchdog cancellation on standard networks.
  static const Duration _kSilentOpenWatchdogHls = Duration(seconds: 12);

  /// Stage timings for the current start, so `/logs` can say where the time
  /// went without a debugger attached.
  PlaybackTrace? _trace;

  /// The engine's own last words, kept for the silent-open report.
  ///
  /// mpv writes its diagnostics to the debug console, which a shipped build
  /// does not keep. A source that opens and never draws leaves no other trace,
  /// so the tail is dumped into the app log at the moment the watchdog fires -
  /// the one place a viewer can read it (`/logs`).
  final List<String> _mpvLogTail = <String>[];

  /// The subtitle files of what is playing - the source's and any the viewer
  /// added - which SkyStream draws over the picture rather than handing to
  /// mpv. See [SideCarSubtitles].
  late final SideCarSubtitles _sideCars;

  /// The clock the overlaid files are timed off: media_kit's position and
  /// playing state, plus the delay set in the subtitles sheet.
  late final MpvSubtitlePlayback _subtitlePlayback = MpvSubtitlePlayback(
    _player,
  );

  /// The tracks inside the video, mirrored for the sheet. media_kit owns both
  /// the list and the selection; these only echo what it last said.
  final ValueNotifier<List<SubtitleTrack>> _embeddedSubtitles = ValueNotifier(
    const <SubtitleTrack>[],
  );
  final ValueNotifier<String?> _activeEmbeddedSubtitle = ValueNotifier(null);

  /// The video tracks inside the media (e.g. HLS renditions), mirrored for manual quality choice.
  final ValueNotifier<List<VideoTrack>> _videoTracks = ValueNotifier(
    const <VideoTrack>[],
  );
  final ValueNotifier<VideoTrack?> _currentVideoTrack = ValueNotifier(null);

  /// Manual quality override chosen by the viewer (e.g. '1080p', '720p', 'Auto')
  String? _manualQualitySelection;

  /// Set while media is opened with the Subtitles setting at Off: mpv selects
  /// a subtitle for itself as the file opens, and one selected behind a viewer
  /// who asked for none is turned off again - see [_applySubtitleDefault].
  bool _subtitlesOffPending = false;
  String? _subtitleOffAsked;

  /// Whether the viewer has opened the subtitles sheet on this episode, which
  /// is where every subtitle choice is made. The Off default and Auto never
  /// override one.
  bool _viewerChoseSubtitle = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _playing = false;
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;
  double _playbackSpeed = 1.0;
  bool _isFullscreen = false;
  BoxFit _fit = BoxFit.contain;
  PlayerSettings? _settings;

  static BoxFit _fitFromSettings(String mode) => switch (mode.toLowerCase()) {
    'zoom' => BoxFit.cover,
    'stretch' => BoxFit.fill,
    _ => BoxFit.contain,
  };

  int get _seekStep => _settings?.seekDuration ?? 10;

  /// How this device is driven, derived per build from the device profile -
  /// a television is handed the ten-foot ramp and a wrapped action row, and
  /// everything else the two-line bar a pointer can drag. [unknown] until the
  /// profile resolves, which reads as "not a television": the smaller chrome
  /// is the one that looks right on every form factor that has not been
  /// narrowed yet.
  PlayerFormFactor _form = PlayerFormFactor.unknown;

  bool get _isTv => _form == PlayerFormFactor.tv;

  PlaybackProgressRecorder? _recorder;
  PlaybackTracker? _tracker;
  int _token = 0;
  DateTime _lastProgressSave = DateTime.now();

  final FocusNode _focusNode = FocusNode();

  ProviderContainer? _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  T _read<T>(ProviderListenable<T> provider) {
    final container = _container;
    if (container != null) {
      return container.read(provider);
    }
    return ref.read(provider);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

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

    _item = widget.item;
    if ((_item.episodes == null || _item.episodes!.isEmpty) &&
        widget.item.url.isNotEmpty) {
      try {
        final cached = _read(detailsControllerProvider(widget.item.url))
            .details
            .asData
            ?.value;
        if (cached != null &&
            cached.episodes != null &&
            cached.episodes!.isNotEmpty) {
          _item = cached;
        }
      } catch (_) {}
    }

    _currentVideoUrl = widget.videoUrl;
    _settings = _read(playerSettingsProvider).asData?.value;
    _fit = _fitFromSettings(_settings?.defaultResizeMode ?? 'Fit');
    _currentEpisode =
        widget.episode ??
        _item.episodes?.firstWhereOrNull((e) {
          final u1 = e.url.trim().replaceAll(RegExp(r'/+$'), '');
          final u2 = widget.videoUrl.trim().replaceAll(RegExp(r'/+$'), '');
          return e.url == widget.videoUrl || (u1.isNotEmpty && u1 == u2);
        });

    _player = Player(
      configuration: PlayerConfiguration(
        title: 'SkyStream',
        bufferSize: _bufferPlan().megabytes * 1024 * 1024,
        // `info`, not `error`: a source that opens and then draws nothing
        // usually has no error to report, only messages about what it was
        // waiting on. They are kept in [_mpvLogTail] and surfaced in-app when
        // the startup watchdog fires.
        logLevel: MPVLogLevel.info,
      ),
    );

    _videoController = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: _settings?.hardwareDecoding ?? true,
      ),
    );

    _sideCars = SideCarSubtitles(
      fetch: (url, headers) => _read(sideCarFetchProvider)(url, headers),
      onUnreadable: _handSideCarToEngine,
    );
    _sideCars.addListener(_onSideCars);

    _mpvConfig = _applyMpvOptimizations();
    _listenPlayerStreams();
    _startPlayback();
    _startControlsTimer();
  }

  /// Android can freeze or kill a backgrounded process at any moment, so the
  /// last five-second sample is written on the way out rather than on the next
  /// tick. The tracker session carries on: a viewer who comes back is still
  /// watching the same episode, and [_recordFinalProgress] is what ends it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      if (!kIsWeb && Platform.isAndroid) unawaited(WakelockPlus.enable());
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      _flushProgress();
      // `inactive` also means a PiP transition or a permission dialog, so the
      // screen flag only goes with the app actually leaving the foreground.
      if ((state == AppLifecycleState.paused ||
              state == AppLifecycleState.hidden) &&
          !kIsWeb &&
          Platform.isAndroid) {
        unawaited(WakelockPlus.disable());
      }
    }
  }

  /// The buffer the viewer asked for, resolved exactly as the settings row and
  /// the VLC engine resolve it, so the number shown and the number used are
  /// the same one.
  ({int megabytes, int seconds}) _bufferPlan() {
    final settings = _read(playerSettingsProvider).asData?.value ?? _settings;
    final tier =
        _read(deviceProfileProvider).asData?.value.tier ?? DeviceTier.standard;
    return (
      megabytes: resolveNetworkBufferMb(
        settings?.networkBufferMb,
        tier,
        chosenDurationMinutes: settings?.bufferDurationMinutes,
      ),
      seconds: resolveReadAheadSeconds(settings?.bufferDurationMinutes, tier),
    );
  }

  Future<void> _applyMpvOptimizations() async {
    if (_player.platform is NativePlayer) {
      final native = _player.platform as NativePlayer;
      try {
        if (!kIsWeb && Platform.isAndroid) {
          // Zero-copy direct hardware decoding into Android SurfaceTexture
          await native.setProperty('hwdec', 'mediacodec');
          await native.setProperty('scale', 'bilinear');
          await native.setProperty('cscale', 'bilinear');
          await native.setProperty(
            'framedrop',
            'yes',
          ); // Standard decode drop, NOT vo
          // Mobile cache tuning (high-throughput readahead, fills buffer aggressively)
          await native.setProperty('cache', 'yes');
          await native.setProperty('cache-pause-wait', '2');
          await native.setProperty('demuxer-lavf-probesize', '1048576');
          // Seconds: 500000 is rejected as out of range, not read as 0.5 s.
          await native.setProperty('demuxer-lavf-analyzeduration', '0.5');
          await native.setProperty('hr-seek', 'yes');
          await native.setProperty('hr-seek-framedrop', 'yes');
          await native.setProperty('network-timeout', '10');
          await native.setProperty(
            'stream-lavf-o',
            'timeout=10000000,reconnect_streamed=1,reconnect_delay_max=2',
          );
          await native.setProperty('demuxer-lavf-o', 'allowed_extensions=ALL');
        } else if (!kIsWeb && Platform.isWindows) {
          await native.setProperty('hwdec', 'auto-safe');

          // Fast GPU Scaling & Low-Overhead Shaders (Optimized for Intel UHD & Integrated GPUs)
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
          await native.setProperty('video-sync', 'display-resample');

          // High-throughput caching for instant start + full network line speed utilization
          await native.setProperty('cache', 'yes');
          await native.setProperty('cache-pause-wait', '2');
          await native.setProperty('demuxer-lavf-probesize', '1048576');
          // Seconds: 500000 is rejected as out of range, not read as 0.5 s.
          await native.setProperty('demuxer-lavf-analyzeduration', '0.5');
          await native.setProperty('hr-seek', 'yes');
          await native.setProperty('hr-seek-framedrop', 'yes');
          await native.setProperty('network-timeout', '10');

          // Treat localhost as local (disable network buffering logic)
          await native.setProperty(
            'stream-lavf-o',
            'timeout=10000000,reconnect_streamed=1,reconnect_delay_max=2',
          );
          await native.setProperty('demuxer-lavf-o', 'allowed_extensions=ALL');
        }

        if (_settings?.hardwareDecoding == false) {
          await native.setProperty('hwdec', 'no');
        }
        // The viewer's buffer, in the three units mpv splits it into. All
        // three come from one choice: the byte budget and the read-ahead are
        // whichever of the two runs out first, so a read-ahead shorter than
        // the duration would quietly cap it at what used to be a hardcoded
        // minute, and a byte budget smaller than the size would do the same.
        final plan = _bufferPlan();
        await native.setProperty(
          'demuxer-max-bytes',
          '${plan.megabytes * 1024 * 1024}',
        );
        await native.setProperty(
          'demuxer-max-back-bytes',
          '${resolveCacheBehindBytes(plan.megabytes)}',
        );
        await native.setProperty('demuxer-readahead-secs', '${plan.seconds}');
        await native.setProperty('cache-secs', '${plan.seconds}');
        await _applySubtitleStyle(native);

        await native.setProperty('audio-pitch-correction', 'yes');
        await native.setProperty('user-agent', kDefaultBrowserUserAgent);

        // SkyStream Neural AI Enhancements (Dahl Core)
        final aiSettings = _read(aiSettingsProvider).asData?.value;
        if (aiSettings != null && aiSettings.aiEnabled) {
          // 1. Dialogue Isolation & Night Mode Audio Filters
          final af = NeuralMediaEnhancer.buildAudioFilter(aiSettings);
          if (af != null) {
            await native.setProperty('af', af);
          }
          // 2. HDR10 to SDR Tone Mapping
          for (final entry in NeuralMediaEnhancer.buildToneMappingOptions(
            aiSettings,
          ).entries) {
            await native.setProperty(entry.key, entry.value);
          }
          // 3. Anti-Banding & Gradient Smoothing
          for (final entry in NeuralMediaEnhancer.buildAntiBandingOptions(
            aiSettings,
          ).entries) {
            await native.setProperty(entry.key, entry.value);
          }
          // 4. Dynamic Demuxer & Instant Seek
          for (final entry in NeuralMediaEnhancer.buildDemuxerTuningOptions(
            aiSettings,
          ).entries) {
            await native.setProperty(entry.key, entry.value);
          }
        }
      } catch (e) {
        if (kDebugMode)
          debugPrint('[MediaKit] Error configuring mpv properties: $e');
      }
    }
  }

  /// The viewer's subtitle appearance, in mpv's terms: a scale relative to
  /// mpv's own default rather than libVLC's inverse-relative size.
  Future<void> _applySubtitleStyle(NativePlayer native) async {
    final settings = _settings;
    if (settings == null) return;
    final scale = (settings.subtitleSize / 22).clamp(0.5, 3.0);
    await native.setProperty('sub-scale', scale.toStringAsFixed(2));
    await native.setProperty(
      'sub-color',
      _mpvColor(Color(settings.subtitleColor)),
    );
    final background = Color(settings.subtitleBackgroundColor)
        .withValues(alpha: settings.subtitleBackgroundOpacity.clamp(0.0, 1.0));
    await native.setProperty('sub-back-color', _mpvColor(background));
  }

  String _mpvColor(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';

  Episode? get _effectiveCurrentEpisode {
    if (_currentEpisode != null) return _currentEpisode;
    final episodes = _item.episodes ?? widget.item.episodes;
    if (episodes == null || episodes.isEmpty) return null;
    final cleanVideo = _currentVideoUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final cleanWidgetVideo = widget.videoUrl.trim().replaceAll(
      RegExp(r'/+$'),
      '',
    );
    return episodes.firstWhereOrNull((e) {
      final cleanE = e.url.trim().replaceAll(RegExp(r'/+$'), '');
      return e.url == _currentVideoUrl ||
          e.url == widget.videoUrl ||
          (cleanE.isNotEmpty &&
              (cleanE == cleanVideo || cleanE == cleanWidgetVideo));
    });
  }

  Episode? get _nextEpisode {
    final cur = _effectiveCurrentEpisode;
    final lookup = nextEpisodeFor(
      item: _item,
      current: cur,
      videoUrl: _currentVideoUrl,
    );
    return lookup.next;
  }

  Episode? get _previousEpisode {
    final cur = _effectiveCurrentEpisode;
    return previousEpisodeFor(
      item: _item,
      current: cur,
      videoUrl: _currentVideoUrl,
    );
  }

  bool get _hasNextEpisode => _nextEpisode != null;
  bool get _hasPreviousEpisode => _previousEpisode != null;

  /// Moves to the next episode once.
  ///
  /// Three things ask for this at the end of an episode - the countdown, the
  /// completion event and the Next button - and a second advance would skip an
  /// episode nobody asked to skip. The latch covers the window while the first
  /// one is stopping the old media.
  Future<void> _advance() async {
    if (_advancing) return;
    final next = _nextEpisode;
    if (next == null) return;
    _advancing = true;
    try {
      _tracker?.finish();
      rollForwardHistory(read: _read, item: _item, next: next);
      await _startEpisode(next);
    } finally {
      _advancing = false;
    }
  }

  Future<void> _startEpisode(Episode next) async {
    _recorder?.record(
      ProgressSample(position: _position, duration: _duration, token: _token),
      force: true,
    );
    _tracker?.finish();
    await _player.stop();
    // The viewer can leave while the engine is stopping; the fields below are
    // rebuilt state, and touching them after dispose is a crash.
    if (_disposed || !mounted) return;

    _errorRecoveryTimer?.cancel();
    _trackSwitchWatchdog?.cancel();
    _startupWatchdog?.cancel();
    _midstreamStallWatchdog?.cancel();
    _startupWatchdog = null;
    _attemptOpenedAt = null;
    _attemptReachedPicture = false;
    _attemptProviderId = '';
    _attemptTriedProxy = false;
    _attemptTriedDirect = false;
    _trackSettlingUntil = null;
    _openToken++;
    // A file the viewer added belonged to the last episode as much as the
    // source's did, and the next episode's sheet starts unopened.
    _sideCars.clear();
    _viewerChoseSubtitle = false;

    setState(() {
      _currentEpisode = next;
      _currentVideoUrl = next.url;
      _position = Duration.zero;
      _duration = Duration.zero;
      _buffer = Duration.zero;
      _isLoading = true;
      _isSwitching = false;
      _hasPlayedOnce = false;
      _error = '';
      _candidates = const [];
      _resolved = null;
      _attemptIndex = 0;
      _nextEpisodeOffer = null;
      _nextEpisodeDeclined = false;
      _hasPrewarmedNextEpisode = false;
    });

    await _startPlayback();
  }

  void _listenPlayerStreams() {
    _subscriptions.add(
      _player.stream.position.listen((pos) {
        if (_disposed || !mounted) return;
        // Kept current for seeking, resume and progress either way; only the
        // chrome draws it, so with the chrome away there is nothing to repaint.
        // The player emits this several times a second, and rebuilding the
        // whole screen for a number nobody can see is the most expensive thing
        // an idle video does.
        _position = pos;
        _subtitlePlayback.tick(pos);
        _maybeRecordProgress(pos);

        // First movement of the clock is the source's successful start. The
        // delay keeps the previous media's last ticks from being read as the
        // new one's; the watchdog only waits for the same movement.
        final openedAt = _attemptOpenedAt;
        if (!_attemptReachedPicture &&
            openedAt != null &&
            DateTime.now().difference(openedAt) >=
                const Duration(milliseconds: 600) &&
            pos > _attemptStartAt + const Duration(milliseconds: 400)) {
          _attemptReachedPicture = true;
          _startupWatchdog?.cancel();
          _startupWatchdog = null;
          _trace?.lap(
            'first-picture',
            'attempt=$_attemptIndex '
                'since-open=${DateTime.now().difference(openedAt).inMilliseconds}ms',
          );
          _recordProviderHealth(
            success: true,
            responseTime: DateTime.now().difference(openedAt),
          );
        }

        final remaining = _duration - pos;

        // Speculatively pre-warm next episode at 80% progress (Netflix Warm Start)
        if (_hasNextEpisode &&
            !_hasPrewarmedNextEpisode &&
            _duration > const Duration(minutes: 3) &&
            pos.inMilliseconds / _duration.inMilliseconds >= 0.80) {
          _hasPrewarmedNextEpisode = true;
          final next = _nextEpisode;
          if (next != null) {
            unawaited(
              StreamPrewarmer.instance.prewarm(
                item: _item,
                targetUrl: next.url,
                read: _read,
                episode: next,
              ),
            );
          }
        }

        // Offer Next Episode for the same fifteen seconds its countdown shows.
        // Offering it earlier left the card counting down from fifteen while
        // twenty seconds of the episode were still to play, so the advance it
        // took was a skip.
        if (_hasNextEpisode &&
            !_nextEpisodeDeclined &&
            (_settings?.showEpisodes ?? true) &&
            _duration > const Duration(minutes: 5)) {
          if (remaining > Duration.zero &&
              remaining <= const Duration(seconds: 15)) {
            if (_nextEpisodeOffer == null) {
              setState(() => _nextEpisodeOffer = _nextEpisode);
            }
          }
        }

        if (_controlsVisible || _isDragging) {
          setState(() {});
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
        _subtitlePlayback.tick();
        setState(() {
          _playing = isPlaying;
          if (isPlaying) {
            _isLoading = false;
            _isBuffering = false;
            _isSwitching = false;
            _hasPlayedOnce = true;
          }
        });
      }),
    );

    _subscriptions.add(
      _player.stream.tracks.listen((tracks) {
        if (_disposed) return;
        // mpv's own choices - `no` and `auto` - are not tracks a viewer can
        // pick; the sheet offers Off itself.
        final list = [
          for (final track in tracks.subtitle)
            if (track.id != 'no' && track.id != 'auto') track,
        ];
        _embeddedSubtitles.value = list;

        final vList = [
          for (final track in tracks.video)
            if (track.id != 'no' && track.id != 'auto') track,
        ];
        _videoTracks.value = vList;

        // Auto-select preferred embedded subtitle if none is active and user didn't disable
        if (!_viewerChoseSubtitle &&
            _sideCars.active == null &&
            !_subtitlesOffPending &&
            list.isNotEmpty) {
          final prefCode = _read(subtitleLanguageProvider);
          final preferred = preferredSubtitleIndex([
            for (final t in list) t.language ?? t.title ?? '',
          ], prefCode);
          if (preferred != null && preferred < list.length) {
            unawaited(_player.setSubtitleTrack(list[preferred]));
          }
        }
      }),
    );

    _subscriptions.add(
      _player.stream.track.listen((track) {
        if (_disposed) return;
        final subtitle = track.subtitle;
        _activeEmbeddedSubtitle.value =
            subtitle.id == 'no' || subtitle.id == 'auto' ? null : subtitle.id;
        _currentVideoTrack.value = track.video;
        _applySubtitleDefault(subtitle.id);
      }),
    );

    _subscriptions.add(
      _player.stream.buffering.listen((isBuffering) {
        if (_disposed || !mounted) return;
        // Rebuilding the demuxer for a newly chosen audio rendition briefly
        // empties the buffer. Painting a spinner over the picture for that
        // makes a normal track change look like a stall.
        if (isBuffering && _isSettlingTrackChange) return;
        setState(() => _isBuffering = isBuffering);

        if (isBuffering &&
            _attemptReachedPicture &&
            !_isLoading &&
            !_isSwitching) {
          _midstreamStallWatchdog?.cancel();
          _midstreamStallWatchdog = Timer(const Duration(milliseconds: 12000), () {
            if (_disposed || !mounted) return;
            if (_isBuffering && _player.state.playing) {
              if (kDebugMode) {
                debugPrint(
                  '[MediaKit] Mid-stream socket stall (>12000ms). Hot-swapping to shadow mirror at $_position...',
                );
              }
              _recordProviderHealth(success: false, reason: 'mid-stream stall');
              _failoverNext();
            }
          });
        } else {
          _midstreamStallWatchdog?.cancel();
        }
      }),
    );

    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (_disposed || !mounted) return;
        if (!completed) return;
        // A completed event arriving while a new source is opening is the
        // stream we are leaving, not the one we are on.
        if (_isLoading || _isSwitching || _isSettlingTrackChange) return;
        _recordFinalProgress();
        if (_hasNextEpisode && !_nextEpisodeDeclined) {
          _advance();
        }
      }),
    );

    _subscriptions.add(
      _player.stream.log.listen((line) {
        if (_disposed) return;
        final text = line.text.trim();
        if (text.isEmpty) return;
        _rememberMpvLine('${line.level}|${line.prefix}|$text');
      }),
    );

    _subscriptions.add(
      _player.stream.error.listen((err) {
        if (_disposed || !mounted) return;
        if (kDebugMode) debugPrint('[MediaKit] Player Error: $err');
        // Kept for the health score and the final message: "playback error"
        // alone says nothing about whether the link 404'd or the decoder
        // refused the codec.
        _lastEngineError = err.trim();
        _trace?.warn('engine-error', _lastEngineError);
        // libmpv reports an error while it rebuilds the demuxer for a track
        // change. Failing over on that is what made track switching reload
        // the whole link.
        if (_isSettlingTrackChange) return;
        // mpv falls back to reading an HLS playlist as plain text when the
        // stream cannot be opened, then tries every segment as its own file
        // and reports this error for each. Three in a row before any picture
        // means the source is dead: move on instead of waiting out the timer.
        if (!_attemptReachedPicture &&
            err.contains('Failed to recognize file format')) {
          _unrecognizedFormatErrors++;
          if (_unrecognizedFormatErrors >= 3) {
            _unrecognizedFormatErrors = 0;
            _trace?.warn('bad-format', 'attempt=$_attemptIndex');
            _recordProviderHealth(
              success: false,
              reason: 'stream not recognised',
            );
            _failoverNext();
            return;
          }
        }
        _scheduleErrorRecovery();
      }),
    );
  }

  bool get _isSettlingTrackChange {
    final until = _trackSettlingUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _holdThroughTrackChange() {
    _trackSettlingUntil = DateTime.now().add(const Duration(seconds: 3));
    final wasPlaying = _player.state.playing;
    _trackSwitchWatchdog?.cancel();
    if (!wasPlaying) return;
    // If the engine comes out of a rendition change stopped rather than
    // playing, nudge it once. A fatal rendition error re-reports outside the
    // settle window and is handled by _scheduleErrorRecovery.
    _trackSwitchWatchdog = Timer(const Duration(seconds: 3), () {
      if (_disposed || !mounted) return;
      if (_player.state.playing) return;
      unawaited(_player.play());
    });
  }

  /// Gives the engine a moment to recover from an error on its own, then
  /// fails over only if it is genuinely stopped. A dropped segment often
  /// produces an error and recovers; the old immediate failover turned that
  /// into a visible reload.
  void _scheduleErrorRecovery() {
    _errorRecoveryTimer?.cancel();
    _errorRecoveryTimer = Timer(const Duration(milliseconds: 2500), () {
      if (_disposed || !mounted) return;
      final state = _player.state;
      if (state.playing) return;
      _recordProviderHealth(
        success: false,
        reason: _lastEngineError.isEmpty
            ? 'playback error'
            : 'playback error: $_lastEngineError',
      );
      _failoverNext();
    });
  }

  /// Arms the backstop for a source that opens but never draws.
  ///
  /// The wait depends on what was opened - a progressive file gets the longer
  /// leash, a playlist the shorter one - because the two fail in different
  /// shapes (see [_kSilentOpenWatchdogHls]). Either way the source gets one
  /// turn on each open path before it is abandoned (see
  /// [_recoverFromSilentOpen]).
  void _armStartupWatchdog(int token) {
    _startupWatchdog?.cancel();
    _attemptOpenedAt = DateTime.now();
    final wait = _attemptWatchdogWait = _watchdogWait;
    _startupWatchdog = Timer(wait, () {
      if (_disposed || !mounted || token != _openToken) return;
      if (_attemptReachedPicture || _isSettlingTrackChange) return;
      _trace?.warn(
        'no-picture',
        'watchdog-${wait.inSeconds}s attempt=$_attemptIndex '
            'proxy-tried=$_attemptTriedProxy direct-tried=$_attemptTriedDirect',
      );
      unawaited(_recoverFromSilentOpen(token));
    });
  }

  void _rememberMpvLine(String line) {
    _mpvLogTail.add(line);
    if (_mpvLogTail.length > 24) {
      _mpvLogTail.removeAt(0);
    }
  }

  /// Writes what the engine was waiting on into the app log.
  ///
  /// A silent open is the one failure with no error to report: mpv accepted
  /// the URL and then either never fetched, fetched and refused to demux, or
  /// reached the end. Those three look identical from the outside and each
  /// asks for a different fix, so the properties that tell them apart - plus
  /// the engine's own last messages and what the proxy did for this source -
  /// go into `/logs` before anything is retried.
  Future<void> _describeSilentOpen() async {
    if (_player.platform is! NativePlayer) return;
    final native = _player.platform as NativePlayer;
    const keys = <String>[
      'idle-active',
      'core-idle',
      'eof-reached',
      'paused',
      'paused-for-cache',
      'cache-buffering-state',
      'cache-speed',
      'demuxer-cache-duration',
      'demuxer-cache-idle',
      'video-format',
      'audio-format',
      'width',
      'height',
      'time-pos',
    ];
    final parts = <String>[];
    for (final key in keys) {
      try {
        final value = await native.getProperty(
          key,
          waitForInitialization: false,
        );
        parts.add('$key=$value');
      } catch (_) {}
    }
    if (parts.isNotEmpty) _trace?.warn('engine-state', parts.join(' '));
    final tail = _mpvLogTail.length > 12
        ? _mpvLogTail.sublist(_mpvLogTail.length - 12)
        : _mpvLogTail;
    for (final line in tail) {
      _trace?.warn('mpv', line);
    }
    final proxied = LocalProxyService.recentEvents;
    if (proxied.isNotEmpty) _trace?.warn('proxy', proxied.join(' ; '));
  }

  /// What to do about a source that opened and never drew.
  ///
  /// Each source gets one turn on each open path before it is abandoned. A
  /// direct open that never drew is retried through the local proxy, whose
  /// relabelled bodies and rewritten playlist are what some chunk CDNs need; a
  /// proxied open that never drew is retried on the engine's own HTTP stack,
  /// because the proxy is also an extra hop, a header rewrite and a DNS answer,
  /// and any of the three can be the reason the picture never came.
  Future<void> _recoverFromSilentOpen(int token) async {
    final streams = _resolved?.streams ?? _candidates;
    if (_attemptIndex < 0 || _attemptIndex >= streams.length) return;
    final stream = streams[_attemptIndex];
    final at = _attemptStartAt > Duration.zero ? _attemptStartAt : null;
    final url = AppUtils.normalizeUrl(stream.url);
    final headers = playbackHeaders(stream);

    await _describeSilentOpen();
    if (_disposed || !mounted || token != _openToken) return;

    if (!_attemptTriedProxy) {
      if (await _tryProxyFallback(url, headers, at, token)) return;
    } else if (!_attemptTriedDirect) {
      if (await _tryDirectOpen(url, headers, at, token)) return;
    }
    if (_disposed || !mounted || token != _openToken) return;

    // The last source gets the same two turns, and then the viewer is told
    // what happened instead of being left on a spinner that never answers.
    final reason =
        'no picture within ${_attemptWatchdogWait.inSeconds} seconds';
    _recordProviderHealth(success: false, reason: reason);
    if (_attemptIndex + 1 >= streams.length) {
      _lastEngineError = reason;
    }
    _failoverNext();
  }

  /// Which leash the source on screen has earned.
  ///
  /// Read off the URL rather than the engine: a source that redirects to a
  /// playlist is opened by its original address, and a `.m3u8` there is still
  /// a playlist on the other side.
  Duration get _watchdogWait {
    final streams = _resolved?.streams ?? _candidates;
    if (_attemptIndex < 0 || _attemptIndex >= streams.length) {
      return _kSilentOpenWatchdog;
    }
    final uri = Uri.tryParse(AppUtils.normalizeUrl(streams[_attemptIndex].url));
    return uri != null && looksLikeHls(uri)
        ? _kSilentOpenWatchdogHls
        : _kSilentOpenWatchdog;
  }

  /// Feeds the source-selection ranking what actually happened. Elapsed time
  /// here is time to first picture, which is the number a viewer feels - not
  /// how quickly the add-on listed the link.
  void _recordProviderHealth({
    required bool success,
    Duration? responseTime,
    String? reason,
  }) {
    final id = _attemptProviderId;
    if (id.isEmpty) return;
    final enabled =
        _read(playerSettingsProvider).asData?.value.autoHealthScoringEnabled ??
        true;
    if (!enabled) return;
    try {
      final health = _read(providerHealthServiceProvider);
      if (success) {
        health.recordSuccess(id, responseTime: responseTime);
      } else {
        health.recordFailure(id, reason: reason);
      }
    } catch (_) {}
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
    return (bufferedEnd.inMilliseconds / _duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
  }

  Future<void> _startPlayback() async {
    _trace = PlaybackTrace('mediakit');
    setState(() {
      _isLoading = true;
      _error = '';
    });

    try {
      final ep = _effectiveCurrentEpisode;
      final resumeLookup = resolveResumePoint(
        read: _read,
        item: _item,
        episode: ep,
        videoUrl: _currentVideoUrl,
      );

      final localResume = resumePointFor(
        read: _read,
        item: _item,
        episode: ep,
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
      _trace?.lap('resume');

      final resolved = await resolvePlayback(
        read: _read,
        item: _item,
        videoUrl: _currentVideoUrl,
        preloadedStreams: _currentVideoUrl == widget.videoUrl
            ? (widget.preloadedStreams ??
                  StreamPrewarmer.instance
                      .getPrewarmed(_currentVideoUrl)
                      ?.streams)
            : StreamPrewarmer.instance.getPrewarmed(_currentVideoUrl)?.streams,
        // A tapped row opens at once - its check runs behind the open and only
        // steers failover. An auto-picked list is speed-raced instead, so a
        // slow first mirror does not hold the screen.
        //
        // That check is a handful of range requests nobody asked for, so it is
        // skipped on a metered link: the preferred source opens as it stands,
        // and failover still covers one that turns out dead.
        // When AI Intent Pre-Fetch is active, bypass the 1.6s speed probe delay
        // to achieve instant time-to-first-frame handshake.
        probeCandidates:
            (_read(aiSettingsProvider).asData?.value.aiEnabled == true &&
                _read(aiSettingsProvider).asData?.value.intentPreFetch == true)
            ? 1
            : (await isOnMeteredNetwork() ? 1 : kSpeedProbeCandidates),
        probeBudget:
            (_read(aiSettingsProvider).asData?.value.aiEnabled == true &&
                _read(aiSettingsProvider).asData?.value.intentPreFetch == true)
            ? const Duration(milliseconds: 250)
            : kSpeedProbeBudget,
        isCancelled: () => _disposed,
        onCandidates: (streams) {
          if (mounted) setState(() => _candidates = streams);
        },
      );

      if (_disposed) return;
      _resolved = resolved;
      _candidates = resolved.streams;
      _attemptIndex = resolved.index;
      _trace?.lap(
        'resolved',
        'streams=${resolved.streams.length} index=${resolved.index}',
      );

      _token++;
      _recorder = PlaybackProgressRecorder(
        read: _read,
        item: _item,
        episode: ep,
        videoUrl: _currentVideoUrl,
        token: _token,
      );

      _tracker = PlaybackTracker(
        read: _read,
        item: _item,
        episode: ep,
        videoUrl: _currentVideoUrl,
        token: _token,
      );

      final startPosition = resumePoint?.position ?? Duration.zero;
      // mpv reads its hwdec, cache and demuxer limits when the media opens.
      // These used to be applied without waiting, so the first open raced them
      // and could start with defaults. Resolution has been running meanwhile,
      // so awaiting here normally costs nothing.
      await _mpvConfig;
      if (_disposed) return;
      await _openCandidate(_attemptIndex, startAt: startPosition);
    } catch (e) {
      if (_disposed || !mounted) return;
      setState(() {
        _isLoading = false;
        _error = '$e';
      });
    }
  }

  /// Opens [index] on the engine.
  ///
  /// Resolution has already picked it: a tapped source that answered opens as
  /// tapped, and only one that left the check waiting was replaced by a
  /// quicker mirror. A URL the engine rejects gets one retry through the
  /// local proxy before failover.
  Future<void> _openCandidate(
    int index, {
    Duration startAt = Duration.zero,
  }) async {
    final streams = _resolved?.streams ?? _candidates;
    if (streams.isEmpty) return;
    if (index < 0 || index >= streams.length) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isSwitching = false;
          _error = _lastEngineError.isEmpty
              ? 'All available sources failed to play.'
              : 'Playback failed: $_lastEngineError';
        });
      }
      return;
    }

    final stream = streams[index];
    // Resolution drops torrents, but a list built before that rule must not
    // be able to send one to the engine.
    if (isTorrentSource(stream)) {
      _failoverNext();
      return;
    }

    final switching = _hasPlayedOnce;
    _attemptIndex = index;
    _errorRecoveryTimer?.cancel();
    _lastEngineError = '';
    final token = ++_openToken;

    if (mounted) {
      setState(() {
        if (switching) {
          _isSwitching = true;
        } else {
          _isLoading = true;
        }
        _error = '';
      });
    }

    final headers = playbackHeaders(stream);
    final url = AppUtils.normalizeUrl(stream.url);
    final at = startAt > Duration.zero && !isLiveSource(_item, _currentVideoUrl)
        ? startAt
        : null;

    _startupWatchdog?.cancel();
    _startupWatchdog = null;
    _attemptOpenedAt = null;
    _attemptStartAt = at ?? Duration.zero;
    _attemptReachedPicture = false;
    _attemptTriedProxy = false;
    _attemptTriedDirect = false;
    _unrecognizedFormatErrors = 0;
    _attemptProviderId = providerIdForStream(
      stream,
      fallback: _item.provider ?? '',
    );
    _trace?.lap(
      'open',
      'attempt=$index source=${stream.providerName} quality=${stream.source}',
    );
    _loadSourceSubtitles(stream, headers, at ?? Duration.zero);

    try {
      final bool isAlreadyProxied =
          url.startsWith('http://127.0.0.1:') ||
          url.startsWith('http://localhost:');
      final bool shouldRouteThroughShield =
          !isAlreadyProxied &&
          (headers.isNotEmpty ||
              url.toLowerCase().contains('.m3u8') ||
              url.toLowerCase().contains('.mpd'));

      String playUrl = url;
      Map<String, String>? playHeaders = headers;

      if (shouldRouteThroughShield) {
        await LocalProxyService.instance.startServer();
        playUrl = LocalProxyService.instance.getProxyUrl(url, headers: headers);
        _attemptTriedProxy = true;
        playHeaders = const {'X-Local-Proxy': '1'};
        if (_player.platform is NativePlayer) {
          final native = _player.platform as NativePlayer;
          await native.setProperty('referer', '');
          await native.setProperty('http-header-fields', 'X-Local-Proxy: 1');
        }
      } else if (_player.platform is NativePlayer) {
        final native = _player.platform as NativePlayer;
        final referer = headers['Referer'] ?? headers['referer'];
        await native.setProperty('referer', referer ?? '');
        final extraFields = <String>[];
        headers.forEach((k, v) {
          final lk = k.toLowerCase();
          if (lk != 'referer' && lk != 'user-agent') {
            extraFields.add('$k: $v');
          }
        });
        await native.setProperty('http-header-fields', extraFields.join(','));
      }

      await _player.open(
        Media(playUrl, httpHeaders: playHeaders, start: at),
        play: true,
      );
      if (_disposed || !mounted || token != _openToken) return;
      _armStartupWatchdog(token);
      setState(() {
        if (_player.state.playing) {
          _isLoading = false;
          _isSwitching = false;
          _hasPlayedOnce = true;
        }
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[MediaKit] Failed to open stream $index: $e');
      _trace?.warn('open-failed', 'attempt=$index error=${e.runtimeType}');
      if (_disposed || !mounted || token != _openToken) return;
      if (await _tryProxyFallback(url, headers, at, token)) return;
      _recordProviderHealth(success: false, reason: 'could not open: $e');
      _failoverNext();
    }
  }

  /// Retries an engine-rejected URL through the local proxy, which can hand
  /// mpv a URL shape it accepts and carries the source's own headers on every
  /// request.
  Future<bool> _tryProxyFallback(
    String url,
    Map<String, String> headers,
    Duration? at,
    int token,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.scheme.startsWith('http')) return false;
    if (uri.host == '127.0.0.1' ||
        uri.host == 'localhost' ||
        _attemptTriedProxy) {
      return false;
    }
    _attemptTriedProxy = true;
    try {
      await LocalProxyService.instance.startServer();
      final proxyUrl = LocalProxyService.instance.getProxyUrl(
        url,
        headers: headers,
      );
      if (_player.platform is NativePlayer) {
        final native = _player.platform as NativePlayer;
        await native.setProperty('referer', '');
        await native.setProperty('http-header-fields', 'X-Local-Proxy: 1');
      }
      await _player.open(
        Media(proxyUrl, httpHeaders: headers, start: at),
        play: true,
      );
      if (_disposed || !mounted || token != _openToken) return true;
      _trace?.lap('proxy-retry', 'reopened attempt=$_attemptIndex');
      _armStartupWatchdog(token);
      setState(() {
        if (_player.state.playing) {
          _isLoading = false;
          _isSwitching = false;
          _hasPlayedOnce = true;
        }
      });
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[MediaKit] Proxy fallback failed: $e');
      _trace?.warn('proxy-retry', 'failed ${e.runtimeType}');
      return false;
    }
  }

  /// Retries a source that was opened through the proxy directly on the
  /// engine's own HTTP stack.
  ///
  /// The direct path is the control for a silent proxied open: it removes the
  /// local listener, the URL rewrite, the header sanitiser and the DoH answer
  /// in one step, so a source that plays this way was failed by the proxy and
  /// one that does not was failed by itself. The source's own headers still go
  /// with it, since some mirrors refuse a bare request.
  Future<bool> _tryDirectOpen(
    String url,
    Map<String, String> headers,
    Duration? at,
    int token,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.scheme.startsWith('http')) return false;
    if (uri.host == '127.0.0.1' ||
        uri.host == 'localhost' ||
        _attemptTriedDirect) {
      return false;
    }
    _attemptTriedDirect = true;
    try {
      if (_player.platform is NativePlayer) {
        final native = _player.platform as NativePlayer;
        final referer = headers['Referer'] ?? headers['referer'];
        await native.setProperty('referer', referer ?? '');
        final extraFields = <String>[];
        headers.forEach((k, v) {
          final lk = k.toLowerCase();
          if (lk != 'referer' && lk != 'user-agent') {
            extraFields.add('$k: $v');
          }
        });
        await native.setProperty('http-header-fields', extraFields.join(','));
      }
      await _player.open(
        Media(url, httpHeaders: headers, start: at),
        play: true,
      );
      if (_disposed || !mounted || token != _openToken) return true;
      _trace?.lap('direct-retry', 'reopened attempt=$_attemptIndex');
      _armStartupWatchdog(token);
      setState(() {
        if (_player.state.playing) {
          _isLoading = false;
          _isSwitching = false;
          _hasPlayedOnce = true;
        }
      });
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[MediaKit] Direct fallback failed: $e');
      _trace?.warn('direct-retry', 'failed ${e.runtimeType}');
      return false;
    }
  }

  void _failoverNext() {
    final streams = _resolved?.streams ?? _candidates;
    if (_attemptIndex + 1 < streams.length) {
      _trace?.warn(
        'failover',
        'attempt=$_attemptIndex -> ${_attemptIndex + 1}/${streams.length}',
      );
      _openCandidate(_attemptIndex + 1, startAt: _position);
    } else {
      _trace?.warn('gave-up', 'no source left');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = _lastEngineError.isEmpty
              ? 'Playback failed. No more available streams.'
              : 'Playback failed: $_lastEngineError';
        });
      }
    }
  }

  /// The URL of the stream the engine is on, or null before a stream is
  /// chosen. The attempt index is advanced by failover and replaced on a retry,
  /// and a progress sample should never be the thing that indexes past the
  /// list.
  String? get _currentStreamUrl {
    final streams = _resolved?.streams ?? _candidates;
    if (_attemptIndex < 0 || _attemptIndex >= streams.length) return null;
    return streams[_attemptIndex].url;
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
        _recorder?.record(sample, lastStreamUrl: _currentStreamUrl);
        _tracker?.onPlaying(sample);
      }
    }
  }

  /// Writes the position now, without ending the session.
  void _flushProgress() {
    final dur = _duration;
    if (dur <= Duration.zero) return;
    _recorder?.record(
      ProgressSample(position: _position, duration: dur, token: _token),
      lastStreamUrl: _currentStreamUrl,
      force: true,
    );
  }

  void _recordFinalProgress() {
    if (_duration <= Duration.zero) return;
    _flushProgress();
    _tracker?.finish();
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
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      final isFull = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!isFull);
      if (mounted) {
        setState(() => _isFullscreen = !isFull);
      }
    } else if (!kIsWeb && Platform.isAndroid) {
      final isLandscape =
          MediaQuery.of(context).orientation == Orientation.landscape;
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

  /// Replaces the picture's fit - chosen in the More sheet, since it changes
  /// the shape of the picture rather than the playback.
  void _setFit(BoxFit fit) {
    if (fit == _fit) return;
    setState(() => _fit = fit);
  }

  /// Replaces the source's subtitle files for the media that has just been
  /// opened, and puts one on under Auto: the file the viewer was reading
  /// before a reopen, else the source's file in their language.
  ///
  /// Called per attempt, as libVLC's player does, because a failover, a
  /// recovery and a step-down are new media with their own files.
  void _loadSourceSubtitles(
    StreamResult stream,
    Map<String, String> headers,
    Duration startAt,
  ) {
    final previous = _sideCars.active;
    final tracks = _sideCars.replaceSourceTracks([
      for (final sub in stream.subtitles ?? const <SubtitleFile>[])
        if (_playableSubtitleUri(sub.url) case final url?)
          (
            url: url,
            label: sub.label,
            language: sub.lang,
            // A source's subtitles usually sit behind the same checks as its
            // video; a local file has no use for them.
            headers: url.scheme.startsWith('http') ? headers : null,
          ),
    ]);

    final carried = previous?.origin == SideCarOrigin.source
        ? matchSideCar(tracks, previous!)
        : null;
    if (carried != null) {
      _subtitlesOffPending = false;
      unawaited(_sideCars.select(carried, from: startAt));
      return;
    }

    _viewerChoseSubtitle = false;
    _subtitleOffAsked = null;
    final settings =
        _read(playerSettingsProvider).asData?.value ?? const PlayerSettings();
    _subtitlesOffPending = settings.subtitleDefault == SubtitleDefault.off;
    if (_subtitlesOffPending || _sideCars.active != null) return;

    final preferred = preferredSubtitleIndex([
      for (final track in tracks) track.languageCode,
    ], _read(subtitleLanguageProvider));
    if (preferred != null) {
      unawaited(_sideCars.select(tracks[preferred], from: startAt));
    }
  }

  /// Turns off a subtitle mpv selected for itself while one of SkyStream's own
  /// files is on - two on screen at once is never what anyone chose - or while
  /// the setting says Off.
  ///
  /// A standing rule rather than a single call, because mpv can select a
  /// subtitle at the open, when its streams arrive, and again after a seek.
  /// The Off half stands down for the rest of the media the moment the
  /// subtitles sheet is opened.
  void _applySubtitleDefault(String activeId) {
    if (_sideCars.active != null) {
      if (activeId == 'no') {
        _subtitleOffAsked = null;
        return;
      }
      if (activeId == _subtitleOffAsked) return;
      _subtitleOffAsked = activeId;
      unawaited(_player.setSubtitleTrack(SubtitleTrack.no()));
      return;
    }
    if (_viewerChoseSubtitle || !_subtitlesOffPending) return;
    if (activeId == 'no') {
      // Nothing is selected, so the last request landed.
      _subtitleOffAsked = null;
      return;
    }
    if (activeId == _subtitleOffAsked) return;
    _subtitleOffAsked = activeId;
    unawaited(_player.setSubtitleTrack(SubtitleTrack.no()));
  }

  /// A file went on: mpv's own subtitle goes off now, so only one is on
  /// screen.
  void _onSideCars() {
    if (_disposed) return;
    if (_sideCars.active == null) return;
    if (_player.state.track.subtitle.id == 'no') return;
    unawaited(_player.setSubtitleTrack(SubtitleTrack.no()));
  }

  /// A file arrived in a format SkyStream does not read. mpv can be handed
  /// files a different way, but not from here, so the viewer is told rather
  /// than left wondering why the row disappeared.
  void _handSideCarToEngine(SideCarTrack track) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.failedToLoadSubtitles)));
  }

  Uri? _playableSubtitleUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return null;
    if (uri.scheme == 'file') return uri;
    return uri.scheme.startsWith('http') ? uri : null;
  }

  /// The tracks inside the video, in the panel's rows so a remote can reach
  /// them. mpv's own `no` and `auto` entries are not tracks a viewer picks.
  Future<void> _showAudioTrackDialog() async {
    _onUserActivity();
    final l10n = AppLocalizations.of(context);
    final audioTracks = [
      for (final track in _player.state.tracks.audio)
        if (track.id != 'no' && track.id != 'auto') track,
    ];
    final current = _player.state.track.audio;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: HotstarPlayerStyle.panelElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return PlayerPanelMetricsScope(
          metrics: PlayerPanelMetrics.forTv(_isTv),
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PlayerSheetHeader(
                    title: l10n?.audioTracks ?? 'Audio',
                    isTv: _isTv,
                  ),
                  // One audio track is the norm, and the engine reports it -
                  // there is simply nothing to choose between.
                  if (audioTracks.isEmpty)
                    const PanelEmpty(text: 'Default Audio')
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: 12),
                        children: [
                          for (final (index, track) in audioTracks.indexed)
                            PanelRow(
                              label:
                                  track.title ??
                                  track.language ??
                                  l10n?.playerTrackNumber(index + 1) ??
                                  'Track ${index + 1}',
                              selected: track.id == current.id,
                              autofocus: track.id == current.id,
                              onTap: () {
                                Navigator.of(sheetContext).maybePop();
                                if (track.id != current.id) {
                                  _holdThroughTrackChange();
                                  unawaited(_player.setAudioTrack(track));
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showSubtitleTrackDialog() async {
    _onUserActivity();
    // Every subtitle choice is made here, so from now on neither the Off
    // default nor Auto touches the track.
    _viewerChoseSubtitle = true;
    _subtitlesOffPending = false;
    _subtitleOffAsked = null;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: HotstarPlayerStyle.panelElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => MediaKitSubtitleSheet(
        sideCars: _sideCars,
        delay: _subtitlePlayback.delayListenable,
        embeddedTracks: _embeddedSubtitles,
        activeEmbeddedId: _activeEmbeddedSubtitle,
        isTv: _isTv,
        onOff: _turnSubtitlesOff,
        onEmbedded: _selectEmbeddedSubtitle,
        onSideCar: (file) => unawaited(_sideCars.select(file, from: _position)),
        onDelay: _setSubtitleDelay,
        onLoadFile: () => unawaited(_loadSubtitleFile()),
        onSearch: () => unawaited(_openSubtitleSearch()),
      ),
    );
  }

  void _turnSubtitlesOff() {
    _viewerChoseSubtitle = true;
    _subtitlesOffPending = true;
    unawaited(_sideCars.select(null));
    unawaited(_player.setSubtitleTrack(SubtitleTrack.no()));
  }

  void _selectEmbeddedSubtitle(SubtitleTrack track) {
    _viewerChoseSubtitle = true;
    _subtitlesOffPending = false;
    unawaited(_sideCars.select(null));
    unawaited(_player.setSubtitleTrack(track));
  }

  /// Moves the lines against the picture, for both SkyStream's files and the
  /// tracks mpv draws.
  void _setSubtitleDelay(Duration delay) {
    _subtitlePlayback.setDelay(delay);
    final platform = _player.platform;
    if (platform is NativePlayer) {
      unawaited(
        platform.setProperty(
          'sub-delay',
          (delay.inMilliseconds / 1000).toStringAsFixed(3),
        ),
      );
    }
  }

  Future<void> _loadSubtitleFile() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa', 'sub'],
    );
    final path = picked?.path;
    if (path == null) return;
    await _useSubtitleFile(Uri.file(path), label: picked?.name);
  }

  /// Lists a file the viewer brought and puts it on, filling in as it is read.
  Future<bool> _useSubtitleFile(
    Uri file, {
    String? label,
    String? language,
  }) async {
    _viewerChoseSubtitle = true;
    _subtitlesOffPending = false;
    try {
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(file.toString(), title: label, language: language),
      );
    } catch (_) {}
    final track = _sideCars.addViewerTrack(
      file,
      label: label,
      language: language,
    );
    return _sideCars.select(track, from: _position);
  }

  /// The online search, on the same page the libVLC player opens.
  Future<void> _openSubtitleSearch() async {
    _viewerChoseSubtitle = true;
    final target = SubtitleSearchTarget.of(_item, _effectiveCurrentEpisode);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) {
          final l10n = AppLocalizations.of(context)!;
          return Scaffold(
            backgroundColor: const Color(0xFF141414),
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              foregroundColor: Colors.white,
              title: Text(l10n.searchSubtitlesOnline),
            ),
            body: SafeArea(
              child: SubtitleSearchPage(
                target: target,
                onFile: (file, subtitle) => _useSubtitleFile(
                  file,
                  label: subtitle.name.isEmpty ? null : subtitle.name,
                  language: subtitle.language,
                ),
                onDone: () => Navigator.of(context).maybePop(),
              ),
            ),
          );
        },
      ),
    );
  }

  /// The badge the control bar shows for what is playing.
  String get _currentQualityLabel {
    if (_manualQualitySelection != null && _manualQualitySelection != 'Auto') {
      return _manualQualitySelection!;
    }
    final activeVideo = _currentVideoTrack.value;
    if (activeVideo != null && activeVideo.h != null && activeVideo.h! > 0) {
      final h = activeVideo.h!;
      if (h >= 1800) return '4K';
      if (h >= 1260) return '2K';
      if (h >= 900) return '1080p';
      if (h >= 600) return '720p';
      if (h >= 420) return '480p';
      if (h >= 240) return '360p';
    }
    final streams = _resolved?.streams ?? _candidates;
    if (_attemptIndex >= 0 && _attemptIndex < streams.length) {
      final badge = qualityBadgeLabel(streams[_attemptIndex]);
      if (badge != 'Auto') return badge;
    }
    return 'Quality';
  }

  Future<void> _switchSource(int index) async {
    if (_disposed || !mounted) return;
    if (index == _attemptIndex && _player.state.playing) return;
    await _openCandidate(index, startAt: _position);
  }

  void _showSourcesDialog() => _showQualityAndSourcesDialog();

  /// Quality and Source picker: lets the user explicitly lock a desired quality
  /// (Auto, 4K, 1080p, 720p, 480p, 360p) or switch specific HLS renditions,
  /// and pick individual provider mirrors.
  void _showQualityAndSourcesDialog() {
    _onUserActivity();
    final streams = _resolved?.streams ?? _candidates;
    final playingIndex = _attemptIndex;
    final videoTracks = _videoTracks.value;
    final activeTrack = _currentVideoTrack.value;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: HotstarPlayerStyle.panelElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        final l10n = AppLocalizations.of(sheetContext)!;
        return PlayerPanelMetricsScope(
          metrics: PlayerPanelMetrics.forTv(_isTv),
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.78,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PlayerSheetHeader(
                    title: l10n.playerQualityAndSources,
                    isTv: _isTv,
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        // SECTION 1: RESOLUTION / STREAM QUALITY
                        const PanelSubheader(title: 'Quality & Resolution'),

                        // 1. Auto (Adaptive)
                        PanelRow(
                          label: l10n.playerAutoAdaptive,
                          detail: 'Automatically matches connection speed',
                          badges: const <String>['Adaptive'],
                          icon: Icons.auto_awesome_rounded,
                          selected:
                              _manualQualitySelection == null ||
                              _manualQualitySelection == 'Auto',
                          selectedLabel: 'Active',
                          onTap: () {
                            setState(() {
                              _manualQualitySelection = 'Auto';
                            });
                            unawaited(_player.setVideoTrack(VideoTrack.auto()));
                            Navigator.of(sheetContext).maybePop();
                          },
                        ),

                        // 2. Direct HLS Renditions (if demuxed by mpv)
                        if (videoTracks.length > 1) ...[
                          for (final track in videoTracks)
                            PanelRow(
                              label: track.h != null
                                  ? '${track.h}p ${track.h! >= 1080 ? 'Full HD' : (track.h! >= 720 ? 'HD' : 'SD')}'
                                  : (track.title ?? 'Track ${track.id}'),
                              detail: [
                                if (track.w != null && track.h != null)
                                  '${track.w}x${track.h}',
                                if (track.bitrate != null && track.bitrate! > 0)
                                  '${(track.bitrate! / 1000000).toStringAsFixed(1)} Mbps',
                                if (track.fps != null && track.fps! > 0)
                                  '${track.fps!.toStringAsFixed(0)} fps',
                                if (track.codec != null) track.codec!,
                              ].join(' • '),
                              badges: <String>[
                                if (track.h != null) '${track.h}p',
                              ],
                              selected: activeTrack?.id == track.id,
                              selectedLabel: 'Selected',
                              onTap: () {
                                setState(() {
                                  _manualQualitySelection = track.h != null
                                      ? '${track.h}p'
                                      : track.id;
                                });
                                unawaited(_player.setVideoTrack(track));
                                Navigator.of(sheetContext).maybePop();
                              },
                            ),
                        ],

                        // 3. Discrete Target Tiers (4K, 1080p, 720p, 480p, 360p)
                        for (final targetTier in const [
                          (QualityTier.q4k, '4K Ultra HD', '4K'),
                          (QualityTier.q1080, '1080p Full HD', '1080p'),
                          (QualityTier.q720, '720p High Definition', '720p'),
                          (
                            QualityTier.q480,
                            '480p Standard Definition',
                            '480p',
                          ),
                          (QualityTier.q360, '360p Data Saver', '360p'),
                        ]) ...[
                          () {
                            final tier = targetTier.$1;
                            final title = targetTier.$2;
                            final badge = targetTier.$3;

                            final matchingTrack = videoTracks.firstWhereOrNull(
                              (t) => t.h != null && tierForHeight(t.h!) == tier,
                            );

                            final matchingCandidates = streams
                                .asMap()
                                .entries
                                .where(
                                  (e) =>
                                      detectQualityTier(e.value.source) == tier,
                                )
                                .toList();

                            final isAvailable =
                                matchingTrack != null ||
                                matchingCandidates.isNotEmpty;
                            final isCurrentlyActive =
                                _currentQualityLabel == badge ||
                                (activeTrack != null &&
                                    activeTrack.h != null &&
                                    tierForHeight(activeTrack.h!) == tier);

                            if (!isAvailable && videoTracks.isNotEmpty) {
                              return const SizedBox.shrink();
                            }

                            return PanelRow(
                              label: title,
                              detail: isAvailable
                                  ? (matchingTrack != null
                                        ? 'Stream video track'
                                        : '${matchingCandidates.length} server mirror${matchingCandidates.length > 1 ? 's' : ''}')
                                  : 'No server reported this exact resolution',
                              badges: <String>[badge],
                              icon: Icons.high_quality_rounded,
                              selected: isCurrentlyActive,
                              selectedLabel: 'Active',
                              enabled: isAvailable,
                              onTap: () {
                                setState(() {
                                  _manualQualitySelection = badge;
                                });
                                Navigator.of(sheetContext).maybePop();

                                if (matchingTrack != null) {
                                  unawaited(
                                    _player.setVideoTrack(matchingTrack),
                                  );
                                } else if (matchingCandidates.isNotEmpty) {
                                  final bestIndex =
                                      matchingCandidates.first.key;
                                  if (bestIndex != playingIndex) {
                                    unawaited(_switchSource(bestIndex));
                                  }
                                }
                              },
                            );
                          }(),
                        ],

                        // SECTION 2: PROVIDER SERVERS / SOURCES
                        const SizedBox(height: 12),
                        const PanelSubheader(
                          title: 'Provider Servers & Mirrors',
                        ),

                        if (streams.isEmpty)
                          const PanelEmpty(
                            text: 'No other sources were found for this title.',
                          )
                        else
                          for (final (index, stream) in streams.indexed)
                            PanelRow(
                              label: stream.displaySource,
                              detail: [
                                if (stream.providerName.isNotEmpty &&
                                    stream.providerName.toLowerCase() !=
                                        'unknown')
                                  stream.providerName,
                                if (stream.url.contains('.m3u8'))
                                  'HLS Adaptive'
                                else if (stream.url.contains('.mp4') ||
                                    stream.url.contains('.mkv'))
                                  'Direct Container',
                              ].join(' • '),
                              badges: <String>[qualityBadgeLabel(stream)],
                              selected: index == playingIndex,
                              selectedLabel: 'Now playing',
                              autofocus: index == playingIndex,
                              onTap: () {
                                Navigator.of(sheetContext).maybePop();
                                if (index != playingIndex) {
                                  unawaited(_switchSource(index));
                                }
                              },
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _cleanupPlatformOnExit() {
    try {
      _player.stop();
    } catch (_) {}
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
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      try {
        windowManager
            .isFullScreen()
            .then((isFull) {
              if (isFull) windowManager.setFullScreen(false);
            })
            .catchError((_) {});
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
  void dispose() {
    _disposed = true;
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _hideControlsTimer?.cancel();
    _errorRecoveryTimer?.cancel();
    _trackSwitchWatchdog?.cancel();
    _startupWatchdog?.cancel();
    _midstreamStallWatchdog?.cancel();
    for (final s in _subscriptions) {
      try {
        s.cancel();
      } catch (_) {}
    }
    _subscriptions.clear();
    try {
      _recordFinalProgress();
    } catch (e, st) {
      if (kDebugMode)
        debugPrint('Error during _recordFinalProgress in dispose: $e\n$st');
    }
    try {
      _tracker?.finish();
    } catch (e, st) {
      if (kDebugMode)
        debugPrint('Error during _tracker.finish in dispose: $e\n$st');
    }
    try {
      _cleanupPlatformOnExit();
    } catch (e, st) {
      if (kDebugMode)
        debugPrint('Error during _cleanupPlatformOnExit in dispose: $e\n$st');
    }
    try {
      _sideCars.removeListener(_onSideCars);
      _sideCars.dispose();
    } catch (_) {}
    try {
      _subtitlePlayback.dispose();
    } catch (_) {}
    try {
      _embeddedSubtitles.dispose();
    } catch (_) {}
    try {
      _activeEmbeddedSubtitle.dispose();
    } catch (_) {}
    try {
      _videoTracks.dispose();
    } catch (_) {}
    try {
      _currentVideoTrack.dispose();
    } catch (_) {}
    try {
      _player.dispose();
    } catch (_) {}
    try {
      _focusNode.dispose();
    } catch (_) {}
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.space) {
      _togglePlayPause();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _seekRelative(_seekStep);
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _seekRelative(-_seekStep);
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
    // Watched, so a profile that resolves after the first frame - the usual
    // case on a television - re-lays the chrome out at ten-foot size.
    _form = playerFormFactorOf(ref.watch(deviceProfileProvider).asData?.value);

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
                if (!kIsWeb &&
                    (Platform.isWindows ||
                        Platform.isLinux ||
                        Platform.isMacOS)) {
                  _toggleFullscreen();
                } else {
                  final screenWidth = MediaQuery.of(context).size.width;
                  if (details.localPosition.dx < screenWidth / 2) {
                    _seekRelative(-_seekStep);
                  } else {
                    _seekRelative(_seekStep);
                  }
                }
              },
              child: Stack(
                children: [
                  // Video Surface (Direct3D 11 / MediaCodec GPU)
                  Center(
                    child: RepaintBoundary(
                      child: Video(
                        controller: _videoController,
                        fit: _fit,
                        // media_kit's NoVideoControls is `const ... = null`
                        // with no type, so it reads as dynamic and does not
                        // assign to the builder type. Null is what it means.
                        controls: null,
                      ),
                    ),
                  ),

                  // The source's and the viewer's subtitle files, drawn over
                  // the picture so Zoom and Stretch never touch them - the
                  // same renderer libVLC's player uses.
                  Positioned.fill(
                    child: Consumer(
                      builder: (context, ref, _) {
                        final settings =
                            ref.watch(playerSettingsProvider).asData?.value ??
                            const PlayerSettings();
                        return SideCarSubtitleView(
                          playback: _subtitlePlayback,
                          subtitles: _sideCars,
                          settings: settings,
                          // Lifted over the bar while it is up, by the same
                          // clearance every other overlay in the player uses.
                          bottomInset: _controlsVisible
                              ? HotstarPlayerStyle.bottomChromeHeightFor(
                                  isTv: _isTv,
                                )
                              : 0,
                        );
                      },
                    ),
                  ),

                  // Subtle Buffering Indicator
                  if (_isBuffering &&
                      !_isLoading &&
                      !_isSwitching &&
                      _error.isEmpty)
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

                  // Mid-session source change: the picture stays up, so this
                  // says what is happening without replacing the frame with
                  // the full startup screen.
                  if (_isSwitching && _error.isEmpty)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _currentQualityLabel == 'Sources'
                                  ? 'Switching source…'
                                  : 'Switching to $_currentQualityLabel…',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Seamless / Stremio Startup Overlay
                  if ((_isLoading || _error.isNotEmpty) && !_isSwitching)
                    PlayerStartupView(
                      title: _item.title,
                      onPick: (index) =>
                          _openCandidate(index, startAt: _position),
                      episodeLine: _effectiveCurrentEpisode != null
                          ? (_effectiveCurrentEpisode!.name.isNotEmpty
                                ? (_effectiveCurrentEpisode!.season > 0
                                      ? 'S${_effectiveCurrentEpisode!.season} E${_effectiveCurrentEpisode!.episode} - ${_effectiveCurrentEpisode!.name}'
                                      : 'Episode ${_effectiveCurrentEpisode!.episode} - ${_effectiveCurrentEpisode!.name}')
                                : (_effectiveCurrentEpisode!.season > 0
                                      ? 'Season ${_effectiveCurrentEpisode!.season} Episode ${_effectiveCurrentEpisode!.episode}'
                                      : 'Episode ${_effectiveCurrentEpisode!.episode}'))
                          : null,
                      logoUrl: _item.logoUrl,
                      backdropUrl: _item.backdropImageUrl,
                      sourceName:
                          _candidates.isNotEmpty &&
                              _attemptIndex < _candidates.length
                          ? _candidates[_attemptIndex].source
                          : null,
                      status: _isLoading
                          ? (_candidates.isNotEmpty &&
                                    _attemptIndex < _candidates.length
                                ? 'Connecting to ${_candidates[_attemptIndex].source}…'
                                : 'Loading high-performance stream…')
                          : null,
                      reason: _error.isNotEmpty ? _error : null,
                      failed: _error.isNotEmpty,
                      attempt: _candidates.isNotEmpty
                          ? (
                              index: (_attemptIndex + 1).clamp(
                                1,
                                _candidates.length,
                              ),
                              total: _candidates.length,
                            )
                          : null,
                      onBack: _exitPlayer,
                      onRetry: _startPlayback,
                      stremioTheme: stremioTheme,
                      seamlessMode: seamlessMode,
                    ),

                  // Up Next Episode Countdown Card
                  if (_nextEpisodeOffer != null &&
                      !_nextEpisodeDeclined &&
                      (_settings?.showEpisodes ?? true))
                    Positioned(
                      bottom: 90,
                      right: 24,
                      child: NextEpisodeCountdown(
                        title: _nextEpisodeOffer!.name,
                        season: _nextEpisodeOffer!.season,
                        episode: _nextEpisodeOffer!.episode,
                        posterUrl:
                            _nextEpisodeOffer!.posterUrl ??
                            _item.posterImageUrl,
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

                  // A paused frame offers the one press it is waiting for, in
                  // the middle of the picture. While the film runs the bar's
                  // transport is enough - a cluster over the picture is chrome
                  // on a face, and it was the same four buttons twice.
                  if (!_playing &&
                      !_isBuffering &&
                      !_isLoading &&
                      _error.isEmpty)
                    Center(
                      child: PlayerCenterPlayButton(
                        playing: false,
                        label: AppLocalizations.of(context)?.play ?? 'Play',
                        onPressed: _togglePlayPause,
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
                          children: [_buildTopBar(), _buildBottomBar()],
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

  /// The top zone: Back, what is playing, and the one press worth having while
  /// an episode is queued.
  ///
  /// No engine badge. What decodes the picture is a fact about this device,
  /// not a control, and it sat where a viewer looks for a title.
  Widget _buildTopBar() {
    final l10n = AppLocalizations.of(context);
    final ep = _effectiveCurrentEpisode;
    final next = _nextEpisode;
    final String? epText = ep != null
        ? (ep.name.isNotEmpty
              ? (ep.season > 0
                    ? 'S${ep.season} E${ep.episode} — ${ep.name}'
                    : 'Episode ${ep.episode} — ${ep.name}')
              : (ep.season > 0
                    ? 'Season ${ep.season} Episode ${ep.episode}'
                    : 'Episode ${ep.episode}'))
        : null;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: PlayerTopBar(
        title: _item.title,
        subtitle: epText,
        onBack: _exitPlayer,
        isTv: _isTv,
        trailing: next == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(left: 12),
                child: PlayerActionButton(
                  icon: Icons.skip_next_rounded,
                  label: next.episode > 0
                      ? '${l10n?.next ?? 'Next'} E${next.episode}'
                      : (l10n?.next ?? 'Next'),
                  isTv: _isTv,
                  onTap: () {
                    _onUserActivity();
                    unawaited(_advance());
                  },
                ),
              ),
      ),
    );
  }

  /// The bottom zone: scrubber, transport, clock, then the three controls a
  /// viewer reaches for while watching. Everything else is one press away in
  /// [MediaKitMoreSheet].
  Widget _buildBottomBar() {
    final l10n = AppLocalizations.of(context);
    final String speedLabel =
        '${_playbackSpeed == 1.0 ? '1' : _playbackSpeed.toString()}x';
    final String fitTooltip = '${l10n?.fit ?? 'Fit'}: ${_fitLabel(_fit)}';
    final displayPos = _isDragging && _dragPosition != null
        ? _dragPosition!
        : _position;
    // A feed's clock has no end to count towards, so the label reads LIVE
    // instead of `00:12:04 / --:--` - the same rule, and the same helper, as
    // libVLC's bar.
    final live = isLiveSource(_item, _currentVideoUrl);
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: PlayerBottomBar(
        isTv: _isTv,
        // Everything but a television can drag the strip, so everything but a
        // television gets one line.
        scrollingActions: !_isTv,
        // Its own boundary: the scrubber repaints on every position tick,
        // which would otherwise repaint the bar, its scrim and every button.
        progressBar: RepaintBoundary(
          child: PlayerScrubber(
            position: displayPos,
            duration: _duration,
            hasDuration: _duration > Duration.zero,
            bufferRatio: _bufferRatio,
            canSeek: !live && _duration > Duration.zero,
            isTv: _isTv,
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
        ),
        leading: [
          PlayerIconButton(
            icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            tooltip: _playing
                ? (l10n?.pause ?? 'Pause')
                : (l10n?.play ?? 'Play'),
            isTv: _isTv,
            iconSize: _isTv ? 34 : 30,
            // A remote starts on the press it makes most often.
            autofocus: _isTv,
            onPressed: _togglePlayPause,
          ),
          if (_hasPreviousEpisode)
            PlayerIconButton(
              icon: Icons.skip_previous_rounded,
              tooltip: l10n?.previous ?? 'Previous',
              isTv: _isTv,
              onPressed: () {
                _onUserActivity();
                final prev = _previousEpisode;
                if (prev != null) unawaited(_startEpisode(prev));
              },
            ),
          if (_hasNextEpisode)
            PlayerIconButton(
              icon: Icons.skip_next_rounded,
              tooltip: l10n?.next ?? 'Next',
              isTv: _isTv,
              onPressed: () {
                _onUserActivity();
                unawaited(_advance());
              },
            ),
          // Nothing to step through on a feed: there is no recorded past to
          // skip back into and no future to skip ahead to.
          if (!live)
            PlayerIconButton(
              icon: Icons.replay_10_rounded,
              tooltip: l10n?.playerRewindSeconds(10) ?? 'Rewind 10s',
              isTv: _isTv,
              onPressed: () => _seekRelative(-10),
            ),
          if (!live)
            PlayerIconButton(
              icon: Icons.forward_10_rounded,
              tooltip: l10n?.playerForwardSeconds(10) ?? 'Forward 10s',
              isTv: _isTv,
              onPressed: () => _seekRelative(10),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 4),
            child: RepaintBoundary(
              child: PlayerTimeLabel(
                position: displayPos,
                duration: _duration,
                hasDuration: _duration > Duration.zero,
                isLive: live,
              ),
            ),
          ),
        ],
        actions: [
          if ((_item.episodes ?? widget.item.episodes)?.isNotEmpty ?? false)
            PlayerIconButton(
              icon: Icons.video_library_rounded,
              tooltip: l10n?.episodes ?? 'Episodes',
              isTv: _isTv,
              onPressed: _showEpisodesDialog,
            ),
          PlayerActionButton(
            label: speedLabel,
            icon: Icons.speed_rounded,
            isTv: _isTv,
            onTap: _cyclePlaybackSpeed,
          ),
          PlayerIconButton(
            icon: Icons.aspect_ratio_rounded,
            tooltip: fitTooltip,
            isTv: _isTv,
            onPressed: _cycleFit,
          ),
          ListenableBuilder(
            listenable: Listenable.merge([_videoTracks, _currentVideoTrack]),
            builder: (context, _) => PlayerActionButton(
              label: _currentQualityLabel,
              icon: Icons.high_quality_rounded,
              isTv: _isTv,
              onTap: _showQualityAndSourcesDialog,
            ),
          ),
          PlayerIconButton(
            icon: Icons.audiotrack_rounded,
            tooltip: l10n?.audioTracks ?? 'Audio',
            isTv: _isTv,
            onPressed: _showAudioTrackDialog,
          ),
          ListenableBuilder(
            listenable: Listenable.merge([_sideCars, _activeEmbeddedSubtitle]),
            builder: (context, _) => PlayerIconButton(
              icon: Icons.subtitles_rounded,
              tooltip: l10n?.subtitles ?? 'Subtitles',
              isTv: _isTv,
              highlight:
                  _sideCars.active != null ||
                  _activeEmbeddedSubtitle.value != null,
              onPressed: _showSubtitleTrackDialog,
            ),
          ),
          if (!kIsWeb &&
              (Platform.isWindows || Platform.isLinux || Platform.isMacOS))
            PlayerIconButton(
              icon: _isFullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              tooltip: _isFullscreen ? 'Exit Fullscreen' : 'Fullscreen',
              isTv: _isTv,
              onPressed: _toggleFullscreen,
            ),
          PlayerIconButton(
            icon: Icons.tune_rounded,
            tooltip: l10n?.options ?? 'Options',
            isTv: _isTv,
            onPressed: _showMoreSheet,
          ),
        ],
      ),
    );
  }

  void _cyclePlaybackSpeed() {
    _onUserActivity();
    const speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    int nextIdx = 0;
    for (int i = 0; i < speeds.length; i++) {
      if ((speeds[i] - _playbackSpeed).abs() < 0.05) {
        nextIdx = (i + 1) % speeds.length;
        break;
      }
    }
    _setPlaybackSpeed(speeds[nextIdx]);
  }

  void _cycleFit() {
    _onUserActivity();
    final next = switch (_fit) {
      BoxFit.contain => BoxFit.cover,
      BoxFit.cover => BoxFit.fill,
      _ => BoxFit.contain,
    };
    setState(() => _fit = next);
  }

  String _fitLabel(BoxFit fit) => switch (fit) {
    BoxFit.cover => 'Zoom',
    BoxFit.fill => 'Stretch',
    _ => 'Fit',
  };

  Future<void> _showEpisodesDialog() async {
    _onUserActivity();
    final episodes = _item.episodes ?? widget.item.episodes ?? [];
    if (episodes.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: HotstarPlayerStyle.panelElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => PlayerPanelMetricsScope(
        metrics: PlayerPanelMetrics.forTv(_isTv),
        child: SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.75,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PlayerSheetHeader(
                  title: 'Episodes (${episodes.length})',
                  isTv: _isTv,
                ),
                Flexible(
                  child: PlayerEpisodesTab(
                    episodes: episodes,
                    currentEpisode: _effectiveCurrentEpisode,
                    onPick: (ep) {
                      Navigator.of(sheetContext).maybePop();
                      unawaited(_startEpisode(ep));
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Speed, fit, fullscreen and the source picker: the controls that change
  /// how the film is played rather than what is playing.
  Future<void> _showMoreSheet() async {
    _onUserActivity();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: HotstarPlayerStyle.panelElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => MediaKitMoreSheet(
        speed: _playbackSpeed,
        fit: _fit,
        isFullscreen: _isFullscreen,
        quality: _currentQualityLabel,
        isTv: _isTv,
        isLive: isLiveSource(_item, _currentVideoUrl),
        onSpeed: _setPlaybackSpeed,
        onFit: _setFit,
        onFullscreen: _toggleFullscreen,
        onSources: () {
          Navigator.of(sheetContext).maybePop();
          _showSourcesDialog();
        },
      ),
    );
  }

  void _setPlaybackSpeed(double speed) {
    if (speed == _playbackSpeed) return;
    setState(() => _playbackSpeed = speed);
    unawaited(_player.setRate(speed));
  }
}
