/// Turning a `PlayerRouteExtra` into something an engine can actually open.
///
/// `PlayerRouteExtra.videoUrl` is not a URL. It is an opaque token handed to
/// the active plugin's `loadStreams()`, and plugins are free to put anything
/// in it — an episode page, a `tmdb:` id, or a JSON array of candidate
/// sources — so it must never be handed to `Uri.parse`.
///
/// Resolution is engine-agnostic: it ends at a [StreamResult] and nothing here
/// knows which engine opens it, so both players share this.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart'
    show ProviderListenable;
import 'package:http/http.dart' as http;

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/logger/playback_trace.dart';
import '../../../core/storage/history_repository.dart';
import '../../../core/network/http_defaults.dart';
import '../../../core/network/probe_answer.dart';
import '../../../core/utils/app_utils.dart';
import '../../../core/utils/stream_quality_sorter.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../core/services/provider_health_service.dart';
import '../../../core/services/dahl_service.dart';
import '../../library/presentation/history_provider.dart';
import '../../settings/presentation/player_settings_provider.dart';

/// Just enough of Riverpod to read providers. Both `Ref.read` and
/// `WidgetRef.read` satisfy this, so the resolver can be called from a
/// Notifier or straight from a widget without caring which it got.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// A resolved, ordered candidate list plus the one to open first.
class ResolvedPlayback {
  const ResolvedPlayback({
    required this.streams,
    required this.index,
    this.qualityFilteredFallback = false,
  });

  /// Quality-filtered and sorted, best first. Never empty.
  final List<StreamResult> streams;

  /// Index into [streams] of the stream to play. Later indices are the
  /// failover order.
  final int index;

  /// The quality filter matched nothing and was dropped, so [streams] is
  /// unfiltered. Callers may want to say so.
  final bool qualityFilteredFallback;

  StreamResult get selected => streams[index];
}

/// The identity a stream must present on the network.
///
/// Shared so that every request about one stream looks like the same client.
/// A CDN that ties a signed URL to the requesting agent will 403 if the probe,
/// the licence fetch and the engine disagree — and libVLC's own default
/// User-Agent is rejected outright by many of them.
Map<String, String> playbackHeaders(StreamResult stream) {
  final headers = <String, String>{...?stream.headers};
  final hasUserAgent = headers.keys.any((k) => k.toLowerCase() == 'user-agent');
  if (!hasUserAgent) headers['User-Agent'] = kDefaultBrowserUserAgent;

  return headers;
}

/// The identity a source's playback results are remembered under.
///
/// Health belongs to the server that actually carried the video, so the
/// provider name leads: the source label is often a quality or a bridge-
/// specific tag shared by every provider, and scoring those together teaches
/// the ranking nothing about which mirror is fast.
String providerIdForStream(StreamResult stream, {String fallback = ''}) {
  final name = stream.providerName.trim();
  if (name.isNotEmpty && name.toLowerCase() != 'unknown') return name;
  final source = stream.source.trim();
  return source.isNotEmpty ? source : fallback;
}

/// Turns a resolved candidate into a URL an engine can actually open.
///
/// Torrent playback is retired: this returns null for a torrent rather than
/// seeding it, so even a stale list cannot restart the torrent server. Every
/// other source is already playable and only needs normalising.
String? playableUrlFor(StreamResult stream) {
  if (isTorrentSource(stream)) return null;
  return AppUtils.normalizeUrl(stream.url);
}

/// Whether this candidate is a torrent rather than something an engine can
/// open directly.
///
/// The path check is deliberately narrowed by [StreamResult.source]: a bare
/// absolute path is normally a local file, and only a torrent-sourced one is a
/// seeded file the torrent service knows about.
bool isTorrentSource(StreamResult stream) =>
    isTorrentUrl(stream.url) ||
    (stream.url.startsWith('/') && stream.source.contains('Torrent'));

/// Whether [url] itself names a torrent. Playback is direct-only, so this is a
/// refusal rather than a hand-off to the torrent service.
bool isTorrentUrl(String url) =>
    url.startsWith('magnet:') || url.endsWith('.torrent');

/// A URL that names itself as on-demand. Vetoes [_liveUrlShapes], because those
/// are guesses and this is the source saying what it is: Xtream Codes serves
/// VOD from `/movie/` and `/series/`, and Wowza's on-demand HLS lives under
/// `/vod/` while still being cut into `chunklist_*.m3u8` files.
final RegExp _vodMarkers = RegExp(r'/(vod|movies?|series)/');

