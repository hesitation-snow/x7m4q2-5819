/// Keeps the current viewer's relationship independent from cached book data.
class FollowRelationState {
  int _viewerUid = 0;
  int _targetUid = 0;
  int _revision = 0;
  bool _resolved = false;
  bool _pending = false;
  bool _followed = false;

  bool get followed => _followed;

  bool bind({
    required int viewerUid,
    required int targetUid,
    required bool initialValue,
  }) {
    if (_viewerUid == viewerUid && _targetUid == targetUid) {
      if (!_resolved && !_pending) _followed = initialValue;
      return false;
    }
    _viewerUid = viewerUid;
    _targetUid = targetUid;
    _revision++;
    _resolved = false;
    _pending = false;
    _followed = initialValue;
    return true;
  }

  int? beginRefresh({bool force = false}) {
    if ((_pending || _resolved) && !force) return null;
    _pending = true;
    return ++_revision;
  }

  int beginMutation() {
    _pending = true;
    return ++_revision;
  }

  bool isCurrent(int request) => request == _revision;

  bool complete(int request, bool followed) {
    if (!isCurrent(request)) return false;
    _followed = followed;
    _resolved = true;
    _pending = false;
    return true;
  }

  void fail(int request) {
    if (isCurrent(request)) _pending = false;
  }
}
