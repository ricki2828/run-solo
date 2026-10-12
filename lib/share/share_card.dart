/// The share card: one good-looking image of a run, the four scores or a
/// moment, drawn in the B look (light ground, colour blocks, condensed type)
/// whatever theme the phone uses. It is
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
import '../theme/lanes.dart';
import '../theme/pack_look.dart';
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

  /// "62" (the percentile), or the 0 to 99 score without a profile.
  final String value;

  /// "th percentile" / "percentile"; empty without a value.
  final String unit;

  /// "Up 2 in 6 weeks"; null when there is no change to report.
  final String? change;
}

/// A pack result as a band only: "faster than 6 in 10" and "men 40-49", from
/// published norms. Never a name, a route or a real runner.
class PackShareData {
  const PackShareData({required this.fasterThanInTen, required this.band});

  /// 1 to 9.
  final int fasterThanInTen;

  /// "men 40-49".
  final String band;
}

class ScoresCardData extends ShareCardData {
  const ScoresCardData({required this.lanes, this.pack});
  final List<ScoreLaneData> lanes;

  /// Set only by a caller that chooses to share the pack result; the scores
  /// builder leaves it null, so the card shows no age band unless asked.
  final PackShareData? pack;

  static const String _title = 'MY SCORES';
  String get title => _title;
}

/// A moment (first, PB, level up, weekly story) as a card: the big figure
/// in its colour, nothing about where or when. [detail] must already be free
/// of days and months: build it with [shareSafeMomentDetail].
class MomentCardData extends ShareCardData {
  const MomentCardData({
    required this.eyebrow,
    required this.big,
    required this.detail,
    required this.colour,
  });

  final String eyebrow;
  final String big;
  final String detail;
  final Color colour;
}

final RegExp _whenPhrase = RegExp(
  r'\s+(?:on|than|in|since|from|last)\s+(?:'
  r'(?:Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day|'
  r'(?:January|February|March|April|May|June|July|August|September|October|'
  r'November|December))\b',
  caseSensitive: false,
);

/// A moment's detail line without any day or month ("28:12 on Sunday." ->
/// "28:12."), so a shared card says nothing about when.
String shareSafeMomentDetail(String detail) =>
    detail.replaceAll(_whenPhrase, '');

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

