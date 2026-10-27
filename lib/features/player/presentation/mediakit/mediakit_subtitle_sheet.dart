/// The subtitles sheet of the media_kit player.
///
/// One list, in the order a viewer looks for a subtitle: Off, the tracks
/// inside the video, the files the source shipped and the viewer brought, then
/// the two ways to get a new file and the delay.
///
/// Everything is a [PanelRow] - the side panel's row - so this sheet behaves
/// like the one libVLC's player opens: one focus stop per row, Select or a tap
/// activates it, and a remote's arrows move between rows. The online search is
/// the same page as there, in a full-screen step of its own.
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../domain/side_car_subtitles.dart';
import '../../domain/track_language.dart';
import '../vlc/panel/player_panel_metrics.dart';
import '../vlc/panel/player_panel_row.dart';
import '../widgets/player_sheet_header.dart';

/// How far one press of the delay stepper moves, and how far a held one does -
/// the panel's own steps, so the two players correct a badly muxed file alike.
const Duration _kDelayStep = Duration(milliseconds: 100);
const Duration _kDelayCoarseStep = Duration(milliseconds: 500);

Duration _stepOf(PanelStep step) =>
    step == PanelStep.coarse ? _kDelayCoarseStep : _kDelayStep;

/// `+100ms`, `-500ms`, `+1.5s`: always signed, so a zero reads as a state.
String _delayLabel(Duration delay) {
  final ms = delay.inMilliseconds;
  final sign = ms < 0 ? '-' : '+';
  final magnitude = ms.abs();
  if (magnitude < 1000) return '$sign${magnitude}ms';
  return '$sign${(magnitude / 1000).toStringAsFixed(1)}s';
}

/// A subtitle file's row: what the source or the viewer called it, else its
/// language, else the file's own name.
String _fileLabel(SideCarTrack file, int index, AppLocalizations l10n) {
  final label = file.label?.trim();
  if (label != null && label.isNotEmpty) return label;
  final language = languageNameForCode(file.languageCode ?? '');
  if (language != null) return language;
  final name = file.url.pathSegments.lastOrNull;
  if (name != null && name.isNotEmpty) return Uri.decodeComponent(name);
  return l10n.playerTrackNumber(index + 1);
}

/// A track inside the video's row: its title, else its language, else the
/// engine's number for it - the same naming the side panel uses.
String _trackLabel(
  SubtitleTrack track,
  int index,
  AppLocalizations l10n,
) {
  final title = track.title?.trim();
  if (title != null && title.isNotEmpty) return title;
  final language = track.language?.trim();
  if (language != null &&
      language.isNotEmpty &&
      language.toLowerCase() != 'und') {
    return languageNameForCode(language) ?? language.toUpperCase();
  }
  return l10n.playerTrackNumber(index + 1);
}

/// The subtitles menu.
class MediaKitSubtitleSheet extends StatelessWidget {
  const MediaKitSubtitleSheet({
    required this.sideCars,
    required this.delay,
    required this.embeddedTracks,
    required this.activeEmbeddedId,
    required this.isTv,
    required this.onOff,
    required this.onEmbedded,
    required this.onSideCar,
    required this.onDelay,
    required this.onLoadFile,
    required this.onSearch,
    super.key,
  });

  /// The files SkyStream draws itself: the source's and the viewer's.
  final SideCarSubtitles sideCars;

  /// The delay the viewer set. Its own channel rather than the playback clock,
  /// so this list does not rebuild on every position tick - the mpv adapter
  /// publishes the delay on a notifier of its own for exactly this.
  final ValueListenable<Duration> delay;

  /// The tracks inside the video, as media_kit lists them.
  final ValueListenable<List<SubtitleTrack>> embeddedTracks;

  /// The track inside the video that is on, or null.
  final ValueListenable<String?> activeEmbeddedId;

  /// The ten-foot ramp for a television; the sheet is outside the side panel,
  /// which is the only thing that would otherwise have installed it.
  final bool isTv;

  final VoidCallback onOff;
  final ValueChanged<SubtitleTrack> onEmbedded;
  final ValueChanged<SideCarTrack> onSideCar;
  final ValueChanged<Duration> onDelay;
  final VoidCallback onLoadFile;
  final VoidCallback onSearch;

  /// Every source the sheet reads, as one, so one list rebuild follows any of
  /// them: a file finishing its fetch, a track appearing, the delay moving.
  Listenable get _sources => Listenable.merge([
    sideCars,
    delay,
    embeddedTracks,
    activeEmbeddedId,
  ]);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PlayerPanelMetricsScope(
      metrics: PlayerPanelMetrics.forTv(isTv),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _sources,
          builder: (context, _) => ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PlayerSheetHeader(title: l10n.subtitles, isTv: isTv),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 12),
                    children: _rows(l10n),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _rows(AppLocalizations l10n) {
    final tracks = embeddedTracks.value;
    final activeId = activeEmbeddedId.value;
    final files = sideCars.tracks;
    final activeFile = sideCars.active;
    final nothingOn = activeId == null && activeFile == null;

    return [
      PanelRow(
        label: l10n.off,
        icon: Icons.subtitles_off_outlined,
        selected: nothingOn,
        autofocus: nothingOn,
        onTap: onOff,
      ),
      if (tracks.isEmpty && files.isEmpty)
        PanelEmpty(text: l10n.noSubtitlesFound)
      else ...[
        for (final (index, track) in tracks.indexed)
          PanelRow(
            label: _trackLabel(track, index, l10n),
            selected: activeFile == null && track.id == activeId,
            // The sheet opens on whatever is on, so a remote lands on the
            // track it is about to change rather than on Off.
            autofocus: activeFile == null && track.id == activeId,
            onTap: () => onEmbedded(track),
          ),
        for (final (index, file) in files.indexed)
          PanelRow(
            label: _fileLabel(file, index, l10n),
            detail: switch (sideCars.statusOf(file)) {
              SideCarStatus.loading => l10n.loading,
              SideCarStatus.failed => l10n.failed,
              _ => null,
            },
            selected: activeFile == file,
            autofocus: activeFile == file,
            onTap: () => onSideCar(file),
          ),
      ],
      PanelSubheader(title: l10n.subtitleOptions),
      PanelRow(
        label: l10n.loadSubtitleFile,
        icon: Icons.file_open_outlined,
        onTap: onLoadFile,
      ),
      PanelRow(
        label: l10n.searchSubtitlesOnline,
        icon: Icons.search_rounded,
        onTap: onSearch,
      ),
      PanelStepperRow(
        label: l10n.subtitleDelay,
        value: _delayLabel(delay.value),
        onDecrease: (step) => onDelay(delay.value - _stepOf(step)),
        onIncrease: (step) => onDelay(delay.value + _stepOf(step)),
        onReset: delay.value == Duration.zero
            ? null
            : () => onDelay(Duration.zero),
      ),
    ];
  }
}