/// URL shapes that in practice only IPTV and live packagers produce.
///
/// Deliberately narrower than "ends in .m3u8" — a VOD HLS ladder is also
/// `.m3u8`, and calling those live would kill seeking and resume across a large
/// slice of ordinary content. So: the path segments IPTV portals mount channels
/// under, the two live-edge playlist names (`stream.m3u8` from most origins,
/// `chunklist` from Wowza), and the Xtream Codes query that asks for a channel
/// list rather than a file.
final RegExp _liveUrlShapes = RegExp(
  r'/live/|/iptv/|stream\.m3u8|chunklist|(type|output)=m3u8',
);

/// Whether this source should be treated as live.
///
/// The item's own content type wins, then the URL scheme, then the URL's
/// shape. Torrents and local files are always VOD however they are labelled.
/// Decided from data both engines can see rather than from an engine report,
/// because liveness changes buffering, seeking, progress writing and what
/// end-of-media means.
///
/// The URL-shape pass matters because plugins routinely hand back an IPTV feed
/// typed as `movie`. Without it that stream gets VOD caching instead of
/// `:live-caching`, writes progress against a duration that means nothing, and
/// on a drop takes the end-of-media branch instead of reconnecting.
bool isLiveSource(MultimediaItem item, String url) {
  if (url.isEmpty) return item.contentType == MultimediaContentType.livestream;
  final lower = url.toLowerCase();
  if (lower.startsWith('magnet:') ||
      lower.endsWith('.torrent') ||
      lower.startsWith('/')) {
    return false;
  }
  if (item.contentType == MultimediaContentType.livestream) return true;
  if (lower.startsWith('rtmp://') ||
      lower.startsWith('rtsp://') ||
      lower.startsWith('mms://') ||
      lower.startsWith('udp://') ||
      lower.startsWith('rtp://')) {
    return true;
  }
  if (_vodMarkers.hasMatch(lower)) return false;
  return _liveUrlShapes.hasMatch(lower);
}

/// Why resolution gave up, as a code the UI can localize.
///
/// Resolution runs with no BuildContext, so it names the failure and
/// [describeStreamFailure] renders it.
enum StreamResolutionFailure {
  noProvider,
  nothingToPlay,
  loadFailed,
  cancelled,
  noStreams,
}

/// Resolution failed in a way worth showing the user.
class StreamResolutionException implements Exception {
  const StreamResolutionException(this.failure, {this.detail});

  final StreamResolutionFailure failure;

  /// The underlying error text, when there is one worth passing on.
  final String? detail;

  /// The developer-facing form, for logs and `toString()`. Derived from
  /// [failure] so a diagnostic can never describe a different failure from the
  /// one the viewer is shown. English on purpose; [describeStreamFailure] is
  /// what the viewer sees.
  String get message => switch (failure) {
    StreamResolutionFailure.noProvider => 'No provider selected.',
    StreamResolutionFailure.nothingToPlay => 'Nothing to play.',
    StreamResolutionFailure.loadFailed => 'Could not load sources: $detail',
    StreamResolutionFailure.cancelled => 'Cancelled.',
    StreamResolutionFailure.noStreams => 'No streams found.',
  };

  @override
  String toString() => message;
}

/// The viewer-facing wording for a failed resolution.
String describeStreamFailure(
  AppLocalizations l10n,
  StreamResolutionException failure,
) => switch (failure.failure) {
  StreamResolutionFailure.noProvider => l10n.playerNoProviderSelected,
  StreamResolutionFailure.nothingToPlay => l10n.playerNothingToPlay,
  StreamResolutionFailure.loadFailed => l10n.playerCouldNotLoadSources(
    failure.detail ?? '',
  ),
  StreamResolutionFailure.cancelled => l10n.playerResolutionCancelled,
  StreamResolutionFailure.noStreams => l10n.playerNoStreamsFound,
};

/// Where one candidate's health probe has got to.
///
/// [trying] is reported when the probe is dispatched rather than when it
/// answers, because the probes run as a parallel race.
enum ProbeOutcome {
  trying,

  /// It answered with something to play, and nothing says it cannot be
  /// sought in.
  healthy,

  /// It answered with something to play, from a server that ignores byte
  /// ranges: it plays, but only from its start, so it cannot be sought in and
  /// a resume starts it over. Google's video-downloads host is one.
  unseekable,

