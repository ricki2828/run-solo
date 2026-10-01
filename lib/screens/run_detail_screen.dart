import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../map/map_surface.dart';
import '../map/route_builder.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/zone_histogram.dart';
import '../theme/theme.dart';
import '../theme/zones.dart';
import '../widgets/chrome.dart';
import '../widgets/coaching.dart';
import '../widgets/hold_button.dart';
import '../widgets/rep_bars.dart';
import '../widgets/recent_activity.dart' show runTypeColor;
import '../widgets/weather_chip.dart';
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
          appBar: AppBar(title: Text(runTitle(d.summary).toUpperCase())),
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
    final weather = detailWeatherChip(
      weatherChipView(
        analysis: a,
        units: units,
        fetchEnabled: services.settings.settings.weatherPerRun,
      ),
      runEnd: d.run.end,
      now: services.now(),
    );
    final hasRoute = !a.indoor && !route.isEmpty;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
      children: [
        if (showHeader) ...[
          const SizedBox(height: Space.x8),
          _Header(detail: d, units: units),
          const SizedBox(height: Space.x16),
          // A10.6: on run detail the coaching follows the header.
          CoachingSection(runId: d.run.id),
        ],
        // A6: the weather chip sits under the header, before the map.
        if (weather != null) ...[
          WeatherChip(view: weather),
          const SizedBox(height: Space.x16),
        ],
        // No route (indoor, or no GPS): no empty box, the figures speak.
        if (hasRoute) ...[
          AspectRatio(
            aspectRatio: 4 / 3,
            child: _MapCard(route: route, indoor: a.indoor),
          ),
          const SizedBox(height: Space.x24),
        ],
        switch (d.summary.mode) {
          RecordMode.intervals => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FourByFourTables(detail: d, units: units, onVerdict: onVerdict),
              const SizedBox(height: Space.x24),
              _DistanceSplits(
                free: free,
                units: units,
                color: d.summary.spec?.isGoal == true || d.summary.isParkrun
                    ? AuroraRunType.goal
                    : AuroraRunType.intervals,
              ),
            ],
          ),
          RecordMode.laps
              when d.summary.spec?.templateId == engine.SessionSpec.fartlekId =>
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FartlekBlock(
                  summary: a.fartlek,
                  timeInBandSeconds: a.laps?.hrPresent == true
                      ? a.laps?.timeInBandSeconds
                      : null,
                  units: units,
                ),
                const SizedBox(height: Space.x24),
                _LapsTable(view: a.laps, units: units),
              ],
            ),
          RecordMode.laps => _LapsTable(view: a.laps, units: units),
          RecordMode.free || RecordMode.cooper => _Splits(
            free: free,
            units: units,
            heat: d.summary.mode == RecordMode.cooper ? null : a.heat,
          ),
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

/// How long after a run's end "Weather: fetching when online" can still be
/// true: the queue tries on the run finishing and on each app open, and
/// nothing is fetching for a run from last week.
const Duration kWeatherFetchWindow = Duration(hours: 2);

/// The weather chip as run detail shows it: a pending chip only while the
/// fetch can still be in flight, never as a permanent placeholder.
WeatherChipView? detailWeatherChip(
  WeatherChipView? view, {
  required DateTime runEnd,
  required DateTime now,
}) {
  if (view == null) return null;
  if (view.state == WeatherChipState.pending &&
      now.difference(runEnd) > kWeatherFetchWindow) {
    return null;
  }
  return view;
}

class _Header extends StatefulWidget {
  const _Header({required this.detail, required this.units});
  final RunDetail detail;
  final Units units;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  String? _place;
  String? _custom;
  bool _renamed = false;

  @override
  void initState() {
    super.initState();
    _place = widget.detail.summary.place;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // An older run, or one the geocoder could not name when it finished:
    // try again now (null when offline or indoors, which stays blank).
    if (_place == null && widget.detail.summary.startPoint != null) {
      final id = widget.detail.run.id;
      AppServices.of(context).places.ensure(id).then((p) {
        if (mounted && p != null) setState(() => _place = p);
      });
    }
  }

