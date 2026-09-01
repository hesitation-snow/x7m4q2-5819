import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/models.dart';

void main() {
  test('root book comment reply targets the root without a nested reply id',
      () {
    final ids = resolveBookCommentReplyIds(
      LKComment(commentId: 5676),
    );

    expect(ids.rootCommentId, 5676);
    expect(ids.replyCommentId, 0);
  });

  test('nested book comment reply targets both the root and nested comment',
      () {
    final ids = resolveBookCommentReplyIds(
      LKComment(commentId: 1538, rootCommentId: 5676),
    );

    expect(ids.rootCommentId, 5676);
    expect(ids.replyCommentId, 1538);
  });

  test('visible parent id fills missing nested reply metadata', () {
    final ids = resolveBookCommentReplyIds(
      LKComment(commentId: 129963),
      parentCommentId: 1351423,
    );

    expect(ids.rootCommentId, 1351423);
    expect(ids.replyCommentId, 129963);
  });
}
