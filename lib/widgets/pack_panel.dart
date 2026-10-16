import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/gateway.dart';
import '../state/pack_norms.dart';
import '../state/progress_snapshot.dart';
import '../theme/lanes.dart';
import '../theme/theme.dart';
import 'choice_chips.dart';

/// "Your pack" (direction B): the runner's age band drawn from published
/// norms. Filter chips pick the lane of evidence; the pace chip carries the
/// histogram, the YOU marker and the band reference paces.
class PackPanel extends StatefulWidget {
  const PackPanel({
    super.key,
    required this.snapshot,
    this.units = Units.km,
    this.onOpenSettings,
    this.onShare,
  });

  final ProgressSnapshot snapshot;

  /// Display units. The norms stay per-km inside; only the text converts.
  final Units units;

  /// Opens Settings, for the "add your age" prompt.
  final VoidCallback? onOpenSettings;

  /// Shares the pack band as a card. Null hides the button; the caller
  /// passes it only when there is a pack to share.
  final VoidCallback? onShare;

  @override
  State<PackPanel> createState() => _PackPanelState();
}

class _PackPanelState extends State<PackPanel> {
  int _chip = 0;

  static const _labels = ['5K PACE', 'CONSISTENCY', 'DISTANCE'];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final snap = widget.snapshot;
    final pack = snap.pack;
    final tint = Color.alphaBlend(t.typeGoal.withValues(alpha: 0.18), t.bgBase);
    return Column(
      key: const ValueKey('pack-panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'YOUR PACK',
          style: RunSoloType.title28.copyWith(color: t.inkPrimary),
        ),
        const SizedBox(height: Space.x12),
        ChoiceChips(
          labels: _labels,
          keys: [
            for (var i = 0; i < _labels.length; i++) ValueKey('pack-chip-$i'),
          ],
          selected: _chip,
          onSelect: (i) => setState(() => _chip = i),
        ),
        const SizedBox(height: Space.x16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Space.x16),
          decoration: BoxDecoration(
            color: tint,
            borderRadius: BorderRadius.circular(Radii.card),
          ),
          child: switch (_chip) {
            1 => _Consistency(streak: snap.streak),
            2 => _Distance(story: snap.story, units: widget.units),
            _ =>
              pack == null
                  ? _NoPack(
                      snapshot: snap,
                      onOpenSettings: widget.onOpenSettings,
                    )
                  : _Pace(snapshot: snap, pack: pack, units: widget.units),
          },
        ),
        if (_chip == 0 && pack != null) ...[
          const SizedBox(height: Space.x12),
          _RefTable(pack: pack, units: widget.units),
          if (widget.onShare != null) ...[
            const SizedBox(height: Space.x12),
            OutlinedButton(
              key: const ValueKey('share-pack'),
              onPressed: widget.onShare,
              child: const Text('SHARE MY PACK'),
            ),
          ],
        ],
        const SizedBox(height: Space.x12),
        Text(
          'Comparisons use published norms for your age band, never other '
          'runners. Names and routes are never shown, and your runs stay on '
          'your phone.',
          key: const ValueKey('pack-footnote'),
          textAlign: TextAlign.center,
          style: RunSoloType.label13.copyWith(color: t.inkSecondary),
        ),
      ],
    );
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text, {this.tag});
  final String text;
  final String? tag;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: RunSoloType.micro11.copyWith(color: t.inkPrimary),
          ),
        ),
        if (tag != null)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.x8,
              vertical: Space.x4,
            ),
            decoration: BoxDecoration(
              color: t.bgRaised,
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Text(
              tag!,
              style: RunSoloType.micro11.copyWith(color: t.inkPrimary),
            ),
          ),
      ],
    );
  }
}

TextStyle _bigStyle(RunSoloTokens t) =>
    RunSoloType.display44.copyWith(color: t.inkPrimary, height: 0.95);

