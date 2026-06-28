import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/engine/prng.dart';

void main() {
  test('same seed yields identical sequence (reproducible)', () {
    final a = Prng(12345);
    final b = Prng(12345);
    final seqA = List.generate(20, (_) => a.nextU32());
    final seqB = List.generate(20, (_) => b.nextU32());
    expect(seqA, seqB);
  });

  test('different seeds diverge', () {
    final a = Prng(1);
    final b = Prng(2);
    expect(a.nextU32(), isNot(equals(b.nextU32())));
  });

  test('nextU32 stays within unsigned 32-bit range', () {
    final p = Prng(99);
    for (var i = 0; i < 1000; i++) {
      final v = p.nextU32();
      expect(v, greaterThanOrEqualTo(0));
      expect(v, lessThanOrEqualTo(0xFFFFFFFF));
    }
  });

  test('nextInt returns values in [0, max)', () {
    final p = Prng(7);
    for (var i = 0; i < 1000; i++) {
      final v = p.nextInt(5);
      expect(v, inInclusiveRange(0, 4));
    }
  });
}
