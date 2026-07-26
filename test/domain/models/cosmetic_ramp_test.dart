import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/models/cosmetic.dart';

void main() {
  group('Cosmetic ramps', () {
    test('every theme has a full 12-entry tier ramp', () {
      for (final c in Cosmetic.values) {
        expect(c.colors, hasLength(12), reason: '${c.name} ramp');
      }
    });

    test('every ramp entry is opaque ARGB except the empty slot', () {
      for (final c in Cosmetic.values) {
        // Tier 0 is the translucent empty slot; tiers 1..11 are opaque.
        for (var tier = 1; tier < c.colors.length; tier++) {
          final alpha = (c.colors[tier] >> 24) & 0xFF;
          expect(alpha, 0xFF,
              reason: '${c.name} tier $tier should be fully opaque');
        }
      }
    });

    test('the six new themes exist with their intended unlocks', () {
      Cosmetic byName(String n) => Cosmetic.values.firstWhere((c) => c.name == n);
      expect(byName('midnight').unlock, CosmeticUnlock.streak);
      expect(byName('midnight').threshold, 14);
      expect(byName('ember').unlock, CosmeticUnlock.achievement);
      expect(byName('frost').unlock, CosmeticUnlock.achievement);
      expect(byName('candy').unlock, CosmeticUnlock.rewardedAd);
      expect(byName('mono').unlock, CosmeticUnlock.purchase);
      expect(byName('galaxy').unlock, CosmeticUnlock.purchase);
    });
  });
}
