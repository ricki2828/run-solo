import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../theme/theme.dart';

/// Progress: 5K, 10K, half and marathon times with their ranges, and the
/// VO2 reading, all on true pace. A row without enough running behind it
/// says why. The detail (tap "How this works") explains the method and is
/// the one place the word "estimate" appears.
class RaceEstimatesCard extends StatefulWidget {
  const RaceEstimatesCard({super.key, required this.estimates});

  final engine.RaceEstimates estimates;

  @override
  State<RaceEstimatesCard> createState() => _RaceEstimatesCardState();
}

class _RaceEstimatesCardState extends State<RaceEstimatesCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final e = widget.estimates;
    final vo2 = e.vo2;
    return Container(
      key: const ValueKey('race-estimates'),
      width: double.infinity,
      padding: const EdgeInsets.all(Space.x16),
      decoration: BoxDecoration(
        color: t.bgBase,
        border: Border.all(color: t.lineHair),
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'RACE TIMES AND VO2',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x4),
          Text(
            'On a flat, cool day, from your best recent run.',
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x12),
          for (final r in e.rows) _Row(row: r),
          if (vo2 != null) ...[
            const Divider(height: Space.x24),
            Semantics(
              container: true,
              excludeSemantics: true,
              label: 'VO2 max ${vo2.vo2.toStringAsFixed(1)}',
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      'VO2 max',
                      style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                    ),
                  ),
                  Text(
                    vo2.vo2.toStringAsFixed(1),
                    key: const ValueKey('race-vo2'),
                    style: RunSoloType.heading19.copyWith(
                      color: t.inkPrimary,
                      fontFeatures: RunSoloType.tabular,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              'From your ${vo2.sourceLabel} on ${vo2.asOf.day} '
              '${_months[vo2.asOf.month - 1]}',
              style: RunSoloType.label13.copyWith(color: t.inkSecondary),
            ),
          ],
          const SizedBox(height: Space.x8),
          InkWell(
            key: const ValueKey('race-how'),
            onTap: () => setState(() => _open = !_open),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _open ? 'Hide how this works' : 'How this works',
                  style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                ),
              ),
            ),
          ),
          if (_open)
            for (final p in engine.RaceEstimates.method) ...[
              Text(
                p,
                style: RunSoloType.body15.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x8),
            ],
        ],
      ),
    );
  }

  static const _months = [
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
}

class _Row extends StatelessWidget {
  const _Row({required this.row});
  final engine.RaceEstimateRow row;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x12),
      child: Semantics(
        container: true,
        excludeSemantics: true,
        label: row.semantics,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    row.label,
                    style: RunSoloType.body17.copyWith(
                      color: row.hasTime ? t.inkPrimary : t.inkSecondary,
                    ),
                  ),
                ),
                if (row.time case final time?)
                  Text(
                    time,
                    key: ValueKey('race-time-${row.label}'),
                    style: RunSoloType.heading19.copyWith(
                      color: t.inkPrimary,
                      fontFeatures: RunSoloType.tabular,
                    ),
                  ),
              ],
            ),
            if (row.range case final range?)
              Text(
                range,
                key: ValueKey('race-range-${row.label}'),
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
            if (row.whyNot case final why?)
              Text(
                why,
                key: ValueKey('race-why-${row.label}'),
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
          ],
        ),
      ),
    );
  }
}