/// The earned lanes as Home shows them (same norms, same rounding); a lane
/// with no score yet is left off rather than printed as "--".
ScoresCardData scoresCardData(
  Map<engine.IdentityLane, engine.IdentityScore> scores, {
  required ProfileSex sex,
  required int? age,
}) => ScoresCardData(
  lanes: [
    for (final lane in engine.IdentityLane.values)
      if (scores[lane] != null)
        () {
          final s = scores[lane]!;
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
/// Direction B look: a light ground whatever theme the phone uses, one big
/// colour block (the run type, the violet pack, or the moment's colour) and
/// condensed type, so a shared card reads as the same product as Home.
class ShareCard extends StatelessWidget {
  const ShareCard({super.key, required this.data});

  final ShareCardData data;

  @override
  Widget build(BuildContext context) => Theme(
    data: runSoloTheme(brightness: Brightness.light),
    child: Builder(
      builder: (context) {
        final t = Theme.of(context).extension<RunSoloTokens>()!;
        return SizedBox.fromSize(
          size: kShareCardSize,
          child: DecoratedBox(
            decoration: BoxDecoration(color: t.bgBase),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: switch (data) {
                final RunCardData d => _RunBody(data: d, t: t),
                final ScoresCardData d => _ScoresBody(data: d, t: t),
                final MomentCardData d => _MomentBody(data: d, t: t),
              },
            ),
          ),
        );
      },
    ),
  );
}

/// The mark, top left.
class _Header extends StatelessWidget {
  const _Header({required this.t});
  final RunSoloTokens t;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [const LapLineFullMark(height: 30)],
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
  Widget build(BuildContext context) {
    final fill = data.colour;
    final ink = readableOn(fill);
    final tile = fill.withValues(alpha: PackLook.laneTint);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Header(t: t),
        const SizedBox(height: 12),
        // The run-type block: which kind of run, never how good it was.
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(Radii.card),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.typeName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RunSoloType.micro11.copyWith(
                    color: ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  data.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  key: const ValueKey('share-title'),
                  style: RunSoloType.heading19.copyWith(
                    fontSize: 30,
                    color: ink,
                  ),
                ),
                if (data.hasRoute)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: CustomPaint(
                        key: const ValueKey('share-route'),
                        painter: RouteLinePainter(data.route, ink),
                        size: Size.infinite,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
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
        if (data.truePace case final p?)
          SizedBox(
            height: 104,
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    children: [
                      Expanded(
                        child: _Stat(
                          label: 'DISTANCE',
                          value: data.distance,
                          t: t,
                          fill: tile,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: _Stat(
                          label: 'TIME',
                          value: data.time,
                          t: t,
                          fill: tile,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 6,
                  child: _Stat(
                    label: 'TRUE PACE',
                    value: p,
                    t: t,
                    fill: tile,
                    big: true,
                  ),
                ),
              ],
            ),
          )
        else
          SizedBox(
            height: 64,
            child: Row(
              children: [
                Expanded(
                  child: _Stat(
                    label: 'DISTANCE',
                    value: data.distance,
                    t: t,
                    fill: tile,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Stat(
                    label: 'TIME',
                    value: data.time,
                    t: t,
                    fill: tile,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        _Footer(t: t, left: data.date),
      ],
    );
  }
}

class _MomentBody extends StatelessWidget {
  const _MomentBody({required this.data, required this.t});
  final MomentCardData data;
  final RunSoloTokens t;

  @override
  Widget build(BuildContext context) {
    final ink = readableOn(data.colour);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Header(t: t),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: data.colour,
              borderRadius: BorderRadius.circular(Radii.sheet),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.eyebrow,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: RunSoloType.micro11.copyWith(
                    color: ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    data.big,
                    key: const ValueKey('share-moment-big'),
                    maxLines: 1,
                    style: RunSoloType.display96.copyWith(
                      fontSize: 150,
                      color: ink,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  data.detail,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: RunSoloType.body17.copyWith(color: ink),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _Footer(t: t),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.t,
    required this.fill,
    this.big = false,
  });
  final String label;
  final String value;
  final RunSoloTokens t;
  final Color fill;
  final bool big;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(Radii.card),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(label, style: RunSoloType.micro11.copyWith(color: t.inkSecondary)),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: (big ? RunSoloType.display64 : RunSoloType.display44)
                  .copyWith(
                    color: t.inkPrimary,
                    fontFeatures: RunSoloType.tabular,
                  ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _ScoresBody extends StatelessWidget {
  const _ScoresBody({required this.data, required this.t});
  final ScoresCardData data;
  final RunSoloTokens t;

  /// The lane a label names ("AEROBIC" -> aerobic); null for an unknown one.
  static engine.IdentityLane? _lane(String label) {
    for (final l in engine.IdentityLane.values) {
      if (l.name.toUpperCase() == label) return l;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final pack = data.pack;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Header(t: t),
        const SizedBox(height: 12),
        // The pack hero: a band only, from published norms. Never names,
        // routes or real runners.
        Container(
          key: const ValueKey('share-pack-hero'),
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: PackLook.violet,
            borderRadius: BorderRadius.circular(Radii.card),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                data.title,
                style: RunSoloType.micro11.copyWith(
                  color: PackLook.onVioletSoft,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  pack == null
                      ? 'MY FOUR SCORES'
                      : 'FASTER THAN ${pack.fasterThanInTen} IN 10',
                  maxLines: 1,
                  style: RunSoloType.display44.copyWith(
                    color: PackLook.onViolet,
                  ),
                ),
              ),
              Text(
                pack == null
                    ? 'Percentiles from published norms.'
                    : '${pack.band}, from published norms.',
                style: RunSoloType.label13.copyWith(color: PackLook.onViolet),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final lane in data.lanes) ...[
          Expanded(
            child: _LaneRow(lane: lane, laneId: _lane(lane.label), t: t),
          ),
          const SizedBox(height: 8),
        ],
        _Footer(t: t),
      ],
    );
  }
}

class _LaneRow extends StatelessWidget {
  const _LaneRow({required this.lane, required this.laneId, required this.t});
  final ScoreLaneData lane;
  final engine.IdentityLane? laneId;
  final RunSoloTokens t;

  @override
  Widget build(BuildContext context) {
    // A lane keeps its own colour; an unknown label falls back to the
    // tinted ground.
    final fill = laneId == null
        ? t.inkMuted.withValues(alpha: PackLook.laneTint)
        : t.laneFill(laneId!);
    final ink = laneId == null ? t.inkPrimary : readableOn(fill);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 6,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lane.label,
                  maxLines: 1,
                  style: RunSoloType.micro11.copyWith(
                    color: ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (lane.change case final c?)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      c,
                      maxLines: 1,
                      style: RunSoloType.label13.copyWith(color: ink),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 7,
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: lane.value,
                        style: RunSoloType.display44.copyWith(
                          color: lane.unit.isEmpty ? t.inkMuted : ink,
                          fontFeatures: RunSoloType.tabular,
                        ),
                      ),
                      if (lane.unit.isNotEmpty)
                        TextSpan(
                          // The ordinal sits tight on the number: "62nd percentile".
                          text: RegExp(r'^(st|nd|rd|th) ').hasMatch(lane.unit)
                              ? lane.unit
                              : ' ${lane.unit}',
                          style: RunSoloType.label13.copyWith(color: ink),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
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
