import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/services.dart';
import '../state/progress_snapshot.dart';
import '../theme/lanes.dart';
import '../theme/theme.dart';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

String _laneName(engine.IdentityLane l) => switch (l) {
  engine.IdentityLane.aerobic => 'AEROBIC',
  engine.IdentityLane.speed => 'SPEED',
  engine.IdentityLane.mid => 'MID',
  engine.IdentityLane.long => 'LONG',
};

/// "5 to 11 Oct" for the Monday-to-Sunday week starting [start].
String weekLabel(DateTime start) {
  final end = start.add(const Duration(days: 6));
  final from = start.month == end.month
      ? '${start.day}'
      : '${start.day} ${_months[start.month - 1]}';
  return '$from to ${end.day} ${_months[end.month - 1]}';
}

/// The weekly story, full screen: week label, the week's km, one headline,
/// Monday-to-Sunday bars in lane colours, the lane of the week. Opened by
/// name (`Routes.weeklyStory`); [story] is passed in by tests, otherwise it
/// is read from the progress snapshot.
class WeeklyStoryScreen extends StatefulWidget {
  const WeeklyStoryScreen({super.key, this.story});
  final WeeklyStory? story;

  @override
  State<WeeklyStoryScreen> createState() => _WeeklyStoryScreenState();
}

class _WeeklyStoryScreenState extends State<WeeklyStoryScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  Future<WeeklyStory?>? _load;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load ??= widget.story != null
        ? Future.value(widget.story)
        : _fromSnapshot();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  Future<WeeklyStory?> _fromSnapshot() async {
    final s = AppServices.of(context);
    final runs = await s.history.list();
    final p = s.settings.settings;
    return buildProgressSnapshot(
      runs,
      now: s.now(),
      sex: p.profileSex,
      birthYear: p.birthYear,
    ).story;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final fill = t.typeIntervals;
    final ink = readableOn(fill);
    return FutureBuilder<WeeklyStory?>(
      future: _load,
      builder: (context, snap) {
        final story = snap.data;
        return Scaffold(
          key: const ValueKey('weekly-story'),
          backgroundColor: fill,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.screenGutter,
                Space.x8,
                Space.screenGutter,
                Space.x24,
              ),
              child: story == null
                  ? _Empty(
                      ink: ink,
                      loading: snap.connectionState != ConnectionState.done,
                    )
                  : _Body(story: story, t: t, ink: ink, fill: fill, c: _c),
            ),
          ),
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.ink, required this.loading});
  final Color ink;
  final bool loading;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Align(
        alignment: Alignment.centerRight,
        child: IconButton(
          key: const ValueKey('story-close'),
          tooltip: 'Close',
          icon: Icon(Icons.close, color: ink),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      const Spacer(),
      if (!loading)
        Text(
          'Your first weekly story lands after your first full week.',
          key: const ValueKey('story-empty'),
          textAlign: TextAlign.center,
          style: RunSoloType.body17.copyWith(color: ink),
        ),
      const Spacer(),
    ],
  );
}

class _Body extends StatelessWidget {
  const _Body({
    required this.story,
    required this.t,
    required this.ink,
    required this.fill,
    required this.c,
  });
  final WeeklyStory story;
  final RunSoloTokens t;
  final Color ink;
  final Color fill;
  final AnimationController c;

  @override
  Widget build(BuildContext context) {
    Animation<double> beat(double a, double b, [Curve k = Curves.easeOut]) =>
        CurvedAnimation(
          parent: c,
          curve: Interval(a, b, curve: k),
        );
    final figure = beat(0.05, 0.5, Curves.easeOutBack);
    final bars = beat(0.35, 0.9, Curves.easeOutCubic);
    final rest = beat(0.5, 0.9);
    final lane = story.laneOfWeek;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: Space.x4),
                child: Text(
                  'WEEKLY STORY  ${weekLabel(story.weekStart).toUpperCase()}',
                  key: const ValueKey('story-week'),
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
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
        const Spacer(flex: 2),
        FadeTransition(
          opacity: beat(0.05, 0.3),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.7, end: 1).animate(figure),
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                story.km.toStringAsFixed(1),
                key: const ValueKey('story-km'),
                maxLines: 1,
                style: RunSoloType.display96.copyWith(
                  fontSize: 200,
                  color: ink,
                ),
              ),
            ),
          ),
        ),
        FadeTransition(
          opacity: rest,
          child: Text(
            'KILOMETRES',
            style: RunSoloType.display44.copyWith(color: ink),
          ),
        ),
        const SizedBox(height: Space.x16),
        FadeTransition(
          opacity: rest,
          child: Text(
            story.headline,
            key: const ValueKey('story-headline'),
            style: RunSoloType.body17.copyWith(color: ink),
          ),
        ),
        const Spacer(),
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
                SizedBox(
                  height: 132,
                  child: AnimatedBuilder(
                    animation: bars,
                    builder: (_, _) => Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var i = 0; i < 7; i++)
                          Expanded(
                            child: _Bar(
                              key: ValueKey('story-bar-$i'),
                              km: i < story.dailyKm.length
                                  ? story.dailyKm[i]
                                  : 0,
                              maxKm: _max(story.dailyKm),
                              colour: _colourFor(i),
                              empty: t.lineHair,
                              grow: bars.value,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Space.x8),
                Row(
                  children: [
                    for (var i = 0; i < 7; i++)
                      Expanded(
                        child: Text(
                          _days[i],
                          textAlign: TextAlign.center,
                          style: RunSoloType.label13.copyWith(
                            color: t.inkSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Space.x16),
        FadeTransition(
          opacity: rest,
          child: Row(
            children: [
              Text(
                '${story.runs} ${story.runs == 1 ? 'RUN' : 'RUNS'}',
                key: const ValueKey('story-runs'),
                style: RunSoloType.heading26.copyWith(color: ink),
              ),
              const Spacer(),
              if (lane != null)
                DecoratedBox(
                  key: const ValueKey('story-lane'),
                  decoration: BoxDecoration(
                    color: t.laneFill(lane),
                    borderRadius: BorderRadius.circular(Radii.pill),
                    border: Border.all(color: ink, width: 1.5),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.x12,
                      vertical: Space.x8,
                    ),
                    child: Text(
                      'LANE OF THE WEEK  ${_laneName(lane)}',
                      style: RunSoloType.micro11.copyWith(
                        color: readableOn(t.laneFill(lane)),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Space.x24),
        FadeTransition(
          opacity: rest,
          child: FilledButton(
            key: const ValueKey('story-next'),
            style: FilledButton.styleFrom(
              backgroundColor: ink,
              foregroundColor: fill,
            ),
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Next'),
          ),
        ),
      ],
    );
  }

  Color _colourFor(int i) {
    final lane = i < story.dailyLane.length ? story.dailyLane[i] : null;
    return lane == null ? t.inkMuted : t.laneFill(lane);
  }

  static double _max(List<double> v) =>
      v.fold<double>(1, (a, b) => b > a ? b : a);
}

class _Bar extends StatelessWidget {
  const _Bar({
    super.key,
    required this.km,
    required this.maxKm,
    required this.colour,
    required this.empty,
    required this.grow,
  });
  final double km;
  final double maxKm;
  final Color colour;
  final Color empty;
  final double grow;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, box) {
      final h = km <= 0 ? 4.0 : 10 + (box.maxHeight - 10) * (km / maxKm);
      return Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          width: 26,
          height: h * grow.clamp(0.0, 1.0),
          decoration: BoxDecoration(
            color: km <= 0 ? empty : colour,
            borderRadius: BorderRadius.circular(5),
          ),
        ),
      );
    },
  );
}
