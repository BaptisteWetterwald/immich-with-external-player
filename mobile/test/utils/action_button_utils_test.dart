import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/utils/action_button.utils.dart';

void main() {
  final date = DateTime.utc(2026, 10, 11);
  final video = RemoteAsset(
    id: 'video-1',
    name: 'Holiday.mkv',
    ownerId: 'owner-1',
    checksum: 'checksum-1',
    type: AssetType.video,
    createdAt: date,
    updatedAt: date,
    isEdited: false,
  );

  ActionButtonContext context({
    BaseAsset? asset,
    bool owner = true,
    bool lockedView = false,
    TimelineOrigin origin = TimelineOrigin.main,
    int selectedCount = 1,
  }) => ActionButtonContext(
    asset: asset ?? video,
    isOwner: owner,
    isArchived: false,
    isInLockedView: lockedView,
    isStacked: false,
    currentAlbum: null,
    advancedTroubleshooting: false,
    source: ActionSource.viewer,
    timelineOrigin: origin,
    selectedCount: selectedCount,
  );

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('external player action visibility', () {
    test('appears for one owned remote video on Android', () {
      expect(ActionButtonType.externalPlayer.shouldShow(context()), isTrue);
    });

    for (final platform in TargetPlatform.values.where((platform) => platform != TargetPlatform.android)) {
      test('is hidden on $platform', () {
        debugDefaultTargetPlatformOverride = platform;

        expect(ActionButtonType.externalPlayer.shouldShow(context()), isFalse);
      });
    }

    test('is hidden for a remote photo', () {
      expect(
        ActionButtonType.externalPlayer.shouldShow(context(asset: video.copyWith(type: AssetType.image))),
        isFalse,
      );
    });

    test('is hidden for videos owned by someone else', () {
      expect(ActionButtonType.externalPlayer.shouldShow(context(owner: false)), isFalse);
    });

    test('is hidden in the locked folder', () {
      expect(ActionButtonType.externalPlayer.shouldShow(context(lockedView: true)), isFalse);
    });

    test('is hidden for locked videos even outside the locked folder', () {
      expect(
        ActionButtonType.externalPlayer.shouldShow(context(asset: video.copyWith(visibility: AssetVisibility.locked))),
        isFalse,
      );
    });

    test('is hidden for deleted videos', () {
      expect(ActionButtonType.externalPlayer.shouldShow(context(asset: video.copyWith(deletedAt: date))), isFalse);
    });

    test('is hidden in the trash even when the asset is not marked deleted', () {
      expect(ActionButtonType.externalPlayer.shouldShow(context(origin: TimelineOrigin.trash)), isFalse);
    });

    for (final selectedCount in [0, 2]) {
      test('is hidden with $selectedCount selected assets', () {
        expect(ActionButtonType.externalPlayer.shouldShow(context(selectedCount: selectedCount)), isFalse);
      });
    }

    for (final remoteId in [null, 'video-1']) {
      test('is hidden for a local video ${remoteId == null ? 'without' : 'with'} a linked server asset', () {
        final localVideo = LocalAsset(
          id: 'local-video',
          remoteId: remoteId,
          name: 'Holiday.mkv',
          checksum: 'checksum-1',
          type: AssetType.video,
          createdAt: date,
          updatedAt: date,
          playbackStyle: AssetPlaybackStyle.video,
          isEdited: false,
        );

        expect(ActionButtonType.externalPlayer.shouldShow(context(asset: localVideo)), isFalse);
      });
    }
  });
}
