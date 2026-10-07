/// The share card: one good-looking image of a run or of the four scores,
/// drawn in the app's own night theme whatever theme the phone uses. It is
/// rendered on the phone and handed to the share sheet; nothing is uploaded
/// and no account is involved. No place name, date-and-time stamp or map
/// ever appears on it, except the bare route line when the runner turns on
/// "Show map".
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../map/route_builder.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/home_progress.dart';
import '../state/settings.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart' show LapLineFullMark;
import '../widgets/recent_activity.dart' show runTypeColor;

/// The card's layout size (4:5). The image is captured at 3x: 1080 x 1350.
const Size kShareCardSize = Size(360, 450);
const double kShareCardPixelRatio = 3;

/// What a card shows. [colour] is the run-type colour (Aurora), which says
/// which kind of run it was, never how good it was.
sealed class ShareCardData {
  const ShareCardData();
}

class RunCardData extends ShareCardData {
  const RunCardData({
    required this.title,
    required this.typeName,
    required this.colour,
    required this.date,
    required this.distance,
    required this.time,
    this.truePace,
    this.verdict,
    this.verdictHeadline,
    this.route = const [],
  });

  /// The runner's own name for the run, or "Morning Free".
  final String title;
  final String typeName;
  final Color colour;

  /// "Sat 12 Sep".
  final String date;
  final String distance;
  final String time;

  /// "5:10/km"; null for a run under 500 m.
  final String? truePace;

  /// "FASTER", "HOLDING"... only where the run has a verdict.
  final String? verdict;

  /// Picks the verdict's colour: mint faster, vermillion slower, Bone else.
  /// Cyan is for a PB only, which a card never claims.
  final engine.VerdictHeadline? verdictHeadline;

  /// The run's route, drawn only when the runner turned on "Show map" (the
  /// builder leaves it empty otherwise). Shape only: no tiles, no names.
  final List<GeoPoint> route;

  bool get hasRoute => route.length >= 2;

  RunCardData withRoute(List<GeoPoint> points) => RunCardData(
    title: title,
    typeName: typeName,
    colour: colour,
    date: date,
    distance: distance,
    time: time,
    truePace: truePace,
    verdict: verdict,
    verdictHeadline: verdictHeadline,
    route: points,
  );
}

/// One lane on the scores card.
class ScoreLaneData {
  const ScoreLaneData({
    required this.label,
    required this.value,
    required this.unit,
    this.change,
  });

  final String label;

  /// "62" (the percentile) or "--" for a lane not earned yet.
  final String value;

  /// "th percentile" / "percentile"; empty without a value.
  final String unit;

  /// "Up 2 in 6 weeks"; null when there is no change to report.
  final String? change;
}

class ScoresCardData extends ShareCardData {
  const ScoresCardData({required this.lanes});
  final List<ScoreLaneData> lanes;

  static const String _title = 'MY SCORES';
  String get title => _title;
}

/// The run's card, from what History already holds (index-row fields only)
/// and its route. [route] is passed in only for "Show map".
RunCardData runCardData(RunSummary run, Units units) => RunCardData(
  title: run.customTitle ?? runTitle(run),
  typeName: runTitle(run).toUpperCase(),
  colour: runTypeColor(run, RunSoloTokens.dark),
  date: Fmt.dayDate(run.localStart),
  distance: Fmt.distance(run.distanceM, units),
  time: Fmt.clock(run.durationMs),
  truePace: run.truePaceSecPerKm == null
      ? null
      : Fmt.paceUnit(run.truePaceSecPerKm, units),
  verdict: run.isFourByFour ? run.verdict?.headline.text : null,
  verdictHeadline: run.isFourByFour ? run.verdict?.headline : null,
);