  /// No answer, or a refusal.
  unhealthy,

  /// It answered with a web page - a link generator, a login, a missing-file
  /// page served with a 200 - rather than anything to play.
  notVideo,
}

extension ProbeOutcomeReach on ProbeOutcome {
  /// Whether the check got an answer a player can open, seekable or not.
  bool get reached =>
      this == ProbeOutcome.healthy || this == ProbeOutcome.unseekable;
}

/// What one speed-check request found, and how long the server took to say it.
///
/// Time-to-first-byte is the part of startup a source owns: DNS, TLS, redirects
/// and the wait before the gateway answers. It does not promise the segments
/// behind it are fast too, which is why a source that answers quickly still
/// runs under the player's own no-picture watchdog.
class _ProbeAnswer {
  const _ProbeAnswer(this.outcome, this.ttfb);

  final ProbeOutcome outcome;
  final Duration ttfb;
}

/// Resolves [videoUrl] for [item] into playable streams.
///
/// [preloadedStreams] short-circuits the plugin call, for callers that have
/// already aggregated sources across plugins. Its order is taken as given —
/// neither re-sorted nor overridden by watch history — so its first entry is
/// what opens unless it is slow. Torrents are dropped from it: playback is
/// direct-only.
///
/// [probeCandidates] is how many mirrors are speed-checked at once, in
/// priority order, with a dead one's place going to the next in line. The
/// quickest of the preferred quality tier wins, so a title whose first mirror
/// is slow starts on a fast one instead of waiting it out. Pass 0 to skip
/// probing.
///
/// A list handed in is a row the viewer pressed, so it never waits: its head
/// opens at once and the check runs behind it, its verdicts steering failover
/// rather than the first open. [probeBudget] caps how long the check may hold
/// up an auto-selected playback.
///
/// [onCandidates] fires as soon as the ordered list exists; indices in every
/// later report and in [ResolvedPlayback] are indices into that list.
/// [onProbe] fires for each candidate as it is dispatched and again as it
/// settles. Neither changes what is resolved.
///
/// Completing [pick] with an index into that list ends the race on exactly
/// that candidate: the viewer chose it from the source list while the check
/// was running, and the probes do not overrule them. Distinct from
/// [isCancelled], which abandons resolution altogether. Completing [abandon]
/// ends a check still running, for a caller that has stopped waiting - the
/// screen closing - so nothing it armed outlives it.
Future<ResolvedPlayback> resolvePlayback({
  required ProviderReader read,
  required MultimediaItem item,
  required String videoUrl,
  List<StreamResult>? preloadedStreams,
  int probeCandidates = 3,
  Duration probeBudget = kProbeBudget,
  bool Function()? isCancelled,
  void Function(List<StreamResult> streams)? onCandidates,
  void Function(int index, ProbeOutcome outcome)? onProbe,
  Future<int>? pick,
  Future<void>? abandon,
}) async {
  final trace = PlaybackTrace('resolve');
  final direct = _directStream(item, videoUrl);
  if (direct != null) {
    trace.lap('direct');
    final streams = [direct];
    onCandidates?.call(streams);
    return ResolvedPlayback(streams: streams, index: 0);
  }
  // A magnet or .torrent link used to be handed to the bundled torrent
  // server. That is retired, so there is no fallback left to offer it.
  if (isTorrentUrl(videoUrl)) {
    throw const StreamResolutionException(
      StreamResolutionFailure.nothingToPlay,
    );
  }

  final preloaded = (preloadedStreams ?? const <StreamResult>[])
      .where((s) => !isTorrentSource(s))
      .toList(growable: false);
  final provider = _resolveProvider(read, item);
  if (provider == null && preloaded.isEmpty) {
    throw const StreamResolutionException(StreamResolutionFailure.noProvider);
  }
  if (videoUrl.isEmpty && preloaded.isEmpty) {
    throw const StreamResolutionException(
      StreamResolutionFailure.nothingToPlay,
    );
  }

  // A list handed in is a choice the viewer already made: the sheets put the
  // tapped source first and have ranked the rest themselves.
  final handPicked = preloaded.isNotEmpty;

  List<StreamResult> raw = const <StreamResult>[];
  if (handPicked) {
    raw = preloaded;
  } else {
    final sw = Stopwatch()..start();
    try {
      raw = (await provider!.loadStreams(videoUrl))
          .where((s) => !isTorrentSource(s))
          .toList(growable: false);
      sw.stop();
      try {
        read(providerHealthServiceProvider).recordSuccess(
          provider.packageName,
          responseTime: sw.elapsed,
        );
      } catch (_) {}
    } catch (e) {
      // Dahl Self-Healing Scraper Hook
      var healed = false;
      try {
        final dahl = read(dahlServiceProvider);
        final healedLink = await dahl.repairBrokenScraper(
          rawSnippet: '$e',
          streamHint: '${item.title} $videoUrl',
        );
        if (healedLink != null) {
          raw = [StreamResult(url: healedLink, source: 'Dahl Healed Stream', providerName: 'Dahl AI')];
          healed = true;
        }
      } catch (_) {}

      if (!healed) {
        try {
          read(providerHealthServiceProvider).recordFailure(
            provider?.packageName ?? '',
            reason: '$e',
          );
        } catch (_) {}
        throw StreamResolutionException(
          StreamResolutionFailure.loadFailed,
          detail: '$e',
        );
      }
    }
  }
  if (isCancelled?.call() ?? false) {
    throw const StreamResolutionException(StreamResolutionFailure.cancelled);
  }
  if (raw.isEmpty) {
    throw const StreamResolutionException(StreamResolutionFailure.noStreams);
  }
  trace.lap(
    'links',
    'count=${raw.length} source=${handPicked ? 'hand-picked' : provider?.packageName}',
  );

  // Ranking that list again opens a source nobody picked, and a filter can
  // drop the picked one out of it altogether - so a hand-picked list does not
  // need the settings at all, and must not wait on a cold settings box for
  // nothing.
  var didFallback = false;
  final settings = handPicked ? null : await _playerSettings(read);
  var streams = handPicked || settings == null
      ? raw
      : await _byQuality(raw, settings, (v) => didFallback = v);

  // Apply provider health scoring to prioritize fast and reliable providers if enabled
  if (!handPicked &&
      streams.length > 1 &&
      (settings?.autoHealthScoringEnabled ?? true)) {
    try {
      final health = read(providerHealthServiceProvider);
      streams = health.rankSourcesByHealth<StreamResult>(
        sources: streams,
        getProviderId: (s) =>
            providerIdForStream(s, fallback: provider?.packageName ?? ''),
      );
    } catch (_) {}
  }

  if (streams.isEmpty) {
    throw const StreamResolutionException(StreamResolutionFailure.noStreams);
  }
  onCandidates?.call(streams);
  trace.lap(
    'ranked',
    'count=${streams.length}${didFallback ? ' quality-fallback' : ''}',
  );

  // A preloaded list skips the ranking above but is still a list of links
  // nobody has opened, so it is checked like any other - and the setting still
  // turns the check off, read without blocking when the box is already warm
  // (the player keeps it so) because nothing else here waits on it.
  var probeEnabled = true;
  try {
    probeEnabled =
        (settings ?? read(playerSettingsProvider).asData?.value)
            ?.autoHealthScoringEnabled ??
        true;
  } catch (_) {}

  final saved = handPicked ? 0 : _savedStreamIndex(read, item, streams);
  // With the check off, the leading source of the ranked list opens: no probe
  // race, so no quick mirror can drop a slow-but-working link.
  final index = (!probeEnabled || probeCandidates <= 1)
      ? saved
      : await _firstHealthyStream(
          streams,
          startIndex: saved,
          // A tapped row is a choice, not a candidate: it opens at once, and
          // the check behind it only steers failover.
          pinned: handPicked ? 0 : -1,
          limit: probeCandidates,
          budget: probeBudget,
          isCancelled: isCancelled,
          onProbe: onProbe,
          pick: pick,
          abandon: abandon,
        );

  trace.lap(
    'probe',
    'enabled=$probeEnabled candidates=$probeCandidates '
        'budget=${probeBudget.inMilliseconds}ms '
        'pinned=${handPicked ? 0 : -1} index=$index',
  );
  return ResolvedPlayback(
    streams: streams,
    index: index,
    qualityFilteredFallback: didFallback,
  );
}

