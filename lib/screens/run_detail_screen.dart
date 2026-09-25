import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../map/map_surface.dart';
import '../map/route_builder.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/laps_view.dart';
import '../theme/theme.dart';
import '../theme/zones.dart';
import '../widgets/chrome.dart';
import '../widgets/hold_button.dart';
import '../widgets/rep_bars.dart';
import 'verdict_screen.dart';

/// Run detail (design brief §4.7, addendum A4): header, post-run map, rep /
/// recovery tables (4x4), lap table (Laps), splits (Free), HR time in zone,
/// fix laps, delete (2 s hold). Weather chip is Phase 3 and not rendered.
class RunDetailScreen extends StatefulWidget {
  const RunDetailScreen({super.key, required this.runId});
  final String runId;

  @override
  State<RunDetailScreen> createState() => _RunDetailScreenState();
}

class _RunDetailScreenState extends State<RunDetailScreen> {
  Future<RunDetail?>? _load;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load ??= AppServices.of(context).history.load(widget.runId);
  }

  Future<void> _delete(RunDetail d) async {
    final services = AppServices.of(context);
    await services.history.delete(d.run.id);
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return FutureBuilder<RunDetail?>(
      future: _load,
      builder: (context, snap) {
        if (!snap.hasData && snap.connectionState != ConnectionState.done) {
          return Scaffold(appBar: AppBar(title: const Text('RUN')));
        }
        final d = snap.data;
        if (d == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('RUN')),
            body: Padding(
              padding: const EdgeInsets.all(Space.screenGutter),
              child: Text(
                'File missing. This run is listed but its file is gone.',
                style: RunSoloType.body17.copyWith(color: t.semWarn),
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(modeTitle(d.summary.mode).toUpperCase())),
          body: SafeArea(
            child: RunDetailBody(
              detail: d,
              showHeader: true,
              onFixLaps: d.summary.isFourByFour
                  ? () async {
                      await Navigator.of(context)
                          .pushNamed(Routes.fixLaps, arguments: d.run.id);
                      if (mounted) {
                        setState(() {
                          _load = AppServices.of(context).history
                              .load(widget.runId);
                        });
                      }
                    }
                  : null,
              onDelete: () => _delete(d),
              onVerdict: d.summary.isFourByFour
                  ? () =>
                        Navigator.of(context)
                            .pushNamed(Routes.verdict, arguments: d.run.id)
                  : null,
            ),
          ),
        );
      },
    );
  }
}

