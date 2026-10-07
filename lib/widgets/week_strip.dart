import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../state/history_store.dart';
import '../state/history_weeks.dart';
import '../theme/theme.dart';
import '../theme/zones.dart';

/// Home's "your week": Monday to Sunday (the runner's local dates), one bar
/// per day. A day's bar is as tall as the time run, stacked by time in each
/// HR zone (Z1 at the bottom); time with no heart rate is grey on top. A day
/// with no run is a light stub. One hour is a full-height bar.
class WeekStrip extends StatelessWidget {
  const WeekStrip({
    super.key,
    required this.runs,
    required this.zones,
    required this.now,
  });

  final List<RunSummary> runs;
  final engine.HrZones zones;

  /// The phone's wall clock; anchors the week and "today".
  final DateTime now;

  static const double barAreaHeight = 56;
  static const double _fullSeconds = 3600;

  /// Per weekday (0 = Monday): seconds in Z1-Z5 (slots 1-5) and slot 0 for
  /// moving time with no heart rate.
  static List<List<double>> daysOf(
    List<RunSummary> runs,
    engine.HrZones zones,
    DateTime now,
  ) {
    final out = List.generate(7, (_) => List<double>.filled(6, 0));
    final week = groupByWeek([
      for (final r in runs)
        if (!r.missing) r,
    ], now);
    if (week.isEmpty) return out;
    for (final r in week.first.runs) {
      final day = out[r.localStart.weekday - 1];
      final movingSec = (r.row?.movingMs ?? r.durationMs) / 1000;
      final hist = r.hrHist?.zoneSeconds(zones);
      final hrSec = hist == null ? 0.0 : hist.fold(0.0, (a, b) => a + b);
      if (hist != null) {
        for (var z = 1; z <= 5; z++) {
          day[z] += hist[z];
        }
      }
      day[0] += math.max(0, movingSec - hrSec);
    }
    return out;
  }

  static String _total(List<List<double>> days) {
    final secs = days.fold(0.0, (a, d) => a + d.fold(0.0, (x, y) => x + y));
    final ran = days.where((d) => d.any((s) => s > 0)).length;
    final mins = (secs / 60).round();
    final time = mins < 60
        ? '$mins min'
        : '${mins ~/ 60}:${(mins % 60).toString().padLeft(2, '0')}';
    return ran == 0
        ? 'No runs yet'
        : '$time · $ran ${ran == 1 ? 'day' : 'days'}';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final brightness = Theme.of(context).brightness;
    final days = daysOf(runs, zones, now);
    final today = now.weekday - 1;
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final tallest = days
        .map((d) => d.fold(0.0, (a, b) => a + b))
        .fold(0.0, math.max);
    final scale = math.max(tallest, _fullSeconds);
    return Semantics(
      label: 'Your week. ${_total(days)}',
      child: Column(
        key: const ValueKey('week-strip'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'YOUR WEEK',
                style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
              ),
              const Spacer(),
              Text(
                _total(days),
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
            ],
          ),
          const SizedBox(height: Space.x8),
          SizedBox(
            height: barAreaHeight + 22,
            child: Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Column(
                      children: [
                        SizedBox(
                          height: barAreaHeight,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: _DayBar(
                              key: ValueKey('week-bar-$i'),
                              seconds: days[i],
                              scale: scale,
                              colors: [
                                t.inkMuted,
                                for (var z = 1; z <= 5; z++)
                                  HrZones.distribution(z, brightness),
                              ],
                              stub: t.lineHair,
                            ),
                          ),
                        ),
                        const SizedBox(height: Space.x4),
                        Text(
                          letters[i],
                          style: RunSoloType.label13.copyWith(
                            color: i == today ? t.inkPrimary : t.inkSecondary,
                            fontWeight: i == today
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ],
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

class _DayBar extends StatelessWidget {
  const _DayBar({
    super.key,
    required this.seconds,
    required this.scale,
    required this.colors,
    required this.stub,
  });
  final List<double> seconds;
  final double scale;
  final List<Color> colors;
  final Color stub;

  static const double width = 18;

  @override
  Widget build(BuildContext context) {
    final total = seconds.fold(0.0, (a, b) => a + b);
    if (total <= 0) {
      return Container(
        width: width,
        height: 4,
        decoration: BoxDecoration(
          color: stub,
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    final h = math.max(6.0, WeekStrip.barAreaHeight * total / scale);
    // Z1 at the bottom to Z5, then the no-heart-rate remainder on top.
    final order = [1, 2, 3, 4, 5, 0];
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        width: width,
        height: h,
        child: Column(
          verticalDirection: VerticalDirection.up,
          children: [
            for (final z in order)
              if (seconds[z] > 0)
                Expanded(
                  flex: math.max(1, (seconds[z] * 1000).round()),
                  child: ColoredBox(color: colors[z]),
                ),
          ],
        ),
      ),
    );
  }
}
