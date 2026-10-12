import 'package:flutter/material.dart';

import '../../state/progress_snapshot.dart';
import '../../theme/pack_look.dart';
import '../../theme/theme.dart';
import 'block_chip.dart';

/// The age-band bars with the "you" bar picked out, slowest bin first. Pure
/// paint: no text, so a share card can put its own words around it.
/// [youBin] null draws the crowd alone (day one, no pack yet).
class PackHistogram extends StatelessWidget {
  const PackHistogram({
    super.key,
    required this.bins,
    this.youBin,
    this.height = 64,
    this.crowd = PackLook.crowdBar,
    this.you = PackLook.youBar,
  });

  final List<double> bins;
  final int? youBin;
  final double height;
  final Color crowd;
  final Color you;

  /// The same bell the fixtures use, for the state with no pack yet.
  static final List<double> placeholder = [
    for (var i = 0; i < 20; i++) 1 / (1 + (i - 9.5) * (i - 9.5) / 12),
  ];

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < bins.length; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: FractionallySizedBox(
              heightFactor: bins[i].clamp(0.06, 1.0),
              alignment: Alignment.bottomCenter,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: i == youBin ? you : crowd,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// "M40-49" -> ("men", "40-49"); null when it is not that shape.
({String who, String ages})? _bandWords(String band) {
  final m = RegExp(r'^([MF])(\d+-\d+)$').firstMatch(band);
  if (m == null) return null;
  return (who: m.group(1) == 'F' ? 'women' : 'men', ages: m.group(2)!);
}

/// The big violet block: where you sit in your age-band pack, from published
/// norms, with the calibrating level and age grade underneath. With no pack
/// yet it invites the first run instead of showing an empty chart.
class PackHero extends StatelessWidget {
  const PackHero({
    super.key,
    required this.level,
    required this.runCount,
    this.pack,
    this.needsProfile = false,
    this.noNorms = false,
    this.needsBirthYear = false,
    this.onAddProfile,
    this.slowerLabel = 'Slower',
    this.fasterLabel = 'Faster',
  });

  final CalibratedLevel level;
  final PackStanding? pack;
  final int runCount;

  /// The runner has runs but no sex or birth year, so no pack can be worked
  /// out. The hero says so and [onAddProfile] opens the profile.
  final bool needsProfile;

  /// The saved sex has no published norms (prefer not to say), so no pack
  /// exists for this profile whatever else is added. Says so once, no nag.
  final bool noNorms;

  /// With [noNorms], the birth year is still missing: the one fix on offer.
  final bool needsBirthYear;
  final VoidCallback? onAddProfile;

  /// The axis words under the histogram, plain strings so a share card or a
  /// translated build can swap them.
  final String slowerLabel;
  final String fasterLabel;

  @override
  Widget build(BuildContext context) {
    final p = pack;
    final words = p == null ? null : _bandWords(p.band);
    final n = p?.fasterThanInTen.clamp(0, 9);
    final String eyebrow;
    final String big;
    final String sub;
    final showAdd =
        p == null && runCount > 0 && (noNorms ? needsBirthYear : needsProfile);
    if (p == null && noNorms && runCount > 0) {
      eyebrow = 'YOUR AGE-BAND PACK';
      big = 'NO PACK FOR\nTHIS PROFILE';
      sub =
          "Pack comparisons use published men's and women's norms, so "
          "there's no pack for this profile.";
    } else if (p == null && needsProfile && runCount > 0) {
      eyebrow = 'YOUR AGE-BAND PACK';
      big = 'ADD YOUR\nAGE BAND';
      sub =
          'Add your age and sex to see where your runs put you in the pack. '
          'It stays on your phone.';
    } else if (p == null && runCount > 0) {
      eyebrow = 'YOUR AGE-BAND PACK';
      big = 'ALMOST\nIN THE PACK';
      sub =
          'Your runs so far are not enough to place you. A steady run of a '
          'few km does it. Nothing leaves your phone.';
    } else if (p == null) {
      eyebrow = 'YOUR AGE-BAND PACK';
      big = 'FIND\nYOUR PACK';
      sub =
          'One run puts you in the pack for your age, worked out from '
          'published norms. Nothing leaves your phone.';
    } else if (n == 0) {
      eyebrow = '${p.band} PACK THIS WEEK';
      big = 'EVERY RUN\nMOVES YOU UP';
      sub = 'You are just starting out. Same boat as most of the pack.';
    } else {
      eyebrow = '${p.band} PACK THIS WEEK';
      big = 'FASTER THAN\n$n IN 10';
      sub = words == null
          ? 'of your age band, from published norms.'
          : '${words.who} aged ${words.ages}, from published norms.';
    }
    final stats = <String>[
      if (level.level > 0) 'LEVEL ${level.level}',
      if (level.ageGradePct != null) 'AGE GRADE ${level.ageGradePct!.round()}%',
    ];
    final moved = level.levelMonthAgo == null
        ? null
        : level.level - level.levelMonthAgo!;
    return Semantics(
      container: true,
      label: '$eyebrow. ${big.replaceAll('\n', ' ')}. $sub',
      child: Container(
        key: const ValueKey('pack-hero'),
        width: double.infinity,
        padding: const EdgeInsets.all(Space.x16),
        decoration: BoxDecoration(
          color: PackLook.violet,
          borderRadius: BorderRadius.circular(Radii.sheet),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    eyebrow,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RunSoloType.micro11.copyWith(
                      color: PackLook.onVioletSoft,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (level.calibrating && runCount > 0)
                  const BlockChip(
                    label: 'CALIBRATING',
                    fill: PackLook.violetPanel,
                    ink: PackLook.onViolet,
                  ),
              ],
            ),
            const SizedBox(height: Space.x8),
            Text(
              big,
              key: const ValueKey('pack-hero-big'),
              style: RunSoloType.display64.copyWith(color: PackLook.onViolet),
            ),
            const SizedBox(height: Space.x8),
            Text(
              sub,
              style: RunSoloType.body15.copyWith(color: PackLook.onViolet),
            ),
            if (showAdd) ...[
              const SizedBox(height: Space.x12),
              Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  key: const ValueKey('pack-hero-add-profile'),
                  onTap: onAddProfile,
                  borderRadius: BorderRadius.circular(Radii.pill),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: Space.x16),
                    decoration: BoxDecoration(
                      color: PackLook.onViolet,
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                    child: Text(
                      noNorms ? 'Add your birth year' : 'Add your age band',
                      style: RunSoloType.body15.copyWith(
                        color: PackLook.violet,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: Space.x16),
            Container(
              padding: const EdgeInsets.all(Space.x12),
              decoration: BoxDecoration(
                color: PackLook.violetPanel,
                borderRadius: BorderRadius.circular(Radii.card),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PackHistogram(
                    bins: p?.histogram ?? PackHistogram.placeholder,
                    youBin: p?.youBin,
                  ),
                  const SizedBox(height: Space.x8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final s in [slowerLabel, fasterLabel])
                        Text(
                          s,
                          style: RunSoloType.label13.copyWith(
                            color: PackLook.onViolet,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (stats.isNotEmpty || level.calibrating) ...[
              const SizedBox(height: Space.x12),
              Wrap(
                spacing: Space.x8,
                runSpacing: Space.x8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final s in stats)
                    BlockChip(
                      label: s,
                      fill: PackLook.onViolet,
                      ink: PackLook.violet,
                    ),
                  if (moved != null && moved != 0)
                    Text(
                      moved > 0
                          ? 'Up $moved on last month'
                          : 'Down ${-moved} on last month',
                      style: RunSoloType.label13.copyWith(
                        color: PackLook.onViolet,
                      ),
                    ),
                ],
              ),
              if (level.calibrating && runCount > 0) ...[
                const SizedBox(height: Space.x8),
                Text(
                  level.runsToSettle > 0
                      ? 'Still settling. ${level.runsToSettle} more '
                            '${level.runsToSettle == 1 ? 'run' : 'runs'} or one '
                            'hard effort locks it in.'
                      : 'Still settling. One hard effort locks it in.',
                  style: RunSoloType.label13.copyWith(
                    color: PackLook.onVioletSoft,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
