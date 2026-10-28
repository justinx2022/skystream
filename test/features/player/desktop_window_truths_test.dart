import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/services/local_proxy_service.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/player/presentation/player_platform_service.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_screen.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';
import 'package:window_manager/window_manager.dart';

/// Two desktop lies the player used to tell.
///
/// The first is full screen. `_isFullscreen` was only ever written by the
/// player's own toggle, so anything else that moved the window - the app-wide
/// F11 handler in main.dart, the macOS green button, the window menu - left the
/// flag stale: the button showed the wrong icon and Escape, which the controls
/// gate on that flag, did nothing. The window is the only thing that knows, so
/// the proof here is that the *window's* events move the flag, with no toggle
/// call anywhere in the test.
///
/// The second is video fit. `VlcPlayer` builds its own FittedBox from `fit`,
/// but the screen constructed it with no `fit:` at all, so the texture path was
/// pinned to contain no matter what the viewer's default resize mode said -
/// and on Windows and Linux the native `setFit` the controls call is a no-op,
/// so nothing else was going to honour it either.
///
/// The texture platform is the subject for the same reason the PiP test uses
/// it: `create` answers with its own view id, so the test knows which event
/// channel to speak on to get a first frame and reach the playing stage.
const MethodChannel _pip = MethodChannel('dev.akash.skystream.player/pip');
const MethodChannel _vlc = MethodChannel('vlc_player');
const MethodChannel _window = MethodChannel('window_manager');

const int _viewId = 1;
const EventChannel _events = EventChannel('vlc_player/events/$_viewId');

final TargetPlatformVariant _texturePlatform = TargetPlatformVariant.only(
  TargetPlatform.windows,
);

/// See pip_engine_continuity_test.dart: wakelock_plus speaks pigeon, and an
/// unanswered toggle surfaces as a stray PlatformException on whichever test
/// happens to be running.
const String _wakelockToggle =
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

/// The screen watches connectivity for the whole of its life and, on a
/// handset, mirrors the system volume through the volume plugin. Both open a
/// platform stream that has to be cancelled on dispose, so both need answering
/// here as well as on the device; see vlc_screen_harness.dart.
const MethodChannel _connectivity = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);
const EventChannel _connectivityStatus = EventChannel(
  'dev.fluttercommunity.plus/connectivity_status',
);
const MethodChannel _volume =
    MethodChannel('com.yosemiteyss.flutter_volume_controller/method');
const EventChannel _volumeEvents =
    EventChannel('com.yosemiteyss.flutter_volume_controller/event');

