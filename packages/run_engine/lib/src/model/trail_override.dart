/// The runner's own call on one run's trail, kept in its sidecar (keyed by
/// run id, so it survives every index rebuild and moves with the run).
///
/// - [split]: this run is NOT on the trail it matched; it is never grouped
///   with other runs, and no other run is grouped through it.
/// - [join]: this run IS on the same trail as run [joinRunId], whatever the
///   automatic match says. Only this run moves; the runs it used to match
///   stay where they were.
///
/// Pure data, no matching: `Trails.group` honours it first.
class TrailOverride {
  const TrailOverride.split() : isSplit = true, joinRunId = null;
  const TrailOverride.join(String this.joinRunId) : isSplit = false;

  final bool isSplit;

  /// The run whose trail this run joins (a member of the target trail).
  final String? joinRunId;

  Map<String, Object?> toJson() =>
      isSplit ? const {'kind': 'split'} : {'kind': 'join', 'with': joinRunId};

  /// Null for anything unreadable: no override, never a damaged sidecar.
  static TrailOverride? fromJson(Object? j) {
    if (j is! Map) return null;
    if (j['kind'] == 'split') return const TrailOverride.split();
    final with_ = j['with'];
    if (j['kind'] == 'join' && with_ is String && with_.isNotEmpty) {
      return TrailOverride.join(with_);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is TrailOverride &&
      other.isSplit == isSplit &&
      other.joinRunId == joinRunId;

  @override
  int get hashCode => Object.hash(isSplit, joinRunId);

  @override
  String toString() => isSplit ? 'split' : 'join($joinRunId)';
}
