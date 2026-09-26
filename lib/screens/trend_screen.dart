import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/delta_glyph.dart';
import 'cooper_result_screen.dart' show cooperTests;

/// Trend per run type (design brief §4.9); Intervals group by comparison
/// key (plan §3.8), one chip per session shape, titled with the session
/// name. The 4x4 key (t240x*): hero 6-run median, delta vs
/// the previous median, dot-and-line chart (Y inverted, median band, noise
/// floor band, PB dots in Arc), bests row. Laps and Free show distance and
/// pace only, no verdict language. Under two sessions: "Two 4x4s draw the
/// first line". Charts are `CustomPainter`, no package.
class TrendScreen extends StatefulWidget {
  const TrendScreen({super.key});

  @override
  State<TrendScreen> createState() => _TrendScreenState();
}

class _TrendScreenState extends State<TrendScreen> {
  RecordMode _type = RecordMode.intervals;

  /// Selected Intervals comparison key; null = the most recent one.
  String? _key;
  Future<List<RunSummary>>? _runs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runs ??= AppServices.of(context).history.list();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final settings = AppServices.of(context).settings.settings;
    final units = settings.units;
    final heatAdjusted = settings.compareHeatAdjusted;
    return Scaffold(
      appBar: AppBar(title: const Text('TREND')),
      body: SafeArea(
        child: FutureBuilder<List<RunSummary>>(
          future: _runs,
          builder: (context, snap) {
            final all = snap.data ?? const <RunSummary>[];
            final typed =
                all.where((r) => r.mode == _type && !r.missing).toList()
                  ..sort((a, b) => a.start.compareTo(b.start));
            // Intervals: one trend per comparison key, newest key first,
            // titled by the latest run's session name.
            final keys = <String, String>{};
            for (final r in typed.reversed) {
              final k = trendKey(r);
              if (k != null) keys.putIfAbsent(k, () => runTitle(r));
            }
            final key = _type != RecordMode.intervals
                ? null
                : keys.containsKey(_key)
                ? _key
                : keys.keys.firstOrNull;
            final runs = key == null
                ? typed
                : typed.where((r) => trendKey(r) == key).toList();
            final title = key == null
                ? modeTitle(_type).toUpperCase()
                : keys[key]!.toUpperCase();
            return ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.screenGutter,
              ),
              children: [
                const SizedBox(height: Space.x8),
                // Scrolls sideways rather than overflow: four chips on a
                // narrow phone at a large text size.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final m in [
                        RecordMode.intervals,
                        RecordMode.laps,
                        RecordMode.free,
                        RecordMode.cooper,
                      ]) ...[
                        if (m != RecordMode.intervals)
                          const SizedBox(width: Space.x8),
                        _TypeChip(
                          label: m == RecordMode.cooper
                              ? 'Test'
                              : modeTitle(m).split(' ').first,
                          selected: _type == m,
                          onTap: () => setState(() => _type = m),
                        ),
                      ],
                    ],
                  ),
                ),
                if (keys.length > 1) ...[
                  const SizedBox(height: Space.x12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final e in keys.entries) ...[
                          _TypeChip(
                            key: ValueKey('trend-key-${e.key}'),
                            label: e.value,
                            selected: e.key == key,
                            onTap: () => setState(() => _key = e.key),
                          ),
                          const SizedBox(width: Space.x8),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: Space.x24),
                _LaneHeader(
                  title:
                      '$title · ${runs.length} SESSION${runs.length == 1 ? '' : 'S'}',
                ),
                const SizedBox(height: Space.x24),
                switch (_type) {
                  // Every session shape: I3 gives each key its work pace,
                  // floor and bests; runs of one key only.
                  RecordMode.intervals => _FourByFourTrend(
                    runs: runs,
                    units: units,
                    heatAdjusted: heatAdjusted,
                    emptyText:
                        key == null || key == engine.ComparisonKey.norwegian4x4
                        ? 'Two 4x4s draw the first line.'
                        : 'Two sessions draw the first line.',
                  ),
                  RecordMode.cooper => _CooperTrend(runs: runs),
                  RecordMode.laps ||
                  RecordMode.free => _DistanceTrend(runs: runs, units: units),
                },
                const SizedBox(height: Space.x24),
                if (runs.isEmpty)
                  Text(
                    'Nothing here yet.',
                    style: RunSoloType.body17.copyWith(color: t.inkSecondary),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The comparison key a run's trend groups under (plan §3.8).
String? trendKey(RunSummary r) =>
    r.comparisonKey ??
    r.spec?.comparisonKey ??
    (r.hasIntervals ? engine.ComparisonKey.norwegian4x4 : null);

/// Session medians for the 4x4 trend: the engine's work pace per run and the
/// rolling median of the previous 6 (the verdict's comparison set).
class TrendPoint {
  const TrendPoint({
    required this.index,
    required this.start,
    required this.paceSecPerKm,
    required this.medianSecPerKm,
    required this.best,
    this.ghostSecPerKm,
  });
  final int index;
  final DateTime start;

  /// The pace the verdict compared: heat-adjusted with "Compare
  /// heat-adjusted paces" on and weather for the run (W2), raw otherwise.
  final double paceSecPerKm;
  final double? medianSecPerKm;
  final bool best;

  /// The other twin, drawn behind in ink.secondary (design brief A6): the
  /// adjusted pace with the setting off, the raw one with it on. Null
  /// without usable weather, or when the heat slowed nothing.
  final double? ghostSecPerKm;
}

List<TrendPoint> trendPoints(
  List<RunSummary> chronological, {
  bool heatAdjusted = false,
}) {
  final out = <TrendPoint>[];
  final prior = <double>[];
  for (final r in chronological) {
    final raw = r.workPaceSecPerKm;
    if (raw == null) continue;
    final adj = r.heatAdjustedWorkPaceSecPerKm;
    final twin = adj == null || adj == raw ? null : adj;
    final pace = heatAdjusted && twin != null ? twin : raw;
    final window = prior.length > 6 ? prior.sublist(prior.length - 6) : prior;
    out.add(
      TrendPoint(
        index: out.length + 1,
        start: r.start,
        paceSecPerKm: pace,
        medianSecPerKm: window.isEmpty ? null : median(window),
        best: r.verdict?.bestIn365Days ?? false,
        ghostSecPerKm: twin == null
            ? null
            : heatAdjusted
            ? raw
            : twin,
      ),
    );
    if (r.eligibleAsPrior) prior.add(pace);
  }
  return out;
}

double median(List<double> v) {
  final s = List.of(v)..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

class _FourByFourTrend extends StatelessWidget {
  const _FourByFourTrend({
    required this.runs,
    required this.units,
    this.heatAdjusted = false,
    this.emptyText = 'Two 4x4s draw the first line.',
  });
  final String emptyText;
  final List<RunSummary> runs;
  final Units units;

  /// "Compare heat-adjusted paces" (W2): the adjusted series leads.
  final bool heatAdjusted;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final points = trendPoints(runs, heatAdjusted: heatAdjusted);
    final ghost = points.any((p) => p.ghostSecPerKm != null);
    if (points.length < 2) {
      return Text(
        emptyText,
        key: const ValueKey('trend-empty'),
        style: RunSoloType.body17.copyWith(color: t.inkSecondary),
      );
    }
    final recent = points.length > 6
        ? points.sublist(points.length - 6)
        : points;
    final current = median(recent.map((p) => p.paceSecPerKm).toList());
    final previousWindow = points.length > 1
        ? points.sublist(math.max(0, points.length - 7), points.length - 1)
        : const <TrendPoint>[];
    final previous = previousWindow.isEmpty
        ? null
        : median(previousWindow.map((p) => p.paceSecPerKm).toList());
    final delta = previous == null ? null : current - previous;
    final floor =
        runs.last.verdict?.floorSecPerKm ??
        engine.EngineConstants.defaults.runFloorSecPerKm;
    double? bestRep;
    double? bestSession;
    double? lowestFade;
    double? bestRecovery;
    for (final m in runs.where((r) => r.hasIntervals)) {
      for (final pace in m.cleanRepPacesSecPerKm) {
        if (pace != null && (bestRep == null || pace < bestRep)) {
          bestRep = pace;
        }
      }
      final p = m.workPaceSecPerKm;
      if (p != null && (bestSession == null || p < bestSession)) {
        bestSession = p;
      }
      final f = m.fadeSecPerKm;
      if (f != null && (lowestFade == null || f < lowestFade)) lowestFade = f;
      final rp = m.recoveryPaceSecPerKm;
      if (rp != null && (bestRecovery == null || rp < bestRecovery)) {
        bestRecovery = rp;
      }
    }
    final deltaColor = delta == null
        ? t.inkSecondary
        : delta < -floor
        ? t.semFaster
        : delta > floor
        ? t.semSlower
        : t.semNoise;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'MEDIAN WORK PACE, LAST ${recent.length}'
          '${heatAdjusted && ghost ? ', HEAT-ADJUSTED' : ''}',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              Fmt.paceUnit(current, units),
              key: const ValueKey('trend-hero'),
              style: RunSoloType.display64.copyWith(color: t.inkPrimary),
            ),
            const SizedBox(width: Space.x16),
            if (delta != null)
              Padding(
                // Sit the glyph on the number's x-height, not the cap line.
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    DeltaGlyph(
                      direction: DeltaGlyph.forDelta(delta, dead: floor),
                      color: deltaColor,
                      size: 14,
                    ),
                    const SizedBox(width: Space.x4),
                    Text(
                      _deltaText(delta, units),
                      style: RunSoloType.title28.copyWith(color: deltaColor),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: Space.x24),
        SizedBox(
          height: 220,
          child: CustomPaint(
            painter: _TrendPainter(
              points: points,
              floor: floor,
              ink: t.inkPrimary,
              muted: t.inkMuted,
              hair: t.lineHair,
              arc: t.accentArc,
              secondary: t.inkSecondary,
              units: units,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        if (ghost) ...[
          const SizedBox(height: Space.x8),
          _TrendLegend(heatAdjusted: heatAdjusted),
        ],
        const SizedBox(height: Space.x24),
        Text(
          'BESTS',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x12),
        Wrap(
          spacing: Space.x24,
          runSpacing: Space.x12,
          children: [
            StatTile(
              label: 'best rep',
              value: Fmt.pace(bestRep, units),
              size: 28,
            ),
            StatTile(
              label: 'best session',
              value: Fmt.pace(bestSession, units),
              size: 28,
            ),
            StatTile(
              label: 'lowest fade',
              value: lowestFade == null ? '--' : '${lowestFade.round()} s',
              size: 28,
            ),
            StatTile(
              label: 'best recovery',
              value: Fmt.pace(bestRecovery, units),
              size: 28,
            ),
          ],
        ),
      ],
    );
  }

  static String _deltaText(double delta, Units units) {
    final d = engine.PaceFormat.toUnit(
      delta,
      units == Units.mi ? engine.Units.mi : engine.Units.km,
    ).round();
    return '${d.abs()} s';
  }
}

/// Two micro labels under the chart when it draws both twins (brief A6):
/// the leading series in Bone, the ghost in ink.secondary.
class _TrendLegend extends StatelessWidget {
  const _TrendLegend({required this.heatAdjusted});
  final bool heatAdjusted;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    Widget item(String label, Color color) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 16, height: 2, color: color),
        const SizedBox(width: Space.x4),
        Text(label, style: RunSoloType.micro11.copyWith(color: color)),
      ],
    );
    final (lead, back) = heatAdjusted
        ? ('HEAT-ADJ', 'RAW')
        : ('RAW', 'HEAT-ADJ');
    return Row(
      key: const ValueKey('trend-legend'),
      children: [
        item(lead, t.inkPrimary),
        const SizedBox(width: Space.x16),
        item(back, t.inkSecondary),
      ],
    );
  }
}

