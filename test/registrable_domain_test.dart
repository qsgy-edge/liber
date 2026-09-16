import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/public_suffix_list.dart';
import 'package:liber/source/registrable_domain.dart';

/// The cookie key ADR 0011 §3 fixes: the baseline's `getSubDomain` answer
/// (`eTLD+1` through the public suffix list), the host itself for an IP literal.
void main() {
  test('a registrable domain is the public suffix plus one label', () {
    expect(registrableDomain('www.example.com'), 'example.com');
    expect(registrableDomain('example.com'), 'example.com');
    expect(registrableDomain('a.b.example.co.uk'), 'example.co.uk');
    // Two hosts of one site share the key; two sites do not.
    expect(
      registrableDomain('www.example.com'),
      registrableDomain('shop.example.com'),
    );
    expect(
      registrableDomain('example.com'),
      isNot(registrableDomain('example.org')),
    );
  });

  test('wildcard and exception rules decide the site boundary', () {
    // `*.ck` makes `bar.ck` a suffix, so the registrable domain is `foo.bar.ck`.
    expect(registrableDomain('foo.bar.ck'), 'foo.bar.ck');
    // `!www.ck` is an exception to it: `www.ck` itself is the registrable domain.
    expect(registrableDomain('www.ck'), 'www.ck');
  });

  test('the private section of the list counts, as the baseline counts it', () {
    // Guava's `getEffectiveTldPlusOne` uses ICANN and private rules together;
    // `blogspot.com` is a private suffix, so a blog keeps its own key.
    expect(registrableDomain('foo.blogspot.com'), 'foo.blogspot.com');
    expect(registrableDomain('a.foo.blogspot.com'), 'foo.blogspot.com');
  });

  test('a host the list leaves without one stays itself', () {
    expect(registrableDomain('co.uk'), 'co.uk');
    expect(registrableDomain('localhost'), 'localhost');
    expect(registrableDomain(''), '');
  });

  test('an IP literal stays itself', () {
    expect(registrableDomain('127.0.0.1'), '127.0.0.1');
    expect(registrableDomain('::1'), '::1');
    expect(registrableDomain('2001:db8::1'), '2001:db8::1');
  });

  test('a host is lowercased before it is keyed', () {
    expect(registrableDomain('WWW.Example.COM'), 'example.com');
  });

  test('the shipped list records which snapshot it is', () {
    expect(publicSuffixListVersion, isNotEmpty);
    expect(publicSuffixListCommit, isNotEmpty);
    // The ICANN/private split has to survive the generator, because the
    // algorithm reads it to decide which rules are private.
    expect(publicSuffixList, contains('BEGIN PRIVATE'));
    expect(publicSuffixList, contains('END PRIVATE'));
  });
}
