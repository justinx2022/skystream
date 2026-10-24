import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/device_info_provider.dart';
import '../../player/domain/network_buffer.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/stream_quality_sorter.dart';

import 'package:skystream/l10n/generated/app_localizations.dart';

import 'player_settings_provider.dart';
import 'widgets/settings_dialogs.dart';
import 'widgets/settings_widgets.dart';
import 'widgets/subtitle_appearance_settings.dart';

/// Sub-screen for configuring all video playback, gestures, display, and quality preferences.
class PlayerSettingsScreen extends ConsumerWidget {
  final bool isEmbedded;

  const PlayerSettingsScreen({super.key, this.isEmbedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final profile = ref.watch(deviceProfileProvider).asData?.value;

    final playerSettings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();

    final durationMinutes = playerSettings.bufferDurationMinutes ??
        defaultBufferDurationMinutes(profile?.tier ?? DeviceTier.standard);

    // The size in force: what the viewer chose, or what this device starts
    // with. Resolved here so the row and the dialog agree with the player.
    final bufferMb = resolveNetworkBufferMb(
      playerSettings.networkBufferMb,
      profile?.tier ?? DeviceTier.standard,
      chosenDurationMinutes: playerSettings.bufferDurationMinutes,
    );

    // Whether this device has a touchscreen, which is the only thing the four
    // gesture rows below depend on: a swipe, a drag and a double-tap are the
    // one input that genuinely does not exist on a remote, a keyboard or a
    // mouse, so they are the one control the app is allowed to hide.
    //
    // A hardware fact, therefore, and asked of hardware: the mobile operating
    // systems, minus the leanback boxes and Apple TVs that run them without a
    // touchscreen. `DeviceProfile.isTv` is the single authority for "this is a
    // television"; the geometric guess in `ResponsiveContext` that used to be
    // OR-ed in here called every landscape Android phone a television and took
    // all four rows away while the gestures kept firing underneath them, so
    // the viewer could no longer switch off a gesture that was still happening.
    // Window shape must never reach this decision - the phone in landscape and
    // the phone in portrait are the same phone.
    final platform = Theme.of(context).platform;
    final isTouchDevice =
        (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS) &&
        profile?.isTv != true;

    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: ListView(
            // Vertical only; SettingsGroup owns the horizontal inset.
            padding: const EdgeInsets.symmetric(
              vertical: LayoutConstants.spacingSm,
            ).copyWith(bottom: LayoutConstants.shellBottomContentPadding(context)),
            children: [
              SettingsGroup(
                title: 'Speed & Playback Enhancements',
                children: [
                  SettingsTile(
                    icon: Icons.flash_on_rounded,
                    title: 'Multi-Connection Speed Booster',
                    subtitle: playerSettings.multiConnectionBooster
                        ? 'Parallel segment prefetching active (Debrid-like saturation)'
                        : 'Disabled (single stream download)',
                    trailing: Switch(
                      value: playerSettings.multiConnectionBooster,
                      onChanged: (val) => ref
                          .read(playerSettingsProvider.notifier)
                          .setMultiConnectionBooster(val),
                    ),
                    onTap: () => ref
                        .read(playerSettingsProvider.notifier)
                        .setMultiConnectionBooster(
                          !playerSettings.multiConnectionBooster,
                        ),
                  ),
                  SettingsTile(
                    icon: Icons.movie_filter_rounded,
                    title: 'Seamless One-Click Play (Netflix Style)',
                    subtitle: playerSettings.seamlessPlayback
                        ? 'Dives into playback immediately from Continue Watching'
                        : 'Opens details screen and provider selector first',
                    trailing: Switch(
                      value: playerSettings.seamlessPlayback,
                      onChanged: (val) => ref
                          .read(playerSettingsProvider.notifier)
                          .setSeamlessPlayback(val),
                    ),
                    onTap: () => ref
                        .read(playerSettingsProvider.notifier)
                        .setSeamlessPlayback(!playerSettings.seamlessPlayback),
                  ),
                  SettingsTile(
                    icon: Icons.blur_on_rounded,
                    title: 'Stremio-style Loading Screen',
                    subtitle: playerSettings.stremioLoadScreen
                        ? 'Pulsating title, poster backdrop & Dive In button'
                        : 'Classic minimal spinner',
                    trailing: Switch(
                      value: playerSettings.stremioLoadScreen,
                      onChanged: (val) => ref
                          .read(playerSettingsProvider.notifier)
                          .setStremioLoadScreen(val),
                    ),
                    onTap: () => ref
                        .read(playerSettingsProvider.notifier)
                        .setStremioLoadScreen(!playerSettings.stremioLoadScreen),
                  ),
                  SettingsTile(
                    icon: Icons.sync_rounded,
                    title: 'Local Network Watch Sync',
                    subtitle: playerSettings.lanSync
                        ? 'Auto-syncs watch progress across PC, TV & phone on home Wi-Fi'
                        : 'Disabled',
                    isLast: !Platform.isWindows,
                    trailing: Switch(
                      value: playerSettings.lanSync,
                      onChanged: (val) =>
                          ref.read(playerSettingsProvider.notifier).setLanSync(val),
                    ),
                    onTap: () => ref
                        .read(playerSettingsProvider.notifier)
                        .setLanSync(!playerSettings.lanSync),
                  ),
                  if (Platform.isWindows || Platform.isAndroid)
                    SettingsTile(
                      icon: Icons.speed_rounded,
                      title: Platform.isWindows
                          ? 'Windows GPU Engine (libmpv)'
                          : 'High-Performance Engine (media_kit)',
                      subtitle: playerSettings.useMediaKitOnWindows
                          ? (Platform.isWindows
                              ? 'Zero-copy Direct3D 11 hardware rendering (media_kit)'
                              : 'Hardware accelerated MediaCodec engine with high-speed caching')
                          : 'Standard libVLC engine',
                      isLast: true,
                      trailing: Switch(
                        value: playerSettings.useMediaKitOnWindows,
                        onChanged: (val) => ref
                            .read(playerSettingsProvider.notifier)
                            .setUseMediaKitOnWindows(val),
                      ),
                      onTap: () => ref
                          .read(playerSettingsProvider.notifier)
                          .setUseMediaKitOnWindows(
                            !playerSettings.useMediaKitOnWindows,
                          ),
                    ),
                ],
              ),
              const SizedBox(height: LayoutConstants.spacingLg),
              SettingsGroup(
                title: l10n.player,
                children: [
                  SettingsTile(
                    icon: Icons.smart_display_rounded,
                    title: l10n.defaultPlayer,
                    subtitle: getPlayerDisplayName(
                      playerSettings.preferredPlayer,
                      l10n,
                    ),
                    onTap: () => showDefaultPlayerDialog(
                      context,
                      ref,
                      playerSettings.preferredPlayer,
                    ),
                  ),
                  if (isTouchDevice) ...[
                    SettingsTile(
                      icon: Icons.swipe_vertical_rounded,
                      title: l10n.leftGesture,
                      subtitle: getGestureLabel(
                        playerSettings.leftGesture,
                        l10n,
                      ),
                      onTap: () => showGestureDialog(
                        context,
                        ref,
                        true,
                        playerSettings.leftGesture,
                      ),
                    ),
                    SettingsTile(
                      icon: Icons.swipe_vertical_rounded,
                      title: l10n.rightGesture,
                      subtitle: getGestureLabel(
                        playerSettings.rightGesture,
                        l10n,
                      ),
                      onTap: () => showGestureDialog(
                        context,
                        ref,
                        false,
                        playerSettings.rightGesture,
                      ),
                    ),
                    SettingsTile(
                      icon: Icons.touch_app_rounded,
                      title: l10n.doubleTapToSeek,
                      subtitle: playerSettings.doubleTapEnabled
                          ? l10n.enabled
                          : l10n.disabled,
                      trailing: Switch(
                        value: playerSettings.doubleTapEnabled,
                        onChanged: (val) => ref
                            .read(playerSettingsProvider.notifier)
                            .setDoubleTapEnabled(val),
                      ),
                      onTap: () => ref
                          .read(playerSettingsProvider.notifier)
                          .setDoubleTapEnabled(
                            !playerSettings.doubleTapEnabled,
                          ),
                    ),
                    SettingsTile(
                      icon: Icons.swipe_rounded,
                      title: l10n.swipeToSeek,
                      subtitle: playerSettings.swipeSeekEnabled
                          ? l10n.enabled
                          : l10n.disabled,
                      trailing: Switch(
                        value: playerSettings.swipeSeekEnabled,
                        onChanged: (val) => ref
                            .read(playerSettingsProvider.notifier)
                            .setSwipeSeekEnabled(val),
                      ),
                      onTap: () => ref
                          .read(playerSettingsProvider.notifier)
                          .setSwipeSeekEnabled(
                            !playerSettings.swipeSeekEnabled,
                          ),
                    ),
                  ],
                  SettingsTile(
                    icon: Icons.av_timer_rounded,
                    title: l10n.seekDuration,
                    subtitle: formatSeekDuration(
                      playerSettings.seekDuration,
                      l10n,
                    ),
                    onTap: () => showDurationDialog(
                      context,
                      ref,
                      playerSettings.seekDuration,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.download_for_offline_rounded,
                    title: l10n.networkBuffer,
                    subtitle: formatNetworkBuffer(bufferMb),
                    onTap: () =>
                        showNetworkBufferDialog(context, ref, bufferMb),
                  ),
                  SettingsTile(
                    icon: Icons.hourglass_top_rounded,
                    title: 'Buffer Duration Ahead',
                    subtitle: formatBufferDuration(durationMinutes),
                    onTap: () => showBufferDurationDialog(
                      context,
                      ref,
                      durationMinutes,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.health_and_safety_rounded,
                    title: 'Auto Health Scoring & Failover',
                    subtitle: playerSettings.autoHealthScoringEnabled
                        ? 'Prioritizing fast, healthy links & auto-switching'
                        : 'Standard provider order without auto-switching',
                    trailing: Switch(
                      value: playerSettings.autoHealthScoringEnabled,
                      onChanged: (val) => ref
                          .read(playerSettingsProvider.notifier)
                          .setAutoHealthScoringEnabled(val),
                    ),
                    onTap: () => ref
                        .read(playerSettingsProvider.notifier)
                        .setAutoHealthScoringEnabled(
                          !playerSettings.autoHealthScoringEnabled,
                        ),
                  ),
                  SettingsTile(
                    icon: Icons.aspect_ratio_rounded,
                    title: l10n.defaultResizeMode,
                    subtitle: getResizeModeLabel(
                      playerSettings.defaultResizeMode,
                      l10n,
                    ),
                    onTap: () => showResizeDialog(
                      context,
                      ref,
                      playerSettings.defaultResizeMode,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.subtitles_rounded,
                    title: l10n.subtitleDefault,
                    subtitle: subtitleDefaultLabel(
                      playerSettings.subtitleDefault,
                      l10n,
                    ),
                    onTap: () => showSubtitleDefaultDialog(
                      context,
                      ref,
                      playerSettings.subtitleDefault,
                    ),
                  ),
                  if (_switchReachesDecoder(context))
                    SettingsTile(
                      icon: Icons.high_quality_rounded,
                      title: l10n.hardwareDecoding,
                      subtitle: playerSettings.hardwareDecoding
                          ? '${l10n.enabled} (${l10n.recommended})'
                          : l10n.disabled,
                      trailing: Switch(
                        value: playerSettings.hardwareDecoding,
                        onChanged: (val) => ref
                            .read(playerSettingsProvider.notifier)
                            .setHardwareDecoding(val),
                      ),
                      onTap: () => ref
                          .read(playerSettingsProvider.notifier)
                          .setHardwareDecoding(
                            !playerSettings.hardwareDecoding,
                          ),
                    ),
                  SettingsTile(
                    icon: Icons.volume_up_rounded,
                    title: 'Maximum volume',
                    subtitle: playerSettings.maxVolumePercent <= 100
                        ? '100% (no boost)'
                        : '${playerSettings.maxVolumePercent}% — boost enabled',
                    onTap: () =>
                        showMaxVolumeDialog(context, ref, playerSettings),
                  ),
                  // The pair splits on metered vs unmetered, not on Wi-Fi:
                  // Ethernet, a VPN tunnel and no link at all take this one.
                  SettingsTile(
                    icon: Icons.wifi_rounded,
                    title: l10n.unmeteredQualityPreference,
                    subtitle: qualityPreferenceLabel(
                      playerSettings.wifiQuality,
                      l10n,
                    ),
                    onTap: () => showQualityDialog(
                      context,
                      ref,
                      title: l10n.unmeteredQualityPreference,
                      current: playerSettings.wifiQuality,
                      onChanged: ref
                          .read(playerSettingsProvider.notifier)
                          .setWifiQuality,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.signal_cellular_alt_rounded,
                    title: l10n.mobileQualityPreference,
                    subtitle: qualityPreferenceLabel(
                      playerSettings.mobileQuality,
                      l10n,
                    ),
                    onTap: () => showQualityDialog(
                      context,
                      ref,
                      title: l10n.mobileQualityPreference,
                      current: playerSettings.mobileQuality,
                      onChanged: ref
                          .read(playerSettingsProvider.notifier)
                          .setMobileQuality,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.filter_list_rounded,
                    title: 'Quality Filter Mode',
                    subtitle: _qualityFilterModeLabel(
                      playerSettings.qualityFilterMode,
                    ),
                    onTap: () => showQualityFilterModeDialog(
                      context,
                      ref,
                      current: playerSettings.qualityFilterMode,
                      onChanged: ref
                          .read(playerSettingsProvider.notifier)
                          .setQualityFilterMode,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.router_rounded,
                    title: 'Preferred Stream Type',
                    subtitle: _preferredStreamTypeLabel(
                      playerSettings.preferredStreamType,
                    ),
                    onTap: () => showPreferredStreamTypeDialog(
                      context,
                      ref,
                      current: playerSettings.preferredStreamType,
                      onChanged: ref
                          .read(playerSettingsProvider.notifier)
                          .setPreferredStreamType,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.tune_rounded,
                    title: l10n.playerControls,
                    subtitle: l10n.playerControlsSubtitle,
                    isLast: true,
                    onTap: () => showPlayerControlsDialog(context, ref),
                  ),
                ],
              ),
              SubtitleAppearanceGroup(settings: playerSettings),
            ],
          ),
        ),
      ),
    );

    if (isEmbedded) {
      return content;
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              const SettingsRoute().go(context);
            }
          },
        ),
        title: Text(l10n.player),
      ),
      body: content,
    );
  }
}

/// Whether the hardware-decoding switch reaches a decoder on this platform.
///
/// Android only, and the reason is the same one [hardwareDecodeAvailable]
/// encodes — this is its UI half, so the row is offered exactly where the
/// switch decides something.
///
/// The preference goes out as an instance-level `--avcodec-hw`. Windows and
/// Linux render through libVLC's vmem callbacks, and
/// `libvlc_video_set_callbacks` sets `avcodec-hw = "none"` on the media player
/// as it installs them; `var_Inherit` stops at the first object holding the
/// variable, and the media player sits below the instance, so the option never
/// arrives and both decode in software whichever way the switch is set. iOS
/// and macOS decode on VideoToolbox, a standalone module in VLC 3 rather than
/// an avcodec accelerator, so `avcodec-hw` has no authority over it and the
/// hardware path is there either way.
///
/// Shown anyway, the row would report "Enabled" over a software decoder on
/// Windows and Linux and "Disabled" over a hardware one on Darwin — the app
/// stating something untrue about itself. Hiding it is not a feature withheld:
/// there is no choice to make.
///
/// Read through [ThemeData.platform] rather than dart:io so a test can state
/// which device it is pretending to be, matching `_supportsFullScreenMode` in
/// settings_screen.dart.
bool _switchReachesDecoder(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.android;

String _qualityFilterModeLabel(QualityFilterMode mode) {
  switch (mode) {
    case QualityFilterMode.any:
      return 'Show all (sort only)';
    case QualityFilterMode.atOrAbove:
      return 'Hide sources below preference';
    case QualityFilterMode.atOrBelow:
      return 'Hide sources above preference';
  }
}

String _preferredStreamTypeLabel(PreferredStreamType type) {
  switch (type) {
    case PreferredStreamType.hlsDirect:
      return 'HLS / Direct HTTP (Instant, <1s)';
    case PreferredStreamType.torrent:
      return 'Torrent / P2P (More sources, slower start)';
  }
}

void showPreferredStreamTypeDialog(
  BuildContext context,
  WidgetRef ref, {
  required PreferredStreamType current,
  required ValueChanged<PreferredStreamType> onChanged,
}) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Preferred Stream Type'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioListTile<PreferredStreamType>(
            title: const Text('HLS / Direct HTTP (Instant, <1s)'),
            subtitle: const Text('Fast start, plays immediately. Best for most content.'),
            value: PreferredStreamType.hlsDirect,
            groupValue: current,
            onChanged: (val) {
              if (val != null) {
                onChanged(val);
                Navigator.pop(context);
              }
            },
          ),
          RadioListTile<PreferredStreamType>(
            title: const Text('Torrent / P2P (More sources, slower start)'),
            subtitle: const Text('More sources available, but slower ramp-up. Use for obscure content.'),
            value: PreferredStreamType.torrent,
            groupValue: current,
            onChanged: (val) {
              if (val != null) {
                onChanged(val);
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
    ),
  );
}
