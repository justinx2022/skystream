import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_torrent_server/flutter_torrent_server.dart';
import '../utils/torrent_file_parser.dart';
import '../utils/app_utils.dart';
import '../models/torrent_status.dart';

class TorrentService {
  static final TorrentService _instance = TorrentService._internal();
  factory TorrentService() => _instance;
  TorrentService._internal();

  final _server = FlutterTorrentServer();
  String? _serverUrl;
  bool _isStarted = false;
  String? _activeTorrentHash;

  /// The cache the server is configured with, in megabytes, and how much of it
  /// is held ahead of the read point.
  ///
  /// Seeded with what the standard device tier would choose, because the
  /// server can be started by a source resolver long before anything with
  /// access to the viewer's settings runs. [applyBufferSettings] corrects it
  /// the moment the player knows better.
  int _cacheMb = 512;
  int _readAheadPercent = 85;

  /// Points the server's cache at the size the viewer chose for the player.
  ///
  /// One number for both engines: a viewer who asked for 256 MB of buffer
  /// meant it for whatever they are watching, and a torrent used to ignore
  /// them and take a hard-coded 64 MB whatever the setting said.
  ///
  /// Safe to call before the server is up - the values are remembered and
  /// applied by [start] - and safe to call again afterwards, which re-POSTs
  /// them. Note that TorrServer allocates the cache per torrent, so a change
  /// made mid-stream reaches the *next* torrent rather than the one playing.
  Future<void> applyBufferSettings({
    required int cacheMb,
    required int readAheadPercent,
  }) async {
    if (cacheMb == _cacheMb && readAheadPercent == _readAheadPercent) return;
    _cacheMb = cacheMb;
    _readAheadPercent = readAheadPercent;
    if (_isStarted) await _configureSettings();
  }

  Future<TorrentStatus?> getCurrentStatus() async {
    if (_activeTorrentHash == null || !_isStarted) {
      return null;
    }
    try {
      final statusMap = await _server.getTorrentStatus(_activeTorrentHash!);
      if (statusMap != null) {
        return TorrentStatus.fromMap(statusMap);
      }
    } catch (e) {
      if (kDebugMode) debugPrint("Error fetching status: $e");
    }
    return null;
  }

  Future<void> start() async {
    if (_isStarted) {
      return;
    }
    try {
      final port = await _server.start();
      if (port > 0) {
        _serverUrl = "http://127.0.0.1:$port";
        _isStarted = true;
        if (kDebugMode) debugPrint("Torrent Server started at $_serverUrl");
        await _configureSettings();
      }
    } catch (e) {
      if (kDebugMode) debugPrint("Failed to start torrent server: $e");
    }
  }

