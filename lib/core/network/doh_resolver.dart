import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../logger/app_logger.dart';

/// Quad-Redundant Encrypted DNS-over-HTTPS (DoH) Resolver.
///
/// Bypasses ISP DNS poisoning, sinkholing, and domain blocks by resolving
/// provider hostnames over encrypted HTTPS queries to Cloudflare, Google and
/// Quad9 — then dials the answer while keeping the hostname on the URL, so TLS
/// still verifies the name it belongs to.
class DohResolver {
  DohResolver._();

  static final DohResolver instance = DohResolver._();

  static const List<String> _dohEndpoints = [
    'https://cloudflare-dns.com/dns-query',
    'https://dns.google/resolve',
    'https://dns.quad9.net/dns-query',
  ];

  final Map<String, ({String ip, DateTime expiresAt})> _cache = {};

  /// Clients already dialing through [installOn]. Identity, not equality:
  /// `HttpClient` has no value semantics and each one owns its own pool.
  final Set<HttpClient> _installed = HashSet<HttpClient>.identity();

  /// Resolves [hostname] to an IPv4 address, racing top DoH providers.
  Future<String?> resolve(String hostname) async {
    final now = DateTime.now();
    final cached = _cache[hostname];
    if (cached != null && cached.expiresAt.isAfter(now)) {
      return cached.ip;
    }

    final completer = Completer<String?>();
    var remaining = 2;

    for (final endpoint in _dohEndpoints.take(2)) {
      unawaited(
        _queryDoh(endpoint, hostname)
            .then((ip) {
              if (ip != null && !completer.isCompleted) {
                _cache[hostname] = (
                  ip: ip,
                  expiresAt: now.add(const Duration(minutes: 30)),
                );
                completer.complete(ip);
              } else {
                remaining--;
                if (remaining <= 0 && !completer.isCompleted) {
                  completer.complete(null);
                }
              }
            })
            .catchError((_) {
              remaining--;
              if (remaining <= 0 && !completer.isCompleted) {
                completer.complete(null);
              }
            }),
      );
    }

    final answer = await completer.future.timeout(
      const Duration(milliseconds: 1500),
      onTimeout: () => null,
    );
    if (answer == null) {
      // The fallback is the system resolver, which on a poisoned network is
      // exactly what DoH exists to avoid. Worth one line in the app log: a
      // playback that fails here fails everywhere, and the cause is otherwise
      // invisible once the app leaves the debug console.
      talker.warning(
        '[doh] $hostname did not resolve over DoH; using system DNS',
      );
    }
    return answer;
  }

  /// Installs this resolver as [client]'s dialer.
  ///
  /// DoH still chooses the address, but only the socket is pointed at the
  /// answer: the URL keeps the real hostname, so TLS sends the right SNI and
  /// validates the certificate against the name. Rewriting the URL host
  /// instead, as this used to do, presented an IP to every CDN — Cloudflare-
  /// fronted hosts answered 403 or failed the handshake, and certificate
  /// checks had to be disabled to get any proxied traffic through at all.
  void installOn(HttpClient client) {
    if (!_installed.add(client)) return;
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final host = uri.host;
      final target =
          _isIpv4(host) || host == 'localhost' || host.endsWith('.local')
          ? host
          : await resolve(host) ?? host;
      final socket = await Socket.connect(
        target,
        uri.port,
      ).timeout(const Duration(seconds: 10));
      if (uri.scheme != 'https') {
        return ConnectionTask.fromSocket(Future.value(socket), socket.destroy);
      }
      try {
        final tls = await SecureSocket.secure(
          socket,
          host: host,
        ).timeout(const Duration(seconds: 10));
        return ConnectionTask.fromSocket(Future.value(tls), tls.destroy);
      } catch (_) {
        socket.destroy();
        rethrow;
      }
    };
  }

  /// Opens [uri] on [client], which must be dialing through [installOn].
  ///
  /// Kept as a seam so callers do not each have to know about the dialer; the
  /// URL itself is never rewritten.
  Future<HttpClientRequest> openUrl({
    required HttpClient client,
    required String method,
    required Uri uri,
  }) {
    installOn(client);
    return client.openUrl(method, uri);
  }

  Future<String?> _queryDoh(String endpoint, String hostname) async {
    try {
      final uri = Uri.parse(endpoint)
          .replace(queryParameters: {'name': hostname, 'type': 'A'});
      final resp = await http
          .get(uri, headers: {'Accept': 'application/dns-json'})
          .timeout(const Duration(milliseconds: 1200));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final answers = data['Answer'] as List<dynamic>?;
        if (answers != null && answers.isNotEmpty) {
          for (final ans in answers) {
            final type = ans['type'] as int?;
            final dataStr = ans['data'] as String?;
            if (type == 1 && dataStr != null && _isIpv4(dataStr)) {
              if (kDebugMode) {
                debugPrint(
                  '[DOH-MESH] Resolved "$hostname" -> $dataStr via $endpoint',
                );
              }
              return dataStr;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static bool _isIpv4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  void clear() {
    _cache.clear();
    _installed.clear();
  }
}
