import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/utils/tailscale_endpoint.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

final externalPlayerServiceProvider = Provider((ref) {
  final current = ref.watch(apiServiceProvider).sharedLinksApi;
  final store = ref.watch(storeServiceProvider);
  return ExternalPlayerService(
    current,
    store,
    apiFactory: () {
      // ApiService reuses a mutable client across server changes. Pin each playback
      // operation to its server and prevent shared-link requests from following redirects.
      final client = current.apiClient;
      final pinned = ApiClient(basePath: client.basePath, authentication: client.authentication);
      pinned.defaultHeaderMap.addAll(client.defaultHeaderMap);
      pinned.client = _PlaybackApiClient(client.client, Uri.parse(client.basePath), store, () => client.basePath);
      return SharedLinksApi(pinned);
    },
  );
});

/// Gives another application access to one video, without exposing the account's session.
class ExternalPlayerService {
  ExternalPlayerService(this._sharedLinks, this._store, {DateTime Function()? now, this._apiFactory})
    : _now = now ?? DateTime.now;

  static const _channel = MethodChannel('immich/external_player');
  final SharedLinksApi _sharedLinks;
  final StoreService _store;
  final DateTime Function() _now;
  final SharedLinksApi Function()? _apiFactory;
  final _log = Logger('ExternalPlayerService');
  bool _opening = false;

  Future<void> openVideo(RemoteAsset asset, {required bool original, required String chooserTitle}) async {
    if (_opening) {
      return;
    }
    if (!asset.isVideo || asset.isLocked || asset.isTrashed || asset.ownerId != _store.get(.currentUser).id) {
      throw StateError('This video cannot be opened externally');
    }

    _opening = true;
    try {
      final endpoint = _store.get(.serverEndpoint);
      final userId = _store.get(.currentUser).id;
      final token = _store.tryGet(.accessToken);
      final base = Uri.parse(endpoint);
      void requireSession() => _requireSession(endpoint, userId, token: token);
      requireSession();
      final sharedLinks = _apiFactory?.call() ?? _sharedLinks;
      if (await _channel.invokeMethod<bool>('isAvailable') != true) {
        throw PlatformException(code: 'NO_PLAYER');
      }
      requireSession();
      await _channel.invokeMethod<void>('validateEndpoint', {'url': endpoint});
      requireSession();
      await _cleanupExpired(endpoint, userId, sharedLinks);
      requireSession();
      final now = _now().toUtc();
      final lifetime = asset.duration + const Duration(hours: 1);
      final expiresAt = now.add(lifetime > const Duration(hours: 2) ? lifetime : const Duration(hours: 2));
      final link = await sharedLinks.createSharedLink(
        SharedLinkCreateDto(
          type: SharedLinkType.INDIVIDUAL,
          assetIds: Optional.present([asset.id]),
          description: const Optional.present('Immich Just Player temporary playback'),
          expiresAt: Optional.present(expiresAt),
          allowUpload: const Optional.present(false),
          allowDownload: Optional.present(original),
          // Immich disallows original downloads when metadata is hidden.
          showMetadata: Optional.present(original),
        ),
      );
      if (link == null) {
        throw StateError('Failed to prepare video playback');
      }

      final pending = _PendingShare(endpoint, userId, link.id, expiresAt);
      try {
        // Persist IDs only. Playback keys and session credentials never enter this journal.
        await _savePending([..._readPending(), pending]);
        requireSession();
        final url = base.replace(
          pathSegments: [
            ...base.pathSegments.where((segment) => segment.isNotEmpty),
            'assets',
            asset.id,
            if (original) 'original' else ...['video', 'playback'],
          ],
          queryParameters: {'key': link.key},
          fragment: '',
        );
        await _channel.invokeMethod<void>('open', {
          'url': url.toString(),
          'mimeType': 'video/*',
          'title': asset.name,
          'chooserTitle': chooserTitle,
        });
      } catch (_) {
        // A launch failure must not leave an unnecessary live share behind.
        if (await _remove(pending, sharedLinks)) {
          await _savePending(
            _readPending()
                .where((entry) => entry.id != pending.id || entry.endpoint != endpoint || entry.userId != userId)
                .toList(),
          );
        }
        rethrow;
      }
    } finally {
      _opening = false;
    }
  }

