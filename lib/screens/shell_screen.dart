import 'package:flutter/material.dart';

import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'permissions_screen.dart';
import 'recovery_dialog.dart';

/// Bottom-nav shell. On first frame it runs the recovery check (plan §3:
/// orphaned journals are offered on app open only) and, if the run is still
/// live in the service, jumps straight back to the record screen.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key, this.now, this.checkRecoveryOnOpen = true});
  final DateTime Function()? now;
  final bool checkRecoveryOnOpen;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  AppTab _tab = AppTab.home;
  bool _checked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_checked || !widget.checkRecoveryOnOpen) return;
    _checked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _onOpen());
  }

  Future<void> _onOpen() async {
    final services = AppServices.of(context);
    final status = await services.recorder.status();
    if (!mounted) return;
    if (status.state == RecorderState.recording ||
        status.state == RecorderState.paused) {
      await services.recording.attach();
      if (mounted) await Navigator.of(context).pushNamed(Routes.recording);
      return;
    }
    if (!services.settings.settings.onboardingDone) {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => const _OnboardingRoute(),
          fullscreenDialog: true,
        ),
      );
      if (!mounted) return;
    }
    await RecoveryDialog.checkAndShow(context);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab.index,
        children: [
          HomeScreen(now: widget.now),
          HistoryScreen(onStart: () => setState(() => _tab = AppTab.home)),
          const _Placeholder(
            title: 'TREND',
            line: 'Two 4x4s draw the first line.',
          ),
          const _SettingsLite(),
        ],
      ),
      bottomNavigationBar: BottomNav(
        current: _tab,
        onSelect: (t) => setState(() => _tab = t),
      ),
    );
  }
}

class _OnboardingRoute extends StatelessWidget {
  const _OnboardingRoute();

  @override
  Widget build(BuildContext context) {
    return _OnboardingIntro(
      onContinue: () async {
        final ok = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => const PermissionsScreen(onboarding: true),
          ),
        );
        if (context.mounted) Navigator.of(context).pop(ok == true);
      },
    );
  }
}

/// Onboarding screen 1 (design brief §4.1): line, units, Continue.
class _OnboardingIntro extends StatelessWidget {
  const _OnboardingIntro({required this.onContinue});
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final services = AppServices.of(context);
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) {
        final units = services.settings.settings.units;
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.screenGutter,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: Space.x48),
                  const TallyMark(height: 48),
                  const SizedBox(height: Space.x32),
                  Text('YOU AGAINST\nYOUR LAST RUN', style: text.displayMedium),
                  const SizedBox(height: Space.x16),
                  Text(
                    'Record a 4x4. Next time you get a verdict.',
                    style: text.bodyLarge?.copyWith(color: t.inkSecondary),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      for (final u in Units.values) ...[
                        Expanded(
                          child: _UnitChip(
                            label: u == Units.km ? 'km' : 'mi',
                            selected: units == u,
                            onTap: () => services.settings.update(
                              (s) => s.copyWith(units: u),
                            ),
                          ),
                        ),
                        if (u == Units.km) const SizedBox(width: Space.x12),
                      ],
                    ],
                  ),
                  const SizedBox(height: Space.x24),
                  FilledButton(
                    onPressed: onContinue,
                    child: const Text('CONTINUE'),
                  ),
                  const SizedBox(height: Space.x24),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _UnitChip extends StatelessWidget {
  const _UnitChip({
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
        borderRadius: BorderRadius.circular(Radii.button),
        child: Container(
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.button),
            border: Border.all(
              color: selected ? t.inkPrimary : t.lineHair,
              width: 2,
            ),
          ),
          child: Text(
            label,
            style: RunSoloType.title28.copyWith(
              color: selected ? t.inkPrimary : t.inkSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title, required this.line});
  final String title;
  final String line;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Padding(
        padding: const EdgeInsets.all(Space.screenGutter),
        child: Text(
          line,
          style: RunSoloType.body17.copyWith(color: t.inkSecondary),
        ),
      ),
    );
  }
}

/// Just enough Settings for Phase 1: strap, checklist, units, motion.
class _SettingsLite extends StatelessWidget {
  const _SettingsLite();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) {
        final s = services.settings.settings;
        Widget row(String label, String value, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.lineHair)),
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
        );
        return Scaffold(
          appBar: AppBar(title: const Text('SETTINGS')),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
            children: [
              row(
                'Units',
                s.units == Units.km ? 'km' : 'mi',
                () => services.settings.update(
                  (x) => x.copyWith(
                    units: x.units == Units.km ? Units.mi : Units.km,
                  ),
                ),
              ),
              row(
                'Heart rate strap',
                s.strap?.label ?? 'None',
                () => Navigator.of(context).pushNamed(Routes.pairing),
              ),
              row(
                'Setup checklist',
                '',
                () => Navigator.of(context).pushNamed(Routes.permissions),
              ),
              row(
                'Reduced motion',
                s.reducedMotion ? 'On' : 'Off',
                () => services.settings.update(
                  (x) => x.copyWith(reducedMotion: !x.reducedMotion),
                ),
              ),
              const SizedBox(height: Space.x24),
              Text(
                'Your runs never leave your phone.',
                style: RunSoloType.label13.copyWith(color: t.inkMuted),
              ),
            ],
          ),
        );
      },
    );
  }
}