class _DistanceTrend extends StatelessWidget {
  const _DistanceTrend({required this.runs, required this.units});
  final List<RunSummary> runs;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    if (runs.isEmpty) return const SizedBox.shrink();
    final totalM = runs.fold(0.0, (a, r) => a + r.distanceM);
    final paced = runs.where((r) => r.avgSecPerKm != null).toList();
    final avgPace = paced.isEmpty
        ? null
        : paced.map((r) => r.avgSecPerKm!).reduce((a, b) => a + b) /
              paced.length;
    final longest = runs.map((r) => r.distanceM).reduce(math.max);
    double? fastest;
    for (final r in paced) {
      if (fastest == null || r.avgSecPerKm! < fastest) fastest = r.avgSecPerKm;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Space.x24,
          runSpacing: Space.x12,
          children: [
            StatTile(label: 'total', value: Fmt.distance(totalM, units)),
            StatTile(label: 'avg pace', value: Fmt.pace(avgPace, units)),
            StatTile(
              label: 'longest',
              value: Fmt.distance(longest, units),
              size: 28,
            ),
            StatTile(
              label: 'fastest',
              value: Fmt.pace(fastest, units),
              size: 28,
            ),
          ],
        ),
        const SizedBox(height: Space.x24),
        Text(
          'Distance and pace only. No verdict for this run type.',
          style: RunSoloType.body15.copyWith(color: t.inkSecondary),
        ),
      ],
    );
  }
}

