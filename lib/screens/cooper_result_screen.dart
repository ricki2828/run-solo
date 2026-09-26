/// The 12-minute test's result (C1; design addendum A5, A10.5 v2): the
/// distance, the VO2 estimate under its label with the likely range, the
/// board chip, the change since the last test, the heat line, the pace by
/// minute against the usual curve, and the method. A measurement, not a
/// verdict: no Rive, no bloom, no Arc except the PB chip.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/max_hr.dart';
import '../theme/theme.dart';
import '../widgets/board_chips.dart';
import '../widgets/chrome.dart';
import '../widgets/coaching.dart';
import '../widgets/vo2_trend.dart';
import 'run_detail_screen.dart';
import 'settings_screen.dart' show kOpenMeteoAttribution;

/// "People your age" (plan §3.6, design A10.5): the engine's norms, off
/// until the FRIEND table is read. A test swaps in a lookup to check the
/// section; the app never does.
@visibleForTesting
engine.PeopleYourAge? Function({
  required double vo2,
  required int age,
  engine.NormsSex? sex,
})
debugPeopleYourAge = _enginePeopleYourAge;

engine.PeopleYourAge? _enginePeopleYourAge({
  required double vo2,
  required int age,
  engine.NormsSex? sex,
}) => engine.ResearchNorms.peopleYourAge(vo2: vo2, age: age, sex: sex);

/// A past valid test on this phone.
typedef CooperTest = ({
  String id,
  DateTime date,
  double vo2,
  List<double> minuteM,
});

/// Every valid test in [runs], oldest first. Reads the index row (W5b: a
/// History summary carries no analysis on the file store).
List<CooperTest> cooperTests(List<RunSummary> runs) {
  final out = <CooperTest>[];
  for (final r in runs) {
    final c = r.cooper;
    if (r.mode != RecordMode.cooper ||
        c == null ||
        !c.valid ||
        c.vo2 == null ||
        c.minuteM.length != engine.CooperProjection.minutes) {
      continue;
    }
    out.add((id: r.id, date: r.start, vo2: c.vo2!, minuteM: c.minuteM));
  }
  out.sort((a, b) => a.date.compareTo(b.date));
  return out;
}

/// "2 880 m".
String metresText(double m) {
  final s = m.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return '$b m';
}

class CooperResultScreen extends StatefulWidget {
  const CooperResultScreen({
    super.key,
    required this.detail,
    this.justFinished = false,
  });
  final RunDetail detail;
  final bool justFinished;

  @override
  State<CooperResultScreen> createState() => _CooperResultScreenState();
}

