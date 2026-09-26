/// Event names that differ by build flavour (K1; Phase 4 copy rules). The
/// app injects them from its one flavour-config file; engine copy never
/// holds the literal, so a store build cannot ship a name it may not use.
class EventNames {
  const EventNames({required this.parkrun, this.parkrunPluralName});

  /// A neutral name for callers that inject nothing (tests, tools): never
  /// the trademark. The play build's own name is decided with L5.
  static const EventNames generic = EventNames(parkrun: '5K time trial');

  /// The Saturday 5 km event: its own name in dogfood/debug builds, the L5
  /// store name (e.g. "5K time trial") in the play build.
  final String parkrun;

  /// The plural when "+s" is wrong; null = [parkrun] + "s".
  final String? parkrunPluralName;

  String get parkrunPlural => parkrunPluralName ?? '${parkrun}s';
}
