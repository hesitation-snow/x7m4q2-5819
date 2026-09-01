import 'package:flutter_test/flutter_test.dart';

import 'package:yomiru/api/models.dart';

void main() {
  test('parses the brave quiz paper and keeps the answer identifiers', () {
    final paper = LKBraveQuizPaper.fromJson({
      'session_id': 'quiz-session-1',
      'passing_score': 60,
      'questions': [
        {
          'question_id': 12,
          'question': '轻之国度是什么？',
          'options': [
            {'option_id': 101, 'option_key': 'A', 'text': '社区'},
            {'option_id': 102, 'option_key': 'B', 'text': '游戏'},
          ],
        },
      ],
    });

    expect(paper.sessionId, 'quiz-session-1');
    expect(paper.passingScore, 60);
    expect(paper.questions, hasLength(1));
    expect(paper.questions.single.questionId, 12);
    expect(paper.questions.single.options.first.optionId, 101);
    expect(paper.questions.single.options.first.submissionValue, 101);
  });

  test('parses the already-answered state without loading a new paper', () {
    final status = LKBraveQuizStatus.fromJson({
      'status': {
        'is_answered': 1,
        'score': 80,
      },
    });

    expect(status.answered, isTrue);
    expect(status.available, isFalse);
    expect(status.score, 80);
  });

  test('parses the live quiz state fields', () {
    final available = LKBraveQuizStatus.fromJson({
      'status': 'unanswered',
      'attempted_today': 0,
      'can_start': 1,
    });
    expect(available.answered, isFalse);
    expect(available.available, isTrue);

    final attempted = LKBraveQuizStatus.fromJson({
      'status': 'answered',
      'attempted_today': 1,
      'can_start': 0,
    });
    expect(attempted.answered, isTrue);
    expect(attempted.available, isFalse);
  });

  test('parses the live question list without inventing a session id', () {
    final paper = LKBraveQuizPaper.fromJson({
      'status': 'available',
      'ttl': 900,
      'expires_at': '2099-01-01 00:00:00',
      'count': 1,
      'passing_score': 60,
      'points_per_question': 2,
      'list': [
        {
          'order': 1,
          'question_id': 12,
          'question': '题目',
          'options': [
            {'option_id': 101, 'text': '选项'},
          ],
        },
      ],
    });

    expect(paper.sessionId, isEmpty);
    expect(paper.status, 'available');
    expect(paper.ttl, 900);
    expect(paper.questions, hasLength(1));
  });

  test('accepts keyed options when a question has no numeric option id', () {
    final option = LKBraveQuizOption.fromJson({
      'key': 'C',
      'label': '第三个选项',
    });

    expect(option.optionKey, 'C');
    expect(option.submissionValue, 'C');
  });

  test('finds a nested quiz session returned beside the paper', () {
    final paper = LKBraveQuizPaper.fromJson({
      'paper': {
        'questions': [
          {
            'id': 1,
            'title': '题目',
            'options': [
              {'id': 1, 'label': '选项'},
            ],
          },
        ],
      },
      'quiz_session': {'id': 'nested-session'},
    });

    expect(paper.sessionId, 'nested-session');
    expect(paper.questions, hasLength(1));
  });
}