final ByteData? _wakelockReply = const StandardMessageCodec().encodeMessage(
  <Object?>[null],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// What the window would answer if asked. The screen reads it once on the
  /// way in, which is the only way it can know about a window that was already
  /// full screen before the video opened.
  late bool windowIsFullScreen;

  setUp(() {
    windowIsFullScreen = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_vlc, (call) async {
      if (call.method == 'create') {
        return <String, Object?>{'viewId': _viewId, 'textureId': _viewId};
      }
      return null;
    });
    messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(onListen: (arguments, sink) {}),
    );
    messenger.setMockMessageHandler(
      _wakelockToggle,
      (message) async => _wakelockReply,
    );
    messenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(
      _connectivity,
      (call) async => <String>['wifi'],
    );
    messenger.setMockStreamHandler(
      _connectivityStatus,
      MockStreamHandler.inline(onListen: (arguments, sink) {}),
    );
    messenger.setMockMethodCallHandler(_volume, (call) async {
      if (call.method == 'getVolume') return '1.0';
      return null;
    });
    messenger.setMockStreamHandler(
      _volumeEvents,
      MockStreamHandler.inline(onListen: (arguments, sink) {}),
    );
    messenger.setMockMethodCallHandler(_window, (call) async {
      switch (call.method) {
        case 'isFullScreen':
          return windowIsFullScreen;
        case 'setFullScreen':
          windowIsFullScreen =
              (call.arguments as Map)['isFullScreen'] as bool? ?? false;
          return null;
      }
      return null;
    });
  });

  tearDown(() async {
    immersiveRouteActive.value = false;
    // The HLS URL goes through the local proxy, which binds a real HttpServer
    // whose two-minute idle timer outlives the widget tree. The service is a
    // singleton meant to live for the app, not for one test.
    await LocalProxyService.instance.shutdown();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_vlc, null);
    messenger.setMockStreamHandler(_events, null);
    messenger.setMockMessageHandler(_wakelockToggle, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    messenger.setMockMethodCallHandler(_window, null);
    messenger.setMockMethodCallHandler(_pip, null);
    messenger.setMockMethodCallHandler(_connectivity, null);
    messenger.setMockStreamHandler(_connectivityStatus, null);
    messenger.setMockMethodCallHandler(_volume, null);
    messenger.setMockStreamHandler(_volumeEvents, null);
  });

  /// Delivers a window event exactly as the native plugin does: an `onEvent`
  /// call on window_manager's own channel, which its Dart side fans out to
  /// every registered [WindowListener]. Nothing in the app is called directly,
  /// which is the whole point - the OS is upstream of the player here.
  Future<void> emitWindowEvent(WidgetTester tester, String name) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _window.name,
      _window.codec.encodeMethodCall(
        MethodCall('onEvent', <String, Object?>{'eventName': name}),
      ),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> sendFirstFrame(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _events.name,
      _events.codec.encodeSuccessEnvelope(<String, Object?>{
        'state': 'playing',
        'position': 1500,
        'duration': 0,
        'volume': 100,
        'playbackSpeed': 1.0,
        'isReady': true,
        'isSeekable': true,
        'isLive': false,
      }),
      null,
    );
    // Past the controller's 250ms event throttle.
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// An item from the `Remote` provider is the shortest honest route to the
  /// playing stage: `resolvePlayback` short-circuits to a direct stream.
  Future<void> pumpPlayingScreen(
    WidgetTester tester, {
    PlayerSettings settings = const PlayerSettings(),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProfileProvider.overrideWithValue(
            const AsyncValue.data(DeviceProfile(isTv: false)),
          ),
          playerSettingsProvider.overrideWithBuild((_, _) => settings),
          historyRepositoryProvider.overrideWithValue(_NoHistory()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: VlcPlayerScreen(
            item: MultimediaItem(
              title: 'Channel One',
              url: 'https://example.com/live.m3u8',
              posterUrl: '',
              provider: 'Remote',
            ),
            videoUrl: 'https://example.com/live.m3u8',
          ),
        ),
      ),
    );
    // Resolution, the resume lookup, setMedia and the texture attach are all
    // async gaps, and so is the full-screen seed read.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.byType(VlcPlayer),
      findsOneWidget,
      reason: 'the screen never reached the playing stage',
    );
    await sendFirstFrame(tester);
  }

  bool controlsSayFullscreen(WidgetTester tester) => tester
      .widget<VlcPlayerControls>(find.byType(VlcPlayerControls))
      .isFullscreen;

  /// Takes the player down and stops the proxy behind it.
  ///
  /// The binding checks for stray timers the moment the test body returns,
  /// which is before [tearDown] runs, and an HLS source leaves the local
  /// proxy's HttpServer holding a two-minute idle timer.
  Future<void> closePlayer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(LocalProxyService.instance.shutdown);
  }

  testWidgets(
    'full screen follows the window, not the button',
    variant: _texturePlatform,
    (tester) async {
      await pumpPlayingScreen(tester);
      expect(controlsSayFullscreen(tester), isFalse);

      // What F11 in main.dart and the macOS green button both end up doing.
      await emitWindowEvent(tester, kWindowEventEnterFullScreen);
      expect(
        controlsSayFullscreen(tester),
        isTrue,
        reason: 'the window went full screen and the player never noticed',
      );

      await emitWindowEvent(tester, kWindowEventLeaveFullScreen);
      expect(controlsSayFullscreen(tester), isFalse);

      await closePlayer(tester);
    },
  );

  testWidgets(
    'a window already full screen is picked up on the way in',
    variant: _texturePlatform,
    (tester) async {
      windowIsFullScreen = true;

      await pumpPlayingScreen(tester);

      expect(
        controlsSayFullscreen(tester),
        isTrue,
        reason:
            'the player opened into a full-screen window showing the '
            'enter-full-screen icon',
      );

      await closePlayer(tester);
    },
  );

  testWidgets(
    'the player claims the whole window while it is up',
    variant: _texturePlatform,
    (tester) async {
      expect(immersiveRouteActive.value, isFalse);

      await pumpPlayingScreen(tester);

      expect(
        immersiveRouteActive.value,
        isTrue,
        reason: 'nothing tells the desktop shell to stand its title bar down',
      );

      await closePlayer(tester);

      expect(
        immersiveRouteActive.value,
        isFalse,
        reason:
            'the flag outlived the player and the title bar never came back',
      );
    },
  );

  testWidgets(
    "the viewer's default resize mode reaches the video",
    variant: _texturePlatform,
    (tester) async {
      await pumpPlayingScreen(
        tester,
        settings: const PlayerSettings(defaultResizeMode: 'Zoom'),
      );

      expect(
        tester.widget<VlcPlayer>(find.byType(VlcPlayer)).fit,
        VlcVideoFit.cover,
        reason:
            'the texture path draws its own FittedBox from this, and on '
            'Windows and Linux nothing else honours fit at all',
      );

      await closePlayer(tester);
    },
  );
}

/// The resume lookup reads history, which ends in Hive. Neither subject here
/// has any business standing a storage stack up.
class _NoHistory extends HistoryRepository {
  _NoHistory() : super(StorageService());

  @override
  List<HistoryItem> getWatchHistory() => const <HistoryItem>[];

  @override
  int getPosition(String url) => 0;

  @override
  int getDuration(String url) => 0;

  @override
  Future<void> saveProgress(
    MultimediaItem item,
    int position,
    int duration, {
    String? lastStreamUrl,
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodePosterUrl,
  }) async {}
}
