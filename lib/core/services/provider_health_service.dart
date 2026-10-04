import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Performance and reliability statistics for an extension or stream provider.
class ProviderHealthRecord {
  final String providerId;
  final int successCount;
  final int failureCount;
  final int consecutiveFailures;
  final int lastResponseTimeMs;
  final DateTime lastAttemptAt;

  const ProviderHealthRecord({
    required this.providerId,
    this.successCount = 0,
    this.failureCount = 0,
    this.consecutiveFailures = 0,
    this.lastResponseTimeMs = 0,
    required this.lastAttemptAt,
  });

  /// Computes a composite health score between 0.0 (completely dead) and 1.0 (healthy & fast).
  ///
  /// Factors:
  /// - Consecutive failures cause an aggressive penalty (each drops score by 35%).
  /// - Historical success ratio (successes vs total attempts).
  /// - Response latency (fast responses < 1500ms score higher than slow > 5000ms).
  /// - Grace cooldown: failures older than 15 minutes recover gradually.
  double get score {
    // If failures are older than 15 minutes, recover consecutive penalty
    final minutesSinceAttempt = DateTime.now().difference(lastAttemptAt).inMinutes;
    final effectiveConsecutiveFailures = minutesSinceAttempt > 15
        ? (consecutiveFailures - (minutesSinceAttempt ~/ 15)).clamp(0, 10)
        : consecutiveFailures;

    if (effectiveConsecutiveFailures >= 3) {
      return 0.1; // Severely degraded
    } else if (effectiveConsecutiveFailures == 2) {
      return 0.35;
    } else if (effectiveConsecutiveFailures == 1) {
      return 0.65;
    }

    final total = successCount + failureCount;
    if (total == 0) return 0.9; // Untested gets high benefit of doubt

    final ratio = successCount / total;

    // Latency factor: < 1500ms = 1.0, 5000ms = 0.8, > 10000ms = 0.6
    final latencyScore = lastResponseTimeMs <= 0
        ? 1.0
        : (1.0 - ((lastResponseTimeMs - 1500) / 15000)).clamp(0.6, 1.0);

    return (ratio * 0.7 + latencyScore * 0.3).clamp(0.1, 1.0);
  }

  ProviderHealthRecord copyWith({
    int? successCount,
    int? failureCount,
    int? consecutiveFailures,
    int? lastResponseTimeMs,
    DateTime? lastAttemptAt,
  }) {
    return ProviderHealthRecord(
      providerId: providerId,
      successCount: successCount ?? this.successCount,
      failureCount: failureCount ?? this.failureCount,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      lastResponseTimeMs: lastResponseTimeMs ?? this.lastResponseTimeMs,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'providerId': providerId,
    'successCount': successCount,
    'failureCount': failureCount,
    'consecutiveFailures': consecutiveFailures,
    'lastResponseTimeMs': lastResponseTimeMs,
    'lastAttemptAt': lastAttemptAt.toIso8601String(),
  };

  factory ProviderHealthRecord.fromJson(Map<String, dynamic> json) {
    return ProviderHealthRecord(
      providerId: json['providerId'] as String,
      successCount: json['successCount'] as int? ?? 0,
      failureCount: json['failureCount'] as int? ?? 0,
      consecutiveFailures: json['consecutiveFailures'] as int? ?? 0,
      lastResponseTimeMs: json['lastResponseTimeMs'] as int? ?? 0,
      lastAttemptAt: json['lastAttemptAt'] != null
          ? DateTime.tryParse(json['lastAttemptAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

/// Service that maintains and updates provider health metrics and failover priority.
class ProviderHealthService {
  static const String _kPrefsKey = 'provider_health_records_v1';
  final Map<String, ProviderHealthRecord> _records = {};
  bool _loaded = false;

  ProviderHealthService() {
    _loadFromStorage();
  }

  Future<void> _loadFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          if (entry.value is Map<String, dynamic>) {
            _records[entry.key] = ProviderHealthRecord.fromJson(
              entry.value as Map<String, dynamic>,
            );
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('ProviderHealthService._loadFromStorage error: $e');
    } finally {
      _loaded = true;
    }
  }

  Future<void> _saveToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(
        _records.map((k, v) => MapEntry(k, v.toJson())),
      );
      await prefs.setString(_kPrefsKey, encoded);
    } catch (e) {
      if (kDebugMode) debugPrint('ProviderHealthService._saveToStorage error: $e');
    }
  }

  /// Records a successful scraping or streaming attempt from [providerId].
  void recordSuccess(String providerId, {Duration? responseTime}) {
    if (providerId.isEmpty) return;
    final now = DateTime.now();
    final current = _records[providerId] ??
        ProviderHealthRecord(providerId: providerId, lastAttemptAt: now);

    final ms = responseTime?.inMilliseconds ?? current.lastResponseTimeMs;
    _records[providerId] = current.copyWith(
      successCount: current.successCount + 1,
      consecutiveFailures: 0,
      lastResponseTimeMs: ms,
      lastAttemptAt: now,
    );
    _saveToStorage();
  }

  /// Records a failed attempt (timeout, HTTP error, 403, broken link) for [providerId].
  void recordFailure(String providerId, {String? reason}) {
    if (providerId.isEmpty) return;
    final now = DateTime.now();
    final current = _records[providerId] ??
        ProviderHealthRecord(providerId: providerId, lastAttemptAt: now);

    _records[providerId] = current.copyWith(
      failureCount: current.failureCount + 1,
      consecutiveFailures: current.consecutiveFailures + 1,
      lastAttemptAt: now,
    );
    _saveToStorage();
  }

  /// Retrieves the health score for a provider (0.0 to 1.0).
  ///
  /// Default for an untested provider is 0.9 (benefit of doubt).
  double getHealthScore(String providerId) {
    if (providerId.isEmpty) return 0.9;
    final record = _records[providerId];
    return record?.score ?? 0.9;
  }

  /// Whether a provider is currently considered healthy enough for primary selection.
  bool isHealthy(String providerId) {
    return getHealthScore(providerId) >= 0.4;
  }

  /// Sorts candidate stream sources so healthy and fast providers come first.
  ///
  /// Preserves relative order if health scores are within a close margin.
  List<T> rankSourcesByHealth<T>({
    required List<T> sources,
    required String Function(T) getProviderId,
  }) {
    if (sources.length <= 1) return sources;

    final scored = sources.map((source) {
      final pid = getProviderId(source);
      return (source: source, score: getHealthScore(pid));
    }).toList();

    // Sort descending by score. If scores are within 0.15, preserve original order.
    scored.sort((a, b) {
      if ((a.score - b.score).abs() > 0.15) {
        return b.score.compareTo(a.score);
      }
      return 0;
    });

    return scored.map((e) => e.source).toList();
  }
}

final providerHealthServiceProvider = Provider<ProviderHealthService>((ref) {
  return ProviderHealthService();
});