/// The scrolling body, shared with the post-run summary.
class RunDetailBody extends StatelessWidget {
  const RunDetailBody({
    super.key,
    required this.detail,
    this.showHeader = true,
    this.onFixLaps,
    this.onDelete,
    this.onVerdict,
  });
  final RunDetail detail;
  final bool showHeader;
  final VoidCallback? onFixLaps;
  final VoidCallback? onDelete;
  final VoidCallback? onVerdict;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final units = services.settings.settings.units;
    final maxHr = services.maxHr.maxHr;
    final d = detail;
    final a = d.analysis;
    final free = a.freeRun;
    // Rep markers only on a 4x4; a Laps run gets numbered lap chips (A4).
    final route = RouteBuilder.build(
      d.run,
      detection: d.summary.isFourByFour ? a.detection : null,
    );
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
      children: [
        if (showHeader) ...[
          const SizedBox(height: Space.x8),
          _Header(detail: d, units: units),
          const SizedBox(height: Space.x16),
        ],
        AspectRatio(
          aspectRatio: 4 / 3,
          child: _MapCard(route: route, indoor: a.indoor),
        ),
        const SizedBox(height: Space.x24),
        switch (d.summary.mode) {
          RecordMode.fourByFour => _FourByFourTables(
            detail: d,
            units: units,
            onVerdict: onVerdict,
          ),
          RecordMode.laps => _LapsTable(
            view: LapsView.from(d.run, maxHrUsed: maxHr),
            units: units,
          ),
          RecordMode.free ||
          RecordMode.cooper => _Splits(free: free, units: units),
        },
        if (d.run.hasHr) ...[
          const SizedBox(height: Space.x24),
          _ZoneStrip(seconds: zoneSecondsOf(d.run, maxHr), maxHr: maxHr),
        ],
        const SizedBox(height: Space.x32),
        if (onFixLaps != null)
          _Row(
            label: 'Fix laps',
            value: d.sidecar.lapEdits.isEmpty
                ? ''
                : '${d.sidecar.lapEdits.length} edit${d.sidecar.lapEdits.length == 1 ? '' : 's'}',
            onTap: onFixLaps!,
          ),
        if (onDelete != null) ...[
          const SizedBox(height: Space.x24),
          HoldButton(
            label: 'HOLD TO DELETE',
            icon: Icons.delete_outline,
            color: t.semDanger,
            onHeld: onDelete!,
            haptics: services.settings.settings.haptics,
          ),
        ],
        const SizedBox(height: Space.x24),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.detail, required this.units});
  final RunDetail detail;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final d = detail;
    final free = d.analysis.freeRun;
    final avgHr = free.avgHr;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${modeLabel(d.summary.mode)} · ${Fmt.dayDate(d.run.start)} · ${Fmt.hhmm(d.run.start)}',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: StatTile(
                label: 'time',
                value: Fmt.clock(d.summary.durationMs),
              ),
            ),
            Expanded(
              child: StatTile(
                label: 'distance',
                value: Fmt.distance(free.distanceM, units),
              ),
            ),
            Expanded(
              child: StatTile(
                label: avgHr == null ? 'pace' : 'avg hr',
                value: avgHr == null
                    ? Fmt.pace(free.avgPaceSecPerKm, units)
                    : '${avgHr.round()}',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Map card states (A4): route on Google (or the shape fallback), "Indoor
/// run, no route", "Map needs Google Play services".
class _MapCard extends StatelessWidget {
  const _MapCard({required this.route, required this.indoor});
  final RouteGeometry route;
  final bool indoor;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    if (indoor || route.isEmpty) {
      return _MapMessage(text: 'Indoor run, no route');
    }
    return FutureBuilder<PermissionSnapshot>(
      future: services.permissions.status(),
      builder: (context, snap) {
        final gms = snap.data?.gmsAvailable ?? true;
        if (!gms && services.maps.available) {
          return Stack(
            fit: StackFit.expand,
            children: [
              RouteShape(route: route),
              Positioned(
                left: Space.x12,
                bottom: Space.x8,
                child: Text(
                  'Map needs Google Play services',
                  style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                ),
              ),
            ],
          );
        }
        return Semantics(
          button: true,
          label: 'Open full-screen map',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                fullscreenDialog: true,
                builder: (_) => FullScreenMap(route: route),
              ),
            ),
            child: services.maps.build(context, route),
          ),
        );
      },
    );
  }
}

class _MapMessage extends StatelessWidget {
  const _MapMessage({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.bgRaised,
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: Text(
        text,
        style: RunSoloType.body15.copyWith(color: t.inkSecondary),
      ),
    );
  }
}

/// Interactive map with a 56 dp close button top left (A4).
class FullScreenMap extends StatefulWidget {
  const FullScreenMap({super.key, required this.route});
  final RouteGeometry route;

  @override
  State<FullScreenMap> createState() => _FullScreenMapState();
}

