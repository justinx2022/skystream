import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/layout_constants.dart';
import 'ai_settings_provider.dart';
import 'widgets/settings_widgets.dart';

class AiSettingsScreen extends ConsumerWidget {
  const AiSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final aiAsync = ref.watch(aiSettingsProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('AI Neural Engine'),
      ),
      body: aiAsync.when(
        data: (AiSettings settings) => _buildBody(context, ref, settings),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object e, StackTrace _) => Center(child: Text('Error: $e')),
      ),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref, AiSettings settings) {
    final notifier = ref.read(aiSettingsProvider.notifier);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: ListView(
          padding: const EdgeInsets.symmetric(
            vertical: LayoutConstants.spacingSm,
          ).copyWith(
            bottom: LayoutConstants.shellBottomContentPadding(context),
          ),
          children: [
            // Master Switch
            SettingsGroup(
              title: 'CORE NEURAL ENGINE',
              children: [
                SettingsTile(
                  icon: Icons.psychology_rounded,
                  title: 'Dahl Neural Engine',
                  subtitle: settings.aiEnabled
                      ? 'Autonomous healing & real-time media acceleration'
                      : 'Disabled (standard native playback)',
                  trailing: Switch(
                    value: settings.aiEnabled,
                    onChanged: (bool val) =>
                        notifier.update((AiSettings s) => s.copyWith(aiEnabled: val)),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(aiEnabled: !settings.aiEnabled),
                  ),
                ),
                SettingsTile(
                  icon: Icons.vpn_key_rounded,
                  title: 'Dahl Gateway Token',
                  subtitle: settings.dahlApiKey.isEmpty
                      ? 'Using bundled high-throughput gateway pool'
                      : 'Custom token active (${settings.dahlApiKey.substring(0, 6)}...)',
                  isLast: true,
                  onTap: () => _showApiKeyDialog(context, ref, settings.dahlApiKey),
                ),
              ],
            ),
            const SizedBox(height: LayoutConstants.spacingLg),

            // Performance & Playback Acceleration
            SettingsGroup(
              title: 'PLAYBACK & STREAM ACCELERATION',
              children: [
                SettingsTile(
                  icon: Icons.bolt_rounded,
                  title: 'Predictive Stream Pre-Warming',
                  subtitle: 'Pre-resolves links on hover for sub-300ms startup',
                  trailing: Switch(
                    value: settings.intentPreFetch,
                    onChanged: (bool val) =>
                        notifier.update((AiSettings s) => s.copyWith(intentPreFetch: val)),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(intentPreFetch: !settings.intentPreFetch),
                  ),
                ),
                SettingsTile(
                  icon: Icons.dynamic_feed_rounded,
                  title: 'Multi-CDN Chunk Sharding',
                  subtitle: 'Splits requests across high-speed Google/PixelDrain mirrors',
                  trailing: Switch(
                    value: settings.multiCdnSharding,
                    onChanged: (bool val) =>
                        notifier.update((AiSettings s) => s.copyWith(multiCdnSharding: val)),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(multiCdnSharding: !settings.multiCdnSharding),
                  ),
                ),
                SettingsTile(
                  icon: Icons.memory_rounded,
                  title: 'Dynamic Demuxer & RAM Buffer Tuning',
                  subtitle: 'Expands mpv buffer up to 150MB & sets fast probe size',
                  trailing: Switch(
                    value: settings.dynamicDemuxerTuning,
                    onChanged: (bool val) => notifier.update(
                      (AiSettings s) => s.copyWith(dynamicDemuxerTuning: val),
                    ),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(
                      dynamicDemuxerTuning: !settings.dynamicDemuxerTuning,
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.fast_forward_rounded,
                  title: 'Instant Seek Keyframe Pre-Caching',
                  subtitle: 'Maps cue headers for butter-smooth zero-freeze scrubbing',
                  isLast: true,
                  trailing: Switch(
                    value: settings.seekKeyframePreCache,
                    onChanged: (bool val) => notifier.update(
                      (AiSettings s) => s.copyWith(seekKeyframePreCache: val),
                    ),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(
                      seekKeyframePreCache: !settings.seekKeyframePreCache,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: LayoutConstants.spacingLg),

            // Video & Shader Level
            SettingsGroup(
              title: 'NEURAL VIDEO & SHADERS',
              children: [
                SettingsTile(
                  icon: Icons.auto_awesome_rounded,
                  title: 'Neural Super-Resolution (Anime4K / FSRCNNX)',
                  subtitle: 'Real-time AI upscaling with sharp lines & edge refinement',
                  trailing: Switch(
                    value: settings.neuralSuperResolution,
                    onChanged: (bool val) => notifier.update(
                      (AiSettings s) => s.copyWith(neuralSuperResolution: val),
                    ),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(
                      neuralSuperResolution: !settings.neuralSuperResolution,
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.hdr_on_rounded,
                  title: 'HDR10 to SDR Dynamic Tone-Mapping',
                  subtitle: 'Injects BT.2446a perceptual curves for punchy colors on standard displays',
                  trailing: Switch(
                    value: settings.hdrToneMapping,
                    onChanged: (bool val) =>
                        notifier.update((AiSettings s) => s.copyWith(hdrToneMapping: val)),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(hdrToneMapping: !settings.hdrToneMapping),
                  ),
                ),
                SettingsTile(
                  icon: Icons.gradient_rounded,
                  title: 'Anti-Banding & Dark Gradient Smoothing',
                  subtitle: 'Eliminates color stepping and grain artifacts in shadows',
                  isLast: true,
                  trailing: Switch(
                    value: settings.antiBanding,
                    onChanged: (bool val) =>
                        notifier.update((AiSettings s) => s.copyWith(antiBanding: val)),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(antiBanding: !settings.antiBanding),
                  ),
                ),
              ],
            ),
            const SizedBox(height: LayoutConstants.spacingLg),

            // Audio Intelligence
            SettingsGroup(
              title: 'ACOUSTIC & AUDIO INTELLIGENCE',
              children: [
                SettingsTile(
                  icon: Icons.record_voice_over_rounded,
                  title: 'AI Dialogue Isolation & Center Boost',
                  subtitle: 'Isolates dialogue frequencies so speech is clear over loud effects',
                  trailing: Switch(
                    value: settings.dialogueIsolation,
                    onChanged: (bool val) => notifier.update(
                      (AiSettings s) => s.copyWith(dialogueIsolation: val),
                    ),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(
                      dialogueIsolation: !settings.dialogueIsolation,
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.nightlight_round,
                  title: 'Night Listening Dynamic Range Compression',
                  subtitle: 'Tames explosive volume spikes without muffling quiet whispers',
                  trailing: Switch(
                    value: settings.nightModeAudio,
                    onChanged: (bool val) =>
                        notifier.update((AiSettings s) => s.copyWith(nightModeAudio: val)),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(nightModeAudio: !settings.nightModeAudio),
                  ),
                ),
                SettingsTile(
                  icon: Icons.sync_rounded,
                  title: 'Multi-Audio Lip-Sync Auto-Alignment',
                  subtitle: 'Automatically compensates for dubbed audio drift',
                  isLast: true,
                  trailing: Switch(
                    value: settings.multiAudioSync,
                    onChanged: (bool val) =>
                        notifier.update((AiSettings s) => s.copyWith(multiAudioSync: val)),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(multiAudioSync: !settings.multiAudioSync),
                  ),
                ),
              ],
            ),
            const SizedBox(height: LayoutConstants.spacingLg),

            // Self-Healing
            SettingsGroup(
              title: 'AUTONOMOUS SELF-HEALING & SCRAPERS',
              children: [
                SettingsTile(
                  icon: Icons.healing_rounded,
                  title: 'Self-Healing Broken Scrapers',
                  subtitle: 'Automatically parses mutated website redirects on the fly',
                  trailing: Switch(
                    value: settings.selfHealingScrapers,
                    onChanged: (bool val) => notifier.update(
                      (AiSettings s) => s.copyWith(selfHealingScrapers: val),
                    ),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(
                      selfHealingScrapers: !settings.selfHealingScrapers,
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.shield_rounded,
                  title: '403 Forbidden Header Auto-Correction',
                  subtitle: 'Negotiates missing Referer or User-Agent headers with CDNs',
                  trailing: Switch(
                    value: settings.autoFixForbiddenHeaders,
                    onChanged: (bool val) => notifier.update(
                      (AiSettings s) => s.copyWith(autoFixForbiddenHeaders: val),
                    ),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(
                      autoFixForbiddenHeaders: !settings.autoFixForbiddenHeaders,
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.radar_rounded,
                  title: 'Ghost Link & Mirror Resurrection',
                  subtitle: 'Substitutes dead URLs mid-playback using release group hashes',
                  isLast: true,
                  trailing: Switch(
                    value: settings.ghostLinkResurrection,
                    onChanged: (bool val) => notifier.update(
                      (AiSettings s) => s.copyWith(ghostLinkResurrection: val),
                    ),
                  ),
                  onTap: () => notifier.update(
                    (AiSettings s) => s.copyWith(
                      ghostLinkResurrection: !settings.ghostLinkResurrection,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showApiKeyDialog(
    BuildContext context,
    WidgetRef ref,
    String currentKey,
  ) {
    final controller = TextEditingController(text: currentKey);
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Custom Dahl API Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Leave blank to use SkyStream\'s shared 100M token pool, '
              'or enter your private Dahl Inference key:',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'dahl_...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              ref
                  .read(aiSettingsProvider.notifier)
                  .update((AiSettings s) => s.copyWith(dahlApiKey: controller.text.trim()));
              Navigator.pop(dialogContext);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