/// The four lanes as Home shows them (same norms, same rounding); a lane
/// with no score yet reads "--".
ScoresCardData scoresCardData(
  Map<engine.IdentityLane, engine.IdentityScore> scores, {
  required ProfileSex sex,
  required int? age,
}) => ScoresCardData(
  lanes: [
    for (final lane in engine.IdentityLane.values)
      () {
        final s = scores[lane];
        if (s == null) {
          return ScoreLaneData(
            label: lane.name.toUpperCase(),
            value: '--',
            unit: '',
          );
        }
        final p = ScoreNorms.percentile(
          lane,
          s.vdot,
          s.source,
          sex: sex,
          age: age,
        );
        final change = ScoreNorms.change(s, sex: sex, age: age);
        return ScoreLaneData(
          label: lane.name.toUpperCase(),
          // Without a profile there is no percentile: the app's own 0 to 99
          // score stands in, labelled as a score.
          value: '${p ?? s.score}',
          unit: p == null
              ? 'score'
              : '${ScoreNorms.ordinalSuffix(p)} percentile',
          change: switch (change) {
            null => null,
            > 0 => 'Up $change in 6 weeks',
            < 0 => 'Down ${-change} in 6 weeks',
            _ => 'No change in 6 weeks',
          },
        );
      }(),
  ],
);

/// The image itself. Size is [kShareCardSize]; wrap in a FittedBox to preview.
class ShareCard extends StatelessWidget {
  const ShareCard({super.key, required this.data});

  final ShareCardData data;

  @override
  Widget build(BuildContext context) => Theme(
    data: runSoloTheme(brightness: Brightness.dark),
    child: Builder(
      builder: (context) {
        final t = Theme.of(context).extension<RunSoloTokens>()!;
        final glow = switch (data) {
          RunCardData d => d.colour,
          ScoresCardData() => t.typeLaps,
        };
        return SizedBox.fromSize(
          size: kShareCardSize,
          child: DecoratedBox(
            decoration: BoxDecoration(color: t.bgBase),
            child: Stack(
              children: [
                // Aurora: two soft glows of the run-type colour.
                Positioned(
                  left: -120,
                  top: -140,
                  child: _Glow(colour: glow, size: 420, alpha: 0.30),
                ),
                Positioned(
                  right: -160,
                  bottom: -180,
                  child: _Glow(colour: glow, size: 460, alpha: 0.18),
                ),
                Padding(
                  padding: const EdgeInsets.all(28),
                  child: switch (data) {
                    final RunCardData d => _RunBody(data: d, t: t),
                    final ScoresCardData d => _ScoresBody(data: d, t: t),
                  },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _Glow extends StatelessWidget {
  const _Glow({required this.colour, required this.size, required this.alpha});
  final Color colour;
  final double size;
  final double alpha;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: [
          colour.withValues(alpha: alpha),
          colour.withValues(alpha: 0),
        ],
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.right, required this.rightColour});
  final String right;
  final Color rightColour;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      const LapLineFullMark(height: 34),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          right,
          maxLines: 1,
          textAlign: TextAlign.right,
          overflow: TextOverflow.ellipsis,
          style: RunSoloType.micro11.copyWith(color: rightColour),
        ),
      ),
    ],
  );
}

class _Footer extends StatelessWidget {
  const _Footer({required this.t, this.left});
  final RunSoloTokens t;
  final String? left;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (left != null)
        Text(left!, style: RunSoloType.label13.copyWith(color: t.inkSecondary)),
      const Spacer(),
      Text(
        'Run Supreme',
        style: RunSoloType.label13.copyWith(color: t.inkSecondary),
      ),
    ],
  );
}

class _RunBody extends StatelessWidget {
  const _RunBody({required this.data, required this.t});
  final RunCardData data;
  final RunSoloTokens t;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Header(right: data.typeName, rightColour: data.colour),
      const SizedBox(height: 20),
      Text(
        data.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        key: const ValueKey('share-title'),
        style: RunSoloType.heading19.copyWith(
          fontSize: 26,
          color: t.inkPrimary,
        ),
      ),
      if (data.hasRoute)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: CustomPaint(
              key: const ValueKey('share-route'),
              painter: RouteLinePainter(data.route, data.colour),
              size: Size.infinite,
            ),
          ),
        )
      else
        const Spacer(),
      if (data.verdict case final v?) ...[
        Text(
          v,
          key: const ValueKey('share-verdict'),
          style: RunSoloType.display44.copyWith(
            color: switch (data.verdictHeadline) {
              engine.VerdictHeadline.faster => t.semImproving,
              engine.VerdictHeadline.slower => t.semSlower,
              _ => t.inkPrimary,
            },
          ),
        ),
        const SizedBox(height: 8),
      ],
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: _Stat(label: 'DISTANCE', value: data.distance, t: t),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Stat(label: 'TIME', value: data.time, t: t),
          ),
        ],
      ),
      if (data.truePace case final p?) ...[
        const SizedBox(height: 14),
        _Stat(label: 'TRUE PACE', value: p, t: t, big: true),
      ],
      const SizedBox(height: 20),
      _Footer(t: t, left: data.date),
    ],
  );
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.t,
    this.big = false,
  });
  final String label;
  final String value;
  final RunSoloTokens t;
  final bool big;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: RunSoloType.micro11.copyWith(color: t.inkSecondary)),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          value,
          style: (big ? RunSoloType.display64 : RunSoloType.display44).copyWith(
            color: t.inkPrimary,
            fontFeatures: RunSoloType.tabular,
          ),
        ),
      ),
    ],
  );
}

