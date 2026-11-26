import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/comments_page.dart';
import 'package:yomiru/pages/dynamic_page.dart';
import 'package:yomiru/pages/dynamic_publish_page.dart';

http.Response _jsonOk(Map<String, dynamic> data) => http.Response.bytes(
      utf8.encode(jsonEncode({'code': 0, 'data': data})),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _topicJson(
  int id,
  String name, {
  int? tagId,
  String alias = 'alias-default',
  int? status = 1,
  int usageCount = 0,
}) =>
    {
      'tag_id': tagId ?? id,
      'topic_tag_id': id,
      'name': name,
      'alias': alias,
      if (status != null) 'status': status,
      'usage_count': usageCount,
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKApi.clearTopicTagsCache();
    LKClient.shared.session.clear();
  });

  tearDown(() {
    LKApi.clearTopicTagsCache();
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
  });

  group('LKTopicTag.parseList & LKDynamicItem', () {
    test('returns empty list for [], null, non-list, missing fields, dirty data', () {
      expect(LKTopicTag.parseList(const []), isEmpty);
      expect(LKTopicTag.parseList(null), isEmpty);
      expect(LKTopicTag.parseList('not-a-list'), isEmpty);
      expect(
        LKTopicTag.parseList([
          null,
          42,
          '吐槽',
          <String, dynamic>{},
          {'tag_id': 0, 'topic_tag_id': 0, 'name': '无ID'},
          {'tag_id': 12, 'topic_tag_id': 12, 'name': '   '},
          {'tag_id': 13, 'topic_tag_id': 13, 'name': '已停用', 'status': 0},
          {'tag_id': 14, 'topic_tag_id': 14, 'name': '已删除', 'status': 2},
        ]),
        isEmpty,
      );
    });

    test('parses valid tags, preserves distinct ids, allows missing status, deduplicates', () {
      final parsed = LKTopicTag.parseList([
        _topicJson(108, '这本轻小说真厉害2027', tagId: 99, alias: 'hash108', status: null, usageCount: 8),
        _topicJson(108, '这本轻小说真厉害2027', tagId: 99, alias: 'hash108', status: 1, usageCount: 8),
        _topicJson(27, '吐槽', alias: 'hash27', usageCount: 25),
      ]);

      expect(parsed, hasLength(2));
      expect(parsed[0].tagId, 99);
      expect(parsed[0].topicId, 108);
      expect(parsed[0].name, '这本轻小说真厉害2027');
      expect(parsed[0].alias, 'hash108');
      expect(parsed[0].usageCount, 8);
      expect(parsed[0].toPublishJson(), {
        'tag_id': 99,
        'topic_tag_id': 108,
        'name': '这本轻小说真厉害2027',
        'alias': 'hash108',
      });
      expect(parsed[1].name, '吐槽');
      expect(parsed[1].usageCount, 25);
    });

    test('LKDynamicItem parses topic_tags and defaults to empty list', () {
      final withTopics = LKDynamicItem.fromJson({
        'dynamic_id': 4114,
        'summary': '今年榜单真热闹',
        'topic_tags': [
          _topicJson(108, '这本轻小说真厉害2027', status: null),
        ],
      });
      expect(withTopics.topicTags, hasLength(1));
      expect(withTopics.topicTags.single.name, '这本轻小说真厉害2027');

      final emptyTopics = LKDynamicItem.fromJson({
        'dynamic_id': 4115,
        'summary': '普通动态',
        'topic_tags': const [],
      });
      expect(emptyTopics.topicTags, isEmpty);
    });
  });

  group('LKApi topic endpoints & cache', () {
    test('dynamicTopicTags is unauthenticated, caches results, and falls back offline', () async {
      final requests = <Map<String, dynamic>>[];
      var failRequests = false;
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          if (failRequests) {
            throw Exception('network error');
          }
          expect(request.url.path.endsWith('/api/dynamic/get-topic-tags-v1'), isTrue);
          expect(request.headers.containsKey('cookie'), isFalse);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(body);
          return _jsonOk({
            'list': [
              _topicJson(27, '吐槽', usageCount: 25),
              _topicJson(55, 'app', usageCount: 5),
            ],
          });
        }),
      );
      LKApi.client.session
        ..uid = 42
        ..securityKey = 'secret-key';

      final tags = await LKApi.dynamicTopicTags();
      expect(tags.map((e) => e.name), ['吐槽', 'app']);
      expect(LKApi.cachedTopicTags.map((e) => e.name), ['吐槽', 'app']);
      expect(requests.single.containsKey('security_key'), isFalse);
      expect(requests.single['q'], '');
      expect(requests.single['limit'], 50);

      failRequests = true;
      final cachedAll = await LKApi.dynamicTopicTags();
      expect(cachedAll.map((e) => e.name), ['吐槽', 'app']);
      final cachedFiltered = await LKApi.dynamicTopicTags(q: 'AP');
      expect(cachedFiltered.map((e) => e.name), ['app']);
    });

    test('publishShortDynamic omits topic_tags when null and sends 1-item array when set', () async {
      final bodies = <Map<String, dynamic>>[];
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          expect(request.url.path.endsWith('/api/dynamic/publish-short-post-v1'), isTrue);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          bodies.add(body);
          return _jsonOk({
            'dynamic': {
              'dynamic_id': 9001,
              'summary': body['summary'],
              if (body.containsKey('topic_tags')) 'topic_tags': body['topic_tags'],
            },
          });
        }),
      );
      LKApi.client.session
        ..uid = 42
        ..securityKey = 'secret-key';

      await LKApi.publishShortDynamic('不带话题的正文');
      expect(bodies.last.containsKey('topic_tags'), isFalse);
      expect(bodies.last['content'], '不带话题的正文');

      const topic = LKTopicTag(
        tagId: 99,
        topicId: 108,
        name: '这本轻小说真厉害2027',
        alias: 'alias108',
      );
      await LKApi.publishShortDynamic('带话题的正文', topic: topic);
      expect(bodies.last['content'], '带话题的正文');
      expect(bodies.last['summary'], '带话题的正文');
      expect(bodies.last['topic_tags'], [
        {
          'tag_id': 99,
          'topic_tag_id': 108,
          'name': '这本轻小说真厉害2027',
          'alias': 'alias108',
        },
      ]);
    });

    test('dynamicFeedPage sends topic_tag_id only when positive', () async {
      final feedBodies = <Map<String, dynamic>>[];
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          expect(request.url.path.endsWith('/api/dynamic/get-feed-v1'), isTrue);
          feedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return _jsonOk({'list': const [], 'has_more': false});
        }),
      );

      await LKApi.dynamicFeedPage(tab: 'follow', anonymous: true);
      expect(feedBodies.last.containsKey('topic_tag_id'), isFalse);

      await LKApi.dynamicFeedPage(tab: 'follow', anonymous: true, topicTagId: 27);
      expect(feedBodies.last['topic_tag_id'], 27);
    });
  });

  group('DynamicPublishPage topic UI', () {
    testWidgets('selects and cancels quick chips, searches in sheet, and submits selected topic',
        (tester) async {
      final publishBodies = <Map<String, dynamic>>[];
      final topicQueries = <String>[];
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path.endsWith('/api/dynamic/get-topic-tags-v1')) {
            final q = (body['q'] ?? '').toString();
            topicQueries.add(q);
            final list = q == 'app'
                ? [_topicJson(55, 'app', usageCount: 12)]
                : [
                    _topicJson(27, '吐槽', usageCount: 25),
                    _topicJson(108, '这本轻小说真厉害2027', usageCount: 8),
                    for (var i = 1; i <= 8; i++) _topicJson(200 + i, '热门话题$i'),
                  ];
            return _jsonOk({'list': list});
          }
          if (request.url.path.endsWith('/api/dynamic/publish-short-post-v1')) {
            publishBodies.add(body);
            return _jsonOk({
              'dynamic': {'dynamic_id': 1001},
            });
          }
          return _jsonOk({});
        }),
      );
      LKApi.client.session
        ..uid = 42
        ..securityKey = 'mock-key';
      LKClient.shared.session
        ..uid = 42
        ..securityKey = 'mock-key';

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DynamicPublishPage()),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      // Quick chip select & toggle off
      final chipFinder = find.widgetWithText(FilterChip, '# 吐槽');
      expect(chipFinder, findsOneWidget);
      await tester.tap(chipFinder);
      await tester.pump();
      expect(tester.widget<FilterChip>(chipFinder).selected, isTrue);

      await tester.tap(chipFinder);
      await tester.pump();
      expect(tester.widget<FilterChip>(chipFinder).selected, isFalse);

      // Open sheet, debounce search, pick 'app'
      await tester.tap(find.byKey(const ValueKey('topic-picker-open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('topic-search-input')), 'app');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(topicQueries, contains('app'));

      await tester.tap(find.widgetWithText(ListTile, '# app'));
      await tester.pumpAndSettle();

      final appChip = find.widgetWithText(FilterChip, '# app');
      expect(appChip, findsOneWidget);
      expect(tester.widget<FilterChip>(appChip).selected, isTrue);

      // Reopen picker and tap already-selected '# app' to clear selection
      await tester.tap(find.byKey(const ValueKey('topic-picker-open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('topic-search-input')), 'app');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '# app'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilterChip, '# app'), findsNothing);

      // Select '# 这本轻小说真厉害2027' and publish
      final yearChip = find.widgetWithText(FilterChip, '# 这本轻小说真厉害2027');
      await tester.tap(yearChip);
      await tester.pump();
      await tester.enterText(
          find.byKey(const ValueKey('dynamic-content-input')), '推荐这本');
      await tester.tap(find.widgetWithText(FilledButton, '发布'));
      await tester.pumpAndSettle();

      expect(publishBodies, hasLength(1));
      expect(publishBodies.single['content'], '推荐这本');
      expect(publishBodies.single['topic_tags'], [
        {
          'tag_id': 108,
          'topic_tag_id': 108,
          'name': '这本轻小说真厉害2027',
          'alias': 'alias-default',
        },
      ]);
    });

    testWidgets('publish remains usable when topic API fails', (tester) async {
      final publishBodies = <Map<String, dynamic>>[];
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/api/dynamic/get-topic-tags-v1')) {
            return http.Response('error', 500);
          }
          if (request.url.path.endsWith('/api/dynamic/publish-short-post-v1')) {
            publishBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _jsonOk({
              'dynamic': {'dynamic_id': 1002},
            });
          }
          return _jsonOk({});
        }),
      );
      LKApi.client.session
        ..uid = 42
        ..securityKey = 'mock-key';
      LKClient.shared.session
        ..uid = 42
        ..securityKey = 'mock-key';

      await tester.pumpWidget(const MaterialApp(home: DynamicPublishPage()));
      await tester.pumpAndSettle();

      final publishButton = find.widgetWithText(FilledButton, '发布');
      expect(tester.widget<FilledButton>(publishButton).onPressed, isNotNull);

      await tester.enterText(
          find.byKey(const ValueKey('dynamic-content-input')), '无话题也能发');
      await tester.tap(publishButton);
      await tester.pumpAndSettle();

      expect(publishBodies, hasLength(1));
      expect(publishBodies.single['content'], '无话题也能发');
      expect(publishBodies.single.containsKey('topic_tags'), isFalse);
    });
  });

  group('DynamicPage topic rendering', () {
    testWidgets('renders # topic name when present and nothing when empty', (tester) async {
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          final data = request.url.path.endsWith('get-feed-v1')
              ? {
                  'list': [
                    {
                      'dynamic_id': 101,
                      'summary': '有话题的动态正文',
                      'topic_tags': [
                        _topicJson(108, '这本轻小说真厉害2027', status: null),
                      ],
                    },
                    {
                      'dynamic_id': 102,
                      'summary': '没有话题的动态正文',
                      'topic_tags': const [],
                    },
                  ],
                  'has_more': false,
                }
              : <String, dynamic>{};
          return http.Response(
            jsonEncode({'code': 0, 'data': data}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
      await tester.pumpAndSettle();

      expect(find.text('有话题的动态正文'), findsOneWidget);
      expect(find.text('没有话题的动态正文'), findsOneWidget);
      expect(find.text('# 这本轻小说真厉害2027'), findsOneWidget);
      expect(find.textContaining('# '), findsOneWidget);
    });

    testWidgets('top bar topic button opens picker, fetches server topic feed, and clears filter',
        (tester) async {
      final feedBodies = <Map<String, dynamic>>[];
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path.endsWith('/api/dynamic/get-topic-tags-v1')) {
            final q = (body['q'] ?? '').toString();
            final list = q == '吐槽'
                ? [_topicJson(27, '吐槽', usageCount: 25)]
                : [
                    _topicJson(27, '吐槽', usageCount: 25),
                    _topicJson(108, '这本轻小说真厉害2027', usageCount: 8),
                  ];
            return _jsonOk({'list': list});
          }
          if (request.url.path.endsWith('get-feed-v1')) {
            feedBodies.add(body);
            final topicId = body['topic_tag_id'];
            if (topicId == 27) {
              return _jsonOk({
                'list': [
                  {
                    'dynamic_id': 4071,
                    'summary': '服务端拉回的吐槽动态',
                    'topic_tags': [_topicJson(27, '吐槽', status: null)],
                  },
                ],
                'has_more': false,
              });
            }
            return _jsonOk({
              'list': [
                {
                  'dynamic_id': 100,
                  'summary': '主广场默认动态',
                  'topic_tags': const [],
                },
              ],
              'has_more': false,
            });
          }
          return _jsonOk({});
        }),
      );

      await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
      await tester.pumpAndSettle();

      expect(find.text('主广场默认动态'), findsOneWidget);
      expect(find.byKey(const ValueKey('dynamic-topic-filter-button')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('dynamic-topic-filter-button')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('topic-search-input')), '吐槽');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ListTile, '# 吐槽'));
      await tester.pumpAndSettle();

      expect(feedBodies.any((b) => b['topic_tag_id'] == 27), isTrue);
      expect(find.byKey(const ValueKey('dynamic-topic-filter-button')), findsNothing);
      expect(find.byKey(const ValueKey('dynamic-active-topic-filter')), findsOneWidget);
      expect(find.text('吐槽'), findsOneWidget);
      expect(find.textContaining('# #'), findsNothing);
      expect(find.text('服务端拉回的吐槽动态'), findsOneWidget);
      expect(find.text('主广场默认动态'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('dynamic-active-topic-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('topic-picker-clear')));
      await tester.pumpAndSettle();

      expect(feedBodies.last.containsKey('topic_tag_id'), isFalse);
      expect(find.byKey(const ValueKey('dynamic-topic-filter-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('dynamic-active-topic-filter')), findsNothing);
      expect(find.text('主广场默认动态'), findsOneWidget);
    });

    testWidgets('tapping topic filters list via server API and re-tapping clears filter', (tester) async {
      final feedBodies = <Map<String, dynamic>>[];
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('get-feed-v1')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            feedBodies.add(body);
            final topicId = body['topic_tag_id'];
            return _jsonOk({
              'list': [
                if (topicId == null || topicId == 301)
                  {
                    'dynamic_id': 201,
                    'summary': '讨论新番的动态',
                    'topic_tags': [_topicJson(301, '日番讨论', status: null)],
                  },
                if (topicId == null)
                  {
                    'dynamic_id': 202,
                    'summary': '讨论轻小说的动态',
                    'topic_tags': [_topicJson(302, '轻小说', status: null)],
                  },
              ],
              'has_more': false,
            });
          }
          return _jsonOk({});
        }),
      );

      await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('# 日番讨论'));
      await tester.pumpAndSettle();

      expect(feedBodies.any((b) => b['topic_tag_id'] == 301), isTrue);
      expect(find.byKey(const ValueKey('dynamic-topic-filter-button')), findsNothing);
      expect(find.byKey(const ValueKey('dynamic-active-topic-filter')), findsOneWidget);
      expect(find.text('日番讨论'), findsOneWidget);
      expect(find.text('讨论新番的动态'), findsOneWidget);
      expect(find.text('讨论轻小说的动态'), findsNothing);

      await tester.tap(find.text('# 日番讨论'));
      await tester.pumpAndSettle();

      expect(feedBodies.last.containsKey('topic_tag_id'), isFalse);
      expect(find.byKey(const ValueKey('dynamic-topic-filter-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('dynamic-active-topic-filter')), findsNothing);
      expect(find.text('讨论新番的动态'), findsOneWidget);
      expect(find.text('讨论轻小说的动态'), findsOneWidget);
    });

    testWidgets('navigating to CommentsPage shows topic and tapping topic filters back on list',
        (tester) async {
      final feedBodies = <Map<String, dynamic>>[];
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('get-feed-v1')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            feedBodies.add(body);
            final topicId = body['topic_tag_id'];
            return _jsonOk({
              'list': [
                if (topicId == null || topicId == 401)
                  {
                    'dynamic_id': 301,
                    'summary': '详情带话题的动态',
                    'topic_tags': [_topicJson(401, '动画化', status: null)],
                  },
                if (topicId == null)
                  {
                    'dynamic_id': 302,
                    'summary': '另一条不相关的动态',
                    'topic_tags': [_topicJson(402, '吐槽', status: null)],
                  },
              ],
              'has_more': false,
            });
          }
          if (request.url.path.endsWith('get-detail-v1')) {
            return _jsonOk({
              'dynamic': {
                'dynamic_id': 301,
                'summary': '详情带话题的动态',
                'topic_tags': [_topicJson(401, '动画化', status: null)],
              },
            });
          }
          if (request.url.path.endsWith('get-comments-v1')) {
            return _jsonOk({'list': const [], 'has_more': false});
          }
          return _jsonOk({});
        }),
      );

      await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('详情带话题的动态'));
      await tester.pumpAndSettle();

      expect(find.byType(CommentsPage), findsOneWidget);
      expect(find.text('# 动画化'), findsOneWidget);

      await tester.tap(find.text('# 动画化'));
      await tester.pumpAndSettle();

      expect(find.byType(CommentsPage), findsNothing);
      expect(find.byKey(const ValueKey('dynamic-active-topic-filter')), findsOneWidget);
      expect(find.text('详情带话题的动态'), findsOneWidget);
      expect(find.text('另一条不相关的动态'), findsNothing);
    });
  });

  group('Recent topics & CommentsPage standalone', () {
    test('LKStore persists recent topics in MRU order with deduplication and cap of 8', () async {
      for (var i = 1; i <= 10; i++) {
        await LKStore.recordRecentTopicTag(
          LKTopicTag(tagId: i, topicId: i, name: '话题$i', alias: 'a$i'),
        );
      }
      await LKStore.recordRecentTopicTag(
        const LKTopicTag(tagId: 5, topicId: 5, name: '话题5', alias: 'a5'),
      );

      final recent = await LKStore.readRecentTopicTags();
      expect(recent.map((e) => e.name), [
        '话题5',
        '话题10',
        '话题9',
        '话题8',
        '话题7',
        '话题6',
        '话题4',
        '话题3',
      ]);
    });

    testWidgets('DynamicPublishPage preselects initialTopic, prioritizes recent topics, and records on publish',
        (tester) async {
      await LKStore.recordRecentTopicTag(
        const LKTopicTag(tagId: 90, topicId: 90, name: '最近话题', alias: 'r90'),
      );
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/api/dynamic/get-topic-tags-v1')) {
            return _jsonOk({
              'list': [
                for (var i = 1; i <= 8; i++) _topicJson(500 + i, '热门$i'),
                _topicJson(90, '最近话题', alias: 'r90'),
              ],
            });
          }
          if (request.url.path.endsWith('/api/dynamic/publish-short-post-v1')) {
            return _jsonOk({'dynamic': {'dynamic_id': 2001}});
          }
          return _jsonOk({});
        }),
      );
      LKApi.client.session
        ..uid = 42
        ..securityKey = 'mock-key';
      LKClient.shared.session
        ..uid = 42
        ..securityKey = 'mock-key';

      const initial = LKTopicTag(tagId: 77, topicId: 77, name: '预选话题', alias: 'i77');
      await tester.pumpWidget(
        const MaterialApp(home: DynamicPublishPage(initialTopic: initial)),
      );
      await tester.pumpAndSettle();

      final initialChip = find.widgetWithText(FilterChip, '# 预选话题');
      expect(initialChip, findsOneWidget);
      expect(tester.widget<FilterChip>(initialChip).selected, isTrue);
      expect(find.widgetWithText(FilterChip, '# 最近话题'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('dynamic-content-input')), '带着预选话题发一条');
      await tester.tap(find.widgetWithText(FilledButton, '发布'));
      await tester.pumpAndSettle();

      final recentAfterPublish = await LKStore.readRecentTopicTags();
      expect(recentAfterPublish.first.name, '预选话题');
    });

    testWidgets('CommentsPage hides topic section when topic_tags is empty', (tester) async {
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('get-detail-v1')) {
            return _jsonOk({
              'dynamic': {
                'dynamic_id': 901,
                'summary': '无话题详情正文',
                'topic_tags': const [],
              },
            });
          }
          if (request.url.path.endsWith('get-comments-v1')) {
            return _jsonOk({'list': const [], 'has_more': false});
          }
          return _jsonOk({});
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CommentsPage(
            dynamicId: 901,
            dynamicPreview: LKDynamicItem(dynamicId: 901, summary: '无话题详情正文'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('无话题详情正文'), findsOneWidget);
      expect(find.textContaining('# '), findsNothing);
    });
  });
}
