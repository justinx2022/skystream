import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/network/doh_resolver.dart';
import 'package:skystream/core/services/provider_health_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DohResolver', () {
    test('DohResolver tracks known IPs and resolves accurately', () async {
      final resolver = DohResolver.instance;
      resolver.clear();

      expect(resolver.isKnownIp('1.1.1.1'), isFalse);

      final ip = await resolver.resolve('cloudflare-dns.com');
      // If network is available, it resolves an IPv4 and adds it to known IPs.
      if (ip != null) {
        expect(resolver.isKnownIp(ip), isTrue);
      }
    });
  });

  group('ProviderHealthService Quarantine', () {
    test('quarantines provider after 3 consecutive failures', () {
      final health = ProviderHealthService();
      const testProvider = 'test_unstable_cdn';

      expect(health.isQuarantined(testProvider), isFalse);

      health.recordFailure(testProvider);
      expect(health.isQuarantined(testProvider), isFalse);

      health.recordFailure(testProvider);
      expect(health.isQuarantined(testProvider), isFalse);

      health.recordFailure(testProvider);
      expect(health.isQuarantined(testProvider), isTrue);
      expect(health.isHealthy(testProvider), isFalse);

      // Successful attempt resets quarantine
      health.recordSuccess(testProvider);
      expect(health.isQuarantined(testProvider), isFalse);
    });
  });
}