/// Local files and remote casts are already playable and never go through a
/// plugin.
StreamResult? _directStream(MultimediaItem item, String videoUrl) {
  final isDirect =
      item.provider == 'Remote' ||
      item.provider == 'Local' ||
      AppUtils.isLocalFile(videoUrl);

  if (!isDirect) return null;
  return StreamResult(
    url: videoUrl,
    source: 'Video',
    providerName: item.provider ?? 'Local',
    headers: const {},
  );
}

/// The plugin [resolvePlayback] would ask for [item]'s streams, or null when
/// it would ask none: a local file or direct link plays as it is, and a
/// torrent has nothing left to play.
///
/// For saying who is being waited on. Resolution itself does not go through
/// this, but it answers from the same two functions, so the two cannot name
/// different plugins.
SkyStreamProvider? pluginFor(
  ProviderReader read,
  MultimediaItem item,
  String videoUrl,
) {
  if (isTorrentUrl(videoUrl)) return null;
  if (_directStream(item, videoUrl) != null) return null;
  return _resolveProvider(read, item);
}

SkyStreamProvider? _resolveProvider(ProviderReader read, MultimediaItem item) {
  final active = read(activeProviderProvider);
  final wanted = item.provider;
  if (wanted != null) {
    final match = read(extensionManagerProvider.notifier)
        .getAllProviders()
        .firstWhereOrNull((p) => p.packageName == wanted || p.name == wanted);
    if (match != null) return match;
  }
  return active;
}

