import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/channel_page.dart';
import 'package:yomiru/services/book_access_probe.dart';
import 'support/book_image_test_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final images = BookImageTestSandbox();
  setUpAll(images.open);
  tearDownAll(images.close);
  testWidgets('leaving a route drops queued unknown-book probes',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    LKStore.resetBraveBookIdsForTesting({});
    LKStore.hideBraveBooks.value = true;
    LKStore.dataSaverMode.value = false;
    final navigator = GlobalKey<NavigatorState>();
    final pending = <Completer<http.Response>>[];
    var detailRequests = 0;
    var catalogRequests = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.contains('/fixture/')) {
        return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'list': List.generate(
                    4, (i) => {'book_id': 940001 + i, 'title': '待补查$i'})
              }
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (request.url.path.endsWith('get-book-detail')) {
        detailRequests++;
        final gate = Completer<http.Response>();
        pending.add(gate);
        return gate.future;
      }
      catalogRequests++;
      return http.Response(
          jsonEncode({
            'code': 0,
            'data': {'list': []}
          }),
          200,
          headers: {'content-type': 'application/json'});
    }));
    try {
      await tester.pumpWidget(MaterialApp(
          navigatorKey: navigator,
          home: const ChannelPage(
              path: '/fixture/probe-route', label: '补查生命周期')));
      for (var i = 0; i < 15 && detailRequests < 2; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
      }
      expect(detailRequests, 2,
          reason: 'Background concurrency is capped at two.');
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('另一页面'))))));
      await tester.pumpAndSettle();
      for (final gate in pending) {
        gate.complete(http.Response(jsonEncode({'code': 0, 'data': {}}), 200,
            headers: {'content-type': 'application/json'}));
      }
      await tester.runAsync(() => BookAccessProbe.shared.whenIdle);
      await tester.pump();
      expect(detailRequests, 2,
          reason: 'Queued probes for the inactive route must not start.');
      expect(catalogRequests, 0,
          reason:
              'In-flight probes must not continue sampling catalogs after leaving.');
      expect(tester.takeException(), isNull);
    } finally {
      for (final gate in pending) {
        if (!gate.isCompleted) {
          gate.complete(http.Response('{"code":0,"data":{}}', 200));
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => BookAccessProbe.shared.whenIdle);
      LKApi.client = LKClient.shared;
    }
  });
}