String _statement(int percentile) {
  if (percentile >= 75) return 'YOU ARE IN THE FAST QUARTER';
  if (percentile >= 50) return 'YOU ARE IN THE FAST HALF';
  final n = percentile ~/ 10;
  if (n == 0) return 'EVERY PACK STARTS SOMEWHERE';
  // The break keeps "4 IN 10" together instead of orphaning the 10.
  return 'FASTER THAN\n$n IN 10';
}

class _Pace extends StatelessWidget {
  const _Pace({
    required this.snapshot,
    required this.pack,
    required this.units,
  });
  final ProgressSnapshot snapshot;
  final PackStanding pack;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final female = PackNorms.isFemaleBand(pack.band);
    String pace(int p) =>
        Fmt.paceUnit(PackNorms.paceSecPerKm(p, female: female), units);
    final lvl = snapshot.level;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Eyebrow(
          '${pack.band}, AGE NORMS',
          tag: lvl.calibrating ? 'CALIBRATING' : 'LEVEL ${lvl.level}',
        ),
        const SizedBox(height: Space.x8),
        Text(
          _statement(pack.percentile),
          key: const ValueKey('pack-statement'),
          style: _bigStyle(t),
        ),
        const SizedBox(height: Space.x16),
        _Histogram(
          histogram: pack.histogram,
          youBin: pack.youBin,
          tint: Color.alphaBlend(t.typeGoal.withValues(alpha: 0.18), t.bgBase),
        ),
        const SizedBox(height: Space.x8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final p in [10, 50, 90])
              Text(
                pace(p),
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
          ],
        ),
      ],
    );
  }
}

