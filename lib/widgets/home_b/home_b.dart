/// Direction B ("Cohort") building blocks, 12-Oct-2026. Home uses them now;
/// wave 2 (run cards, share cards, result and detail screens) reuses them so
/// every surface wears the same look.
///
/// Reusable:
/// - [PackHero]: the big violet block. Statement, level and age grade, and
///   the histogram with the "you" bar. Works at any size, with or without a
///   pack (day one shows the "find your pack" state).
/// - [PackHistogram]: just the age-band bars with the "you" marker, for a
///   share card or the Progress pack screen.
/// - [LaneBlock] and [LaneBlockRow]: a flat lane-colour tile with a label, a
///   big number and a caption. A run card can use one block as its header.
/// - [LaneTintCard]: a light page block washed in a lane colour, with the
///   lane colour as its accent. Next session, coach cards, result cards.
/// - [BlockChip]: the small pill that sits on a block (a week, a level).
/// - Colours: `PackLook` in lib/theme/pack_look.dart; lane colours stay
///   `RunSoloTokens.laneFill` / `laneText`.
///
/// Home-only: [StreakCard], [GhostCard], [StoryButton].
library;

export '../../theme/pack_look.dart';
export 'block_chip.dart';
export 'ghost_card.dart';
export 'lane_block.dart';
export 'pack_hero.dart';
export 'streak_card.dart';
export 'story_button.dart';
