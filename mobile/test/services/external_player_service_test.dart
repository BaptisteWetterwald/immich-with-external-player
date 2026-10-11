import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/external_player.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' hide AssetVisibility;

class _MockSharedLinksApi extends Mock implements SharedLinksApi {}

class _MockStoreService extends Mock implements StoreService {}

class _MockApiService extends Mock implements ApiService {}

class _CallbackAuthentication extends Authentication {
  _CallbackAuthentication(this.apply);

  final Future<void> Function() apply;

  @override
  Future<void> applyToParams(List<QueryParam> queryParams, Map<String, String> headerParams) => apply();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('immich/external_player');
  const endpoint = 'https://immich.tailtest.ts.net/photos/api';
  const userId = 'owner-1';
  final now = DateTime.utc(2026, 10, 11, 12);
  final asset = RemoteAsset(
    id: 'video-1',
    name: 'Holiday.mkv',
    ownerId: userId,
    checksum: 'checksum-1',
    type: AssetType.video,
    createdAt: now,
    updatedAt: now,
    durationMs: const Duration(minutes: 10).inMilliseconds,
    isEdited: false,
  );

  late _MockSharedLinksApi sharedLinks;
  late ApiClient apiClient;
  late _MockStoreService store;
  late ExternalPlayerService service;
  late List<MethodCall> calls;
  late String journal;
  late int shareCount;

  List<Map<String, dynamic>> journalEntries() => (jsonDecode(journal) as List<dynamic>).cast<Map<String, dynamic>>();

  Map<String, String> pendingShare(
    String id, {
    String serverEndpoint = endpoint,
    String owner = userId,
    DateTime? expiresAt,
  }) => {
    'endpoint': serverEndpoint,
    'userId': owner,
    'id': id,
    'expiresAt': (expiresAt ?? now.subtract(const Duration(minutes: 1))).toIso8601String(),
  };

  Future<void> open({bool original = false, RemoteAsset? video}) =>
      service.openVideo(video ?? asset, original: original, chooserTitle: 'Open in Just Player');

  setUpAll(() {
    registerFallbackValue(SharedLinkCreateDto(type: SharedLinkType.INDIVIDUAL));
  });

