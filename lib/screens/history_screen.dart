import 'package:flutter/material.dart';

import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';

enum HistoryFilter { all, fourByFour, free }

/// History list (design brief §4.8): newest first, grouped by month, filter
/// chips, buttons only. The verdict arrow column arrives with Phase 2; for
/// now the row shows mode, date, average pace and duration.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.onStart});

  /// Empty-state button; null hides it (e.g. inside the recording flow).
  final VoidCallback? onStart;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  HistoryFilter _filter = HistoryFilter.all;
  Future<List<RunSummary>>? _runs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runs ??= AppServices.of(context).history.list();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final units = AppServices.of(context).settings.settings.units;
    return Scaffold(
      appBar: AppBar(title: const Text('HISTORY')),
      body: SafeArea(
        child: FutureBuilder<List<RunSummary>>(
          future: _runs,
          builder: (context, snap) {
            final all = snap.data;
            if (all == null) return const SizedBox.shrink();
            final runs = all.where((r) {
              return switch (_filter) {
                HistoryFilter.all => true,
                HistoryFilter.fourByFour => r.isFourByFour,
                HistoryFilter.free => !r.isFourByFour,
              };
            }).toList();
            if (all.isEmpty) return _Empty(onStart: widget.onStart);
            return ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.screenGutter,
              ),
              children: [
                const SizedBox(height: Space.x8),
                Row(
                  children: [
                    for (final f in HistoryFilter.values) ...[
                      _FilterChip(
                        label: switch (f) {
                          HistoryFilter.all => 'All',
                          HistoryFilter.fourByFour => '4x4',
                          HistoryFilter.free => 'Free',
                        },
                        selected: _filter == f,
                        onTap: () => setState(() => _filter = f),
                      ),
                      const SizedBox(width: Space.x8),
                    ],
                  ],
                ),
                const SizedBox(height: Space.x16),
                if (runs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.x32),
                    child: Text(
                      'Nothing here yet.',
                      style: text.bodyLarge?.copyWith(color: t.inkSecondary),
                    ),
                  ),
                ..._grouped(runs, units, t),
                const SizedBox(height: Space.x24),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _grouped(List<RunSummary> runs, Units units, RunSoloTokens t) {
    final out = <Widget>[];
    String? month;
    for (final r in runs) {
      final m = Fmt.monthYear(r.start);
      if (m != month) {
        month = m;
        out.add(
          Padding(
            padding: const EdgeInsets.only(top: Space.x16, bottom: Space.x8),
            child: Text(
              m.toUpperCase(),
              style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
            ),
          ),
        );
      }
      out.add(HistoryRow(run: r, units: units));
    }
    return out;
  }
}

class HistoryRow extends StatelessWidget {
  const HistoryRow({super.key, required this.run, required this.units});
  final RunSummary run;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final muted = run.missing ? t.inkMuted : t.inkPrimary;
    return Semantics(
      label:
          '${run.isFourByFour ? '4x4' : 'Free run'}, ${Fmt.dayDate(run.start)}',
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(vertical: Space.x12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.lineHair)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: Text(
                run.isFourByFour ? '4x4' : 'FR',
                style: RunSoloType.title28.copyWith(fontSize: 22, color: muted),
              ),
            ),
            const SizedBox(width: Space.x12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Fmt.dayDate(run.start),
                    style: RunSoloType.body17.copyWith(color: muted),
                  ),
                  Text(
                    run.missing
                        ? 'File missing'
                        : run.isFourByFour
                        ? '${run.laps} laps · ${Fmt.distance(run.distanceM, units)}'
                        : Fmt.distance(run.distanceM, units),
                    style: RunSoloType.label13.copyWith(
                      color: run.missing ? t.semWarn : t.inkSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  Fmt.paceUnit(run.avgSecPerKm, units),
                  style: RunSoloType.title28.copyWith(
                    fontSize: 22,
                    color: muted,
                  ),
                ),
                Text(
                  Fmt.clock(run.durationMs),
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
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
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.chip),
        child: AnimatedContainer(
          duration: MotionDurations.quick,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: Space.x16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? t.inkPrimary : t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.chip),
          ),
          child: Text(
            label,
            style: RunSoloType.label13.copyWith(
              color: selected ? t.bgBase : t.inkPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({this.onStart});
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const TallyMark(height: 40, earned: false),
          const SizedBox(height: Space.x24),
          Text(
            'Your first 4x4 sets the baseline.',
            style: RunSoloType.body17.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x24),
          if (onStart != null)
            FilledButton(onPressed: onStart, child: const Text('START')),
        ],
      ),
    );
  }
}
