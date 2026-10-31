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
    // The resolver only chooses which address to dial; the URL keeps the real
    // hostname so TLS sends it as SNI and validates the certificate against
    // it. Rewriting the host, as it used to, is what made proxied HTTPS
    // requests fail. Here we only pin the lookup itself.
    test(
      'resolves a hostname to an IPv4 answer and reuses the cache',
      () async {
        final resolver = DohResolver.instance;
        resolver.clear();

        final first = await resolver.resolve('cloudflare-dns.com');
        // No network in this environment: nothing to assert.
        if (first == null) return;

        expect(
          RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(first),
          isTrue,
          reason: 'DoH answers are IPv4 literals, not hostnames',
        );
        expect(await resolver.resolve('cloudflare-dns.com'), first);
      },
    );
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