/// Settings can still be loading when playback starts. Silently skipping the
/// quality preference for that window would make the chosen source depend on
/// how warm the cache was, so wait for it instead.
Future<PlayerSettings?> _playerSettings(ProviderReader read) async {
  final snapshot = read(playerSettingsProvider);
  final data = snapshot.asData;
  if (data != null) return data.value;
  try {
    return await read(playerSettingsProvider.future);
  } catch (_) {
    return null;
  }
}

/// Metered link → mobileQuality, unmetered → wifiQuality. If the filter leaves
/// nothing it is dropped rather than failing playback, and [onFallback] reports
/// that.
///
/// Asked once, when playback is resolved, and deliberately not re-asked on a
/// handover: the candidate order is also what failover walks, and the walk
/// records which indices it has tried, so re-sorting mid-session would make
/// that record point at different sources. A viewer who leaves Wi-Fi keeps the
/// rendition they are watching until something else reopens the media, which
/// is the same answer every other player gives.
Future<List<StreamResult>> _byQuality(
  List<StreamResult> streams,
  PlayerSettings settings,
  void Function(bool) onFallback,
) async {
  final preference = await isOnMeteredNetwork()
      ? settings.mobileQuality
      : settings.wifiQuality;
  final filtered = filterStreamsByQuality(
    streams,
    preference,
    settings.qualityFilterMode,
    onFallback: onFallback,
  );
  return sortStreamsByQuality(filtered, preference);
}

/// The source the user last watched this title on, so switching episodes keeps
/// the working provider instead of re-picking from scratch.
int _savedStreamIndex(
  ProviderReader read,
  MultimediaItem item,
  List<StreamResult> streams,
) {
  try {
    final isSeries =
        item.contentType == MultimediaContentType.series ||
        item.contentType == MultimediaContentType.anime;

    String? lastUrl;
    if (isSeries) {
      lastUrl = read(historyRepositoryProvider).getLastStreamUrl(item.url);
    }
    lastUrl ??= read(watchHistoryProvider)
        .firstWhereOrNull((h) => h.item.url == item.url)
        ?.lastStreamUrl;

    if (lastUrl != null) {
      final found = streams.indexWhere((s) => s.url == lastUrl);
      if (found != -1) return found;
    }
  } catch (e) {
    if (kDebugMode) debugPrint('resolvePlayback: saved stream lookup: $e');
  }
  return 0;
}

/// How long the rolling check may run before playback starts regardless: on
/// the best candidate it has found, or the preferred one when it has found
/// none. Fifty dead links at up to six seconds a batch is minutes of spinner.
const Duration kProbeBudget = Duration(seconds: 10);

/// How many mirrors a speed check looks at when auto-selecting.
///
/// Four is enough to find a quick mirror in practice without probing a whole
/// add-on list; every extra probe is another request competing with playback
/// for the same connection.
const int kSpeedProbeCandidates = 4;

/// How long a speed check may hold up playback.
///
/// Only a mirror that has not answered by now is waited on; a preferred source
/// that answers quickly opens immediately. The cap is deliberately below the
/// time a single stalled link used to cost the engine.
const Duration kSpeedProbeBudget = Duration(milliseconds: 1200);