/// C1: past 12-minute test scores, oldest to newest. Every number is an
/// estimate and says so; Bone, never Arc (A5).
class _CooperTrend extends StatelessWidget {
  const _CooperTrend({required this.runs});
  final List<RunSummary> runs;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final tests = cooperTests(runs);
    if (tests.isEmpty) {
      return Text(
        'Take the 12-minute test to see your estimate.',
        key: const ValueKey('cooper-trend-empty'),
        style: RunSoloType.body17.copyWith(color: t.inkSecondary),
      );
    }
    final best = tests.map((x) => x.vo2).reduce(math.max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Space.x24,
          runSpacing: Space.x12,
          children: [
            StatTile(label: 'latest est.', value: '${tests.last.vo2.round()}'),
            StatTile(label: 'best est.', value: '${best.round()}', size: 28),
            StatTile(label: 'tests', value: '${tests.length}', size: 28),
          ],
        ),
        if (tests.length >= 2) ...[
          const SizedBox(height: Space.x24),
          SizedBox(
            key: const ValueKey('cooper-trend-chart'),
            height: 120,
            width: double.infinity,
            child: CustomPaint(
              painter: _Vo2Painter(
                [for (final x in tests) x.vo2],
                line: t.inkPrimary,
                grid: t.lineHair,
              ),
            ),
          ),
        ],
        const SizedBox(height: Space.x16),
        for (final x in tests.reversed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.x8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    Fmt.dayDate(x.date),
                    style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                  ),
                ),
                Text(
                  engine.CooperEstimate(x.minuteM.last).rangeLine,
                  style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                ),
              ],
            ),
          ),
        const SizedBox(height: Space.x8),
        Text(
          engine.CooperResult.disclaimer,
          style: RunSoloType.body15.copyWith(color: t.inkSecondary),
        ),
      ],
    );
  }
}