class _Histogram extends StatelessWidget {
  const _Histogram({
    required this.histogram,
    required this.youBin,
    required this.tint,
  });
  final List<double> histogram;
  final int youBin;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    const maxH = 110.0;
    const tagW = 44.0;
    const tagH = 22.0;
    double barH(int i) => histogram[i].clamp(0.04, 1.0) * maxH;
    return SizedBox(
      key: const ValueKey('pack-histogram'),
      height: maxH + 28,
      child: LayoutBuilder(
        builder: (context, box) {
          final slot = box.maxWidth / histogram.length;
          final left = ((youBin + 0.5) * slot - tagW / 2).clamp(
            0.0,
            box.maxWidth - tagW,
          );
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < histogram.length; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1.5),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            height: barH(i),
                            decoration: BoxDecoration(
                              color: i == youBin
                                  ? t.inkPrimary
                                  : t.typeGoal.withValues(alpha: 0.75),
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              // Painted after the bars so a taller neighbour never covers it;
              // the tint border leaves a gap around the tag.
              Positioned(
                left: left,
                bottom: barH(youBin) + 4,
                width: tagW,
                height: tagH,
                child: Container(
                  key: const ValueKey('pack-you'),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.inkPrimary,
                    border: Border.all(color: tint, width: 2),
                    borderRadius: BorderRadius.circular(Radii.chip),
                  ),
                  child: Text(
                    'YOU',
                    style: RunSoloType.micro11.copyWith(color: t.bgBase),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RefTable extends StatelessWidget {
  const _RefTable({required this.pack, required this.units});
  final PackStanding pack;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final female = PackNorms.isFemaleBand(pack.band);
    String pace(int p) => Fmt.paceUnit(
      PackNorms.paceSecPerKm(p, female: female),
      units,
    ).toUpperCase();
    final rows = [
      ('Top 10% of the pack', pace(90), false),
      ('Top 25%', pace(75), false),
      ('You, this week', pace(pack.percentile), true),
      ('Pack middle', pace(50), false),
    ];
    return Container(
      key: const ValueKey('pack-table'),
      padding: const EdgeInsets.all(Space.x8),
      decoration: BoxDecoration(
        color: t.bgRaised,
        border: Border.all(color: t.lineHair),
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: Column(
        children: [
          for (final (label, value, you) in rows)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.x12,
                vertical: Space.x12,
              ),
              decoration: BoxDecoration(
                color: you ? t.inkPrimary : null,
                borderRadius: BorderRadius.circular(Radii.button),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: RunSoloType.body15.copyWith(
                        fontWeight: FontWeight.w600,
                        color: you ? t.bgBase : t.inkPrimary,
                      ),
                    ),
                  ),
                  Text(
                    value,
                    style: RunSoloType.heading19.copyWith(
                      color: you ? t.bgBase : t.inkPrimary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Per-week label under a consistency bar, two short lines: how long ago
/// ("7 wks", "1 wk", "This wk") over what the bar means ("ran", "ice" for a
/// freeze, "off"). The last bar is this week.
String _weekLabel(int i, List<engine.StreakWeek> recent) {
  final back = recent.length - 1 - i;
  final state = switch (recent[i]) {
    engine.StreakWeek.ran => 'ran',
    engine.StreakWeek.frozen => 'ice',
    engine.StreakWeek.paused => 'paused',
    engine.StreakWeek.missed => 'off',
  };
  final when = back == 0 ? 'This wk' : '$back ${back == 1 ? 'wk' : 'wks'}';
  return '$when\n$state';
}

class _Consistency extends StatelessWidget {
  const _Consistency({required this.streak});
  final WeeklyStreak streak;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final lime = t.laneFill(engine.IdentityLane.aerobic);
    final ice = t.laneFill(engine.IdentityLane.long);
    final weeks = streak.weeks;
    final freezes = streak.freezesReady;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Eyebrow('CONSISTENCY, LAST 8 WEEKS'),
        const SizedBox(height: Space.x8),
        Text(
          weeks == 0
              ? 'ONE RUN STARTS YOUR STREAK'
              : '$weeks ${weeks == 1 ? 'WEEK' : 'WEEKS'} IN A ROW',
          key: const ValueKey('pack-statement'),
          style: _bigStyle(t),
        ),
        const SizedBox(height: Space.x16),
        SizedBox(
          height: 72,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final w in streak.recent)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Container(
                      height: switch (w) {
                        engine.StreakWeek.ran => 72,
                        engine.StreakWeek.frozen => 40,
                        engine.StreakWeek.paused => 24,
                        engine.StreakWeek.missed => 10,
                      },
                      decoration: BoxDecoration(
                        color: switch (w) {
                          engine.StreakWeek.ran => lime,
                          engine.StreakWeek.frozen => ice,
                          _ =>
                            w == engine.StreakWeek.paused
                                ? Colors.transparent
                                : t.bgRaised,
                        },
                        border: w == engine.StreakWeek.paused
                            ? Border.all(color: t.inkSecondary, width: 2)
                            : null,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Space.x4),
        Row(
          key: const ValueKey('pack-week-labels'),
          children: [
            for (var i = 0; i < streak.recent.length; i++)
              Expanded(
                // Tight tracking and scale-down keep "This wk" on two lines
                // and stop neighbours touching at 8 bars on 360 wide.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _weekLabel(i, streak.recent),
                    textAlign: TextAlign.center,
                    style: RunSoloType.micro11.copyWith(
                      color: t.inkSecondary,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: Space.x8),
        Text(
          'Lime is a week you ran. Ice is a week a freeze covered.'
          '${streak.recent.contains(engine.StreakWeek.paused) ? ' Hollow is a paused week.' : ''}'
          ' $freezes freeze${freezes == 1 ? '' : 's'} ready.',
          style: RunSoloType.label13.copyWith(color: t.inkSecondary),
        ),
      ],
    );
  }
}

class _Distance extends StatelessWidget {
  const _Distance({required this.story, required this.units});
  final WeeklyStory? story;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final s = story;
    if (s == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Eyebrow('DISTANCE, LAST WEEK'),
          const SizedBox(height: Space.x8),
          Text(
            'YOUR FIRST FULL WEEK LANDS HERE',
            key: const ValueKey('pack-statement'),
            style: _bigStyle(t),
          ),
          const SizedBox(height: Space.x8),
          Text(
            'Finish a Monday to Sunday week and you get the total and the '
            'day by day shape of it.',
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
        ],
      );
    }
    final peak = s.dailyKm.fold<double>(1, (m, v) => v > m ? v : m);
    const days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    String dayLabel(double km) {
      final v = units == Units.mi
          ? km * 1000 / engine.PaceFormat.metresPerMile
          : km;
      return v.toStringAsFixed(1);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Eyebrow('DISTANCE, LAST WEEK'),
        const SizedBox(height: Space.x8),
        Text(
          '${Fmt.distance1(s.km * 1000, units).toUpperCase()} IN ${s.runs} '
          '${s.runs == 1 ? 'RUN' : 'RUNS'}',
          key: const ValueKey('pack-statement'),
          style: _bigStyle(t),
        ),
        const SizedBox(height: Space.x16),
        SizedBox(
          height: 96 + 16,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < s.dailyKm.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        // Value label: the day's distance in the runner's unit.
                        SizedBox(
                          height: 16,
                          child: Text(
                            s.dailyKm[i] == 0 ? '' : dayLabel(s.dailyKm[i]),
                            maxLines: 1,
                            style: RunSoloType.micro11.copyWith(
                              color: t.inkPrimary,
                            ),
                          ),
                        ),
                        Container(
                          height: s.dailyKm[i] == 0
                              ? 6
                              : 6 + 90 * s.dailyKm[i] / peak,
                          decoration: BoxDecoration(
                            color: s.dailyLane[i] == null
                                ? t.bgRaised
                                : t.laneFill(s.dailyLane[i]!),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Space.x4),
        Row(
          children: [
            for (final d in days)
              Expanded(
                child: Text(
                  d,
                  textAlign: TextAlign.center,
                  style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Day 1, or a runner the app cannot place yet: still coloured, and it says
/// what the first runs unlock.
class _NoPack extends StatelessWidget {
  const _NoPack({required this.snapshot, this.onOpenSettings});
  final ProgressSnapshot snapshot;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final ran = snapshot.runCount > 0;
    const rows = [
      (
        engine.IdentityLane.aerobic,
        'AEROBIC',
        'Any easy run starts your number',
      ),
      (engine.IdentityLane.speed, 'SPEED', 'One interval session unlocks it'),
      (engine.IdentityLane.mid, 'MID', 'A clean 5K or 10K effort'),
      (engine.IdentityLane.long, 'LONG', 'A 15K or longer run'),
    ];
    return Column(
      key: const ValueKey('pack-empty'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Eyebrow('YOUR AGE BAND, FROM RUN 1'),
        const SizedBox(height: Space.x8),
        Text(
          ran ? 'YOUR SPOT SHOWS SOON' : 'YOUR PACK STARTS WITH RUN 1',
          key: const ValueKey('pack-statement'),
          style: _bigStyle(t),
        ),
        const SizedBox(height: Space.x8),
        if (ran)
          InkWell(
            key: const ValueKey('pack-profile'),
            onTap: onOpenSettings,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.x8),
              child: Text(
                'Add your sex and birth year in Settings so we can place '
                'you in your age band.',
                style: RunSoloType.body15.copyWith(
                  color: t.inkPrimary,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          )
        else
          Text(
            'Everyone starts at the same line. Your first runs unlock these.',
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
        const SizedBox(height: Space.x12),
        for (final (lane, name, line) in rows) ...[
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.x12,
              vertical: Space.x12,
            ),
            decoration: BoxDecoration(
              color: t.laneFill(lane),
              borderRadius: BorderRadius.circular(Radii.button),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 84,
                  child: Text(
                    name,
                    style: RunSoloType.heading19.copyWith(
                      color: readableOn(t.laneFill(lane)),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    line,
                    style: RunSoloType.body15.copyWith(
                      color: readableOn(t.laneFill(lane)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.x8),
        ],
        Text(
          'FIRSTS ${snapshot.firstsDone} OF $kFirstsTotal',
          style: RunSoloType.micro11.copyWith(color: t.inkPrimary),
        ),
      ],
    );
  }
}
