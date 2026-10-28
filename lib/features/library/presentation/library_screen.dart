import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'widgets/bookmarks_tab.dart';
import 'widgets/downloads_tab.dart';
import 'widgets/history_tab.dart';
import '../../../shared/focus/app_focus.dart';
import '../../../core/theme/app_world.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  /// 0 = Downloads, 1 = Bookmarks, 2 = History. Settings can open the screen
  /// on a given tab.
  final int initialTab;

  const LibraryScreen({super.key, this.initialTab = 0});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTab.clamp(0, 2);
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: initial,
    );
    _pageController = PageController(initialPage: initial);

    // Sync TabBar -> PageView
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        _pageController.animateToPage(
          _tabController.index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.ease,
        );
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Widescreen is a size question, so it is asked of the size. A
    // television is 960 dp wide and clears the tablet breakpoint like any
    // other big window; it needs no device clause of its own.
    final isWidescreen = context.isTabletOrLarger;

    if (isWidescreen) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            // Inline header matching other widescreen screens
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                height: LayoutConstants.dashboardHeaderHeight,
                padding: const EdgeInsets.symmetric(
                  horizontal: LayoutConstants.dashboardContentPadding,
                ),
                child: Row(
                  children: [
                    Text(
                      AppLocalizations.of(context)!.library,
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    // Tab chips
                    _buildTabChips(context),
                  ],
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (index) {
                  _tabController.animateTo(index);
                },
                physics: const BouncingScrollPhysics(),
                itemCount: 3,
                itemBuilder: (_, i) => switch (i) {
                  0 => const DownloadsTab(),
                  1 => const BookmarksTab(),
                  _ => const HistoryTab(),
                },
              ),
            ),
          ],
        ),
      );
    }

    // Mobile layout: existing AppBar with TabBar
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.library),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              text: AppLocalizations.of(context)!.downloads,
              icon: const Icon(Icons.download_for_offline_rounded),
            ),
            Tab(
              text: AppLocalizations.of(context)!.bookmarks,
              icon: const Icon(Icons.bookmark_rounded),
            ),
            Tab(
              text: AppLocalizations.of(context)!.history,
              icon: const Icon(Icons.history_rounded),
            ),
          ],
        ),
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          _tabController.animateTo(index);
        },
        physics: const BouncingScrollPhysics(),
        children: const [DownloadsTab(), BookmarksTab(), HistoryTab()],
      ),
    );
  }

  Widget _buildTabChips(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AnimatedBuilder(
      animation: _tabController,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TabChip(
              label: l10n.downloads,
              icon: Icons.download_for_offline_rounded,
              selected: _tabController.index == 0,
              onTap: () => _tabController.animateTo(0),
            ),
            const SizedBox(width: 8),
            _TabChip(
              label: l10n.bookmarks,
              icon: Icons.bookmark_rounded,
              selected: _tabController.index == 1,
              onTap: () => _tabController.animateTo(1),
            ),
            const SizedBox(width: 8),
            _TabChip(
              label: l10n.history,
              icon: Icons.history_rounded,
              selected: _tabController.index == 2,
              onTap: () => _tabController.animateTo(2),
            ),
          ],
        );
      },
    );
  }
}

class _TabChip extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _TabChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final world = AppWorldTokens.colorsOf(context);
    // Read through [FocusVisibility] rather than [FocusManager] directly: the
    // highlight mode alone does not rebuild this widget when it changes, and
    // it calls a mouse click keyboard navigation.
    final showHighlight = showFocusIndicator(context, _isFocused);
    final scale = showHighlight ? 1.04 : 1.0;
    final accent = world.accent;

    return Focus(
      onFocusChange: (f) {
        if (mounted) setState(() => _isFocused = f);
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: widget.selected
                  ? accent.withValues(alpha: 0.16)
                  : world.textPrimary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(LayoutConstants.radiusPill),
              border: showHighlight
                  ? AppFocus.border(context, focused: true)
                  : (widget.selected
                        ? Border.all(color: accent.withValues(alpha: 0.35))
                        : Border.all(color: Colors.transparent, width: 1)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  size: 16,
                  color: widget.selected ? accent : world.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: widget.selected ? accent : world.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
