import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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

  /// A peer's payload is a watch history - kilobytes. Read with a ceiling so a
  /// hostile or broken peer cannot make this process hold an unbounded body in
  /// memory, in either direction.
  static const int _kMaxSyncBodyBytes = 2 * 1024 * 1024;

  /// Whether [address] is on a network this device can be a peer of.
  ///
  /// The discovery ping says where to send the local watch history, and it
  /// arrives as a datagram any machine that can reach the socket may send.
  /// Without this check one forged ping sends the whole history to a server of
  /// the sender's choosing; likewise a forwarded port would let the internet
  /// read it. A household peer is always private, link-local or loopback.
  static bool _isPrivateAddress(InternetAddress address) {
    if (address.isLoopback) return true;
    final raw = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && raw.length == 4) {
      return raw[0] == 10 ||
          (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) ||
          (raw[0] == 192 && raw[1] == 168) ||
          (raw[0] == 169 && raw[1] == 254);
    }
    if (address.type == InternetAddressType.IPv6 && raw.length == 16) {
      // fc00::/7 unique-local, fe80::/10 link-local.
      return (raw[0] & 0xfe) == 0xfc ||
          (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80);
    }
    return false;
  }

  /// Reads [body] into memory, or null when it is longer than a history can be.
  static Future<Uint8List?> _readBounded(Stream<List<int>> body) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in body) {
      builder.add(chunk);
      if (builder.length > _kMaxSyncBodyBytes) return null;
    }
    return builder.takeBytes();
  }

  StorageService? _storageService;
  RawDatagramSocket? _udpSocket;
  HttpServer? _httpServer;
  Timer? _broadcastTimer;
  bool _started = false;

  /// `ip:port` of peers a sync is currently running against. Pings arrive as
  /// often as every broadcast, and two overlapping syncs would echo each
  /// other's history back and forth.
  final Set<String> _inFlightPeers = <String>{};

  /// Whether local network sync is enabled. Controlled via Settings.
  bool enabled = true;

  late final String _deviceId =
      'device_${DateTime.now().millisecondsSinceEpoch}_${Platform.operatingSystem}';

  /// Starts the LAN discovery and sync service.
  Future<void> start([StorageService? storageService]) async {
    if (!enabled || _started) return;
    if (storageService != null) {
      _storageService = storageService;
    }
    if (_storageService == null) return;
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
    if (!enabled || _udpSocket == null) return;
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
      // Only a device on this network is a peer. A forwarded port would
      // otherwise serve the whole watch history to the internet.
      final remote = request.connectionInfo?.remoteAddress;
      if (remote == null || !_isPrivateAddress(remote)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }

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
        final body = await _readBounded(request);
        if (body == null) {
          request.response.statusCode = HttpStatus.requestEntityTooLarge;
          await request.response.close();
          return;
        }
        final dynamic decoded = jsonDecode(utf8.decode(body));
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
    if (!enabled) return;
    try {
      final raw = utf8.decode(datagram.data);
      final dynamic json = jsonDecode(raw);
      if (json is Map && json['app'] == 'skystream' && json['type'] == 'lan_sync_ping') {
        // The ping names the address to send our history to, so it is only
        // trusted from this network.
        if (!_isPrivateAddress(datagram.address)) return;
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
    final peerKey = '$ip:$port';
    if (!_inFlightPeers.add(peerKey)) return;
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 4);

      // 1. Fetch remote history from peer
      final getReq = await client.getUrl(Uri.parse('http://$ip:$port/api/sync/history'));
      final getRes = await getReq.close().timeout(const Duration(seconds: 8));
      if (getRes.statusCode == HttpStatus.ok) {
        final body = await _readBounded(getRes);
        final dynamic list = body == null ? null : jsonDecode(utf8.decode(body));
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
        final postRes = await postReq.close().timeout(const Duration(seconds: 8));
        await postRes.drain<void>();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[LAN-SYNC] Peer sync error with $ip:$port: $e');
    } finally {
      client?.close();
      _inFlightPeers.remove(peerKey);
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
