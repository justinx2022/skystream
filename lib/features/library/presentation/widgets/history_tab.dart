import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_world.dart';
import '../../../../core/theme/design_tokens.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/focus/app_focus.dart';
import '../../../../shared/widgets/artwork_overlay.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/section_header.dart';
import '../../../../shared/widgets/shimmer_placeholder.dart';
import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../history_provider.dart';

/// The viewer's own trail through the app.
///
/// GROUND's centrepiece: a list, not a grid, because history is read for
/// "where was I" rather than browsed for "what next" - a row can carry the
/// episode and the progress, and a poster cannot. Every row opens the title's
/// details page, which is where Resume already lives, so this screen never
/// guesses how to start playback.
class HistoryTab extends ConsumerStatefulWidget {
  const HistoryTab({super.key});

  @override
  ConsumerState<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends ConsumerState<HistoryTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final history = ref.watch(watchHistoryProvider);

    if (history.isEmpty) {
      return EmptyState(
        icon: Icons.history_rounded,
        title: l10n.historyEmptyTitle,
        message: l10n.historyEmptyMessage,
        actionLabel: l10n.explore,
        onAction: () => const ExploreRoute().go(context),
      );
    }

    final isWide = context.isTabletOrLarger;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              isWide
                  ? LayoutConstants.dashboardContentPadding
                  : LayoutConstants.spacingMd,
              LayoutConstants.spacingMd,
              isWide
                  ? LayoutConstants.dashboardContentPadding
                  : LayoutConstants.spacingMd,
              LayoutConstants.spacingSm,
            ),
            child: SectionHeader(
              title: l10n.history,
              compact: !isWide,
              action: SectionHeaderAction(
                label: l10n.clearAllHistory,
                icon: Icons.delete_sweep_outlined,
                onPressed: () => _confirmClear(context, l10n),
              ),
            ),
          ),
        ),
        SliverList.builder(
          itemCount: history.length,
          itemBuilder: (context, index) {
            final entry = history[index];
            return Padding(
              padding: EdgeInsets.fromLTRB(
                isWide
                    ? LayoutConstants.dashboardContentPadding
                    : LayoutConstants.spacingMd,
                0,
                isWide
                    ? LayoutConstants.dashboardContentPadding
                    : LayoutConstants.spacingMd,
                AppSpace.sm,
              ),
              child: _HistoryRow(
                key: ValueKey('history_${entry.item.url}_$index'),
                entry: entry,
                onTap: () =>
                    DetailsRoute($extra: DetailsRouteExtra(item: entry.item))
                        .push<void>(context),
                onRemove: () => ref
                    .read(watchHistoryProvider.notifier)
                    .removeFromHistory(entry.item.url),
              ),
            );
          },
        ),
        SliverPadding(
          padding: EdgeInsets.only(
            bottom: LayoutConstants.shellBottomContentPadding(context),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClear(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.clearAllHistory),
        content: Text(l10n.confirmClearHistory),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.clearAllHistory),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(watchHistoryProvider.notifier).clearAllHistory();
    }
  }
}

/// One watched title: artwork on the left, where-you-were on the right.
///
/// A plain elevated fill rather than glass: this is a scrolling list, and a
/// backdrop blur per row is the one place glass stops being affordable.
class _HistoryRow extends StatefulWidget {
  const _HistoryRow({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onRemove,
  });

  final HistoryItem entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final world = AppWorldTokens.colorsOf(context);
    final entry = widget.entry;
    final item = entry.item;
    final radius = BorderRadius.circular(AppRadius.md);
    final show = showFocusIndicator(context, _focused);

    final poster =
        AppImageFallbacks.optional(entry.episodePosterUrl) ??
        AppImageFallbacks.optional(item.posterUrl) ??
        AppImageFallbacks.optional(item.bannerUrl);

    final parts = <String>[
      if (entry.season != null) 'S${entry.season}',
      if (entry.episode != null) 'E${entry.episode}',
      if (entry.progress > 0) '${(entry.progress * 100).round()}%',
    ];

    return Semantics(
      button: true,
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: FocusRing(
          focused: _focused,
          borderRadius: radius,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: radius,
              focusColor: Colors.transparent,
              hoverColor: world.textPrimary.withValues(alpha: 0.04),
              child: Container(
                decoration: BoxDecoration(
                  color: world.elevated,
                  borderRadius: radius,
                  border: Border.all(
                    color: show ? Colors.transparent : world.divider,
                  ),
                ),
                padding: const EdgeInsets.all(AppSpace.sm),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: SizedBox(
                        width: 132,
                        height: 76,
                        child: poster != null
                            ? CachedNetworkImage(
                                imageUrl: poster,
                                fit: BoxFit.cover,
                                memCacheWidth: 264,
                                errorWidget: (_, _, _) =>
                                    ThumbnailErrorPlaceholder(
                                      label: item.title,
                                      isBackdrop: true,
                                    ),
                                placeholder: (_, _) => ShimmerPlaceholder(
                                  borderRadius: AppRadius.sm,
                                ),
                              )
                            : ThumbnailErrorPlaceholder(
                                label: item.title,
                                isBackdrop: true,
                              ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: world.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (parts.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              parts.join(' · '),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: world.textSecondary,
                              ),
                            ),
                          ],
                          if (entry.progress > 0) ...[
                            const SizedBox(height: AppSpace.sm),
                            ProgressLine(value: entry.progress),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: widget.onRemove,
                      tooltip: MaterialLocalizations.of(context)
                          .deleteButtonTooltip,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: world.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