/// Raw VO2 estimates as dots joined by a 1 px line, on a padded scale.
class _Vo2Painter extends CustomPainter {
  _Vo2Painter(this.values, {required this.line, required this.grid});
  final List<double> values;
  final Color line;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = values.reduce(math.min) - 3;
    final hi = values.reduce(math.max) + 3;
    Offset at(int i) => Offset(
      values.length == 1
          ? size.width / 2
          : size.width * i / (values.length - 1),
      size.height * (1 - (values[i] - lo) / (hi - lo)),
    );
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      Paint()..color = grid,
    );
    final p = Paint()
      ..color = line
      ..strokeWidth = 1;
    for (var i = 1; i < values.length; i++) {
      canvas.drawLine(at(i - 1), at(i), p);
    }
    for (var i = 0; i < values.length; i++) {
      canvas.drawCircle(at(i), 4, Paint()..color = line);
    }
  }

  @override
  bool shouldRepaint(_Vo2Painter old) => old.values != values;
}

/// Lane lines header ground (design brief §2.2: 1 px hairlines at 8 px, 6 %).
class _LaneHeader extends StatelessWidget {
  const _LaneHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return SizedBox(
      height: 64,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _LanePainter(t.inkPrimary.withValues(alpha: 0.06)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              title,
              style: RunSoloType.title28.copyWith(color: t.inkPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _LanePainter extends CustomPainter {
  _LanePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var y = 0.0; y < size.height; y += 8) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_LanePainter old) => old.color != color;
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.points,
    required this.floor,
    required this.ink,
    required this.muted,
    required this.hair,
    required this.arc,
    required this.secondary,
    required this.units,
  });
  final List<TrendPoint> points;
  final double floor;
  final Color ink;
  final Color muted;
  final Color hair;
  final Color arc;
  final Color secondary;
  final Units units;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0, bottom = 24.0, top = 8.0;
    final w = size.width - left;
    final h = size.height - bottom - top;
    final paces = [
      for (final p in points) ...[p.paceSecPerKm, ?p.ghostSecPerKm],
    ];
    var lo = paces.reduce(math.min) - floor;
    var hi = paces.reduce(math.max) + floor;
    if (hi - lo < 30) {
      final c = (hi + lo) / 2;
      lo = c - 15;
      hi = c + 15;
    }
    // Y inverted: faster (smaller s/km) is up.
    double y(double pace) => top + (pace - lo) / (hi - lo) * h;
    double x(int i) =>
        points.length == 1 ? left + w / 2 : left + i / (points.length - 1) * w;
    // Three horizontal hairlines with pace labels.
    final hairPaint = Paint()
      ..color = hair
      ..strokeWidth = 1;
    for (var k = 0; k < 3; k++) {
      final pace = lo + (hi - lo) * (k + 0.5) / 3;
      final yy = y(pace);
      canvas.drawLine(Offset(left, yy), Offset(size.width, yy), hairPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: Fmt.pace(pace, units),
          style: RunSoloType.micro11.copyWith(color: secondary),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, yy - tp.height / 2));
    }
    // 6-session median ribbon (band) and the noise floor as a dashed band.
    final ribbon = Path();
    var started = false;
    for (var i = 0; i < points.length; i++) {
      final m = points[i].medianSecPerKm;
      if (m == null) continue;
      if (!started) {
        ribbon.moveTo(x(i), y(m - floor));
        started = true;
      } else {
        ribbon.lineTo(x(i), y(m - floor));
      }
    }
    for (var i = points.length - 1; i >= 0; i--) {
      final m = points[i].medianSecPerKm;
      if (m == null) continue;
      ribbon.lineTo(x(i), y(m + floor));
    }
    if (started) {
      ribbon.close();
      canvas.drawPath(ribbon, Paint()..color = const Color(0x0AFFFFFF));
      final dash = Paint()
        ..color = muted
        ..strokeWidth = 1;
      for (var i = 0; i < points.length; i++) {
        final m = points[i].medianSecPerKm;
        if (m == null) continue;
        for (final off in [-floor, floor]) {
          final yy = y(m + off);
          final x0 = x(i) - 6, x1 = x(i) + 6;
          canvas.drawLine(Offset(x0, yy), Offset(x1, yy), dash);
        }
      }
    }
    // The ghost twin behind (W2): thin line and small dots, broken where a
    // run has none.
    final ghostPaint = Paint()
      ..color = secondary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    Offset? last;
    for (var i = 0; i < points.length; i++) {
      final g = points[i].ghostSecPerKm;
      if (g == null) {
        last = null;
        continue;
      }
      final o = Offset(x(i), y(g));
      if (last != null) canvas.drawLine(last, o, ghostPaint);
      canvas.drawCircle(o, 3, Paint()..color = secondary);
      last = o;
    }
    // Line + dots.
    final line = Path();
    for (var i = 0; i < points.length; i++) {
      final o = Offset(x(i), y(points[i].paceSecPerKm));
      if (i == 0) {
        line.moveTo(o.dx, o.dy);
      } else {
        line.lineTo(o.dx, o.dy);
      }
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (var i = 0; i < points.length; i++) {
      final o = Offset(x(i), y(points[i].paceSecPerKm));
      if (points[i].best) {
        canvas.drawCircle(o, 5, Paint()..color = arc);
        canvas.drawCircle(
          o,
          9,
          Paint()
            ..color = arc
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      } else {
        canvas.drawCircle(o, 4, Paint()..color = ink);
      }
      // Date micro labels on the X axis (first, last, and every 3rd).
      if (i == 0 || i == points.length - 1 || i % 3 == 0) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${points[i].start.day}/${points[i].start.month}',
            style: RunSoloType.micro11.copyWith(color: secondary),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(o.dx - tp.width / 2, size.height - tp.height));
      }
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.points != points;
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: MotionDurations.quick,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: Space.x16),
          alignment: Alignment.center,
          // Selected = 2 px Bone border, like the mode chips (brief §5).
          decoration: BoxDecoration(
            color: t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.chip),
            border: Border.all(
              color: selected ? t.inkPrimary : t.lineHair,
              width: 2,
            ),
          ),
          child: Text(
            label,
            style: RunSoloType.label13.copyWith(
              color: selected ? t.inkPrimary : t.inkSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
