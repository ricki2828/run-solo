import 'package:flutter/material.dart';

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/mode_chip.dart';

/// Home (design brief §4.3): Tally + date, last-run card (verdict arrives in
/// Phase 2, so the card shows pace and duration), mode chips, strap row,
/// START. Checklist incomplete = red row above START.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.now});

  /// Injected for tests; defaults to the wall clock.
  final DateTime Function()? now;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Future<List<RunSummary>>? _runs;
  PermissionSnapshot? _perms;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  void _refresh() {
    final services = AppServices.of(context);
    _runs = services.history.list();
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
                    );
                  },
                ),
                const SizedBox(height: Space.x24),
                Row(
                  children: [
                    Expanded(
                      child: ModeChip(
                        title: '4x4',
                        subtitle:
                            '${settings.reps} × 4:00 · ${Fmt.recovery(settings.recoverySeconds)} rec',
                        selected: settings.lastMode == RecordMode.fourByFour,
                        onTap: () => services.settings.update(
                          (s) => s.copyWith(lastMode: RecordMode.fourByFour),
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.x12),
                    Expanded(
                      child: ModeChip(
                        title: 'FREE RUN',
                        subtitle: 'Lap by hand',
                        selected: settings.lastMode == RecordMode.free,
                        onTap: () => services.settings.update(
                          (s) => s.copyWith(lastMode: RecordMode.free),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.x16),
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
  });
  final RunSummary? run;
  final Units units;
  final DateTime now;

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'LAST 4x4 · ${Fmt.ago(r.start, now).toUpperCase()}',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        Text(Fmt.paceUnit(r.avgSecPerKm, units), style: text.displayMedium),
        const SizedBox(height: Space.x8),
        Text(
          '${r.laps} laps · ${Fmt.clock(r.durationMs)} · verdict after your next 4x4',
          style: text.bodyMedium?.copyWith(color: t.inkSecondary),
        ),
      ],
    );
  }
}

class _StrapRow extends StatelessWidget {
  const _StrapRow({
    required this.label,
    required this.muted,
    required this.onTap,
  });
  final String label;
  final bool muted;
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
              Icon(Icons.favorite, size: 16, color: t.hrZone),
              const SizedBox(width: Space.x8),
              Text(
                label,
                style: RunSoloType.body15.copyWith(
                  color: muted ? t.inkSecondary : t.inkPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