  Future<void> _configureSettings() async {
    try {
      final token = _server.authToken;
      final headers = {
        'Content-Type': 'application/json',
        if (token != null) FlutterTorrentServer.authTokenHeader: token,
      };

      final settings = {
        "action": "set",
        "sets": {
          "CacheSize": _cacheMb * 1024 * 1024,
          "ReaderReadAHead": _readAheadPercent,
          "PreloadCache": 0, // 0% preload cache ensures instant start without blocking on buffer
          "ConnectionsLimit": 100, // 100 connections for rapid peer/swarm discovery
          "TorrentDisconnectTimeout": 30,
          "RetrackersMode": 1,
        }
      };

      final response = await http.post(
        Uri.parse("$_serverUrl/settings"),
        headers: headers,
        body: jsonEncode(settings),
      );

      if (response.statusCode == 200) {
        if (kDebugMode) {
          debugPrint("TorrServer settings configured for instant streaming.");
        }
      } else {
        if (kDebugMode) {
          debugPrint("TorrServer settings response status: ${response.statusCode}");
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint("Failed to configure TorrServer settings: $e");
    }
  }

  Future<void> stop() async {
    try {
      await _server.stop();
    } catch (e) {
      if (kDebugMode) debugPrint("Error stopping torrent server: $e");
    } finally {
      _isStarted = false;
      _serverUrl = null;
      _activeTorrentHash = null;
    }
  }

  Future<String?> getStreamUrl(String magnetLink) async {
    if (!_isStarted) {
      await start();
    }
    if (_serverUrl == null) {
      return null;
    }

    try {
      final String linkToAdd = await _prepareMagnetLink(magnetLink);

      // Add Torrent with a 12s timeout
      final hash = await _server
          .addTorrent(linkToAdd)
          .timeout(const Duration(seconds: 12), onTimeout: () => null);
      if (hash == null) {
        throw Exception("Failed to add torrent or timed out");
      }
      _activeTorrentHash = hash;

      // Poll for Status to get Filename and File Index
      final fileInfo = await _pollForMetadata(hash);
      if (fileInfo == null) {
        throw Exception("Timed out waiting for torrent metadata");
      }

      final int fileIndex = fileInfo['index'] as int;
      final rawPath = fileInfo['path'] as String? ?? 'video.mp4';
      final fileName = Uri.encodeComponent(rawPath.split(RegExp(r'[/\\]')).last);

      // Construct URL with proper filename and extension for instant container demuxing
      // Try to fetch from playlist first
      final playlistStreamUrl = await _fetchPlaylistUrl(hash, fileIndex);
      if (playlistStreamUrl != null) {
        return playlistStreamUrl;
      }

      // Fallback: Direct stream with filename
      return "$_serverUrl/stream/$fileName?link=$hash&index=$fileIndex&play";
    } catch (e) {
      if (kDebugMode) debugPrint("Error generating stream URL: $e");
      return null;
    }
  }

  Future<String> _prepareMagnetLink(String link) async {
    if (!link.startsWith("magnet:") &&
        !link.startsWith("http") &&
        (AppUtils.isLocalFile(link) || link.contains(RegExp(r'\.torrent$')))) {
      try {
        return await TorrentFileParser.getMagnetLink(link);
      } catch (e) {
        throw Exception("Failed to parse torrent file: $e");
      }
    }
    return link;
  }

  Future<Map<String, dynamic>?> _pollForMetadata(String hash) async {
    int attempts = 0;
    // Check every 350ms up to 28 attempts (~10 seconds max) so dead torrents fail over fast
    while (attempts < 28) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      try {
        final status = await _server.getTorrentStatus(hash);
        if (status != null && status['file_stats'] is List) {
          final fileStats = status['file_stats'] as List;
          if (fileStats.isNotEmpty) {
            return _findSequentialVideoFile(fileStats);
          }
        }
      } catch (_) {}
      attempts++;
    }
    return null;
  }

  Map<String, dynamic> _findSequentialVideoFile(List<dynamic> fileStats) {
    final videoExtensions = ['.mp4', '.mkv', '.avi', '.mov', '.webm'];
    final videoFiles = <Map<dynamic, dynamic>>[];

    for (final f in fileStats) {
      if (f is Map) {
        final path = f['path']?.toString() ?? "";
        if (path.isNotEmpty) {
          final lowerPath = path.toLowerCase();
          if (videoExtensions.any((ext) => lowerPath.endsWith(ext))) {
            videoFiles.add(f);
          }
        }
      }
    }

    if (videoFiles.isNotEmpty) {
      // Sort alphabetically to find the "first" file in sequence (e.g. S01E01)
      videoFiles.sort(
        (a, b) => (a['path'] as String).compareTo(b['path'] as String),
      );

      final selectedFile = videoFiles.first;
      int fileIndex = 0;
      if (selectedFile['id'] != null) {
        fileIndex = (selectedFile['id'] as num).toInt();
      }
      if (kDebugMode) {
        debugPrint(
          "Auto-selected first video file: ${selectedFile['path']} (Index: $fileIndex)",
        );
      }
      return {'index': fileIndex, 'path': selectedFile['path']};
    }

    // Fallback to largest file if no video extension matches (e.g. strict naming)
    return _findLargestFile(fileStats);
  }

  Map<String, dynamic> _findLargestFile(List<dynamic> fileStats) {
    Map<dynamic, dynamic>? largestFile;
    int maxLen = -1;
    int largestIndex = 0;

    for (int i = 0; i < fileStats.length; i++) {
      final f = fileStats[i];
      if (f is Map) {
        final path = f['path']?.toString() ?? "";
        if (path.isNotEmpty) {
          final len = (f['length'] as num?)?.toInt() ?? 0;
          if (len > maxLen) {
            maxLen = len;
            largestFile = f;
            largestIndex = i;
          }
        }
      }
    }

    if (largestFile != null) {
      int fileIndex = largestIndex;
      if (largestFile['id'] != null) {
        fileIndex = (largestFile['id'] as num).toInt();
      }
      if (kDebugMode) {
        debugPrint(
          "Fallback to largest file: ${largestFile['path']} (Index: $fileIndex)",
        );
      }
      return {'index': fileIndex, 'path': largestFile['path']};
    }

    return {'index': 0, 'path': 'Unknown'};
  }

  Future<String?> _fetchPlaylistUrl(String hash, int index) async {
    try {
      final playlistUrl = "$_serverUrl/playlist?hash=$hash";
      final plResponse = await http.get(Uri.parse(playlistUrl));

      if (plResponse.statusCode == 200) {
        final lines = plResponse.body.split('\n');
        int currentIndex = 0;
        for (var line in lines) {
          line = line.trim();
          if (line.isNotEmpty && !line.startsWith('#')) {
            if (currentIndex == index) {
              String targetUrl = line;
              if (!targetUrl.startsWith('http')) {
                targetUrl = targetUrl.startsWith('/')
                    ? "$_serverUrl$targetUrl"
                    : "$_serverUrl/$targetUrl";
              }
              return targetUrl;
            }
            currentIndex++;
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint("Failed to fetch playlist: $e");
    }
    return null;
  }

  Future<String?> getStreamUrlForFileIndex(int index) async {
    if (_serverUrl == null || _activeTorrentHash == null) {
      return null;
    }

    // Use "Simplified" format for maximum compatibility
    final streamUrl =
        "$_serverUrl/stream?link=$_activeTorrentHash&index=$index&play";
    if (kDebugMode) {
      debugPrint("Generated Stream URL for Index $index: $streamUrl");
    }
    return streamUrl;
  }
}
