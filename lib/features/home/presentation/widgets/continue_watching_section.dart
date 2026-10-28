import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:skystream/core/utils/responsive_breakpoints.dart';
import 'package:skystream/core/utils/layout_constants.dart';

import 'package:skystream/features/home/presentation/widgets/continue_watching_card.dart';
import 'package:skystream/features/library/presentation/history_provider.dart';
import 'package:skystream/shared/widgets/desktop_scroll_wrapper.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/section_header.dart';

class ContinueWatchingSection extends ConsumerStatefulWidget {
  final String title;
  final List<HistoryItem> items;

  const ContinueWatchingSection({
    super.key,
    required this.title,
    required this.items,
  });

  @override
  ConsumerState<ContinueWatchingSection> createState() =>
      _ContinueWatchingSectionState();
}

class _ContinueWatchingSectionState
    extends ConsumerState<ContinueWatchingSection> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final isLarge = context.isTabletOrLarger;

    final double width = isLarge ? 360.0 : 280.0;
    final double listHeight = isLarge ? 200.0 : 150.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: widget.title,
          subtitle: 'Resume where you left off',
          padding: EdgeInsets.fromLTRB(
            isLarge ? LayoutConstants.dashboardContentPadding : 16,
            LayoutConstants.spacingLg,
            isLarge ? LayoutConstants.dashboardContentPadding : 16,
            LayoutConstants.spacingSm,
          ),
          action: SectionHeaderAction(
            label: AppLocalizations.of(context)!.clearAll,
            icon: Icons.delete_sweep_rounded,
            onPressed: () {
              final l10n = AppLocalizations.of(context)!;
              showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(l10n.clearAllHistory),
                  content: Text(l10n.confirmClearHistory),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l10n.cancel),
                    ),
                    TextButton(
                      onPressed: () {
                        ref
                            .read(watchHistoryProvider.notifier)
                            .clearAllHistory();
                        Navigator.pop(context);
                      },
                      child: Text(
                        l10n.clearAll,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        SizedBox(
          height: listHeight,
          child: DesktopScrollWrapper(
            controller: _scrollController,
            showButtons: isLarge, // Show nav buttons on desktop and TV
            child: Builder(
              builder: (context) {
                const double spacing = 16.0;
                return ListView.builder(
                  controller: _scrollController,
                  // No vertical padding, so the space under the rail is the
                  // next section's 24 alone rather than 24 + 8 - which is what
                  // made the gap below this row read as bigger than the one
                  // above it. Clip.none is what pays for dropping it:
                  // CardsWrapper draws its focus ring OUTSIDE the card and
                  // blurs a glow 8 dp further still, and a clipping viewport
                  // would cut both off with a hard edge on a television.
                  clipBehavior: Clip.none,
                  padding: EdgeInsets.symmetric(
                    horizontal: isLarge
                        ? LayoutConstants.dashboardContentPadding
                        : 16,
                  ),
                  scrollDirection: Axis.horizontal,
                  itemCount: widget.items.length,
                  itemExtent: width + spacing,
                  itemBuilder: (context, index) {
                    final historyItem = widget.items[index];
                    return Padding(
                      padding: const EdgeInsets.only(right: spacing),
                      child: ContinueWatchingCard(
                        key: ValueKey(historyItem.item.url),
                        historyItem: historyItem,
                        width: width,
                        isLarge: isLarge,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
