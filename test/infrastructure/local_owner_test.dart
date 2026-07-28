import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canPush requires a matching complete claimed owner', () {
    const eligible = LocalOwner(
      uid: 'player-1',
      snapshotRevision: 0,
      restoreComplete: true,
      recoveryRequired: false,
      claimed: true,
    );

    expect(eligible.canPush('player-1'), isTrue);
    expect(eligible.canPush('player-2'), isFalse);
    expect(
        eligible.copyWith(restoreComplete: false).canPush('player-1'), isFalse);
    expect(
        eligible.copyWith(recoveryRequired: true).canPush('player-1'), isFalse);
    expect(eligible.copyWith(claimed: false).canPush('player-1'), isFalse);
  });
}
