import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/avatar.dart';
import 'package:connect_merge/domain/models/cosmetic.dart' show CosmeticUnlock;

void main() {
  group('Avatar', () {
    test('emojis are unique (glyph<->enum must be a bijection)', () {
      final emojis = Avatar.values.map((a) => a.emoji).toList();
      expect(emojis.toSet().length, emojis.length);
    });

    test('the original eight are free; the rest are priced purchases', () {
      const originalFree = {'🦊', '🐱', '🐼', '🐸', '🦄', '🐙', '🦉', '🐝'};
      for (final a in Avatar.values) {
        if (originalFree.contains(a.emoji)) {
          expect(a.unlock, CosmeticUnlock.free, reason: '${a.name} must stay free');
          expect(a.price, 0);
        } else {
          expect(a.unlock, CosmeticUnlock.purchase, reason: '${a.name} is a purchase');
          expect(a.price, kAvatarPrice);
        }
      }
    });

    test('exactly 20 purchasable avatars were added', () {
      final buyable =
          Avatar.values.where((a) => a.unlock == CosmeticUnlock.purchase);
      expect(buyable.length, 20);
    });

    test('byEmoji resolves known glyphs and null for unknown', () {
      expect(Avatar.byEmoji('🐺'), Avatar.wolf);
      expect(Avatar.byEmoji('🦊'), Avatar.fox);
      expect(Avatar.byEmoji('🍕'), isNull);
    });

    test('free avatars unlock unconditionally; purchases need the set', () {
      expect(Avatar.fox.isUnlocked(purchased: const {}), isTrue);
      expect(Avatar.wolf.isUnlocked(purchased: const {}), isFalse);
      expect(Avatar.wolf.isUnlocked(purchased: {Avatar.wolf}), isTrue);
    });

    test('unlockedAvatars always contains the free set plus purchased', () {
      final unlocked = unlockedAvatars(purchased: {Avatar.wolf});
      expect(unlocked, contains(Avatar.fox)); // free
      expect(unlocked, contains(Avatar.wolf)); // purchased
      expect(unlocked, isNot(contains(Avatar.lion))); // unpurchased
    });
  });
}