/// Speed-checks candidates in priority order, [limit] at a time, and opens the
/// quickest reachable mirror of the preferred candidate's quality tier.
///
/// The check ends the moment its answer is settled: once the quickest source
/// has answered, a probe still waiting has already spent longer at that link
/// than the answer took, so it cannot be quicker. A fast list therefore pays
/// only its own time to first byte, and a slow first mirror costs a fraction
/// of the engine's connect timeout instead of the whole thing. Speed never
/// promotes a lower tier over the one the ranking chose.
///
/// Rolling: a candidate found dead hands its place to the next unchecked one
/// in line, so the source list shows every slot filled rather than a dead one
/// left where it fell. Completing the caller's `abandon` stops it.
///
/// [pinned] is a candidate the viewer picked. It opens at once, before any
/// probe answers: nothing is allowed between the tap and the first frame. The
/// check still runs behind it - the rest of the list is dispatched and
/// reported as usual - so its verdicts steer failover, never this open.
///
/// Falls back to [startIndex] if every candidate fails, so a wrong probe never
/// blocks playback outright, and to the quickest found so far once [budget]
/// runs out.
Future<int> _firstHealthyStream(
  List<StreamResult> streams, {
  required int startIndex,
  int pinned = -1,
  required int limit,
  required Duration budget,
  bool Function()? isCancelled,
  void Function(int index, ProbeOutcome outcome)? onProbe,
  Future<int>? pick,
  Future<void>? abandon,
}) async {
  if (streams.isEmpty) return 0;
  final start = startIndex.clamp(0, streams.length - 1);
  final pin = pinned >= 0 && pinned < streams.length ? pinned : -1;

  // Every candidate, in priority order: the preferred one, then the rest of
  // the ring after it.
  final order = <int>[
    for (var i = 0; i < streams.length; i++) (start + i) % streams.length,
  ];
  if (order.length <= 1) return start;

  final completer = Completer<int>();
  // The answer and how long the server took to give it, so several working
  // mirrors can be compared instead of opening whichever answered first.
  final results = <int, _ProbeAnswer>{};
  var dispatched = 0;
  var abandoned = false;
  Timer? deadline;
  // Fires once the youngest probe still in flight has spent as long at its
  // link as the quickest answer took, which is the moment it can no longer
  // beat that answer. Without it the check only asks that question when some
  // other probe answers, so one silent mirror - a dead CDN, an unreachable
  // host - holds a settled answer back until [budget].
  Timer? prune;
  // When each probe went out, so one still waiting can be ruled out once it
  // has spent longer at its link than the quickest answer took.
  final sentAt = <int, Duration>{};
  final clock = Stopwatch()..start();

  /// Ends the check on [index]. The deadline goes in the same breath, not
  /// after the caller wakes: a probe answering as the screen closes would
  /// otherwise leave it armed for up to [budget] behind a dead screen.
  void finish(int index) {
    if (completer.isCompleted) return;
    deadline?.cancel();
    prune?.cancel();
    completer.complete(index);
  }

  /// The fastest reachable candidate in the leading candidate's quality tier.
  ///
  /// Tier first, speed second: the list was ordered for the viewer's quality
  /// preference, and a 720p mirror answering 50 ms sooner is not a better
  /// choice than the 1080p the ranking asked for.
  int? fastestReached() {
    int? lead;
    for (final c in order) {
      final answer = results[c];
      if (answer != null && answer.outcome.reached) {
        lead = c;
        break;
      }
    }
    if (lead == null) return null;

    final tier = qualityBadgeLabel(streams[lead]);
    var best = lead;
    for (final c in order) {
      final answer = results[c];
      if (answer == null || !answer.outcome.reached) continue;
      if (qualityBadgeLabel(streams[c]) != tier) continue;
      if (answer.ttfb < results[best]!.ttfb) best = c;
    }
    return best;
  }

  /// Whether a probe still in flight could yet be quicker than [best].
  ///
  /// A probe that has already spent longer waiting than the best answer took
  /// cannot beat it: the wait so far is a lower bound on its own time to first
  /// byte. Only a replacement dispatched behind a failed candidate can still
  /// be young enough to keep the check open.
  bool couldStillWin(int best) {
    final bestTtfb = results[best]!.ttfb;
    for (final c in order.take(dispatched)) {
      if (results.containsKey(c)) continue;
      final sent = sentAt[c];
      if (sent == null || clock.elapsed - sent < bestTtfb) return true;
    }
    return false;
  }

  /// Ends the check the moment every probe still in flight has spent at least
  /// as long as [best] took, since none of them can answer sooner than that.
  ///
  /// The delay is measured on the same clock as [sentAt], so it is exact
  /// rather than an estimate; a probe dispatched later re-arms it through
  /// [decide].
  void armPrune(int best) {
    if (completer.isCompleted) return;
    prune?.cancel();
    final bestTtfb = results[best]!.ttfb;
    Duration? left;
    for (final c in order.take(dispatched)) {
      if (results.containsKey(c)) continue;
      final spent = clock.elapsed - (sentAt[c] ?? Duration.zero);
      final remaining = bestTtfb - spent;
      if (remaining <= Duration.zero) {
        // Already past the point where it could win.
        finish(best);
        return;
      }
      if (left == null || remaining < left) left = remaining;
    }
    if (left == null) return;
    prune = Timer(left, () {
      if (completer.isCompleted) return;
      final winner = fastestReached();
      if (winner != null) finish(winner);
    });
  }

  void decide() {
    if (completer.isCompleted) return;
    // Instant-Start Optimization: If the top preferred candidate answered and is healthy,
    // open it immediately! Never delay the #1 ranked source for 1.2s to wait on lower-ranked mirrors.
    if (results[start]?.outcome.reached ?? false) {
      finish(start);
      return;
    }
    // The quickest answer wins as soon as nothing could still beat it.
    final best = fastestReached();
    if (best != null && !couldStillWin(best)) {
      finish(best);
      return;
    }
    // Nothing has answered yet, or a late replacement could still win: give
    // the probes in flight until they answer; only the budget may cut that
    // short.
    var waiting = false;
    for (final c in order.take(dispatched)) {
      if (!results.containsKey(c)) waiting = true;
    }
    if (!waiting) {
      finish(best ?? start);
      return;
    }
    if (best != null) armPrune(best);
  }

  late final void Function() dispatchNext;

  void record(int idx, _ProbeAnswer answer) {
    // Reported before the completion guard, so a candidate that answers after
    // the check is over still explains itself rather than staying "trying"
    // on screen forever.
    onProbe?.call(idx, answer.outcome);
    results[idx] = answer;
    // Also once decided: the replacement is for the list, not the choice.
    if (!answer.outcome.reached && !abandoned) dispatchNext();
    decide();
  }

  dispatchNext = () {
    if (dispatched >= order.length) return;
    final idx = order[dispatched++];
    sentAt[idx] = clock.elapsed;
    onProbe?.call(idx, ProbeOutcome.trying);
    unawaited(
      _probeAnswer(streams[idx])
          .then((answer) => record(idx, answer))
          .catchError(
            (_) => record(
              idx,
              const _ProbeAnswer(ProbeOutcome.unhealthy, Duration.zero),
            ),
          ),
    );
  };

  // Armed before the probes are dispatched: a pick that has already happened
  // must win the race rather than lose it by a microtask.
  if (pick != null) {
    unawaited(
      pick.then((index) {
        if (index < 0 || index >= streams.length) return;
        finish(index);
      }),
    );
  }

  if (abandon != null) {
    unawaited(
      abandon.then((_) {
        abandoned = true;
        finish(start);
      }),
    );
  }
  deadline = Timer(budget, () => finish(fastestReached() ?? start));

  for (var i = 0; i < limit; i++) {
    dispatchNext();
  }

  // A row the viewer pressed opens now: nothing may stand between the tap and
  // the first frame, so its own probe is advice, never a gate. The check still
  // runs behind it - the rest of the list is dispatched and reported as it
  // answers - so a dead mirror is found for failover without delaying this one.
  if (pin >= 0) finish(pin);

  final winner = await completer.future;
  if (isCancelled?.call() ?? false) return start;
  return winner;
}