class _FullScreenMapState extends State<FullScreenMap> {
  int? _highlighted;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          services.maps.build(
            context,
            widget.route,
            interactive: true,
            onLapTap: (i) => setState(() => _highlighted = i),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(Space.x8),
                child: Material(
                  color: t.bgBase,
                  shape: const CircleBorder(),
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    tooltip: 'Close map',
                    constraints: const BoxConstraints(
                      minWidth: 56,
                      minHeight: 56,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_highlighted != null)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  margin: const EdgeInsets.all(Space.x16),
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.x16,
                    vertical: Space.x8,
                  ),
                  decoration: BoxDecoration(
                    color: t.bgRaised,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Text(
                    'Lap ${_highlighted! + 1}',
                    style: RunSoloType.label13.copyWith(color: t.inkPrimary),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FourByFourTables extends StatefulWidget {
  const _FourByFourTables({
    required this.detail,
    required this.units,
    this.onVerdict,
  });
  final RunDetail detail;
  final Units units;
  final VoidCallback? onVerdict;

  @override
  State<_FourByFourTables> createState() => _FourByFourTablesState();
}

class _FourByFourTablesState extends State<_FourByFourTables> {
  bool _recoveriesOpen = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final d = widget.detail;
    final a = d.analysis;
    final m = a.fourByFour;
    final v = a.verdict;
    final units = widget.units;
    if (m == null) {
      return Text(
        a.detection?.inconsistencyDetail ?? 'No reps found in this run.',
        style: RunSoloType.body17.copyWith(color: t.inkSecondary),
      );
    }
    final prevReps = <int, double?>{};
    // vs last: the verdict's comparison is run-level; per-rep ghosts come
    // from the previous 4x4 when the caller has it (verdict screen). Here we
    // show pace, avg HR and time in zone per rep.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (v != null)
          Semantics(
            button: widget.onVerdict != null,
            child: InkWell(
              onTap: widget.onVerdict,
              child: Padding(
                padding: const EdgeInsets.only(bottom: Space.x16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        v.headline.text,
                        style: RunSoloType.display44.copyWith(
                          color: switch (v.headline) {
                            engine.VerdictHeadline.faster => t.accentArc,
                            engine.VerdictHeadline.slower => t.inkPrimary,
                            engine.VerdictHeadline.noVerdict ||
                            engine.VerdictHeadline.indoorRun => t.inkSecondary,
                            _ => t.inkPrimary,
                          },
                        ),
                      ),
                    ),
                    if (widget.onVerdict != null)
                      Icon(Icons.chevron_right, color: t.inkSecondary),
                  ],
                ),
              ),
            ),
          ),
        _TableHeader(cells: const ['Rep', 'Pace', 'Avg HR', 'In band']),
        for (final r in m.reps)
          _TableRow(
            muted: !r.clean,
            cells: [
              'Rep ${r.number}',
              Fmt.pace(r.paceSecPerKm, units),
              r.meanHr == null ? '--' : '${r.meanHr!.round()}',
              r.zoneSeconds == null
                  ? '--'
                  : '${(r.zoneSeconds! / (r.trimmedSeconds == 0 ? 1 : r.trimmedSeconds) * 100).clamp(0, 100).round()}%',
            ],
            note: !r.clean
                ? (r.dropped
                      ? 'dropped'
                      : switch (r.interruptReason) {
                          engine.InterruptReason.gpsDropped => 'GPS dropped',
                          engine.InterruptReason.paused => 'paused',
                          engine.InterruptReason.recordingStopped =>
                            'recording stopped',
                          null => 'excluded',
                        })
                : null,
          ),
        const SizedBox(height: Space.x16),
        Wrap(
          spacing: Space.x24,
          runSpacing: Space.x12,
          children: [
            StatTile(
              label: 'work pace',
              value: Fmt.pace(m.avgWorkPaceSecPerKm, units),
              size: 28,
            ),
            StatTile(
              label: 'fade',
              value: m.fadeSecPerKm == null
                  ? '--'
                  : '${m.fadeSecPerKm!.round()} s',
              size: 28,
            ),
            StatTile(
              label: 'recovery',
              value: Fmt.pace(m.recoveryPaceSecPerKm, units),
              size: 28,
            ),
            if (m.timeInZoneSeconds != null)
              StatTile(
                label: 'in 4x4 band',
                value:
                    '${(m.timeInZoneSeconds! / (m.workSeconds == 0 ? 1 : m.workSeconds) * 100).clamp(0, 100).round()}%',
                size: 28,
              ),
          ],
        ),
        const SizedBox(height: Space.x16),
        RepBars(
          reps: repBarData(d, null),
          units: units,
          showDelta: false,
          fadeProgress: 1,
        ),
        const SizedBox(height: Space.x16),
        Semantics(
          button: true,
          label: _recoveriesOpen ? 'Hide recoveries' : 'Show recoveries',
          child: InkWell(
            onTap: () => setState(() => _recoveriesOpen = !_recoveriesOpen),
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  Text(
                    'RECOVERIES',
                    style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                  ),
                  const Spacer(),
                  Icon(
                    _recoveriesOpen ? Icons.expand_less : Icons.expand_more,
                    color: t.inkSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_recoveriesOpen) ...[
          _TableHeader(cells: const ['Rec', 'Pace', 'Avg HR', '']),
          for (final r in m.recoveries)
            _TableRow(
              muted: r.dropped,
              cells: [
                'Rec ${r.number}',
                Fmt.pace(r.paceSecPerKm, units),
                r.meanHr == null ? '--' : '${r.meanHr!.round()}',
                '',
              ],
            ),
        ],
        if (prevReps.isNotEmpty) const SizedBox.shrink(),
      ],
    );
  }
}

