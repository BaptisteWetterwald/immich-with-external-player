import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/tailscale_endpoint.dart';

void main() {
  group('isTailscaleEndpoint', () {
    for (final endpoint in [
      'https://immich.tailtest.ts.net/api',
      'http://immich.tailtest.ts.net:2283/photos/api/',
      'https://IMMICH.TAILTEST.TS.NET/api',
      'http://100.64.0.0:2283/api',
      'https://100.100.100.100/api',
      'https://100.127.255.255/api',
      'http://[fd7a:115c:a1e0::]:2283/api',
      'https://[fd7a:115c:a1e0::1]/api',
      'https://[fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff]/api',
      'https://[FD7A:115C:A1E0::1]/api',
    ]) {
      test('accepts Tailscale endpoint $endpoint', () {
        expect(isTailscaleEndpoint(Uri.parse(endpoint)), isTrue);
      });
    }

    for (final endpoint in [
      'https://photos.example.test/api',
      'https://ts.net/api',
      'https://immich.ts.net.example.test/api',
      'https://8.8.8.8/api',
      'http://127.0.0.1/api',
      'http://localhost/api',
      'http://10.0.0.1/api',
      'http://172.16.0.1/api',
      'http://192.168.1.1/api',
      'https://100.63.255.255/api',
      'https://100.128.0.0/api',
      'https://[2001:4860:4860::8888]/api',
      'https://[::1]/api',
      'https://[fd00::1]/api',
      'https://[fd7a:115c:a1df:ffff:ffff:ffff:ffff:ffff]/api',
      'https://[fd7a:115c:a1e1::]/api',
      'https://[::ffff:100.100.100.100]/api',
      'https://user:password@immich.tailtest.ts.net/api',
      'https://user@100.100.100.100/api',
      'https://immich.tailtest.ts.net/api?session=must-not-leak',
      'https://immich.tailtest.ts.net/api#fragment',
      'https://immich.tailtest.ts.net/api?',
      'https://immich.tailtest.ts.net/api#',
      'ftp://immich.tailtest.ts.net/api',
      'file:///api',
      'immich.tailtest.ts.net/api',
      '/api',
    ]) {
      test('rejects an endpoint outside Tailscale: $endpoint', () {
        expect(isTailscaleEndpoint(Uri.parse(endpoint)), isFalse);
      });
    }
  });
}