/// Whether the health probe has no way to look at this candidate, and so
/// passes it without asking: a torrent is served by the local engine once it
/// is seeded, and a bare path is a file on this device.
///
/// A pass from the probe on one of these therefore says nothing, which the
/// source list has to know before it calls one reachable.
bool isUncheckableSource(StreamResult stream) =>
    stream.url.startsWith('magnet:') ||
    stream.url.endsWith('.torrent') ||
    stream.url.startsWith('/');

/// The health probe for one source, outside the race: the same ranged GET and
/// HEAD, for a source opened without having been checked - picked by the
/// viewer from past the top few, or reached by failover.
Future<bool> isReachable(StreamResult stream) async =>
    (await probeSource(stream)).reached;

/// What the health probe finds out about one source, outside the race.
Future<ProbeOutcome> probeSource(StreamResult stream) => _probe(stream);

/// A ranged GET for the first kilobyte, then a HEAD for servers that refuse
/// it.
///
/// The GET answers all the check asks in one request: whether the link
/// answers, whether its server serves byte ranges - the only way a player can
/// jump into a file over HTTP - and, from the first bytes, whether it is a
/// video at all. A HEAD proves only the first, so it is the fallback rather
/// than the lead: a server that refuses the ranged request but answers a
/// plain one still counts as reachable, with nothing said about seeking.
///
/// The elapsed time to the response headers is carried back with the outcome;
/// it is the part of startup the source controls.
Future<ProbeOutcome> _probe(StreamResult stream) async =>
    (await _probeAnswer(stream)).outcome;