class _LapsTable extends StatelessWidget {
  const _LapsTable({required this.view, required this.units});
  final LapsView view;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TableHeader(cells: const ['Lap', 'Time', 'Dist', 'Pace', 'HR']),
        for (final r in view.rows)
          _TableRow(
            highlight: r.number == view.fastestNumber,
            cells: [
              '${r.number}',
              Fmt.clock(r.durationMs),
              Fmt.distance(r.distanceM, units),
              Fmt.pace(r.paceSecPerKm, units),
              r.avgHr == null ? '--' : '${r.avgHr}',
            ],
          ),
        const SizedBox(height: Space.x16),
        Wrap(
          spacing: Space.x24,
          runSpacing: Space.x12,
          children: [
            if (view.fastestNumber != null)
              StatTile(
                label: 'fastest lap',
                value: 'Lap ${view.fastestNumber}',
                size: 28,
              ),
            if (view.spreadSecPerKm != null)
              StatTile(
                label: 'lap spread',
                value:
                    '${view.spreadSecPerKm!.round()} s/${units == Units.mi ? 'mi' : 'km'}',
                size: 28,
              ),
            if (view.avgHr != null)
              StatTile(
                label: 'hr avg / max',
                value: '${view.avgHr} / ${view.maxHr}',
                size: 28,
              ),
            if (view.secondsInBand != null)
              StatTile(
                label: 'in 4x4 band',
                value: Fmt.clock((view.secondsInBand! * 1000).round()),
                size: 28,
              ),
          ],
        ),
        if (view.rows.isEmpty)
          Text(
            'No laps recorded.',
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
      ],
    );
  }
}

class _Splits extends StatelessWidget {
  const _Splits({required this.free, required this.units});
  final engine.FreeRunSummary free;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final unit = units == Units.mi ? 'mi' : 'km';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Space.x24,
          runSpacing: Space.x12,
          children: [
            StatTile(
              label: 'moving',
              value: Fmt.clock((free.movingSeconds * 1000).round()),
              size: 28,
            ),
            StatTile(
              label: 'avg pace',
              value: Fmt.paceUnit(free.avgPaceSecPerKm, units),
              size: 28,
            ),
          ],
        ),
        const SizedBox(height: Space.x16),
        if (free.splitsSecPerUnit.isEmpty)
          Text(
            'Splits appear after the first full $unit.',
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          )
        else ...[
          _TableHeader(cells: [unit.toUpperCase(), 'Pace', '', '']),
          for (var i = 0; i < free.splitsSecPerUnit.length; i++)
            _TableRow(
              cells: [
                '${i + 1}',
                Fmt.pace(free.splitsSecPerUnit[i], units),
                '',
                '',
              ],
            ),
        ],
      ],
    );
  }
}

/// Time in each HR zone as a 5-segment bar plus the minutes per zone.
class _ZoneStrip extends StatelessWidget {
  const _ZoneStrip({required this.seconds, required this.maxHr});
  final List<double> seconds;
  final int maxHr;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final total = seconds.skip(1).fold(0.0, (a, b) => a + b);
    if (total == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TIME IN ZONE · MAX HR $maxHr',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 12,
            child: Row(
              children: [
                for (var z = 1; z <= 5; z++)
                  if (seconds[z] > 0)
                    Expanded(
                      flex: (seconds[z] / total * 1000).round().clamp(1, 1000),
                      child: ColoredBox(color: HrZones.background(z)),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Space.x8),
        Wrap(
          spacing: Space.x16,
          children: [
            for (var z = 1; z <= 5; z++)
              Text(
                'Z$z ${Fmt.clock((seconds[z] * 1000).round())}',
                style: RunSoloType.label13.copyWith(
                  color: seconds[z] > 0 ? t.inkPrimary : t.inkMuted,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader({required this.cells});
  final List<String> cells;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Space.x8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineHair)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            Expanded(
              flex: i == 0 ? 3 : 2,
              child: Text(
                cells[i].toUpperCase(),
                textAlign: i == 0 ? TextAlign.left : TextAlign.right,
                style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

class _TableRow extends StatelessWidget {
  const _TableRow({
    required this.cells,
    this.muted = false,
    this.highlight = false,
    this.note,
  });
  final List<String> cells;
  final bool muted;
  final bool highlight;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final color = muted ? t.semNoise : t.inkPrimary;
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(vertical: Space.x8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineHair)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 0; i < cells.length; i++)
                Expanded(
                  flex: i == 0 ? 3 : 2,
                  child: Padding(
                    padding: EdgeInsets.only(left: i == 0 ? 0 : Space.x8),
                    child: Text(
                      cells[i],
                      textAlign: i == 0 ? TextAlign.left : TextAlign.right,
                      style: RunSoloType.label13.copyWith(
                        fontSize: 15,
                        color: color,
                        fontWeight: highlight
                            ? FontWeight.w700
                            : FontWeight.w500,
                        decoration: muted ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (note != null)
            Text(note!, style: RunSoloType.micro11.copyWith(color: t.semNoise)),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, required this.onTap});
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: t.lineHair),
              bottom: BorderSide(color: t.lineHair),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                ),
              ),
              Text(
                value,
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(width: Space.x8),
              Icon(Icons.chevron_right, size: 20, color: t.inkSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
