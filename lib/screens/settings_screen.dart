import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/max_hr.dart';
import '../state/recording_controller.dart';
import '../state/settings.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';

/// Privacy copy (plan §18.6, addendum A7): one paragraph on every surface.
/// Store listing, About, privacy page and onboarding change together.
const String kPrivacyParagraph =
    'Your recorded route, times and heart rate stay on your phone. '
    'Map tiles come from Google, which sees the map area you view and your '
    'IP address, like any maps app. Weather comes from Open-Meteo using '
    'your location rounded to about 10 km.';
const String kNoAnalyticsLine = 'No analytics of our own. No account. No ads.';
const String kOpenMeteoAttribution = 'Weather data by Open-Meteo.com';
const String kOnboardingInternetLine =
    'Maps and weather use the internet. Your recorded run stays on the phone.';

/// Settings (design brief §4.11, plan D3 / §18): units, heart rate (strap,
/// max HR + source, reset observed max, pending-max sheet, birth year),
/// recording (screen on, volume-key lap, cues, haptics, battery shortcut),
/// motion, about with the §18.6 privacy paragraph.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.now});
  final DateTime Function()? now;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  PermissionSnapshot? _perms;
  bool _busy = false;

  /// False on Android 14: the volume-key toggle is disabled with a reason.
  bool _volumeKeyLaps = true;
  bool _volumeKeyChecked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from the system battery page: re-read the exemption.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPerms();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Plan §4 export: one `RunBundle` JSON per run (file + sidecar) through
  /// the share sheet, so the dogfood build's runs reach the Play build.
  Future<void> _moveRuns(BuildContext context) async {
    final services = AppServices.of(context);
    setState(() => _busy = true);
    try {
      final bundles = await services.history.exportBundles();
      if (bundles.isEmpty) {
        _toast('No runs to move yet.');
        return;
      }
      final dir = await Directory.systemTemp.createTemp('runsolo-export-');
      final paths = <String>[];
      for (final b in bundles) {
        final f = File('${dir.path}/run-${b.run.id}.runsupreme.json');
        await f.writeAsString(engine.RunBundleCodec.encode(b), flush: true);
        paths.add(f.path);
      }
      await services.transfer.shareFiles(
        paths,
        subject:
            'Run Supreme: ${bundles.length} run${bundles.length == 1 ? '' : 's'}',
      );
    } catch (e) {
      _toast('Could not move runs. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Plan §4 import: SAF pick, decode each document (export or bare run
  /// file, v1 or v2), uuid dedupe, write run + sidecar.
  Future<void> _importRuns(BuildContext context) async {
    final services = AppServices.of(context);
    setState(() => _busy = true);
    try {
      final picked = await services.transfer.pickFiles();
      if (picked.isEmpty) return;
      final bundles = <engine.RunBundle>[];
      var unreadable = 0;
      for (final f in picked) {
        try {
          bundles.add(engine.RunBundleCodec.decode(f.text));
        } on engine.RunFileNewerVersionException {
          unreadable += 1;
        } on engine.RunFileFormatException {
          unreadable += 1;
        }
      }
      final result = await services.history.importBundles(bundles);
      // Plan §4: imported runs count against the backup budget too.
      final archived = await services.storage.enforceBackupBudget().catchError(
        (_) => <String>[],
      );
      final parts = <String>[
        'Imported ${result.imported}',
        if (result.alreadyOnDeviceIds.isNotEmpty)
          '${result.alreadyOnDeviceIds.length} already here (edits not merged)',
        if (result.duplicateIds.isNotEmpty)
          '${result.duplicateIds.length} repeated in the files',
        if (unreadable > 0) '$unreadable not Run Supreme files',
      ];
      _toast(
        '${parts.join(', ')}.'
        '${archived.isEmpty ? '' : ' ${archived.length} older runs are past '
                  'the backup budget: move runs to another Run Supreme to keep them safe.'}',
      );
    } catch (e) {
      _toast('Could not import. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshPerms();
    if (_volumeKeyChecked) return;
    _volumeKeyChecked = true;
    AppServices.of(context).permissions.volumeKeyLapsSupported().then((ok) {
      if (mounted && ok != _volumeKeyLaps) setState(() => _volumeKeyLaps = ok);
    });
  }

  void _refreshPerms() {
    AppServices.of(context).permissions.status().then((p) {
      if (mounted) setState(() => _perms = p);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final now = (widget.now ?? services.now)();
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) {
        final s = services.settings.settings;
        final resolved = MaxHr.resolve(s, now);
        Future<void> set(AppSettings Function(AppSettings) f) =>
            services.settings.update(f);
        return Scaffold(
          appBar: AppBar(title: const Text('SETTINGS')),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
            children: [
              const _Section('Units'),
              SettingsRow(
                label: 'Units',
                value: s.units == Units.km ? 'km' : 'mi',
                onTap: () => set(
                  (x) => x.copyWith(
                    units: x.units == Units.km ? Units.mi : Units.km,
                  ),
                ),
              ),
              const _Section('Heart rate'),
              SettingsRow(
                label: 'Strap',
                value: s.strap?.label ?? 'Pair',
                onTap: () => Navigator.of(context).pushNamed(Routes.pairing),
              ),
              SettingsRow(
                label: 'Max HR (entered)',
                value: s.typedMaxHr == null ? 'Not entered' : '${s.typedMaxHr}',
                onTap: () => _editNumber(
                  context,
                  title: 'MAX HR',
                  hint: 'Beats per minute, ${MaxHrRules.min}–${MaxHrRules.max}',
                  initial: s.typedMaxHr,
                  validate: MaxHrRules.validTyped,
                  onSave: (v) => set(
                    (x) => v == null
                        ? x.copyWith(clearTypedMaxHr: true)
                        : x.copyWith(typedMaxHr: v),
                  ),
                ),
              ),
              SettingsRow(
                label: 'Birth year',
                value: s.birthYear == null ? 'Not entered' : '${s.birthYear}',
                onTap: () => _editNumber(
                  context,
                  title: 'BIRTH YEAR',
                  hint: 'Used for 220 minus age when no max HR is entered',
                  initial: s.birthYear,
                  validate: (v) => MaxHrRules.validBirthYear(v, now.year),
                  onSave: (v) => set(
                    (x) => v == null
                        ? x.copyWith(clearBirthYear: true)
                        : x.copyWith(birthYear: v),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.x12),
                child: Text(
                  maxHrSourceLine(resolved),
                  key: const ValueKey('max-hr-source'),
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ),
              if (s.pendingObservedMaxHr != null)
                SettingsRow(
                  label: 'Strap saw ${s.pendingObservedMaxHr} bpm',
                  value: 'Review',
                  valueColor: t.semWarn,
                  onTap: () => showPendingMaxSheet(context),
                ),
              SettingsRow(
                label: 'Reset observed max',
                value: s.observedMaxHr == null ? '' : '${s.observedMaxHr}',
                onTap: s.observedMaxHr == null && s.pendingObservedMaxHr == null
                    ? null
                    : () => set(
                        (x) => x.copyWith(
                          clearObservedMaxHr: true,
                          clearPendingObservedMaxHr: true,
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: Space.x8),
                child: Text(
                  'Zones: 1 under 60 %, 2 to 70 %, 3 to 80 %, 4 to 90 %, 5 above. '
                  'The 4x4 band is 85 to 95 % of max.',
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ),
              const _Section('Recording'),
              _Toggle(
                label: 'Keep screen on',
                value: s.keepScreenOn,
                onChanged: (v) => set((x) => x.copyWith(keepScreenOn: v)),
              ),
              _Toggle(
                label: 'Volume-key lap (Laps run)',
                value: _volumeKeyLaps && s.volumeKeyLapFor(RecordMode.laps),
                onChanged: _volumeKeyLaps
                    ? (v) => set((x) => x.copyWith(volumeKeyLap: v))
                    : null,
                reason: _volumeKeyLaps ? null : kVolumeKeyToggleReason,
              ),
              _Toggle(
                label: 'Voice cues',
                value: s.cues,
                onChanged: (v) => set((x) => x.copyWith(cues: v)),
              ),
              _Toggle(
                label: 'Haptics',
                value: s.haptics,
                onChanged: (v) => set((x) => x.copyWith(haptics: v)),
              ),
              _BatteryRow(
                perms: _perms,
                onTap: () async {
                  await services.permissions.requestBatteryExemption();
                  _refreshPerms();
                },
              ),
              SettingsRow(
                label: 'Setup checklist',
                value: '',
                onTap: () =>
                    Navigator.of(context).pushNamed(Routes.permissions),
              ),
              const _Section('Data'),
              _Toggle(
                label: 'Weather for each run',
                value: s.weatherPerRun,
                onChanged: (v) => set((x) => x.copyWith(weatherPerRun: v)),
              ),
              SettingsRow(
                label: 'Move runs to another Run Supreme',
                value: _busy ? 'Working' : '',
                onTap: _busy ? null : () => _moveRuns(context),
              ),
              SettingsRow(
                label: 'Import runs',
                value: _busy ? 'Working' : '',
                onTap: _busy ? null : () => _importRuns(context),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.x12),
                child: Text(
                  'Each run travels as one file with its edits and verdict. '
                  'Runs already on the receiving phone are skipped.',
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ),
              const _Section('Motion'),
              _Toggle(
                label: 'Reduced motion',
                value: s.reducedMotion,
                onChanged: (v) => set((x) => x.copyWith(reducedMotion: v)),
              ),
              const _Section('About'),
              const SizedBox(height: Space.x8),
              Text(
                'RUN SUPREME',
                style: RunSoloType.title28.copyWith(
                  color: t.inkPrimary,
                  letterSpacing: 28 * 0.02,
                ),
              ),
              const SizedBox(height: Space.x12),
              Text(
                kPrivacyParagraph,
                key: const ValueKey('privacy-paragraph'),
                style: RunSoloType.body15.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x8),
              Text(
                kNoAnalyticsLine,
                style: RunSoloType.body15.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x8),
              Text(
                kOpenMeteoAttribution,
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x32),
            ],
          ),
        );
      },
    );
  }

  Future<void> _editNumber(
    BuildContext context, {
    required String title,
    required String hint,
    required int? initial,
    required bool Function(int) validate,
    required Future<void> Function(int?) onSave,
  }) async {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final ctl = TextEditingController(text: initial?.toString() ?? '');
    String? error;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.bgRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            Space.screenGutter,
            Space.x24,
            Space.screenGutter,
            Space.x24 + MediaQuery.viewInsetsOf(ctx).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: RunSoloType.title28.copyWith(color: t.inkPrimary),
              ),
              const SizedBox(height: Space.x8),
              Text(
                hint,
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x16),
              TextField(
                controller: ctl,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: RunSoloType.display44.copyWith(color: t.inkPrimary),
                decoration: InputDecoration(
                  errorText: error,
                  border: InputBorder.none,
                ),
              ),
              const SizedBox(height: Space.x16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () async {
                        await onSave(null);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: Text(
                        'CLEAR',
                        style: RunSoloType.label13.copyWith(
                          color: t.inkSecondary,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: () async {
                        final v = int.tryParse(ctl.text);
                        if (v == null || !validate(v)) {
                          setSheet(() => error = 'Outside the allowed range.');
                          return;
                        }
                        await onSave(v);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('SAVE'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Max HR 192, seen on your strap 3 Sep" / "Max HR 185, entered" /
/// "Max HR 180, from your age" / "Max HR 190, default".
String maxHrSourceLine(MaxHrResolution r) => switch (r.source) {
  MaxHrSource.observed =>
    'Max HR ${r.maxHr}, seen on your strap${r.observedAt == null ? '' : ' ${Fmt.dayDate(r.observedAt!)}'}',
  MaxHrSource.typed => 'Max HR ${r.maxHr}, entered',
  MaxHrSource.age => 'Max HR ${r.maxHr}, from your age',
  MaxHrSource.fallback => 'Max HR ${r.maxHr}, default until you enter one',
};

/// The artefact-guard confirm sheet (D3 rule 5): an observed 30 s value more
/// than 15 above the typed max, or above 220, is never applied silently.
Future<void> showPendingMaxSheet(BuildContext context) async {
  final services = AppServices.of(context);
  final t = Theme.of(context).extension<RunSoloTokens>()!;
  final pending = services.settings.settings.pendingObservedMaxHr;
  if (pending == null) return;
  final current = services.maxHr.maxHr;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: t.bgRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.screenGutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'STRAP SAW $pending BPM',
              key: const ValueKey('pending-max-sheet'),
              style: RunSoloType.title28.copyWith(color: t.inkPrimary),
            ),
            const SizedBox(height: Space.x12),
            Text(
              'That is well above your max HR of $current. A dry strap can '
              'spike for 30 s. Use $pending as your max, or ignore it?',
              style: RunSoloType.body17.copyWith(color: t.inkPrimary),
            ),
            const SizedBox(height: Space.x24),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () async {
                      await services.settings.update(
                        (x) => x.copyWith(clearPendingObservedMaxHr: true),
                      );
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: Text(
                      'IGNORE',
                      style: RunSoloType.label13.copyWith(
                        color: t.inkSecondary,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () async {
                      await services.settings.update(
                        (x) => x.copyWith(
                          observedMaxHr: pending,
                          observedMaxHrAt: services.now(),
                          clearPendingObservedMaxHr: true,
                        ),
                      );
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: Text('USE $pending'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(top: Space.x24, bottom: Space.x8),
      child: Text(
        title.toUpperCase(),
        style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
      ),
    );
  }
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.valueColor,
  });
  final String label;
  final String value;
  final VoidCallback? onTap;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: onTap != null,
      label: label,
      child: InkWell(
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
                  style: RunSoloType.body17.copyWith(
                    color: onTap == null ? t.inkMuted : t.inkPrimary,
                  ),
                ),
              ),
              Text(
                value,
                style: RunSoloType.label13.copyWith(
                  color: valueColor ?? t.inkSecondary,
                ),
              ),
              const SizedBox(width: Space.x8),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: onTap == null ? t.inkMuted : t.inkSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.value,
    required this.onChanged,
    this.reason,
  });
  final String label;
  final bool value;

  /// Null disables the switch.
  final ValueChanged<bool>? onChanged;

  /// One line under the label, e.g. why the switch is disabled.
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineHair)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: RunSoloType.body17.copyWith(
                    color: onChanged == null ? t.inkSecondary : t.inkPrimary,
                  ),
                ),
                if (reason != null)
                  Text(
                    reason!,
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
              ],
            ),
          ),
          Semantics(
            label: label,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: t.bgBase,
              activeTrackColor: t.inkPrimary,
              inactiveThumbColor: t.inkSecondary,
              inactiveTrackColor: t.bgRaised,
            ),
          ),
        ],
      ),
    );
  }
}

/// Battery shortcut row (Phase 2 backlog): one line of why, opens the
/// system battery page via the gateway; the pill refreshes on resume.
class _BatteryRow extends StatelessWidget {
  const _BatteryRow({required this.perms, required this.onTap});
  final PermissionSnapshot? perms;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final ok = perms?.batteryUnrestricted ?? false;
    return Semantics(
      button: true,
      label: 'Battery optimisation',
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Battery optimisation',
                      style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                    ),
                    Text(
                      ok
                          ? 'Off for Run Supreme. Recording survives a long run with the screen off.'
                          : 'Android can stop recording mid-run. Tap to allow Run Supreme to keep going.',
                      style: RunSoloType.label13.copyWith(
                        color: ok ? t.inkSecondary : t.semWarn,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.x8),
              StatusPill(
                label: ok ? 'OK' : 'NEEDED',
                tone: ok ? PillTone.ok : PillTone.warn,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
