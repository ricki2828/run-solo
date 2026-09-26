/// Event names that differ by build flavour (K1; Phase 4 copy rules). The
/// app injects them from its one flavour-config file; engine copy never
/// holds the literal, so a store build cannot ship a name it may not use.
class EventNames {
  const EventNames({required this.parkrun});

  /// The Saturday 5 km event: its own name in dogfood/debug builds, the L5
  /// store name (e.g. "5K time trial") in the play build.
  final String parkrun;
}
