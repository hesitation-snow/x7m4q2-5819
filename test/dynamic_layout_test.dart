import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/pages/dynamic_page.dart';

void main() {
  test('phone dynamic feed stays single-column', () {
    expect(dynamicFeedColumnCount(const Size(430, 932)), 1);
    expect(dynamicFeedColumnCount(const Size(932, 430)), 1);
  });

  test('tablet dynamic feed uses multiple columns', () {
    expect(dynamicFeedColumnCount(const Size(768, 1024)), 2);
    expect(dynamicFeedColumnCount(const Size(1024, 768)), 2);
    expect(dynamicFeedColumnCount(const Size(1366, 1024)), 3);
  });

  test('narrow tablet split view falls back to one column', () {
    expect(dynamicFeedColumnCount(const Size(520, 1024)), 1);
  });

  test('logging out leaves the account-only feed', () {
    expect(normalizedDynamicFeedTab('follow', loggedIn: false), 'mixed');
    expect(normalizedDynamicFeedTab('mixed', loggedIn: false), 'mixed');
    expect(normalizedDynamicFeedTab('follow', loggedIn: true), 'follow');
  });
}
