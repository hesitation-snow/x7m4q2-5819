import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/follow_relation.dart';

void main() {
  late FollowRelationState state;

  setUp(() {
    state = FollowRelationState()
      ..bind(viewerUid: 1, targetUid: 2, initialValue: false);
  });

  test('late book metadata cannot overwrite an authoritative relationship', () {
    final request = state.beginRefresh()!;
    state.complete(request, true);
    state.bind(viewerUid: 1, targetUid: 2, initialValue: false);
    expect(state.followed, isTrue);
    expect(state.beginRefresh(), isNull);
  });

  test('failed queries can be retried for the same publisher', () {
    final first = state.beginRefresh()!;
    state.fail(first);
    final second = state.beginRefresh();
    expect(second, isNotNull);
    state.complete(second!, true);
    expect(state.followed, isTrue);
  });

  test('follow actions take precedence over an older relationship query', () {
    final query = state.beginRefresh()!;
    final mutation = state.beginMutation();
    state.complete(mutation, true);
    expect(state.complete(query, false), isFalse);
    state.bind(viewerUid: 1, targetUid: 2, initialValue: false);
    expect(state.followed, isTrue);
  });

  test('an authoritative unfollow also survives stale positive book metadata',
      () {
    state.complete(state.beginMutation(), false);
    state.bind(viewerUid: 1, targetUid: 2, initialValue: true);
    expect(state.followed, isFalse);
  });

  test('switching viewers rejects the old account response', () {
    final query = state.beginRefresh()!;
    state.bind(viewerUid: 3, targetUid: 2, initialValue: false);
    expect(state.complete(query, true), isFalse);
    expect(state.followed, isFalse);
    expect(state.beginRefresh(), isNotNull);
  });

  test('returning from a profile can force another relationship query', () {
    state.complete(state.beginRefresh()!, true);
    final next = state.beginRefresh(force: true);
    expect(next, isNotNull);
    state.complete(next!, false);
    expect(state.followed, isFalse);
  });

  test('forcing a query invalidates a previous pending query', () {
    final previous = state.beginRefresh()!;
    final next = state.beginRefresh(force: true)!;
    state.fail(previous);
    expect(state.beginRefresh(), isNull);
    expect(state.complete(previous, true), isFalse);
    state.complete(next, false);
    expect(state.followed, isFalse);
  });
}
