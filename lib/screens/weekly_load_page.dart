import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../theme/lanes.dart';
import '../theme/theme.dart';
import '../widgets/load_bars.dart';

/// "15\nSEP": the Monday under a week's bar.
String loadWeekLabel(DateTime monday) =>
    '${monday.day}\n${Fmt.dayMonth(monday).split(' ').last.toUpperCase()}';

/// "20 TO 26 OCT" for the Monday-to-Sunday week starting [monday].
String loadWeekRange(DateTime monday) {
  final end = monday.add(const Duration(days: 6));
  final from = monday.month == end.month
      ? '${monday.day}'
      : Fmt.dayMonth(monday);
  return '$from TO ${Fmt.dayMonth(end)}'.toUpperCase();
}

/// Page 2 of the weekly story: the finished week's load, set against the
/// recent weeks. The load is the one number the "don't overdo it" warning
/// uses, so the two can never disagree. Calm on purpose: the number first,
/// words for the comparison, never a red ratio.
///
/// [weeks] are oldest first and the last is the week told (a complete week).
/// Done pops with `true`, which closes the story under it as well.
class WeeklyLoadPage extends StatefulWidget {
  const WeeklyLoadPage({super.key, required this.weeks});
  final List<engine.WeekLoad> weeks;

  @override
  State<WeeklyLoadPage> createState() => _WeeklyLoadPageState();
}

class _WeeklyLoadPageState extends State<WeeklyLoadPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _done() => Navigator.of(context).pop(true);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    const fill = AuroraStory.fill;
    final ink = readableOn(fill);
    final weeks = widget.weeks;
    final week = weeks.last;
    final compare = engine.LoadCompare.of(weeks);
    final warn = compare.band == engine.LoadBand.bigJump;
    final chart = weeks.length > 6 ? weeks.sublist(weeks.length - 6) : weeks;
    Animation<double> beat(double a, double b, [Curve k = Curves.easeOut]) =>
        CurvedAnimation(
          parent: _c,
          curve: Interval(a, b, curve: k),
        );
    final figure = beat(0.05, 0.5, Curves.easeOutBack);
    final bars = beat(0.35, 0.9, Curves.easeOutCubic);
    final rest = beat(0.5, 0.9);
    final usualOk = compare.state == engine.LoadCompareState.ok;
    // The usual weeks are the 4 bars straight before this week's.
    final usualFrom = (chart.length - 5).clamp(0, chart.length - 1);
    final load = week.load.round();
    return Scaffold(
      key: const ValueKey('weekly-load'),
      backgroundColor: fill,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.screenGutter,
            Space.x8,
            Space.screenGutter,
            Space.x24,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: Space.x4),
                      child: Text(
                        'YOUR LOAD  ${loadWeekRange(week.monday)}',
                        key: const ValueKey('load-week'),
                        style: RunSoloType.runLabel.copyWith(
                          color: ink.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('story-close'),
                    tooltip: 'Close',
                    icon: Icon(Icons.close, color: ink),
                    onPressed: _done,
                  ),
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FadeTransition(
                        opacity: beat(0.05, 0.3),
                        child: ScaleTransition(
                          scale: Tween<double>(
                            begin: 0.7,
                            end: 1,
                          ).animate(figure),
                          alignment: Alignment.centerLeft,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '$load',
                              key: const ValueKey('load-number'),
                              maxLines: 1,
                              style: RunSoloType.display96.copyWith(
                                fontSize: 160,
                                color: ink,
                              ),
                            ),
                          ),
                        ),
                      ),
                      FadeTransition(
                        opacity: rest,
                        child: Text(
                          'LOAD',
                          style: RunSoloType.display44.copyWith(color: ink),
                        ),
                      ),
                      FadeTransition(
                        opacity: rest,
                        child: Text(
                          engine.LoadWords.explainer,
                          key: const ValueKey('load-explainer'),
                          style: RunSoloType.label13.copyWith(
                            color: ink.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                      const SizedBox(height: Space.x12),
                      FadeTransition(
                        opacity: rest,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (warn) ...[
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 2,
                                  right: Space.x8,
                                ),
                                child: Icon(
                                  Icons.warning_amber,
                                  size: 18,
                                  color: t.semWarn,
                                ),
                              ),
                            ],
                            Expanded(
                              child: Text(
                                engine.LoadWords.headline(week, compare),
                                key: const ValueKey('load-headline'),
                                style: RunSoloType.body17.copyWith(color: ink),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: Space.x16),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: t.bgRaised,
                          borderRadius: BorderRadius.circular(Radii.card),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(Space.cardPadding),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              AnimatedBuilder(
                                animation: bars,
                                builder: (_, _) => LoadBars(
                                  key: const ValueKey('load-bars'),
                                  grow: bars.value,
                                  usual: usualOk ? compare.usual : null,
                                  usualFrom: usualFrom,
                                  semanticsLabel: usualOk
                                      ? 'Load by week. This week $load, '
                                            'usual ${compare.usual.round()}.'
                                      : 'Load by week. This week $load.',
                                  bars: [
                                    for (var i = 0; i < chart.length; i++)
                                      LoadBarData.week(
                                        chart[i],
                                        label: loadWeekLabel(chart[i].monday),
                                        outline: i == chart.length - 1
                                            ? LoadBarOutline.solid
                                            : LoadBarOutline.none,
                                        warn: warn && i == chart.length - 1,
                                        tag: i == chart.length - 1
                                            ? 'THIS WEEK'
                                            : null,
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: Space.x8),
                              Text(
                                'Taller is more load',
                                style: RunSoloType.label13.copyWith(
                                  color: t.inkSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: Space.x16),
                      FadeTransition(
                        opacity: rest,
                        child: Text(
                          engine.LoadWords.changed(week, compare),
                          key: const ValueKey('load-changed'),
                          style: RunSoloType.body15.copyWith(color: ink),
                        ),
                      ),
                      const SizedBox(height: Space.x8),
                      FadeTransition(
                        opacity: rest,
                        child: Text(
                          engine.LoadWords.suggest(week, compare),
                          key: const ValueKey('load-suggest'),
                          style: RunSoloType.body15.copyWith(
                            color: ink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (week.mostlyAssumed) ...[
                        const SizedBox(height: Space.x12),
                        Text(
                          engine.LoadWords.noHrNote,
                          key: const ValueKey('load-nohr-note'),
                          style: RunSoloType.label13.copyWith(
                            color: ink.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          key: const ValueKey('load-why'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            foregroundColor: ink,
                            padding: EdgeInsets.zero,
                          ),
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Why this number?'),
                              content: Text(engine.LoadWords.why(week)),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(),
                                  child: const Text('Got it'),
                                ),
                              ],
                            ),
                          ),
                          child: const Text('Why this number?'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.x16),
              FadeTransition(
                opacity: rest,
                child: FilledButton(
                  key: const ValueKey('story-done'),
                  style: FilledButton.styleFrom(
                    backgroundColor: ink,
                    foregroundColor: fill,
                  ),
                  onPressed: _done,
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
