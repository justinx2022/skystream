/// The media_kit player's More sheet: everything the bottom bar used to carry
/// that a viewer does not reach for while watching.
///
/// The bar keeps the essentials - transport, the clock, audio, subtitles - and
/// this holds the rest: speed, how the picture is fitted to the frame,
/// fullscreen, and the source picker behind the quality badge.
///
/// Built from [PanelRow], the side panel's row, for the same reason the
/// subtitles sheet is: one focus stop per row, Select or a tap activates it,
/// and a remote's arrows move between rows.
library;

import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../vlc/panel/player_panel_metrics.dart';
import '../vlc/panel/player_panel_row.dart';
import '../widgets/player_sheet_header.dart';

/// The speeds a tap can land on. Not a slider: a speed is chosen, and a list
/// says which one is on without the viewer reading a thumb's position.
const List<double> _kSpeeds = <double>[0.75, 1, 1.25, 1.5, 2];

/// `0.75x`, `1x`, `1.5x` - a whole speed without a trailing zero.
String _speedLabel(double speed) =>
    speed == speed.roundToDouble() ? '${speed.toInt()}x' : '${speed}x';

/// The three fits, named the way the button that cycles them names them.
const List<(BoxFit, String)> _kFits = <(BoxFit, String)>[
  (BoxFit.contain, 'Contain'),
  (BoxFit.cover, 'Cover'),
  (BoxFit.fill, 'Fill'),
];

class MediaKitMoreSheet extends StatefulWidget {
  const MediaKitMoreSheet({
    required this.speed,
    required this.fit,
    required this.isFullscreen,
    required this.quality,
    required this.isTv,
    required this.isLive,
    required this.onSpeed,
    required this.onFit,
    required this.onFullscreen,
    required this.onSources,
    super.key,
  });

  final double speed;
  final BoxFit fit;
  final bool isFullscreen;

  /// What the quality badge reads, so the source row says which one is on.
  final String quality;

  /// The sheet sits outside the side panel, so nothing has installed the
  /// ten-foot ramp for it. On a television every row here would otherwise be
  /// drawn at its phone size - 14 sp on a 55-inch screen.
  final bool isTv;

  /// A live feed has no speed. The section is absent there rather than present
  /// and inert, exactly as libVLC's bar treats it.
  final bool isLive;

  final ValueChanged<double> onSpeed;
  final ValueChanged<BoxFit> onFit;
  final VoidCallback onFullscreen;
  final VoidCallback onSources;

  @override
  State<MediaKitMoreSheet> createState() => _MediaKitMoreSheetState();
}

class _MediaKitMoreSheetState extends State<MediaKitMoreSheet> {
  late double _speed = widget.speed;
  late BoxFit _fit = widget.fit;
  late bool _fullscreen = widget.isFullscreen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PlayerPanelMetricsScope(
      metrics: PlayerPanelMetrics.forTv(widget.isTv),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PlayerSheetHeader(title: 'More', isTv: widget.isTv),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    if (!widget.isLive) ...[
                      PanelSubheader(title: l10n.playbackSpeed),
                      for (final speed in _kSpeeds)
                        PanelRow(
                          label: _speedLabel(speed),
                          selected: speed == _speed,
                          // On a television the sheet opens on the speed that
                          // is on, not at the top of the list.
                          autofocus: widget.isTv && speed == _speed,
                          onTap: () {
                            setState(() => _speed = speed);
                            widget.onSpeed(speed);
                          },
                        ),
                    ],
                    PanelSubheader(title: l10n.fit),
                    for (final (fit, label) in _kFits)
                      PanelRow(
                        label: label,
                        selected: fit == _fit,
                        // With no speed section above it on a live feed, the
                        // fit row is what a remote's first move lands on.
                        autofocus: widget.isTv && widget.isLive && fit == _fit,
                        onTap: () {
                          setState(() => _fit = fit);
                          widget.onFit(fit);
                        },
                      ),
                    // No subheader: these two are single rows, and a heading
                    // that only repeats the row's own label is furniture.
                    const SizedBox(height: 8),
                    PanelRow(
                      label: l10n.sources,
                      detail: widget.quality,
                      icon: Icons.layers_rounded,
                      onTap: widget.onSources,
                    ),
                    PanelRow(
                      label: l10n.fullscreen,
                      icon: Icons.fullscreen_rounded,
                      selected: _fullscreen,
                      onTap: () {
                        setState(() => _fullscreen = !_fullscreen);
                        widget.onFullscreen();
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
  }
}
