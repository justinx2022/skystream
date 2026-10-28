/// How large a read-ahead buffer to start a device with.
///
/// A default, never a cap. An earlier version of this converted a duration
/// into bytes and then clamped the result to what the device could hold, which
/// meant most of the choices on offer produced the same buffer and the control
/// mostly did nothing. The number a viewer picks is now reserved exactly; this
/// only decides where a fresh install starts.
library;

import '../../../core/providers/device_info_provider.dart';

/// The sizes offered, in megabytes.
///
/// Stops at 1024. The buffer is resident and competes with the decoder's own
/// picture pool, so past this the returns are small and the risk is not - but
/// it is offered, because a machine with memory to spare can spend it and
/// nothing here should decide that on the owner's behalf.
///
/// Note that the top of this range is not sized for the bottom of the device
/// range: a gigabyte is most of what a 2 GB handset has. The tier defaults
/// below are what protect a fresh install; this list is what someone who has
/// gone looking for the setting is allowed to ask for.
const List<int> kNetworkBufferChoicesMb = <int>[
  64,
  128,
  256,
  512,
  1024,
  2048,
  4096,
  8192,
];

/// Where a device starts before anyone chooses.
///
/// Scaled by tier rather than by a raw megabyte count because the tier already
/// folds in Android's own low-RAM flag, which an OEM sets knowing things about
/// the device that a number does not capture.
int defaultNetworkBufferMb(DeviceTier tier) => switch (tier) {
  // Cheap sticks and old phones. 256 MB leaves plenty of room.
  DeviceTier.low => 256,

  // Ordinary phones, tablets and TV boxes.
  DeviceTier.standard => 512,

  // Anything with memory to spare. Desktops and high-RAM devices get 2048 MB (2 GB).
  DeviceTier.high => 2048,
};

/// The buffer durations offered to the viewer, in minutes.
///
/// Ranges from 2 minutes up to 90 minutes (1 hour 30 minutes).
const List<int> kBufferDurationMinutesChoices = <int>[
  2,
  5,
  10,
  15,
  30,
  45,
  60,
  90,
];

/// The default buffer duration in minutes when the viewer has not chosen one.
int defaultBufferDurationMinutes(DeviceTier tier) => switch (tier) {
  DeviceTier.low => 5,
  DeviceTier.standard => 15,
  DeviceTier.high => 45,
};

/// Formats a buffer duration in minutes into a human-readable string (e.g. "2 min", "1 hr", "1h 30m").
String formatBufferDuration(int minutes) {
  if (minutes < 60) {
    return '$minutes min';
  }
  final hours = minutes ~/ 60;
  final remaining = minutes % 60;
  if (remaining == 0) {
    return '$hours hr${hours > 1 ? "s" : ""}';
  }
  return '${hours}h ${remaining}m';
}

/// Converts a requested duration (in minutes) and estimated video bitrate
/// into megabytes, bounded safely by device tier to avoid Out-Of-Memory (OOM) crashes.
int bufferDurationToMb({
  required int durationMinutes,
  String? quality,
  required DeviceTier tier,
}) {
  final double mbPerMin = switch (quality?.toLowerCase()) {
    '4k' || '2160p' => 135.0,
    '1080p' || 'fhd' => 45.0,
    '720p' || 'hd' => 25.0,
    _ => 35.0,
  };

  final calculatedMb = (durationMinutes * mbPerMin).round();

  // Maximum memory safety caps based on device tier
  final maxSafeMb = switch (tier) {
    DeviceTier.low => 512,
    DeviceTier.standard => 1536,
    DeviceTier.high => 8192,
  };

  return calculatedMb.clamp(64, maxSafeMb);
}

/// The buffer to actually use: what the viewer chose (either by duration or direct size),
/// or this device's default when they have not chosen.
int resolveNetworkBufferMb(
  int? chosenMb,
  DeviceTier tier, {
  int? chosenDurationMinutes,
  String? quality,
}) {
  if (chosenDurationMinutes != null && chosenDurationMinutes > 0) {
    return bufferDurationToMb(
      durationMinutes: chosenDurationMinutes,
      quality: quality,
      tier: tier,
    );
  }
  return chosenMb ?? defaultNetworkBufferMb(tier);
}

/// The most of a torrent cache worth spending on data already played.
///
/// A cap, because the behind-window is dead weight for anyone who never seeks
/// backwards, and the ahead-window is what keeps a torrent playing at all.
/// 64 MB is roughly a minute of 1080p, which is as far back as a viewer
/// realistically scrubs by hand.
const int kMaxTorrentBehindMb = 64;

/// The share of a torrent cache kept *ahead* of the read point, as the
/// percentage TorrServer's `readerReadAHead` wants.
///
/// TorrServer splits one cache between read-ahead and history, and the split
/// is the only backward-buffer control anywhere in this player: libVLC 3's
/// prefetch filter takes a size and decides the rest itself. So this is where
/// "a ten second step back should not re-download" is actually answered.
///
/// A quarter of the cache, capped by [kMaxTorrentBehindMb]. At the 95 % this
/// replaces, a 64 MB cache kept about 3 MB behind the playhead - under four
/// seconds of 1080p, so every back-step of any size re-fetched pieces the
/// reader had just finished with.
///
/// Returns a percentage rather than a size because that is TorrServer's unit,
/// and it is rounded, so the arithmetic is worth a test rather than a comment.
///
/// Rounded up: rounding down was what let a 4 GB cache keep almost 82 MB of
/// history, because half a percent of a cache that large is more than the cap.
int torrentReadAheadPercent(int cacheMb) {
  if (cacheMb <= 0) return 95;
  final behind = (cacheMb * 0.25).round().clamp(0, kMaxTorrentBehindMb);
  final ahead = ((cacheMb - behind) / cacheMb * 100).ceil();
  // Never so little read-ahead that the torrent cannot keep up; the behind
  // window is a convenience and the ahead window is the playback.
  return ahead.clamp(60, 99);
}
