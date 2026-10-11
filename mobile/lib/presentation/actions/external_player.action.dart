import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/external_player.service.dart';

final _stateProvider = Provider.family.autoDispose<RemoteAsset?, ActionSource>((ref, source) {
  final assets = ref.watch(assetsActionProvider(source));
  if (assets.length != 1) {
    return null;
  }
  final asset = assets.first;
  if (asset is! RemoteAsset || !asset.isVideo || asset.isLocked || asset.isTrashed) {
    return null;
  }
  return asset.ownerId == ref.watch(authUserProvider).id ? asset : null;
}, dependencies: [assetsActionProvider]);

class ExternalPlayerAction extends AssetActionBuilder {
  const ExternalPlayerAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    final asset = ref.watch(_stateProvider(source));
    if (asset == null) {
      return null;
    }
    return ActionItem(
      icon: Icons.play_circle_outline,
      label: context.t.open_in_external_player,
      onAction: () => _open(context, ref, asset),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref, RemoteAsset asset) async {
    final player = ref.read(externalPlayerServiceProvider);
    final toast = ref.read(toastServiceProvider);
    final original = ref.read(appConfigProvider).viewer.loadOriginalVideo;
    final video = source == ActionSource.viewer ? ref.read(videoPlayerProvider(asset.id).notifier) : null;
    final title = context.t.open_in_external_player;
    final noPlayer = context.t.external_player_not_found;
    final unsafeEndpoint = context.t.external_player_tailscale_required;
    final failed = context.t.external_player_failed;

    try {
      await video?.pause();
      await player.openVideo(asset, original: original, chooserTitle: title);
    } on PlatformException catch (error) {
      toast.error(switch (error.code) {
        'NO_PLAYER' => noPlayer,
        'UNSAFE_ENDPOINT' => unsafeEndpoint,
        _ => failed,
      });
    } catch (_) {
      toast.error(failed);
    }
  }
}