  Future<void> _rename() async {
    final services = AppServices.of(context);
    final current = _renamed ? _custom : widget.detail.summary.customTitle;
    final controller = TextEditingController(
      text: current ?? runIdentityTitle(widget.detail.summary),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Name this run'),
        content: TextField(
          key: const ValueKey('rename-field'),
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Hill repeats'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (current != null)
            TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('Use automatic name'),
            ),
          TextButton(
            key: const ValueKey('rename-save'),
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    final title = engine.RunIdentity.cleanTitle(result);
    await services.history.setTitle(widget.detail.run.id, title);
    if (mounted) {
      setState(() {
        _custom = title;
        _renamed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final d = widget.detail;
    final units = widget.units;
    final summary = d.summary;
    final custom = _renamed ? _custom : summary.customTitle;
    final timeWord = engine.RunIdentity.timeOfDay(summary.start.toLocal());
    final free = d.analysis.freeRun;
    final avgHr = free.avgHr;
    // The test's figures, when this is one (C1 via the index row).
    final cooper = d.summary.cooper;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    if (custom == null)
                      TextSpan(
                        text: '$timeWord ',
                        style: TextStyle(color: t.inkPrimary),
                      ),
                    TextSpan(
                      text: custom ?? runSessionName(summary),
                      style: TextStyle(color: runTypeColor(summary)),
                    ),
                  ],
                ),
                key: const ValueKey('detail-title'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: RunSoloType.heading19,
              ),
            ),
            SizedBox(
              width: 48,
              height: 48,
              child: IconButton(
                key: const ValueKey('rename-run'),
                padding: EdgeInsets.zero,
                tooltip: 'Rename run',
                icon: Icon(
                  Icons.edit_outlined,
                  size: 20,
                  color: t.inkSecondary,
                ),
                onPressed: _rename,
              ),
            ),
          ],
        ),
        Text(
          whereWhen(_place, summary.start),
          key: const ValueKey('detail-where-when'),
          style: RunSoloType.label13.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x12),
        // Labels share one bottom edge; the numbers scale down to fit.
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: StatTile(
                label: 'time',
                // A test's own window (27-Sep field test: total time
                // counted the cool-down).
                value: cooper == null
                    ? Fmt.clock(d.summary.durationMs)
                    : cooper.valid
                    ? '12:00'
                    : Fmt.clock(
                        d.summary.durationMs <
                                engine.CooperProjection.testSeconds * 1000
                            ? d.summary.durationMs
                            : engine.CooperProjection.testSeconds * 1000,
                      ),
                size: 36,
              ),
            ),
            const SizedBox(width: Space.x16),
            Expanded(
              child: StatTile(
                label: 'distance',
                value: Fmt.distance(
                  cooper?.testDistanceM ?? free.distanceM,
                  units,
                ),
                size: 36,
              ),
            ),
            const SizedBox(width: Space.x16),
            Expanded(
              child: StatTile(
                label: cooper?.primeVo2 != null
                    ? 'VO2 est.'
                    : avgHr == null
                    ? 'pace'
                    : 'avg hr',
                value: cooper?.primeVo2 != null
                    ? '${cooper!.primeVo2!.round()}'
                    : avgHr == null
                    ? Fmt.pace(free.avgPaceSecPerKm, units)
                    : '${avgHr.round()}',
                size: 36,
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
class _MapCard extends StatefulWidget {
  const _MapCard({required this.route, required this.indoor});
  final RouteGeometry route;
  final bool indoor;

  @override
  State<_MapCard> createState() => _MapCardState();
}

class _MapCardState extends State<_MapCard> {
  Future<PermissionSnapshot>? _perms;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _perms ??= AppServices.of(context).permissions.status();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final route = widget.route;
    if (widget.indoor || route.isEmpty) {
      return _MapMessage(text: 'Indoor run, no route');
    }
    return FutureBuilder<PermissionSnapshot>(
      future: _perms,
      builder: (context, snap) {
        // Until the GMS check answers, draw our own shape: never a
        // GoogleMap for a frame on a device without Play services.
        if (!snap.hasData) return RouteShape(route: route);
        final gms = snap.data!.gmsAvailable;
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
    final m = a.intervals;
    final v = d.summary.verdict;
    final units = widget.units;
    if (m == null) {
      return Text(
        a.detection?.inconsistencyDetail ?? 'No reps found in this run.',
        style: RunSoloType.body17.copyWith(color: t.inkSecondary),
      );
    }
    final repTime =
        m.kind == engine.IntervalMetricKind.repTime &&
        m.nominalRepMetres != null;
    final short = m.kind == engine.IntervalMetricKind.untrimmedPace;
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
        // I3: rep-time sessions list the time for the rep distance; short
        // reps (untrimmed) show peak HR, since HR lags a 30 s effort and
        // there is no time in zone.
        _TableHeader(
          cells: [
            'Rep',
            repTime ? 'Time' : 'Pace',
            short ? 'Peak HR' : 'Avg HR',
            short ? '' : 'In band',
          ],
        ),
        for (final r in m.reps)
          _TableRow(
            muted: !r.clean,
            cells: [
              'Rep ${r.number}',
              repTime && r.paceSecPerKm != null
                  ? Fmt.clock((r.paceSecPerKm! * m.nominalRepMetres!).round())
                  : Fmt.pace(r.paceSecPerKm, units),
              short
                  ? (r.peakHr == null ? '--' : '${r.peakHr}')
                  : (r.meanHr == null ? '--' : '${r.meanHr!.round()}'),
              short
                  ? ''
                  : r.zoneSeconds == null
                  ? '--'
                  : '${(r.zoneSeconds! / (r.trimmedSeconds == 0 ? 1 : r.trimmedSeconds) * 100).clamp(0, 100).round()}%',
            ],
            note: r.clean && a.heat?.adjusts == true
                ? () {
                    final twin = a.heat!.paceAtDistance(
                      r.paceSecPerKm!,
                      (r.lap.d0M + r.lap.d1M) / 2,
                    );
                    return twin == null
                        ? null
                        : 'Cool-day estimate: '
                              '${repTime ? Fmt.clock((twin * m.nominalRepMetres!).round()) : Fmt.pace(twin, units)}';
                  }()
                : !r.clean
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
            if (repTime)
              StatTile(
                label: '${m.nominalRepMetres} m average',
                value: m.avgRepSeconds == null
                    ? '--'
                    : Fmt.clock((m.avgRepSeconds! * 1000).round()),
                size: 28,
              )
            else
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
                label: runHeaderTitle(d.summary) == '4x4'
                    ? 'in 4x4 band'
                    : 'in band',
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
  final engine.LapsSummary? view;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final view = this.view;
    if (view == null) {
      return Text(
        'No laps recorded.',
        style: RunSoloType.body15.copyWith(color: t.inkSecondary),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TableHeader(
          cells: ['Lap', 'Time', units == Units.mi ? 'Mi' : 'Km', 'Pace', 'HR'],
        ),
        for (final r in view.laps)
          _TableRow(
            highlight: r.number == view.fastestLapNumber,
            muted: !r.scored,
            cells: [
              '${r.number}',
              Fmt.clock((r.movingSeconds * 1000).round()),
              Fmt.distanceBare(r.distanceM, units),
              Fmt.pace(r.paceSecPerKm, units),
              r.meanHr == null ? '--' : '${r.meanHr!.round()}',
            ],
          ),
        const SizedBox(height: Space.x16),
        Wrap(
          spacing: Space.x24,
          runSpacing: Space.x12,
          children: [
            if (view.fastestLapNumber != null)
              StatTile(
                label: 'fastest lap',
                value: 'Lap ${view.fastestLapNumber}',
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
                value: '${view.avgHr!.round()} / ${view.maxHr}',
                size: 28,
              ),
            if (view.timeInBandSeconds != null)
              StatTile(
                label: 'in 4x4 band',
                value: Fmt.clock((view.timeInBandSeconds! * 1000).round()),
                size: 28,
              ),
          ],
        ),
        if (view.laps.isEmpty)
          Text(
            'No laps recorded.',
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
      ],
    );
  }
}

class _Splits extends StatelessWidget {
  const _Splits({required this.free, required this.units, this.heat});
  final engine.FreeRunSummary free;
  final Units units;
  final engine.HeatAdjustment? heat;

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
          _TableHeader(
            cells: [
              unit.toUpperCase(),
              'Pace',
              heat?.adjusts == true ? 'Cool-day est.' : '',
              '',
            ],
          ),
          for (var i = 0; i < free.splitsSecPerUnit.length; i++)
            _TableRow(
              cells: [
                '${i + 1}',
                Fmt.pace(free.splitsSecPerUnit[i], units),
                heat?.adjusts == true
                    ? Fmt.pace(
                        heat!.paceAtDistance(
                          free.splitsSecPerUnit[i] *
                              1000 /
                              (units == Units.mi ? 1609.344 : 1000),
                          (i + 0.5) * (units == Units.mi ? 1609.344 : 1000),
                        ),
                        units,
                      )
                    : '',
                '',
              ],
            ),
        ],
      ],
    );
  }
}

/// Distance splits describe the recorded run even when INT finds no reps.
/// The engine's FreeRunSummary uses sample-crossing times, not inferred reps;
/// this card does not claim a clean 5K for a broken GPS stretch.
class _DistanceSplits extends StatelessWidget {
  const _DistanceSplits({
    required this.free,
    required this.units,
    required this.color,
  });
  final engine.FreeRunSummary free;
  final Units units;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final unit = units == Units.mi ? 'MI' : 'KM';
    final splits = free.splitsSecPerUnit;
    final quickest = splits.isEmpty
        ? -1
        : splits.indexOf(splits.reduce((a, b) => a < b ? a : b));
    return Container(
      key: const ValueKey('run-distance-splits'),
      decoration: BoxDecoration(
        color: t.bgRaised,
        border: Border.all(color: t.lineHair),
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      padding: const EdgeInsets.all(Space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$unit SPLITS',
            style: RunSoloType.heading19.copyWith(color: color),
          ),
          const SizedBox(height: Space.x4),
          Text(
            'Recorded time for each full $unit, including any pauses.',
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x16),
          if (splits.isEmpty)
            Text(
              'No full $unit recorded.',
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            )
          else
            for (var i = 0; i < splits.length; i++) ...[
              Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${i + 1}',
                      style: RunSoloType.heading26.copyWith(
                        color: i == quickest ? t.semFaster : t.inkPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.x8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(Radii.pill),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        value: splits[i] <= 0
                            ? 1.0
                            : (splits[quickest] / splits[i]).clamp(0.1, 1.0),
                        backgroundColor: t.bgBase,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          i == quickest ? t.semFaster : color,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.x12),
                  Text(
                    Fmt.clock((splits[i] * 1000).round()),
                    style: RunSoloType.heading19.copyWith(
                      color: i == quickest ? t.semFaster : t.inkPrimary,
                    ),
                  ),
                ],
              ),
              if (i + 1 < splits.length) const SizedBox(height: Space.x12),
            ],
        ],
      ),
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
                      softWrap: false,
                      overflow: TextOverflow.fade,
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

/// Fartlek summary (plan §3.5): surge count, surge time, surge pace against
/// easy pace, HR time in band. Informational only; no verdict word.
class FartlekBlock extends StatelessWidget {
  const FartlekBlock({
    super.key,
    required this.summary,
    required this.units,
    this.timeInBandSeconds,
  });

