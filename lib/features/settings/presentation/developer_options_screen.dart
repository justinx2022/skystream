import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import 'dart:async';

import '../../../shared/widgets/text_input_dialog.dart';
import '../../../core/utils/layout_constants.dart';
import '../../extensions/providers/extensions_controller.dart';
import '../../../core/storage/settings_repository.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/providers/device_info_provider.dart';
import '../../../core/router/app_router.dart';
import 'widgets/settings_widgets.dart';

import 'package:skystream/l10n/generated/app_localizations.dart';

import '../../../core/services/notification_service.dart';

import 'package:flutter/foundation.dart';

class DeveloperOptionsScreen extends ConsumerStatefulWidget {
  final bool isEmbedded;

  const DeveloperOptionsScreen({super.key, this.isEmbedded = false});

  @override
  ConsumerState<DeveloperOptionsScreen> createState() =>
      _DeveloperOptionsScreenState();
}

class _DeveloperOptionsScreenState
    extends ConsumerState<DeveloperOptionsScreen> {
  bool _devLoadAssets = false;

  @override
  void initState() {
    super.initState();
    _devLoadAssets = ref.read(settingsRepositoryProvider).getDevLoadAssets();
  }

  @override
  Widget build(BuildContext context) {
    final deviceAsync = ref.watch(deviceProfileProvider);

    final l10n = AppLocalizations.of(context)!;
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: ListView(
            // Vertical only; SettingsGroup owns the horizontal inset. The
            // bottom must clear the shell's floating bottom bar, which
            // overlays this pushed route just like the tab screens.
            padding: const EdgeInsets.symmetric(vertical: 8).copyWith(
              bottom: LayoutConstants.shellBottomContentPadding(context),
            ),
            children: [
              SettingsGroup(
                title: l10n.debugTools,
                children: [
                  SettingsTile(
                    icon: Icons.video_file_rounded,
                    title: l10n.playLocalVideo,
                    subtitle: l10n.playLocalVideoSubtitle,
                    onTap: () => _pickLocalVideo(context),
                  ),
                  SettingsTile(
                    icon: Icons.link_rounded,
                    title: l10n.streamUrl,
                    subtitle: l10n.streamUrlSubtitle,
                    onTap: () => _showStreamUrlDialog(
                      context,
                      deviceAsync.asData?.value.isTv ?? false,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.movie_filter_rounded,
                    title: 'Series Benchmark & Speed Lab',
                    subtitle: 'Test multi-episode TV series, auto-advance, resume, and subtitles',
                    onTap: () => _launchSeriesBenchmark(context),
                  ),
                  if (kDebugMode)
                    SettingsTile(
                      icon: Icons.folder_copy_rounded,
                      title: l10n.loadPluginFromAssets,
                      subtitle: _devLoadAssets ? l10n.enabled : l10n.disabled,
                      isLast: true,
                      trailing: Switch(
                        value: _devLoadAssets,
                        onChanged: (val) => _toggleAssetLoading(context, val),
                      ),
                      onTap: () =>
                          _toggleAssetLoading(context, !_devLoadAssets),
                    ),
                ],
              ),
              SettingsGroup(
                title: l10n.diagnostics,
                children: [
                  SettingsTile(
                    icon: Icons.bug_report_rounded,
                    title: l10n.viewLogs,
                    subtitle: l10n.viewLogsSubtitle,
                    isLast: true,
                    onTap: () {
                      unawaited(const AppLogsRoute().push<void>(context));
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (widget.isEmbedded) {
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
        title: Text(l10n.developerOptions),
      ),
      body: content,
    );
  }

  Future<void> _toggleAssetLoading(BuildContext context, bool newValue) async {
    if (!kDebugMode) {
      ref
          .read(notificationServiceProvider)
          .showError(
            AppLocalizations.of(context)!.debugOnlyFeature,
            title: 'Developer Options',
            icon: Icons.developer_mode_rounded,
          );
      return;
    }

    Future<void> handleDevLoadAssetsChanged(bool? newValue) async {
      if (newValue == null) return;
      await ref.read(settingsRepositoryProvider).setDevLoadAssets(newValue);
      if (context.mounted) {
        setState(() {
          _devLoadAssets = newValue;
        });
      }
    }

    await handleDevLoadAssetsChanged(newValue);

    await ref
        .read(extensionsControllerProvider.notifier)
        .loadInstalledPlugins();
  }

  Future<void> _pickLocalVideo(BuildContext context) async {
    final picked = await FilePicker.pickFile(type: FileType.video);

    if (picked?.path != null && context.mounted) {
      final path = picked!.path!;
      final name = picked.name;

      unawaited(
        PlayerRoute(
          $extra: PlayerRouteExtra(
            item: MultimediaItem(
              title: name,
              url: path,
              posterUrl: '',
              provider: AppLocalizations.of(context)!.local,
              episodes: [Episode(name: name, url: path, posterUrl: '')],
            ),
            videoUrl: path,
          ),
        ).push<void>(context),
      );
    }
  }

  Future<void> _showStreamUrlDialog(BuildContext context, bool isTv) async {
    final l10n = AppLocalizations.of(context)!;
    final url = await TextInputDialog.show(
      context,
      title: l10n.streamUrl,
      hintText: l10n.enterVideoUrlHint,
      confirmLabel: l10n.play,
      // Start focus on Play so a remote press acts immediately.
      autofocusField: false,
    );
    if (url == null || url.isEmpty || !context.mounted) return;

    String title = l10n.networkStream;
    try {
      final uri = Uri.parse(url);
      if (uri.pathSegments.isNotEmpty) {
        title = uri.pathSegments.last;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('DeveloperOptionsScreen: URI parse error: $e');
      }
    }

    await PlayerRoute(
      $extra: PlayerRouteExtra(
        item: MultimediaItem(
          title: title,
          url: url, // Unique URL for history
          posterUrl: '',
          provider: l10n.remote,
          episodes: [Episode(name: title, url: url, posterUrl: '')],
        ),
        videoUrl: url,
      ),
    ).push<void>(context);
  }

  Future<void> _launchSeriesBenchmark(BuildContext context) async {
    final ep1 = Episode(
      name: 'Episode 1: Ultra-Fast Startup Test (Tears of Steel)',
      url: 'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8',
      posterUrl: 'https://images.unsplash.com/photo-1536440136628-849c177e76a1?w=500',
      season: 1,
      episode: 1,
    );
    final ep2 = Episode(
      name: 'Episode 2: Multi-Subtitle Benchmark (Big Buck Bunny)',
      url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
      posterUrl: 'https://images.unsplash.com/photo-1518709268805-4e9042af9f23?w=500',
      season: 1,
      episode: 2,
    );
    final ep3 = Episode(
      name: 'Episode 3: High Bitrate 4K Buffer Stress Test (Sintel)',
      url: 'https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8',
      posterUrl: 'https://images.unsplash.com/photo-1574375927938-d5a98e8ffe85?w=500',
      season: 1,
      episode: 3,
    );

    final item = MultimediaItem(
      title: 'Series Benchmark & Verification Lab',
      url: 'skystream://benchmark/series-lab',
      posterUrl: 'https://images.unsplash.com/photo-1536440136628-849c177e76a1?w=500',
      provider: 'SkyStream Benchmark Engine',
      contentType: MultimediaContentType.series,
      episodes: [ep1, ep2, ep3],
    );

    await PlayerRoute(
      $extra: PlayerRouteExtra(
        item: item,
        videoUrl: ep1.url,
        episode: ep1,
      ),
    ).push<void>(context);
  }
}