Future<_ProbeAnswer> _probeAnswer(StreamResult stream) async {
  if (isUncheckableSource(stream)) {
    return const _ProbeAnswer(ProbeOutcome.healthy, Duration.zero);
  }

  final uri = Uri.tryParse(stream.url);
  if (uri == null || !uri.hasScheme) {
    return const _ProbeAnswer(ProbeOutcome.unhealthy, Duration.zero);
  }
  final headers = playbackHeaders(stream);

  final client = http.Client();
  final clock = Stopwatch()..start();
  try {
    final request = http.Request('GET', uri);
    request.headers.addAll(headers);
    request.headers.putIfAbsent(
      'Range',
      () => 'bytes=0-${kProbeSniffBytes - 1}',
    );
    final resp = await client.send(request).timeout(const Duration(milliseconds: 1000));
    final ttfb = clock.elapsed;
    // Nothing to range over: an empty file, which the old one-byte check
    // passed too.
    if (resp.statusCode == 416) {
      return _ProbeAnswer(ProbeOutcome.healthy, ttfb);
    }
    if (resp.statusCode < 400) {
      final type = resp.headers['content-type'];
      // Only a page or a playlist is worth reading; a server that ignores the
      // range is sending the whole file behind these bytes.
      final head = mayBeWebPage(type)
          ? await _firstBytes(resp.stream).timeout(
              const Duration(milliseconds: 1000),
              onTimeout: () => const <int>[],
            )
          : const <int>[];
      return _ProbeAnswer(_outcomeOf(uri, resp, head), ttfb);
    }
    // A 403 or 405 from the initial probe indicates a dead or blocked CDN edge;
    // do not declare healthy so failover and speed probing pick an active mirror.
    if (resp.statusCode == 403 || resp.statusCode == 405) {
      return _ProbeAnswer(ProbeOutcome.unhealthy, ttfb);
    }
  } catch (_) {
    // Fall through to the HEAD.
  } finally {
    // Hangs up whatever of the body was not read.
    client.close();
  }

  final headClock = Stopwatch()..start();
  try {
    final resp = await http
        .head(uri, headers: headers)
        .timeout(const Duration(milliseconds: 1000));
    if (resp.statusCode < 400) {
      return _ProbeAnswer(ProbeOutcome.healthy, headClock.elapsed);
    }
  } catch (_) {
    // No answer to either.
  }
  return const _ProbeAnswer(ProbeOutcome.unhealthy, Duration.zero);
}

/// What an answer to the ranged GET says about playing [url].
ProbeOutcome _outcomeOf(Uri url, http.BaseResponse resp, List<int> head) {
  final type = resp.headers['content-type'];
  if (isPlaylist(url, type, head)) return ProbeOutcome.healthy;
  if (isWebPage(type, head)) return ProbeOutcome.notVideo;
  final ranged =
      resp.statusCode == 206 ||
      resp.headers.containsKey('content-range') ||
      (resp.headers['accept-ranges']?.toLowerCase().contains('bytes') ?? false);
  return ranged ? ProbeOutcome.healthy : ProbeOutcome.unseekable;
}

/// Up to [kProbeSniffBytes] from the start of [body]. Leaving the loop early
/// cancels the subscription, so the rest is never read.
Future<List<int>> _firstBytes(Stream<List<int>> body) async {
  final bytes = <int>[];
  await for (final chunk in body) {
    final room = kProbeSniffBytes - bytes.length;
    bytes.addAll(chunk.length > room ? chunk.sublist(0, room) : chunk);
    if (bytes.length >= kProbeSniffBytes) break;
  }
  return bytes;
}