  /// The engine's summary (I3 `RunAnalysis.fartlek`); null = no surges.
  final engine.FartlekSummary? summary;
  final Units units;

  /// HR time in the Laps band (85–95 % of max), when a strap was on.
  final double? timeInBandSeconds;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final s = summary;
    if (s == null || s.surgeCount == 0) {
      return Text(
        'No surges marked. Press LAP at the start and end of each surge.',
        key: const ValueKey('fartlek-empty'),
        style: RunSoloType.body15.copyWith(color: t.inkSecondary),
      );
    }
    final unit = units == Units.mi ? '/mi' : '/km';
    return Column(
      key: const ValueKey('fartlek-summary'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'FARTLEK',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        Row(
          children: [
            Expanded(
              child: StatTile(label: 'SURGES', value: '${s.surgeCount}'),
            ),
            Expanded(
              child: StatTile(
                label: 'SURGE TIME',
                value: Fmt.clock((s.surgeSeconds * 1000).round()),
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.x16),
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'SURGE PACE $unit',
                value: Fmt.pace(s.avgSurgePaceSecPerKm, units),
              ),
            ),
            Expanded(
              child: StatTile(
                label: 'EASY PACE $unit',
                value: Fmt.pace(s.avgEasyPaceSecPerKm, units),
              ),
            ),
          ],
        ),
        if (timeInBandSeconds != null) ...[
          const SizedBox(height: Space.x16),
          StatTile(
            label: 'HR 85-95%',
            value: Fmt.clock((timeInBandSeconds! * 1000).round()),
          ),
        ],
      ],
    );
  }
}
