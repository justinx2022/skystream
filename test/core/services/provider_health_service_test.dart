import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/services/provider_health_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProviderHealthRecord', () {
    test('untested provider starts with default optimistic score (0.9)', () {
      final record = ProviderHealthRecord(
        providerId: 'providerA',
        lastAttemptAt: DateTime.now(),
      );
      expect(record.score, 0.9);
    });

    test('consecutive failures severely penalize score', () {
      final now = DateTime.now();
      final oneFail = ProviderHealthRecord(
        providerId: 'p',
        consecutiveFailures: 1,
        failureCount: 1,
        lastAttemptAt: now,
      );
      expect(oneFail.score, 0.65);

      final twoFail = ProviderHealthRecord(
        providerId: 'p',
        consecutiveFailures: 2,
        failureCount: 2,
        lastAttemptAt: now,
      );
      expect(twoFail.score, 0.35);

      final threeFail = ProviderHealthRecord(
        providerId: 'p',
        consecutiveFailures: 3,
        failureCount: 3,
        lastAttemptAt: now,
      );
      expect(threeFail.score, 0.1);
    });

    test('latency factor rewards fast providers over slow providers', () {
      final now = DateTime.now();
      final fast = ProviderHealthRecord(
        providerId: 'fast',
        successCount: 10,
        lastResponseTimeMs: 800,
        lastAttemptAt: now,
      );
      final slow = ProviderHealthRecord(
        providerId: 'slow',
        successCount: 10,
        lastResponseTimeMs: 9000,
        lastAttemptAt: now,
      );

      expect(fast.score, greaterThan(slow.score));
    });

    test('JSON serialization roundtrips accurately', () {
      final now = DateTime.now();
      final record = ProviderHealthRecord(
        providerId: 'test_provider',
        successCount: 5,
        failureCount: 2,
        consecutiveFailures: 1,
        lastResponseTimeMs: 1200,
        lastAttemptAt: now,
      );

      final json = record.toJson();
      final restored = ProviderHealthRecord.fromJson(json);

      expect(restored.providerId, record.providerId);
      expect(restored.successCount, record.successCount);
      expect(restored.failureCount, record.failureCount);
      expect(restored.consecutiveFailures, record.consecutiveFailures);
      expect(restored.lastResponseTimeMs, record.lastResponseTimeMs);
    });
  });

  group('ProviderHealthService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('records success and resets consecutive failures', () {
      final service = ProviderHealthService();

      service.recordFailure('streamHub', reason: 'timeout');
      expect(service.isHealthy('streamHub'), true); // 1 failure is 0.65 >= 0.4

      service.recordFailure('streamHub', reason: '403 Forbidden');
      service.recordFailure('streamHub', reason: '403 Forbidden');
      expect(service.isHealthy('streamHub'), false); // 3 consecutive failures is 0.1 < 0.4

      service.recordSuccess('streamHub', responseTime: const Duration(milliseconds: 500));
      expect(service.isHealthy('streamHub'), true);
      expect(service.getHealthScore('streamHub'), greaterThan(0.4));
    });

    test('rankSourcesByHealth orders healthy providers ahead of broken ones', () {
      final service = ProviderHealthService();

      service.recordFailure('deadProvider');
      service.recordFailure('deadProvider');
      service.recordFailure('deadProvider');

      service.recordSuccess('healthyFastProvider', responseTime: const Duration(milliseconds: 300));

      final sources = [
        {'id': 'deadProvider', 'name': 'Stream A'},
        {'id': 'healthyFastProvider', 'name': 'Stream B'},
      ];

      final ranked = service.rankSourcesByHealth(
        sources: sources,
        getProviderId: (item) => item['id']!,
      );

      expect(ranked.first['id'], 'healthyFastProvider');
      expect(ranked.last['id'], 'deadProvider');
    });
  });
}