  void _requireSession(String endpoint, String userId, {String? token, bool checkToken = true}) {
    final base = Uri.parse(endpoint);
    final apiEndpoint = Uri.parse(_sharedLinks.apiClient.basePath);
    if (!isTailscaleEndpoint(base) ||
        !isTailscaleEndpoint(apiEndpoint) ||
        _normalized(base) != _normalized(apiEndpoint) ||
        _store.tryGet(.serverEndpoint) != endpoint ||
        _store.tryGet(.currentUser)?.id != userId ||
        (checkToken && _store.tryGet(.accessToken) != token)) {
      throw PlatformException(code: 'UNSAFE_ENDPOINT');
    }
  }

  Future<void> _cleanupExpired(String endpoint, String userId, SharedLinksApi sharedLinks) async {
    final retained = <_PendingShare>[];
    for (final entry in _readPending()) {
      if (entry.endpoint != endpoint || entry.userId != userId || entry.expiresAt.isAfter(_now().toUtc())) {
        retained.add(entry);
      } else if (!await _remove(entry, sharedLinks)) {
        retained.add(entry);
      }
    }
    await _savePending(retained);
  }

  Future<bool> _remove(_PendingShare entry, SharedLinksApi sharedLinks) async {
    if (_store.tryGet(.serverEndpoint) != entry.endpoint || _store.tryGet(.currentUser)?.id != entry.userId) {
      return false;
    }
    try {
      _requireSession(entry.endpoint, entry.userId, checkToken: false);
      await sharedLinks.removeSharedLink(entry.id);
      return true;
    } on ApiException catch (error) {
      if (error.code == 404) {
        return true;
      }
      _log.warning('Could not remove a temporary playback share; it will expire on the server');
    } catch (_) {
      _log.warning('Could not remove a temporary playback share; it will expire on the server');
    }
    return false;
  }

  List<_PendingShare> _readPending() {
    final encoded = _store.get(StoreKey.externalPlayerShares, '[]');
    try {
      final entries = jsonDecode(encoded) as List<dynamic>;
      return entries.map((entry) => _PendingShare.fromJson(entry as Map<String, dynamic>)).toList();
    } catch (_) {
      // A corrupt local journal must never cause unrelated server shares to be removed.
      _log.warning('Could not read the temporary playback share journal');
      return [];
    }
  }

  Future<void> _savePending(List<_PendingShare> entries) =>
      _store.put(StoreKey.externalPlayerShares, jsonEncode(entries.map((entry) => entry.toJson()).toList()));
}

Uri _normalized(Uri value) => value.replace(path: value.path.replaceFirst(RegExp(r'/+$'), ''));

class _PlaybackApiClient extends http.BaseClient {
  _PlaybackApiClient(this._delegate, this._endpoint, this._store, this._activeEndpoint)
    : _userId = _store.tryGet(.currentUser)?.id,
      _token = _store.tryGet(.accessToken);

  final http.Client _delegate;
  final Uri _endpoint;
  final StoreService _store;
  final String Function() _activeEndpoint;
  final String? _userId;
  final String? _token;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final active = Uri.parse(_activeEndpoint());
    if (!isTailscaleEndpoint(_endpoint) ||
        _normalized(active) != _normalized(_endpoint) ||
        _store.tryGet(.currentUser)?.id != _userId ||
        _store.tryGet(.accessToken) != _token ||
        _normalized(Uri.parse(_store.get(.serverEndpoint))) != _normalized(_endpoint) ||
        request.url.origin != _endpoint.origin ||
        !request.url.path.startsWith('${_normalized(_endpoint).path}/shared-links')) {
      throw PlatformException(code: 'UNSAFE_ENDPOINT');
    }
    request.followRedirects = false;
    return _delegate.send(request);
  }
}

class _PendingShare {
  const _PendingShare(this.endpoint, this.userId, this.id, this.expiresAt);

  final String endpoint;
  final String userId;
  final String id;
  final DateTime expiresAt;

  factory _PendingShare.fromJson(Map<String, dynamic> value) => _PendingShare(
    value['endpoint'] as String,
    value['userId'] as String,
    value['id'] as String,
    DateTime.parse(value['expiresAt'] as String),
  );

  Map<String, String> toJson() => {
    'endpoint': endpoint,
    'userId': userId,
    'id': id,
    'expiresAt': expiresAt.toIso8601String(),
  };
}