class _CooperResultScreenState extends State<CooperResultScreen> {
  late final Future<List<CooperTest>> _tests = AppServices.of(context).history
      .list()
      .then(cooperTests);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final d = widget.detail;
    final c = d.analysis.cooper;
    final e = c?.estimate;
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<List<CooperTest>>(
          future: _tests,
          builder: (context, snap) {
            final tests = snap.data ?? const <CooperTest>[];
            final i = tests.indexWhere((x) => x.id == d.run.id);
            final prior = i < 0
                ? tests.where((x) => x.date.isBefore(d.run.start)).toList()
                : tests.sublist(0, i);
            // Every valid test up to and including this one: the bars show
            // the last 10, the best counts over all of them (A11).
            final upTo = [for (final p in prior) p.vo2, if (e != null) e.vo2];
            final birthYear = AppServices.of(context)
                .settings
                .settings
                .birthYear;
            // Sex joins Settings with CR2; not set = both ranges (A10.5).
            final norms = e == null || birthYear == null
                ? null
                : debugPeopleYourAge(
                    vo2: e.vo2,
                    age: MaxHr.ageFor(birthYear, d.run.start),
                  );
            final change = e == null
                ? null
                : engine.CooperResult.changeLine(e.vo2, d.run.start, [
                    for (final p in prior) (p.date, p.vo2),
                  ]);
            return ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.screenGutter,
              ),
              children: [
                const SizedBox(height: Space.x16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '12-MIN TEST · ${Fmt.dayDate(d.run.start)}',
                        style: RunSoloType.label13.copyWith(
                          color: t.inkSecondary,
                        ),
                      ),
                    ),
                    if (!widget.justFinished)
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                        tooltip: 'Close',
                        constraints: const BoxConstraints(
                          minWidth: 56,
                          minHeight: 56,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Space.x8),
                Text(
                  metresText(c?.testDistanceM ?? d.analysis.freeRun.distanceM),
                  key: const ValueKey('cooper-distance'),
                  style: RunSoloType.display96.copyWith(color: t.inkPrimary),
                ),
                const SizedBox(height: Space.x12),
                const LapLineDivider(gapAt: 0.18),
                const SizedBox(height: Space.x16),
                if (e != null) ...[
                  Text(
                    'VO2 MAX ESTIMATE',
                    style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                  ),
                  Semantics(
                    label: e.rangeLine,
                    excludeSemantics: true,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          '${e.vo2.round()}',
                          key: const ValueKey('cooper-vo2'),
                          style: RunSoloType.display96.copyWith(
                            color: t.inkPrimary,
                          ),
                        ),
                        const SizedBox(width: Space.x12),
                        Text(
                          '(${e.vo2Low.round()} to ${e.vo2High.round()})',
                          style: RunSoloType.body17.copyWith(
                            color: t.inkPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    'ml/kg/min',
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                  const SizedBox(height: Space.x8),
                  // A10.3 via the shared board fold (LB3).
                  BoardChips(
                    runId: d.run.id,
                    justFinished: widget.justFinished,
                  ),
                  if (change != null)
                    Text(
                      change,
                      key: const ValueKey('cooper-change'),
                      style: RunSoloType.body15.copyWith(
                        color: t.inkPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  // A10.6: on the test result, coaching sits under the
                  // rank chip (the flat-VO2 suggestion lands here).
                  CoachingSection(
                    runId: d.run.id,
                    padding: const EdgeInsets.only(top: Space.x16),
                  ),
                  if (upTo.length >= 2) ...[
                    const SizedBox(height: Space.x16),
                    Text(
                      'VO2 EST. BY TEST',
                      style: RunSoloType.micro11.copyWith(
                        color: t.inkSecondary,
                      ),
                    ),
                    const SizedBox(height: Space.x8),
                    Vo2Bars(
                      key: const ValueKey('cooper-result-trend'),
                      values: upTo.length > Vo2Bars.maxBars
                          ? upTo.sublist(upTo.length - Vo2Bars.maxBars)
                          : upTo,
                      best: upTo.reduce(math.max),
                    ),
                  ],
                ] else if (c?.invalidLine != null)
                  Text(
                    c!.invalidLine!,
                    key: const ValueKey('cooper-invalid'),
                    style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                  ),
                if (c?.heatLine != null) ...[
                  const SizedBox(height: Space.x16),
                  _HeatLine(result: c!),
                ],
                if (c?.minuteM != null) ...[
                  const SizedBox(height: Space.x24),
                  Text(
                    'PACE BY MINUTE',
                    style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                  ),
                  const SizedBox(height: Space.x8),
                  PaceStrip(
                    minuteM: c!.minuteM!,
                    curve: engine.CooperProjection.curveFor([
                      for (final p in prior) p.minuteM,
                    ]),
                  ),
                  const SizedBox(height: Space.x8),
                  Text(
                    prior.length < engine.CooperProjection.personalAfterTests
                        ? 'vs typical curve (research-based)'
                        : 'vs your usual',
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                ],
                if (norms != null) ...[
                  const SizedBox(height: Space.x24),
                  _PeopleYourAge(norms: norms),
                ],
                const SizedBox(height: Space.x24),
                Text(
                  engine.CooperResult.disclaimer,
                  style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('cooper-method'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 48),
                      alignment: Alignment.centerLeft,
                    ),
                    onPressed: () => _sheet(
                      context,
                      'HOW THIS IS ESTIMATED',
                      engine.CooperResult.method,
                    ),
                    child: Text(
                      'How this is estimated',
                      style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                    ),
                  ),
                ),
                const SizedBox(height: Space.x24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(64),
                          side: BorderSide(color: t.lineHair),
                        ),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => RunDetailScreen(runId: d.run.id),
                          ),
                        ),
                        child: Text(
                          'DETAILS',
                          style: RunSoloType.title28.copyWith(
                            color: t.inkPrimary,
                          ),
                        ),
                      ),
                    ),
                    if (widget.justFinished) ...[
                      const SizedBox(width: Space.x12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('DONE'),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Space.x24),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The HV1 line: its own line under the raw estimate, never replacing it.
class _HeatLine extends StatelessWidget {
  const _HeatLine({required this.result});
  final engine.CooperResult result;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final tooHot = result.heat?.tooHot ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                result.heatLine!,
                key: const ValueKey('cooper-heat'),
                style: RunSoloType.body15.copyWith(
                  color: tooHot ? t.semWarn : t.inkPrimary,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('cooper-heat-info'),
              onPressed: () => _sheet(context, 'HEAT ADJUSTMENT', const [
                engine.CooperHeat.caveat,
                '$kOpenMeteoAttribution (CC BY 4.0)',
              ]),
              icon: Icon(Icons.info_outline, color: t.inkSecondary),
              iconSize: 18,
              tooltip: 'About the heat adjustment',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
          ],
        ),
        if (!tooHot)
          Text(
            engine.CooperHeat.disclosure,
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
      ],
    );
  }
}

