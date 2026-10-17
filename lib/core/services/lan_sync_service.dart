import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../domain/entity/multimedia_item.dart';
import '../storage/storage_service.dart';

/// Seamless Cross-Device Watch Progress Synchronization over Local Area Network (Wi-Fi).
///
/// Automatically discovers other SkyStream instances running on the same local
/// network (e.g. PC, Android TV, tablet, phone) and synchronizes watch history,
/// continue-watching states, and playback positions with zero cloud configuration.
class LanSyncService {
  LanSyncService._();

  static final LanSyncService _instance = LanSyncService._();
  static LanSyncService get instance => _instance;

  static const int _udpPort = 42124;
  static const int _httpPort = 42125;
  static const Duration _broadcastInterval = Duration(seconds: 25);

  StorageService? _storageService;
  RawDatagramSocket? _udpSocket;
  HttpServer? _httpServer;
  Timer? _broadcastTimer;
  bool _started = false;

  late final String _deviceId =
      'device_${DateTime.now().millisecondsSinceEpoch}_${Platform.operatingSystem}';

  /// Starts the LAN discovery and sync service.
  Future<void> start(StorageService storageService) async {
    if (_started) return;
    _storageService = storageService;
    _storageService?.onProgressSaved = notifyProgressSaved;
    _started = true;

    try {
      await _startHttpServer();
      await _startUdpDiscovery();
      _broadcastTimer = Timer.periodic(_broadcastInterval, (_) {
        broadcastSyncPing();
      });
      // Initial announcement
      broadcastSyncPing();
      if (kDebugMode) {
        debugPrint('[LAN-SYNC] Started successfully on UDP $_udpPort and HTTP $_httpPort');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[LAN-SYNC] Error starting LAN sync: $e');
    }
  }

  /// Broadcasts an announcement to the local network that this device has fresh progress.
  void broadcastSyncPing() {
    if (_udpSocket == null) return;
    try {
      final payload = jsonEncode({
        'app': 'skystream',
        'type': 'lan_sync_ping',
        'deviceId': _deviceId,
        'os': Platform.operatingSystem,
        'httpPort': _httpServer?.port ?? _httpPort,
      });
      final bytes = utf8.encode(payload);
      _udpSocket!.broadcastEnabled = true;
      _udpSocket!.send(
        bytes,
        InternetAddress('255.255.255.255'),
        _udpPort,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[LAN-SYNC] UDP broadcast error: $e');
    }
  }

  /// Call whenever playback saves progress to notify peers immediately.
  void notifyProgressSaved() {
    broadcastSyncPing();
  }

  Future<void> _startHttpServer() async {
    try {
      _httpServer = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _httpPort,
        shared: true,
      );
      _httpServer!.listen(_handleHttpRequest);
    } catch (e) {
      // Fallback to ephemeral port if 42125 is in use
      try {
        _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
        _httpServer!.listen(_handleHttpRequest);
      } catch (e) {
        if (kDebugMode) debugPrint('[LAN-SYNC] Failed to bind HTTP server: $e');
      }
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/api/sync/history' && request.method == 'GET') {
        final history = _storageService?.getWatchHistory() ?? [];
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(history));
        await request.response.close();
        return;
      }

      if (path == '/api/sync/push' && request.method == 'POST') {
        final content = await utf8.decodeStream(request);
        final dynamic decoded = jsonDecode(content);
        int merged = 0;
        if (decoded is List) {
          merged = await _mergeRemoteHistory(decoded.cast<Map<String, dynamic>>());
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'merged', 'count': merged}));
        await request.response.close();
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (e) {
      if (kDebugMode) debugPrint('[LAN-SYNC] HTTP request error: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _startUdpDiscovery() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _udpPort,
        reuseAddress: true,
      );
      _udpSocket!.broadcastEnabled = true;
      _udpSocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket!.receive();
          if (datagram != null) {
            _handleIncomingDatagram(datagram);
          }
        }
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[LAN-SYNC] Failed to bind UDP socket: $e');
    }
  }

  void _handleIncomingDatagram(Datagram datagram) {
    try {
      final raw = utf8.decode(datagram.data);
      final dynamic json = jsonDecode(raw);
      if (json is Map && json['app'] == 'skystream' && json['type'] == 'lan_sync_ping') {
        final peerDeviceId = json['deviceId']?.toString();
        final peerPort = json['httpPort'] as int? ?? _httpPort;
        if (peerDeviceId != null && peerDeviceId != _deviceId) {
          // Discovered another SkyStream peer on the network!
          final peerIp = datagram.address.address;
          unawaited(_syncWithPeer(peerIp, peerPort));
        }
      }
    } catch (_) {}
  }

  Future<void> _syncWithPeer(String ip, int port) async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);

      // 1. Fetch remote history from peer
      final getReq = await client.getUrl(Uri.parse('http://$ip:$port/api/sync/history'));
      final getRes = await getReq.close();
      if (getRes.statusCode == HttpStatus.ok) {
        final body = await utf8.decodeStream(getRes);
        final dynamic list = jsonDecode(body);
        if (list is List) {
          await _mergeRemoteHistory(list.cast<Map<String, dynamic>>());
        }
      }

      // 2. Push our local history to peer so both stay in lockstep
      final localHistory = _storageService?.getWatchHistory() ?? [];
      if (localHistory.isNotEmpty) {
        final postReq = await client.postUrl(Uri.parse('http://$ip:$port/api/sync/push'));
        postReq.headers.contentType = ContentType.json;
        postReq.write(jsonEncode(localHistory));
        final postRes = await postReq.close();
        await postRes.drain();
      }

      client.close();
    } catch (e) {
      if (kDebugMode) debugPrint('[LAN-SYNC] Peer sync error with $ip:$port: $e');
    }
  }

  Future<int> _mergeRemoteHistory(List<Map<String, dynamic>> remoteEntries) async {
    final storage = _storageService;
    if (storage == null) return 0;

    int mergedCount = 0;
    final localEntries = storage.getWatchHistory();
    final localMap = {for (final e in localEntries) (e['url'] ?? ''): e};

    for (final remote in remoteEntries) {
      final url = remote['url'] as String?;
      if (url == null || url.isEmpty) continue;

      final local = localMap[url];
      final remoteTs = (remote['timestamp'] as int?) ?? 0;
      final localTs = local != null ? ((local['timestamp'] as int?) ?? 0) : 0;
      final remotePos = (remote['position'] as int?) ?? 0;
      final localPos = local != null ? ((local['position'] as int?) ?? 0) : 0;

      // Merge if remote is newer or significantly further ahead
      if (local == null || remoteTs > localTs || (remoteTs == localTs && remotePos > localPos)) {
        final item = MultimediaItem(
          title: (remote['title'] as String?) ?? '',
          url: url,
          posterUrl: (remote['posterUrl'] as String?) ?? '',
          bannerUrl: remote['bannerUrl'] as String?,
          description: remote['description'] as String?,
          contentType: MultimediaItem.parseContentType(
            (remote['contentType'] as String?) ?? 'movie',
          ),
          provider: remote['provider'] as String?,
          tmdbId: remote['tmdbId'] as int?,
          imdbId: remote['imdbId'] as String?,
        );

        final duration = (remote['duration'] as int?) ?? 0;
        await storage.saveProgress(
          item,
          remotePos,
          duration,
          lastStreamUrl: remote['lastStreamUrl'] as String?,
          lastEpisodeUrl: remote['lastEpisodeUrl'] as String?,
          season: remote['season'] as int?,
          episode: remote['episode'] as int?,
          episodeTitle: remote['episodeTitle'] as String?,
          episodePosterUrl: remote['episodePosterUrl'] as String?,
        );
        mergedCount++;
      }
    }

    if (mergedCount > 0 && kDebugMode) {
      debugPrint('[LAN-SYNC] Merged $mergedCount updated history entries from peer');
    }
    return mergedCount;
  }

  /// Stops the service.
  void stop() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _udpSocket?.close();
    _udpSocket = null;
    _httpServer?.close(force: true);
    _httpServer = null;
    _started = false;
  }
}