  setUp(() {
    sharedLinks = _MockSharedLinksApi();
    apiClient = ApiClient(basePath: endpoint);
    when(() => sharedLinks.apiClient).thenReturn(apiClient);
    store = _MockStoreService();
    service = ExternalPlayerService(sharedLinks, store, now: () => now);
    calls = [];
    journal = '[]';
    shareCount = 0;

    final user = UserDto(id: userId, email: 'owner@example.test', name: 'Owner', profileChangedAt: now);
    when(() => store.get(StoreKey.currentUser)).thenReturn(user);
    when(() => store.tryGet(StoreKey.currentUser)).thenReturn(user);
    when(() => store.get(StoreKey.serverEndpoint)).thenReturn(endpoint);
    when(() => store.tryGet(StoreKey.serverEndpoint)).thenReturn(endpoint);
    when(() => store.get(StoreKey.externalPlayerShares, '[]')).thenAnswer((_) => journal);
    when(() => store.put(StoreKey.externalPlayerShares, any<String>())).thenAnswer((invocation) async {
      journal = invocation.positionalArguments[1] as String;
    });

    when(() => sharedLinks.createSharedLink(any())).thenAnswer((invocation) async {
      final request = invocation.positionalArguments.single as SharedLinkCreateDto;
      shareCount++;
      return SharedLinkResponseDto(
        id: 'share-$shareCount',
        key: 'temporary-key-$shareCount',
        type: SharedLinkType.INDIVIDUAL,
        userId: userId,
        createdAt: now,
        expiresAt: request.expiresAt.value,
        allowUpload: false,
        allowDownload: request.allowDownload.value!,
        showMetadata: request.showMetadata.value!,
        description: null,
        password: null,
        slug: null,
      );
    });
    when(() => sharedLinks.removeSharedLink(any())).thenAnswer((_) async {});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'isAvailable' ? true : null;
    });
  });

  tearDown(() {
    apiClient.client.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('does not create or change shares when no external player is installed', () async {
    journal = jsonEncode([pendingShare('expired')]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return false;
    });

    await expectLater(open(), throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'NO_PLAYER')));

    expect(calls.map((call) => call.method), ['isAvailable']);
    verifyNever(() => sharedLinks.createSharedLink(any()));
    verifyNever(() => sharedLinks.removeSharedLink(any()));
    verifyNever(() => store.put(StoreKey.externalPlayerShares, any<String>()));
    expect(journalEntries().single['id'], 'expired');
  });

  for (final original in [false, true]) {
    test('creates one expiring share with permissions for ${original ? 'original' : 'optimized'} playback', () async {
      await open(original: original);

      final request = verify(() => sharedLinks.createSharedLink(captureAny())).captured.single as SharedLinkCreateDto;
      expect(request.type, SharedLinkType.INDIVIDUAL);
      expect(request.assetIds.value, [asset.id]);
      expect(request.albumId.isPresent, false);
      expect(request.allowUpload.value, false);
      expect(request.allowDownload.value, original);
      expect(request.showMetadata.value, original);
      expect(request.expiresAt.value, now.add(const Duration(hours: 2)));
      expect(journalEntries(), [pendingShare('share-1', expiresAt: now.add(const Duration(hours: 2)))]);
      expect(journal, isNot(contains('temporary-key')));
    });

    test('passes the ${original ? 'original' : 'optimized'} URL and title without session credentials', () async {
      const reverseProxyEndpoint = '$endpoint/';
      when(() => store.get(StoreKey.serverEndpoint)).thenReturn(reverseProxyEndpoint);
      when(() => store.tryGet(StoreKey.serverEndpoint)).thenReturn(reverseProxyEndpoint);

      await open(original: original);

      expect(calls.map((call) => call.method), ['isAvailable', 'validateEndpoint', 'open']);
      expect(calls[1].arguments, {'url': reverseProxyEndpoint});
      final arguments = calls.last.arguments as Map<dynamic, dynamic>;
      final url = Uri.parse(arguments['url'] as String);
      expect(url.origin, 'https://immich.tailtest.ts.net');
      expect(url.path, '/photos/api/assets/video-1/${original ? 'original' : 'video/playback'}');
      expect(url.queryParameters, {'key': 'temporary-key-1'});
      expect(url.fragment, isEmpty);
      expect(arguments, {
        'url': url.toString(),
        'mimeType': 'video/*',
        'title': 'Holiday.mkv',
        'chooserTitle': 'Open in Just Player',
      });
      verifyNever(() => store.get(StoreKey.accessToken));
    });
  }

  test('allows a long video to play until one hour after its duration', () async {
    await open(video: asset.copyWith(durationMs: const Duration(hours: 3, minutes: 15).inMilliseconds));

    final request = verify(() => sharedLinks.createSharedLink(captureAny())).captured.single as SharedLinkCreateDto;
    expect(request.expiresAt.value, now.add(const Duration(hours: 4, minutes: 15)));
  });

  test('removes only expired journal shares for the current server and user', () async {
    final unexpired = pendingShare('unexpired', expiresAt: now.add(const Duration(minutes: 1)));
    final otherServer = pendingShare('other-server', serverEndpoint: 'https://other.tailtest.ts.net/api');
    final otherUser = pendingShare('other-user', owner: 'owner-2');
    journal = jsonEncode([
      pendingShare('expired'),
      pendingShare('expires-now', expiresAt: now),
      unexpired,
      otherServer,
      otherUser,
    ]);

    await open();

    verify(() => sharedLinks.removeSharedLink('expired')).called(1);
    verify(() => sharedLinks.removeSharedLink('expires-now')).called(1);
    verifyNever(() => sharedLinks.removeSharedLink('unexpired'));
    verifyNever(() => sharedLinks.removeSharedLink('other-server'));
    verifyNever(() => sharedLinks.removeSharedLink('other-user'));
    expect(journalEntries().map((entry) => entry['id']), ['unexpired', 'other-server', 'other-user', 'share-1']);
  });

  test('forgets an expired journal share that has already been removed on the server', () async {
    journal = jsonEncode([pendingShare('already-removed')]);
    when(() => sharedLinks.removeSharedLink('already-removed')).thenThrow(ApiException(404, 'Not found'));

    await open();

    expect(journalEntries().map((entry) => entry['id']), ['share-1']);
  });

  test('retains failed deletions and retries them on the next playback', () async {
    journal = jsonEncode([pendingShare('retry')]);
    when(() => sharedLinks.removeSharedLink('retry')).thenThrow(ApiException(503, 'Unavailable'));

    await open();

    expect(journalEntries().map((entry) => entry['id']), ['retry', 'share-1']);
    when(() => sharedLinks.removeSharedLink('retry')).thenAnswer((_) async {});

    await open();

    verify(() => sharedLinks.removeSharedLink('retry')).called(2);
    expect(journalEntries().map((entry) => entry['id']), ['share-1', 'share-2']);
  });

  test('deletes the newly created share when launching the external player fails', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'open') {
        throw PlatformException(code: 'OPEN_FAILED');
      }
      return call.method == 'isAvailable' ? true : null;
    });

    await expectLater(open(), throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'OPEN_FAILED')));

    verify(() => sharedLinks.removeSharedLink('share-1')).called(1);
    expect(journalEntries(), isEmpty);
  });

  test('retains the failed-launch share if revocation fails so cleanup can retry it', () async {
    when(() => sharedLinks.removeSharedLink('share-1')).thenThrow(ApiException(503, 'Unavailable'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'open') {
        throw PlatformException(code: 'OPEN_FAILED');
      }
      return call.method == 'isAvailable' ? true : null;
    });

    await expectLater(open(), throwsA(isA<PlatformException>()));

    expect(journalEntries().map((entry) => entry['id']), ['share-1']);
    expect(journal, isNot(contains('temporary-key')));
  });

  test('revokes the new share if its journal entry cannot be persisted', () async {
    var writes = 0;
    when(() => store.put(StoreKey.externalPlayerShares, any<String>())).thenAnswer((invocation) async {
      writes++;
      if (writes == 2) {
        throw StateError('Disk full');
      }
      journal = invocation.positionalArguments[1] as String;
    });

    await expectLater(open(), throwsStateError);

    verify(() => sharedLinks.removeSharedLink('share-1')).called(1);
    expect(journalEntries(), isEmpty);
    expect(calls.map((call) => call.method), ['isAvailable', 'validateEndpoint']);
  });

  test('does not launch without a share and permits retrying after preparation fails', () async {
    when(() => sharedLinks.createSharedLink(any())).thenAnswer((_) async => null);

    await expectLater(open(), throwsStateError);
    await expectLater(open(), throwsStateError);

    verify(() => sharedLinks.createSharedLink(any())).called(2);
    expect(calls.map((call) => call.method), ['isAvailable', 'validateEndpoint', 'isAvailable', 'validateEndpoint']);
    expect(journalEntries(), isEmpty);
  });

  test('ignores a damaged journal without deleting unrelated shares', () async {
    journal = '{invalid JSON';

    await open();

    verifyNever(() => sharedLinks.removeSharedLink(any()));
    expect(journalEntries().map((entry) => entry['id']), ['share-1']);
  });

  test('ignores a second open while the first launch is pending, then permits later opens', () async {
    final available = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'isAvailable' ? available.future : null;
    });

    final firstOpen = open();
    await open();
    available.complete(true);
    await firstOpen;

    expect(shareCount, 1);
    expect(calls.map((call) => call.method), ['isAvailable', 'validateEndpoint', 'open']);

    await open();

    expect(shareCount, 2);
  });

  for (final invalidAsset in [
    asset.copyWith(type: AssetType.image),
    asset.copyWith(visibility: AssetVisibility.locked),
    asset.copyWith(deletedAt: now),
    asset.copyWith(ownerId: 'owner-2'),
  ]) {
    test(
      'rejects an ineligible asset before exposing it to another app: ${invalidAsset.type}/${invalidAsset.visibility}/${invalidAsset.ownerId}/${invalidAsset.isTrashed}',
      () async {
        await expectLater(open(video: invalidAsset), throwsStateError);

        expect(calls, isEmpty);
        verifyNever(() => sharedLinks.createSharedLink(any()));
      },
    );
  }

  for (final unsafeEndpoint in [
    'https://photos.example.test/api',
    'https://immich.tailtest.ts.net.example.test/api',
    'https://8.8.8.8/api',
    'http://192.168.1.10/api',
    'http://10.0.0.10/api',
    'http://127.0.0.1/api',
    'https://100.63.255.255/api',
    'https://100.128.0.0/api',
    'https://[2001:4860:4860::8888]/api',
    'https://user:password@immich.tailtest.ts.net/api',
    'ftp://immich.tailtest.ts.net/api',
    '$endpoint?session=must-not-leak',
    '$endpoint#fragment',
  ]) {
    for (final source in ['store', 'api']) {
      test('rejects unsafe $source endpoint $unsafeEndpoint before calling native code or the server', () async {
        journal = jsonEncode([pendingShare('expired')]);
        if (source == 'store') {
          when(() => store.get(StoreKey.serverEndpoint)).thenReturn(unsafeEndpoint);
        } else {
          apiClient.basePath = unsafeEndpoint;
        }

        await expectLater(
          open(),
          throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'UNSAFE_ENDPOINT')),
        );

        expect(calls, isEmpty);
        verifyNever(() => sharedLinks.createSharedLink(any()));
        verifyNever(() => sharedLinks.removeSharedLink(any()));
        verifyNever(() => store.put(StoreKey.externalPlayerShares, any<String>()));
        expect(journalEntries().single['id'], 'expired');
      });
    }
  }

  for (final safeEndpoint in [
    'https://immich.tailtest.ts.net/api',
    'http://100.64.0.0:2283/api',
    'http://100.127.255.255:2283/api',
    'https://[fd7a:115c:a1e0::1]/api',
  ]) {
    test('opens using a matching Tailscale endpoint $safeEndpoint', () async {
      when(() => store.get(StoreKey.serverEndpoint)).thenReturn(safeEndpoint);
      when(() => store.tryGet(StoreKey.serverEndpoint)).thenReturn(safeEndpoint);
      apiClient.basePath = safeEndpoint;

      await open();

      verify(() => sharedLinks.createSharedLink(any())).called(1);
      expect(calls.map((call) => call.method), ['isAvailable', 'validateEndpoint', 'open']);
      final url = Uri.parse((calls.last.arguments as Map<dynamic, dynamic>)['url'] as String);
      expect(url.host, Uri.parse(safeEndpoint).host);
      expect(url.queryParameters, {'key': 'temporary-key-1'});
    });
  }

  for (final mismatchedEndpoint in [
    'https://other.tailtest.ts.net/photos/api',
    'http://immich.tailtest.ts.net/photos/api',
    'https://immich.tailtest.ts.net:2283/photos/api',
    'https://immich.tailtest.ts.net/api',
  ]) {
    test('rejects mismatched Tailscale API endpoint $mismatchedEndpoint before modifying shares', () async {
      journal = jsonEncode([pendingShare('expired')]);
      apiClient.basePath = mismatchedEndpoint;

      await expectLater(
        open(),
        throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'UNSAFE_ENDPOINT')),
      );

      expect(calls, isEmpty);
      verifyNever(() => sharedLinks.createSharedLink(any()));
      verifyNever(() => sharedLinks.removeSharedLink(any()));
      expect(journalEntries().single['id'], 'expired');
    });
  }

  test('does not call the server when native DNS validation rejects the Tailscale endpoint', () async {
    journal = jsonEncode([pendingShare('expired')]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'validateEndpoint') {
        throw PlatformException(code: 'UNSAFE_ENDPOINT');
      }
      return call.method == 'isAvailable' ? true : null;
    });

    await expectLater(
      open(),
      throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'UNSAFE_ENDPOINT')),
    );

    expect(calls.map((call) => call.method), ['isAvailable', 'validateEndpoint']);
    expect(calls.last.arguments, {'url': endpoint});
    verifyNever(() => sharedLinks.createSharedLink(any()));
    verifyNever(() => sharedLinks.removeSharedLink(any()));
    expect(journalEntries().single['id'], 'expired');
  });

  for (final stage in ['isAvailable', 'validateEndpoint', 'cleanup']) {
    for (final mutation in [
      'public API',
      'other Tailscale API',
      'public store',
      'other Tailscale store',
      'account',
      'token',
    ]) {
      test('aborts when $mutation changes during $stage before creating a share', () async {
        void changeSession() {
          switch (mutation) {
            case 'public API':
              apiClient.basePath = 'https://photos.example.test/api';
            case 'other Tailscale API':
              apiClient.basePath = 'https://other.tailtest.ts.net/photos/api';
            case 'public store':
              when(() => store.get(StoreKey.serverEndpoint)).thenReturn('https://photos.example.test/api');
              when(() => store.tryGet(StoreKey.serverEndpoint)).thenReturn('https://photos.example.test/api');
            case 'other Tailscale store':
              when(() => store.get(StoreKey.serverEndpoint)).thenReturn('https://other.tailtest.ts.net/photos/api');
              when(() => store.tryGet(StoreKey.serverEndpoint)).thenReturn('https://other.tailtest.ts.net/photos/api');
            case 'account':
              final otherUser = UserDto(
                id: 'owner-2',
                email: 'other@example.test',
                name: 'Other',
                profileChangedAt: now,
              );
              when(() => store.get(StoreKey.currentUser)).thenReturn(otherUser);
              when(() => store.tryGet(StoreKey.currentUser)).thenReturn(otherUser);
            case 'token':
              when(() => store.tryGet(StoreKey.accessToken)).thenReturn('new-test-session');
          }
        }

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          calls.add(call);
          if (call.method == stage) {
            changeSession();
          }
          return call.method == 'isAvailable' ? true : null;
        });
        if (stage == 'cleanup') {
          when(() => store.put(StoreKey.externalPlayerShares, any<String>())).thenAnswer((invocation) async {
            journal = invocation.positionalArguments[1] as String;
            changeSession();
          });
        }

        await expectLater(
          open(),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              isIn(['UNSAFE_ENDPOINT', 'SESSION_CHANGED']),
            ),
          ),
        );

        verifyNever(() => sharedLinks.createSharedLink(any()));
        verifyNever(() => sharedLinks.removeSharedLink(any()));
        expect(calls.map((call) => call.method), isNot(contains('open')));
      });
    }
  }

  test('does not delete a second expired share after the API endpoint changes during cleanup', () async {
    journal = jsonEncode([pendingShare('expired-1'), pendingShare('expired-2')]);
    when(() => sharedLinks.removeSharedLink('expired-1')).thenAnswer((_) async {
      apiClient.basePath = 'https://photos.example.test/api';
    });

    await expectLater(
      open(),
      throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'UNSAFE_ENDPOINT')),
    );

    verify(() => sharedLinks.removeSharedLink('expired-1')).called(1);
    verifyNever(() => sharedLinks.removeSharedLink('expired-2'));
    verifyNever(() => sharedLinks.createSharedLink(any()));
    expect(calls.map((call) => call.method), isNot(contains('open')));
  });

  group('provider HTTP session isolation', () {
    ExternalPlayerService providedService(ApiClient current) {
      final apiService = _MockApiService();
      when(() => apiService.sharedLinksApi).thenReturn(SharedLinksApi(current));
      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(apiService), storeServiceProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      return container.read(externalPlayerServiceProvider);
    }

    test('pins each operation to its current server and disables HTTP redirects', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 'http-share-${requests.length}',
            'key': 'http-temporary-key-${requests.length}',
            'type': 'INDIVIDUAL',
            'userId': userId,
            'createdAt': now.toIso8601String(),
            'expiresAt': body['expiresAt'],
            'allowUpload': false,
            'allowDownload': false,
            'showMetadata': false,
            'assets': [],
            'description': null,
            'password': null,
            'slug': null,
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      });
      addTearDown(client.close);
      final current = ApiClient(basePath: endpoint)..client = client;
      final playback = providedService(current);

      await playback.openVideo(asset, original: false, chooserTitle: 'Open');
      const nextEndpoint = 'https://other.tailtest.ts.net/photos/api';
      current.basePath = nextEndpoint;
      when(() => store.get(StoreKey.serverEndpoint)).thenReturn(nextEndpoint);
      when(() => store.tryGet(StoreKey.serverEndpoint)).thenReturn(nextEndpoint);
      await playback.openVideo(asset, original: false, chooserTitle: 'Open');

      expect(requests.map((request) => request.url.toString()), [
        '$endpoint/shared-links',
        '$nextEndpoint/shared-links',
      ]);
      expect(requests.every((request) => !request.followRedirects), isTrue);
      expect(calls.where((call) => call.method == 'open').length, 2);
      expect(journalEntries().map((entry) => entry['endpoint']), [endpoint, nextEndpoint]);
    });

    test('blocks the HTTP delegate if the live API changes during asynchronous authentication', () async {
      var sentRequests = 0;
      late ApiClient current;
      final authentication = _CallbackAuthentication(() async {
        current.basePath = 'https://photos.example.test/api';
      });
      final client = MockClient((request) async {
        sentRequests++;
        return http.Response('', 204);
      });
      addTearDown(client.close);
      current = ApiClient(basePath: endpoint, authentication: authentication)..client = client;
      final playback = providedService(current);

      await expectLater(
        playback.openVideo(asset, original: false, chooserTitle: 'Open'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.innerException,
            'cause',
            isA<PlatformException>().having((error) => error.code, 'code', 'UNSAFE_ENDPOINT'),
          ),
        ),
      );

      expect(sentRequests, 0);
      expect(calls.map((call) => call.method), isNot(contains('open')));
      expect(journalEntries(), isEmpty);
    });
  });
}