/// A10.5 "People your age": a Bone rule with a dot per mark (one, or men
/// and women when sex is not set), the line, and the source. Research-based,
/// never a verdict: no Arc.
class _PeopleYourAge extends StatelessWidget {
  const _PeopleYourAge({required this.norms});
  final engine.PeopleYourAge norms;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      key: const ValueKey('people-your-age'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PEOPLE YOUR AGE',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x12),
        SizedBox(
          height: 12,
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 5.5,
                  child: Container(height: 1, color: t.inkPrimary),
                ),
                for (final (_, pct) in norms.marks)
                  Positioned(
                    left: (box.maxWidth - 12) * pct.clamp(0, 100) / 100,
                    top: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: t.inkPrimary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Space.x12),
        Text(
          norms.line,
          key: const ValueKey('people-your-age-line'),
          style: RunSoloType.body15.copyWith(color: t.inkPrimary),
        ),
        Text(
          norms.source,
          style: RunSoloType.label13.copyWith(color: t.inkSecondary),
        ),
      ],
    );
  }
}

/// A10.5 pace strip: 12 bars (8 dp, 4 dp gaps), height = that minute's
/// speed on a shared scale, Bone; the usual curve as a muted ghost behind.
class PaceStrip extends StatelessWidget {
  const PaceStrip({super.key, required this.minuteM, required this.curve});
  final List<double> minuteM;
  final engine.CooperCurve curve;

  static const double height = 56;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final total = minuteM.last;
    List<double> perMinute(List<double> cum) => [
      for (var i = 0; i < cum.length; i++) cum[i] - (i == 0 ? 0 : cum[i - 1]),
    ];
    final own = perMinute(minuteM);
    final ghost = perMinute([for (final f in curve.fractions) f * total]);
    final all = [...own, ...ghost];
    final lo = all.reduce(math.min), hi = all.reduce(math.max);
    // Shared scale: slowest minute at 40 %, fastest at 100 %.
    double h(double v) => hi == lo ? 1 : 0.4 + 0.6 * (v - lo) / (hi - lo);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          key: const ValueKey('pace-strip'),
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < own.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                SizedBox(
                  width: 8,
                  height: height,
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      Container(
                        height: height * h(ghost[i]),
                        color: t.inkMuted.withValues(alpha: 0.4),
                      ),
                      Container(
                        width: 8,
                        height: height * h(own[i]),
                        margin: const EdgeInsets.symmetric(horizontal: 1.5),
                        color: t.inkPrimary,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 12 * 8 + 11 * 4,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('1', style: RunSoloType.micro11.copyWith(color: t.inkMuted)),
              Text(
                '12',
                style: RunSoloType.micro11.copyWith(color: t.inkMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _sheet(BuildContext context, String title, List<String> lines) {
  final t = Theme.of(context).extension<RunSoloTokens>()!;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: t.bgRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.screenGutter),
        child: Column(
          key: ValueKey('sheet-$title'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: RunSoloType.title28.copyWith(color: t.inkPrimary),
            ),
            for (final l in lines) ...[
              const SizedBox(height: Space.x12),
              Text(l, style: RunSoloType.body15.copyWith(color: t.inkPrimary)),
            ],
          ],
        ),
      ),
    ),
  );
}
