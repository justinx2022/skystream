/// The strip every player sheet opens with: what is being chosen, and the one
/// press that closes it.
///
/// One widget rather than one per sheet because the four sheets - subtitles,
/// more, sources, audio - are the same route shape, and they had already
/// grown three slightly different headers: the subtitle sheet at 18 sp, the
/// More sheet at 18 sp, and the sources and audio sheets with no header at all,
/// only a section label. A viewer navigating by remote should not have to
/// relearn how a sheet closes when they move from one to the next.
library;

import 'package:flutter/material.dart';

import 'hotstar_player_style.dart';

class PlayerSheetHeader extends StatelessWidget {
  const PlayerSheetHeader({required this.title, required this.isTv, super.key});

  final String title;

  /// The ten-foot rung: bigger type, and more room around it, so the title is
  /// legible from a sofa and the close button is a target a D-pad can find.
  final bool isTv;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(isTv ? 24 : 20, isTv ? 18 : 14, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: HotstarPlayerStyle.primaryText,
                fontSize: isTv ? 22 : 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.close_rounded,
              color: HotstarPlayerStyle.secondaryText,
              size: isTv ? 28 : 24,
            ),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}
