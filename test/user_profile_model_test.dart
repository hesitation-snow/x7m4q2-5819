import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/models.dart';

void main() {
  test('public user profile preserves follow state and animated media URLs',
      () {
    final profile = LKPublicUserProfile.fromJson({
      'profile': {
        'uid': 1246722,
        'avatar': 'https://res.lightnovel.fun/avatar.gif',
        'medals': [
          {
            'medal_id': 7,
            'name': 'Test medal',
            'img': 'https://api.lightnovel.fun/medal.gif',
          },
        ],
      },
      'stats': {'fans_count': 12},
      'relation': {
        'followed': 1,
        'is_self': 0,
        'can_follow': 1,
      },
    });

    expect(profile.uid, 1246722);
    expect(profile.avatar, endsWith('.gif'));
    expect(profile.medals.single.image, endsWith('.gif'));
    expect(profile.followersCount, 12);
    expect(profile.followed, isTrue);
    expect(profile.isSelf, isFalse);
    expect(profile.canFollow, isTrue);
  });

  test('missing can_follow keeps a public profile followable', () {
    final profile = LKPublicUserProfile.fromJson({
      'profile': {'uid': 42},
      'relation': {'followed': 0, 'is_self': 0},
    });

    expect(profile.followed, isFalse);
    expect(profile.canFollow, isTrue);
  });
}
