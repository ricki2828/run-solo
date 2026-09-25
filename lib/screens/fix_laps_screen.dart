import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';

/// Fix laps (plan §5, §6; design brief §4.7): a simple list of the laps the
/// detector ran over, each with merge / split / keep / drop. Every edit is
/// written to the sidecar and the engine re-runs; the verdict re-draws with
/// a 400 ms bar redraw, no Rive. Edits are indexed against
/// `RepDetection.laps`, never the raw file laps.
class FixLapsScreen extends StatefulWidget {
  const FixLapsScreen({super.key, required this.runId});
  final String runId;

  @override
  State<FixLapsScreen> createState() => _FixLapsScreenState();
}

class _FixLapsScreenState extends State<FixLapsScreen> {
  RunDetail? _detail;
  bool _busy = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_detail != null) return;
    AppServices.of(context).history.load(widget.runId).then((d) {
      if (mounted) setState(() => _detail = d);
    });
  }

  Future<void> _apply(Future<RunDetail> Function(RunStore) op) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final d = await op(AppServices.of(context).history);
      if (mounted) setState(() => _detail = d);
    } on engine.LapEditException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not apply that edit.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(int index) async {
    final d = _detail!;
    final laps = d.analysis.detection?.laps ?? const <engine.Lap>[];
    final lap = laps[index];
    final action = await showModalBottomSheet<_LapAction>(
      context: context,
      backgroundColor: Theme.of(context).extension<RunSoloTokens>()!.bgRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
      builder: (_) => _LapSheet(
        index: index,
        lap: lap,
        canMerge: index < laps.length - 1,
        units: AppServices.of(context).settings.settings.units,
      ),
    );
    if (action == null || !mounted) return;
    final edit = switch (action.kind) {
      _LapActionKind.merge => engine.LapEdit.merge(index),
      _LapActionKind.split => engine.LapEdit.split(index, action.atMs!),
      _LapActionKind.keep => engine.LapEdit.keep(index),
      _LapActionKind.drop => engine.LapEdit.drop(index),
    };
    await _apply((store) => store.applyLapEdit(widget.runId, edit));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final d = _detail;
    final units = AppServices.of(context).settings.settings.units;
    return Scaffold(
      appBar: AppBar(
        title: const Text('FIX LAPS'),
        actions: [
          if (d != null && d.sidecar.lapEdits.isNotEmpty)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _apply((s) => s.clearLapEdits(widget.runId)),
              child: Text(
                'RESET',
                style: RunSoloType.label13.copyWith(color: t.inkPrimary),
              ),
            ),
        ],
      ),
      body: d == null
          ? const SizedBox.shrink()
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.screenGutter,
                ),
                children: [
                  const SizedBox(height: Space.x8),
                  _Status(detail: d),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.x8),
                      child: Text(
                        _error!,
                        style: RunSoloType.label13.copyWith(color: t.semDanger),
                      ),
                    ),
                  const SizedBox(height: Space.x16),
                  Text(
                    'Tap a lap to merge it with the next, split it, keep it as '
                    'it is, or drop it from the verdict.',
                    style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                  ),
                  const SizedBox(height: Space.x16),
                  ..._rows(d, units, t),
                  const SizedBox(height: Space.x32),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('DONE'),
                  ),
                  const SizedBox(height: Space.x24),
                ],
              ),
            ),
    );
  }

  List<Widget> _rows(RunDetail d, Units units, RunSoloTokens t) {
    final det = d.analysis.detection;
    if (det == null) return const [];
    final roles = <int, String>{};
    for (final l in det.warmup) {
      roles[l.index] = 'warm-up';
    }
    for (final r in det.reps) {
      roles[r.work.index] =
          'rep ${r.number}${r.workDropped ? ' · dropped' : ''}';
      if (r.recovery != null) {
        roles[r.recovery!.index] =
            'recovery ${r.number}${r.recoveryDropped ? ' · dropped' : ''}';
      }
    }
    for (final l in det.cooldown) {
      roles[l.index] = 'cool-down';
    }
    return [
      for (final lap in det.laps)
        _LapRowTile(
          index: lap.index,
          lap: lap,
          role: roles[lap.index] ?? 'unmatched',
          units: units,
          onTap: _busy ? null : () => _edit(lap.index),
        ),
    ];
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.detail});
  final RunDetail detail;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final a = detail.analysis;
    final v = detail.summary.verdict;
    final detail0 = _withRow(a.detection);
    return AnimatedSwitcher(
      duration: MotionDurations.slow,
      // Left-aligned like the page, not centred (the default layout).
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      child: Column(
        key: ValueKey(v?.headline.name ?? 'none'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            v?.headline.text ?? 'NO VERDICT',
            key: const ValueKey('fix-laps-headline'),
            style: RunSoloType.display44.copyWith(
              color: a.lapsInconsistent ? t.inkSecondary : t.inkPrimary,
            ),
          ),
          const SizedBox(height: Space.x8),
          Text(
            a.lapsInconsistent
                ? (detail0 ?? 'The laps do not match a 4x4 pattern.')
                : (v?.subline ?? ''),
            style: RunSoloType.body17.copyWith(color: t.inkPrimary),
          ),
          if (a.lapEditsInvalid)
            Padding(
              padding: const EdgeInsets.only(top: Space.x8),
              child: Text(
                'Earlier edits no longer fit these laps and were ignored.',
                style: RunSoloType.label13.copyWith(color: t.semWarn),
              ),
            ),
          const SizedBox(height: Space.x16),
          const LapLineDivider(gapAt: 0.85),
        ],
      ),
    );
  }
}

