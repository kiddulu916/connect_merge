import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/contacts_hasher.dart';

String _sha(String s) => sha256.convert(utf8.encode(s)).toString();

void main() {
  group('ContactsHasher.normalizePhone', () {
    test('different US formats normalize identically', () {
      const expected = '+14155550100';
      expect(ContactsHasher.normalizePhone('+1 (415) 555-0100'), expected);
      expect(ContactsHasher.normalizePhone('4155550100'), expected);
      expect(ContactsHasher.normalizePhone('+14155550100'), expected);
      expect(ContactsHasher.normalizePhone('1-415-555-0100'), expected);
      expect(ContactsHasher.normalizePhone('  415.555.0100  '), expected);
    });

    test('00 international prefix becomes +', () {
      expect(ContactsHasher.normalizePhone('0044 20 7946 0958'),
          '+442079460958');
    });

    test('keeps existing + international numbers', () {
      expect(
          ContactsHasher.normalizePhone('+44 20 7946 0958'), '+442079460958');
    });

    test('empty / non-numeric returns empty string', () {
      expect(ContactsHasher.normalizePhone(''), '');
      expect(ContactsHasher.normalizePhone('   '), '');
      expect(ContactsHasher.normalizePhone('abc'), '');
    });
  });

  group('ContactsHasher.normalizeEmail', () {
    test('trims and lowercases', () {
      expect(ContactsHasher.normalizeEmail('  Foo.Bar@Example.COM '),
          'foo.bar@example.com');
    });

    test('different cases normalize identically', () {
      expect(ContactsHasher.normalizeEmail('ADA@LOVELACE.org'),
          ContactsHasher.normalizeEmail('ada@lovelace.org'));
    });
  });

  group('ContactsHasher.isEmail', () {
    test('detects @', () {
      expect(ContactsHasher.isEmail('a@b.com'), isTrue);
      expect(ContactsHasher.isEmail('+14155550100'), isFalse);
    });
  });

  group('ContactsHasher.hashContact', () {
    test('phone variants hash identically (stable across formats)', () {
      final a = ContactsHasher.hashContact('+1 (415) 555-0100');
      final b = ContactsHasher.hashContact('4155550100');
      final c = ContactsHasher.hashContact('+14155550100');
      expect(a, isNotNull);
      expect(a, b);
      expect(b, c);
    });

    test('email variants hash identically', () {
      expect(ContactsHasher.hashContact('  Ada@Lovelace.ORG'),
          _sha('ada@lovelace.org'));
    });

    test('hash equals SHA256 of the normalized value (no extra salt)', () {
      expect(ContactsHasher.hashContact('4155550100'), _sha('+14155550100'));
      expect(ContactsHasher.hashContact('Ada@Lovelace.org'),
          _sha('ada@lovelace.org'));
    });

    test('hash is 64 lowercase hex chars (matches server regex)', () {
      final h = ContactsHasher.hashContact('4155550100')!;
      expect(h, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('returns null for unhashable input', () {
      expect(ContactsHasher.hashContact('   '), isNull);
    });

    test('distinct identifiers hash differently', () {
      expect(ContactsHasher.hashContact('4155550100'),
          isNot(ContactsHasher.hashContact('4155550101')));
    });
  });

  group('ContactsHasher.hashAll', () {
    test('drops empties and de-duplicates', () {
      final out = ContactsHasher.hashAll([
        '+1 (415) 555-0100',
        '4155550100', // same as above after normalize
        '   ', // dropped
        'ada@lovelace.org',
      ]);
      expect(out.length, 2);
      expect(out, contains(_sha('+14155550100')));
      expect(out, contains(_sha('ada@lovelace.org')));
    });
  });
}
