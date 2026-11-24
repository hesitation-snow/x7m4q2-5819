import '../services/app_motion.dart';
import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../widgets/common.dart';
import '../widgets/m3_controls.dart';
import 'login_page.dart';

/// 勇者考试页面。
///
/// 入口位于“我的”页资料卡，不和任务中心混在一起。题目和答题状态均由
/// 服务端提供；客户端只暂存当前页面的选择，不保存题卷或答案，也不会自动交卷。
class BraveQuizPage extends StatefulWidget {
  const BraveQuizPage({super.key});

  @override
  State<BraveQuizPage> createState() => _BraveQuizPageState();
}

class _BraveQuizPageState extends State<BraveQuizPage> {
  LKBraveQuizStatus? _status;
  LKBraveQuizPaper? _paper;
  LKBraveQuizResult? _result;
  final Map<LKBraveQuizQuestion, LKBraveQuizOption> _answers = {};
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  int _questionIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _result = null;
        _paper = null;
        _status = null;
        _answers.clear();
        _questionIndex = 0;
      });
    }
    if (!LKClient.shared.session.isLoggedIn) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final status = await LKApi.getBraveQuizState();
      if (!mounted) return;
      if (status.answered || !status.available) {
        setState(() {
          _status = status;
          _loading = false;
        });
        return;
      }
      final paper = await LKApi.getBraveQuizQuestions();
      if (paper.questions.isEmpty) {
        throw LKException(-1, '题目加载失败，请稍后重试');
      }
      if (!mounted) return;
      setState(() {
        _status = status;
        _paper = paper;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _openLogin() async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    if (mounted && LKClient.shared.session.isLoggedIn) _load();
  }

  void _selectOption(LKBraveQuizQuestion question, LKBraveQuizOption option) {
    if (_submitting) return;
    setState(() => _answers[question] = option);
  }

  void _nextQuestion() {
    final paper = _paper;
    if (paper == null) return;
    final question = paper.questions[_questionIndex];
    if (!_answers.containsKey(question)) {
      showLkError(context, '请先选择一个答案');
      return;
    }
    if (_questionIndex < paper.questions.length - 1) {
      setState(() => _questionIndex++);
      return;
    }
    _confirmSubmit();
  }

  void _previousQuestion() {
    if (_questionIndex <= 0 || _submitting) return;
    setState(() => _questionIndex--);
  }

  Future<void> _confirmSubmit() async {
    final paper = _paper;
    if (paper == null) return;
    final missing = paper.questions.indexWhere((q) => !_answers.containsKey(q));
    if (missing >= 0) {
      setState(() => _questionIndex = missing);
      showLkError(context, '请完成全部题目后再交卷');
      return;
    }
    final confirmed = await showDialog<bool>(
      animationStyle: AppMotion.style(context),
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认交卷？'),
        content: const Text('交卷后今日不能再次答题，请确认已完成全部题目。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('再检查一下'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认交卷'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _submit();
  }

  Future<void> _submit() async {
    final paper = _paper;
    if (paper == null || _submitting) return;
    setState(() => _submitting = true);
    try {
      final result = await LKApi.submitBraveQuiz(
        sessionId: paper.sessionId,
        answers: _answers,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _submitting = false;
      });
      // 通过考试后刷新“我的”资料卡上的勇者标识。
      if (_resultPassed(result)) LKClient.sessionRev.value++;
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        showLkError(context, e);
      }
    }
  }

  bool _resultPassed(LKBraveQuizResult result) {
    final passing = _paper?.passingScore ?? _status?.passingScore ?? 60;
    return result.passed || result.score >= passing;
  }

  Widget _scrollBody(List<Widget> children) {
    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: children,
    );
  }

  Widget _medallion(IconData icon,
      {required Color background, required Color foreground}) {
    return Center(
      child: Container(
        width: 64,
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(icon, size: 32, color: foreground),
      ),
    );
  }

  Widget _buildLoggedOut() {
    final scheme = Theme.of(context).colorScheme;
    return _scrollBody([
      const SizedBox(height: 140),
      _medallion(
        Icons.lock_outline_rounded,
        background: scheme.surfaceContainerHigh,
        foreground: scheme.primary,
      ),
      const SizedBox(height: 16),
      Center(
        child: Text(
          '登录后才能参加勇者考试',
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(height: 16),
      Center(
        child: FilledButton(
          onPressed: _openLogin,
          child: const Text('去登录'),
        ),
      ),
    ]);
  }

  Widget _buildLoading() {
    return _scrollBody([
      const SizedBox(height: 220),
      const LkLoadingIndicator(),
    ]);
  }

  Widget _buildError() {
    final scheme = Theme.of(context).colorScheme;
    return _scrollBody([
      const SizedBox(height: 140),
      _medallion(
        Icons.error_outline_rounded,
        background: scheme.errorContainer.withValues(alpha: .7),
        foreground: scheme.onErrorContainer,
      ),
      const SizedBox(height: 14),
      Center(
        child: Text(
          _error ?? '题目加载失败，请稍后重试',
          textAlign: TextAlign.center,
        ),
      ),
      const SizedBox(height: 16),
      Center(
        child: OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重试'),
        ),
      ),
    ]);
  }

  Widget _buildUnavailable() {
    final scheme = Theme.of(context).colorScheme;
    final status = _status!;
    final message = status.answered
        ? '今日已经答题，请明日再试'
        : (status.message.isNotEmpty ? status.message : '勇者答题暂不可用');
    return _scrollBody([
      const SizedBox(height: 140),
      _medallion(
        status.answered
            ? Icons.check_circle_outline_rounded
            : Icons.info_outline_rounded,
        background: status.answered
            ? scheme.primaryContainer
            : scheme.surfaceContainerHigh,
        foreground:
            status.answered ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      ),
      const SizedBox(height: 16),
      Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      if (status.score > 0) ...[
        const SizedBox(height: 8),
        Center(
          child: Text(
            '本次成绩：${status.score} 分',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    ]);
  }

  Widget _buildResult() {
    final scheme = Theme.of(context).colorScheme;
    final result = _result!;
    final passed = _resultPassed(result);
    final passing = _paper?.passingScore ?? _status?.passingScore ?? 60;
    return _scrollBody([
      const SizedBox(height: 68),
      _medallion(
        passed ? Icons.emoji_events_outlined : Icons.assignment_outlined,
        background:
            passed ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        foreground:
            passed ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      ),
      const SizedBox(height: 16),
      Center(
        child: Text(
          passed ? '恭喜通过勇者考试' : '答题未通过',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ),
      const SizedBox(height: 20),
      Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .25)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              _resultLine('得分', '${result.score} / 100'),
              _resultLine('通过分数', '$passing 分'),
              if (result.correctCount > 0)
                _resultLine('答对题数', '${result.correctCount}'),
              if (result.points > 0) _resultLine('获得积分', '${result.points}'),
              if (result.message.isNotEmpty) ...[
                Divider(
                  height: 22,
                  color: scheme.outlineVariant.withValues(alpha: .3),
                ),
                Text(result.message, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 20),
      FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: () => Navigator.pop(context),
        child: const Text('完成'),
      ),
    ]);
  }

  Widget _resultLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildQuiz() {
    final paper = _paper!;
    final question = paper.questions[_questionIndex];
    final selected = _answers[question];
    final total = paper.questions.length;
    final isLast = _questionIndex == total - 1;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _scrollBody([
      Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .25)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const AppSettingIcon(Icons.quiz_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '第 ${_questionIndex + 1} / $total 题',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '单选',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: (_questionIndex + 1) / total,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .25)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            question.prompt,
            style: const TextStyle(fontSize: 17, height: 1.5),
          ),
        ),
      ),
      const SizedBox(height: 12),
      for (var i = 0; i < question.options.length; i++)
        Builder(builder: (_) {
          final option = question.options[i];
          final isSelected = selected == option;
          final badgeLabel =
              i < 26 ? String.fromCharCode(65 + i) : '${i + 1}';
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Semantics(
              selected: isSelected,
              button: true,
              child: Material(
                color: isSelected
                    ? scheme.secondaryContainer
                    : scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: isSelected
                        ? scheme.primary
                        : scheme.outlineVariant.withValues(alpha: .25),
                    width: isSelected ? 1.5 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _submitting
                      ? null
                      : () => _selectOption(question, option),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? scheme.primary
                                : scheme.surfaceContainerHigh,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            badgeLabel,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: isSelected
                                  ? scheme.onPrimary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            option.text,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: isSelected
                                  ? scheme.onSecondaryContainer
                                  : scheme.onSurface,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              height: 1.4,
                            ),
                          ),
                        ),
                        if (isSelected) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.check_circle_rounded,
                            color: scheme.primary,
                            size: 20,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      const SizedBox(height: 8),
      Row(
        children: [
          if (_questionIndex > 0)
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _submitting ? null : _previousQuestion,
                child: const Text('上一题'),
              ),
            ),
          if (_questionIndex > 0) const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _submitting ? null : _nextQuestion,
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: MotionProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isLast ? '提交' : '下一题'),
            ),
          ),
        ],
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = LKClient.shared.session.isLoggedIn;
    return Scaffold(
      appBar: AppBar(
        title: const Text('勇者考试'),
      ),
      body: !loggedIn
          ? _buildLoggedOut()
          : _loading
              ? _buildLoading()
              : _error != null
                  ? _buildError()
                  : _result != null
                      ? _buildResult()
                      : _status?.answered == true || _status?.available == false
                          ? _buildUnavailable()
                          : _paper == null
                              ? _buildError()
                              : _buildQuiz(),
    );
  }
}