/// The engine's line names the rep it tried ("Rep 2 was 7:00, …"); the list
/// below is numbered by lap, so point at the row too when one lap in the
/// list has exactly that duration.
String? _withRow(engine.RepDetection? det) {
  final text = det?.inconsistencyDetail;
  if (text == null || det == null) return text;
  final m = RegExp(r'(\d+):(\d\d)').firstMatch(text);
  if (m == null) return text;
  final secs = int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
  final hits = det.laps
      .where((l) => (l.durationMs / 1000).round() == secs)
      .toList();
  if (hits.length != 1) return text;
  return '$text That is lap ${hits.single.index + 1} below.';
}

class _LapRowTile extends StatelessWidget {
  const _LapRowTile({
    required this.index,
    required this.lap,
    required this.role,
    required this.units,
    required this.onTap,
  });
  final int index;
  final engine.Lap lap;
  final String role;
  final Units units;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final pace = lap.distanceM > 20
        ? lap.durationMs / 1000 / (lap.distanceM / 1000)
        : null;
    final dropped = role.contains('dropped');
    return Semantics(
      button: true,
      label: 'Lap ${index + 1}, $role, ${Fmt.clock(lap.durationMs)}',
      child: InkWell(
        onTap: onTap,
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
                  '${index + 1}',
                  style: RunSoloType.title28.copyWith(
                    fontSize: 22,
                    color: dropped ? t.semNoise : t.inkPrimary,
                  ),
                ),
              ),
              const SizedBox(width: Space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      role.toUpperCase(),
                      style: RunSoloType.micro11.copyWith(
                        color: role == 'unmatched' ? t.semWarn : t.inkSecondary,
                      ),
                    ),
                    Text(
                      '${Fmt.clock(lap.durationMs)} · ${Fmt.distance(lap.distanceM, units)}',
                      style: RunSoloType.body15.copyWith(
                        color: dropped ? t.semNoise : t.inkPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                Fmt.paceUnit(pace, units),
                style: RunSoloType.label13.copyWith(
                  fontSize: 15,
                  color: dropped ? t.semNoise : t.inkPrimary,
                ),
              ),
              const SizedBox(width: Space.x8),
              Icon(Icons.drag_handle, size: 20, color: t.inkMuted),
            ],
          ),
        ),
      ),
    );
  }
}

enum _LapActionKind { merge, split, keep, drop }

class _LapAction {
  const _LapAction(this.kind, {this.atMs});
  final _LapActionKind kind;
  final int? atMs;
}

/// "Keep it, merge it, or drop it?" (plan §6) plus split at a chosen time.
class _LapSheet extends StatefulWidget {
  const _LapSheet({
    required this.index,
    required this.lap,
    required this.canMerge,
    required this.units,
  });
  final int index;
  final engine.Lap lap;
  final bool canMerge;
  final Units units;

  @override
  State<_LapSheet> createState() => _LapSheetState();
}

class _LapSheetState extends State<_LapSheet> {
  late double _splitMs = widget.lap.t0Ms + widget.lap.durationMs / 2;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final lap = widget.lap;
    final canSplit = lap.durationMs > 20000;
    Widget action(
      String label,
      String why,
      VoidCallback? onTap, {
      Color? color,
    }) => Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(vertical: Space.x8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: RunSoloType.body17.copyWith(
                        color: onTap == null
                            ? t.inkMuted
                            : (color ?? t.inkPrimary),
                      ),
                    ),
                    Text(
                      why,
                      style: RunSoloType.label13.copyWith(
                        color: t.inkSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: t.inkSecondary),
            ],
          ),
        ),
      ),
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.screenGutter,
          Space.x24,
          Space.screenGutter,
          Space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'LAP ${widget.index + 1} · ${Fmt.clock(lap.durationMs)}',
              style: RunSoloType.title28.copyWith(color: t.inkPrimary),
            ),
            const SizedBox(height: Space.x12),
            action(
              'Merge with next',
              'A missed press split one lap in two.',
              widget.canMerge
                  ? () => Navigator.pop(
                      context,
                      const _LapAction(_LapActionKind.merge),
                    )
                  : null,
            ),
            action(
              'Keep it',
              'Accept it as a rep even outside the preset window.',
              () =>
                  Navigator.pop(context, const _LapAction(_LapActionKind.keep)),
            ),
            action(
              'Drop it',
              'Excluded from the verdict, like an interrupted rep.',
              () =>
                  Navigator.pop(context, const _LapAction(_LapActionKind.drop)),
              color: t.semSlower,
            ),
            const SizedBox(height: Space.x8),
            Text(
              'SPLIT AT ${Fmt.clock((_splitMs - lap.t0Ms).round())}',
              style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
            ),
            Slider(
              value: _splitMs,
              min: lap.t0Ms + 5000,
              max: lap.t1Ms - 5000.0,
              activeColor: t.inkPrimary,
              inactiveColor: t.lineHair,
              onChanged: canSplit ? (v) => setState(() => _splitMs = v) : null,
              semanticFormatterCallback: (v) =>
                  'Split at ${Fmt.clock((v - lap.t0Ms).round())}',
            ),
            FilledButton(
              onPressed: canSplit
                  ? () => Navigator.pop(
                      context,
                      _LapAction(_LapActionKind.split, atMs: _splitMs.round()),
                    )
                  : null,
              child: const Text('SPLIT HERE'),
            ),
          ],
        ),
      ),
    );
  }
}