class _ScoresBody extends StatelessWidget {
  const _ScoresBody({required this.data, required this.t});
  final ScoresCardData data;
  final RunSoloTokens t;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Header(right: data.title, rightColour: t.inkSecondary),
      const SizedBox(height: 20),
      for (final lane in data.lanes) ...[
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 5,
                child: Text(
                  lane.label,
                  style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                ),
              ),
              Expanded(
                flex: 9,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: lane.value,
                            style: RunSoloType.display44.copyWith(
                              color: lane.unit.isEmpty
                                  ? t.inkMuted
                                  : t.inkPrimary,
                              fontFeatures: RunSoloType.tabular,
                            ),
                          ),
                          if (lane.unit.isNotEmpty)
                            TextSpan(
                              // The ordinal sits tight on the number: "62nd percentile".
                              text:
                                  RegExp(r'^(st|nd|rd|th) ').hasMatch(lane.unit)
                                  ? lane.unit
                                  : ' ${lane.unit}',
                              style: RunSoloType.label13.copyWith(
                                color: t.inkSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (lane.change case final c?)
                      Text(
                        c,
                        style: RunSoloType.label13.copyWith(
                          color: t.inkSecondary,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 8),
      const _Footer(t: RunSoloTokens.dark),
    ],
  );
}

/// The route as a bare line fitted into its box: no tiles, no coordinates.
class RouteLinePainter extends CustomPainter {
  RouteLinePainter(this.points, this.colour);
  final List<GeoPoint> points;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final lat0 =
        points.map((p) => p.lat).reduce((a, b) => a + b) / points.length;
    final kx = math.cos(lat0 * math.pi / 180);
    final xs = [for (final p in points) p.lon * kx];
    final ys = [for (final p in points) -p.lat];
    final minX = xs.reduce(math.min), maxX = xs.reduce(math.max);
    final minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
    final w = math.max(maxX - minX, 1e-9), h = math.max(maxY - minY, 1e-9);
    final scale = math.min(size.width / w, size.height / h);
    final dx = (size.width - w * scale) / 2, dy = (size.height - h * scale) / 2;
    final step = math.max(1, points.length ~/ 400);
    final path = Path();
    for (var i = 0; i < points.length; i += step) {
      final o = Offset(
        dx + (xs[i] - minX) * scale,
        dy + (ys[i] - minY) * scale,
      );
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(RouteLinePainter old) =>
      old.points != points || old.colour != colour;
}
