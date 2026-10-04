import 'dart:async';

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/today_target.dart';
import '../state/weather.dart';
import '../theme/theme.dart';

/// One line on Start before a Free, Trail or Goal run: what today's heat
/// means for the pace to aim for. Nothing without weather (setting off,
/// offline, no outdoor run yet to place the weather), without a recent
/// pace to aim from, or on a cool day.
class TodayTargetLine extends StatefulWidget {
  const TodayTargetLine({
    super.key,
    required this.weather,
    required this.runs,
    required this.units,
    required this.now,
    this.aimTruePaceSecPerKm,
  });

  final WeatherQueue? weather;
  final List<RunSummary>? runs;
  final Units units;
  final DateTime Function() now;

  /// A goal's own pace when it has one; otherwise the recent steady pace.
  final double? aimTruePaceSecPerKm;

  @override
  State<TodayTargetLine> createState() => _TodayTargetLineState();
}

class _TodayTargetLineState extends State<TodayTargetLine> {
  engine.WeatherRecord? _weather;
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    _maybeFetch();
  }

  @override
  void didUpdateWidget(TodayTargetLine old) {
    super.didUpdateWidget(old);
    _maybeFetch();
  }

  /// One request per visit to Start, once History has loaded.
  void _maybeFetch() {
    final w = widget.weather, runs = widget.runs;
    if (_asked || w == null || runs == null) return;
    final at = lastRunLocation(runs);
    if (at == null) return;
    _asked = true;
    unawaited(
      w.currentAt(at.lat, at.lon).then((rec) {
        if (mounted && rec != null) setState(() => _weather = rec);
      }, onError: (Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rec = _weather, runs = widget.runs;
    final temp = rec?.tempC, dew = rec?.dewPointC;
    if (rec == null || runs == null || temp == null || dew == null) {
      return const SizedBox.shrink();
    }
    final aim =
        widget.aimTruePaceSecPerKm ?? typicalTruePace(runs, now: widget.now());
    if (aim == null) return const SizedBox.shrink();
    final target = engine.TodayTarget.of(
      tempC: temp,
      dewPointC: dew,
      aimTrueSecPerKm: aim,
    );
    if (target == null) return const SizedBox.shrink();
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(top: Space.x16),
      child: Text(
        todayTargetLine(target, widget.units),
        key: const ValueKey('today-target'),
        style: RunSoloType.body15.copyWith(color: t.inkPrimary),
      ),
    );
  }
}
