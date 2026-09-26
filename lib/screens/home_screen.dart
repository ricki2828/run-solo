import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/live_context.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/estimated_times_card.dart';
import '../widgets/goal_picker.dart';
import '../widgets/mode_chip.dart';
import 'settings_screen.dart';

/// Home (design brief §4.3): Tally + date, last-run card with its verdict,
/// three mode chips (4x4, Laps, Free), strap row, START. Checklist
/// incomplete = red row above START.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.now});

  /// Injected for tests; defaults to the wall clock.
  final DateTime Function()? now;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Future<List<RunSummary>>? _runs;
  Future<engine.HomeEstimates?>? _estimates;
  PermissionSnapshot? _perms;

  /// The event row shows only once a course exists (A10.4, K1).
  static bool _hasEventCourse(LiveContextSource live) => live.hasEventCourse;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  void _refresh() {
    final services = AppServices.of(context);
    _runs = services.history.list();
    // PD2: ESTIMATED TIMES read the index's derived data, prepared off the
    // UI isolate; the card shows once the first prepare lands.
    final live = services.live;
    if (live != null) {
      _estimates = live.prepare().then(
        (_) => live.homeEstimates(includeEvent: _hasEventCourse(live)),
      );
    }
    services.permissions.status().then((p) {
      if (mounted) setState(() => _perms = p);
    });
  }

  Future<void> _start() async {
    final perms = _perms;
    if (perms != null && !perms.canRecord) {
      final ok = await Navigator.of(context).pushNamed(Routes.permissions);
      if (!mounted || ok != true) {
        _refresh();
        return;
      }
    }
    if (!mounted) return;
    await Navigator.of(context).pushNamed(Routes.start);
    if (mounted) setState(_refresh);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final services = AppServices.of(context);
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) {
        final settings = services.settings.settings;
        final perms = _perms;
        return Scaffold(
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.screenGutter,
              ),
              children: [
                const SizedBox(height: Space.x24),
                Row(
                  children: [
                    const TallyMark(height: 20),
                    const Spacer(),
                    Text(
                      Fmt.dayDate(_now),
                      style: RunSoloType.label13.copyWith(
                        color: t.inkSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.x32),
                FutureBuilder<List<RunSummary>>(
                  future: _runs,
                  builder: (context, snap) {
                    final last = snap.data
                        ?.where((r) => r.isFourByFour)
                        .firstOrNull;
                    return _LastRunCard(
                      run: last,
                      units: settings.units,
                      now: _now,
                      onTap: last == null
                          ? null
                          : () => Navigator.of(context)
                                .pushNamed(Routes.verdict, arguments: last.id),
                    );
                  },
                ),
                FutureBuilder<engine.HomeEstimates?>(
                  future: _estimates,
                  builder: (context, snap) {
                    final e = snap.data;
                    if (e == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: Space.x24),
                      child: EstimatedTimesCard(estimates: e),
                    );
                  },
                ),
                const SizedBox(height: Space.x24),
                ModeChipRow(
                  selected: settings.lastMode,
                  session: services.pickedSession,
                  goal: settings.goalRun,
                  goalLabel: goalLabel(settings),
                  onGoal: () => services.settings.update(
                    (s) => s.copyWith(goalRun: true),
                  ),
                  onSelect: (m) => services.settings.update(
                    (s) => s.copyWith(lastMode: m, goalRun: false),
                  ),
                ),
                const SizedBox(height: Space.x16),
                if (settings.pendingObservedMaxHr != null)
                  _StrapRow(
                    label:
                        'Strap saw ${settings.pendingObservedMaxHr} bpm, tap to review',
                    muted: false,
                    warn: true,
                    onTap: () => showPendingMaxSheet(context),
                  ),
                _StrapRow(
                  label: settings.strap == null
                      ? 'No strap, tap to pair'
                      : 'Strap: ${settings.strap!.label}',
                  muted: settings.strap == null,
                  onTap: () async {
                    await Navigator.of(context).pushNamed(Routes.pairing);
                  },
                ),
                const SizedBox(height: Space.x24),
                if (perms != null && !perms.canRecord)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.x12),
                    child: InkWell(
                      onTap: _start,
                      child: Text(
                        perms.coarseOnly
                            ? 'Location is approximate. Precise is needed for pace.'
                            : 'Location permission needed before you can record.',
                        style: text.labelLarge?.copyWith(color: t.semDanger),
                      ),
                    ),
                  ),
                FilledButton(onPressed: _start, child: const Text('START')),
                const SizedBox(height: Space.x24),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LastRunCard extends StatelessWidget {
  const _LastRunCard({
    required this.run,
    required this.units,
    required this.now,
    this.onTap,
  });
  final RunSummary? run;
  final Units units;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final r = run;
    if (r == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'NO 4x4 YET',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x8),
          Text('BASELINE', style: text.displayMedium),
          const SizedBox(height: Space.x8),
          Text(
            'Your first one sets the baseline.',
            style: text.bodyLarge?.copyWith(color: t.inkSecondary),
          ),
        ],
      );
    }
    final v = r.verdict;
    final word = v?.headline.text;
    final wordColor = switch (v?.headline) {
      engine.VerdictHeadline.faster => t.accentArc,
      null => t.inkPrimary,
      _ => t.inkPrimary,
    };
    final title = runHeaderTitle(r);
    return Semantics(
      button: onTap != null,
      label: 'Last $title${word == null ? '' : ', $word'}',
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'LAST ${title == '4x4' ? title : title.toUpperCase()} · ${Fmt.ago(r.start, now).toUpperCase()}',
              style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x8),
            Text(
              word ?? Fmt.paceUnit(r.headlineSecPerKm, units),
              style: text.displayMedium?.copyWith(color: wordColor),
            ),
            const SizedBox(height: Space.x8),
            Text(
              v?.subline ??
                  '${r.laps} laps · ${Fmt.clock(r.durationMs)} · verdict after your next ${title == '4x4' ? '4x4' : 'one'}',
              style: text.bodyMedium?.copyWith(color: t.inkSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _StrapRow extends StatelessWidget {
  const _StrapRow({
    required this.label,
    required this.muted,
    required this.onTap,
    this.warn = false,
  });
  final String label;
  final bool muted;
  final bool warn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              Icon(
                Icons.favorite,
                size: 16,
                color: warn ? t.semWarn : t.hrZone,
              ),
              const SizedBox(width: Space.x8),
              Expanded(
                child: Text(
                  label,
                  style: RunSoloType.body15.copyWith(
                    color: warn
                        ? t.semWarn
                        : muted
                        ? t.inkSecondary
                        : t.inkPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
