import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/perf_diagnostics.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../platform/host_caps.dart';
import '../state/max_hr.dart';
import '../state/intervals_icu.dart';
import '../state/recording_controller.dart';
import '../state/run_transfer.dart';
import '../state/send_runs.dart' show ExportTarget, HealthTarget, TargetSetup;
import '../state/settings.dart';
import '../topo/pack_manager.dart';
import '../topo/pack_models.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/hr_zones_section.dart';
import 'companion_screen.dart';
import 'intervals_connect_sheet.dart';
import 'send_sheet.dart' show kSendPrivacyLine;

/// Privacy copy (plan §18.6, addendum A7): one paragraph on every surface.
/// Store listing, About, privacy page and onboarding change together.
const String kPrivacyParagraph =
    'Your recorded route, times and heart rate stay on your phone unless you '
    'choose to send them. '
    'Map tiles come from Google, which sees the map area you view and your '
    'IP address. Weather comes from Open-Meteo using '
    'your location rounded to about 10 km. Your phone\'s own geocoder names '
    'a run\'s start point and may use Google Play services.';
const String kNoAnalyticsLine = 'No analytics of our own. No account. No ads.';
const String kOpenMeteoAttribution = 'Weather data by Open-Meteo.com';

/// About, when offline maps are in the build: whose data the Topo map draws.
/// Each installed pack adds its own credit lines (name, licence) below.
const String kTopoAttributionLine =
    'Offline maps: © OpenStreetMap contributors (ODbL), basemap tiles by '
    'Protomaps, terrain by Mapterhorn, with Copernicus DEM data.';
const String kOnboardingInternetLine =
    'Maps and weather use the internet. Runs stay on your phone unless you send them.';

/// Settings → Voice sublines (A10.7).
const String kCoachingTipsLine =
    'Where you stand and short tips, spoken at your splits.';

/// Settings → Recording → Auto-pause.
const String kAutoPauseLine =
    'Pauses when you stop, resumes when you move. Free, Goal and Laps runs; '
    'never in a timed rep or a test.';
const String kShowWhileRunningLine =
    'A 2 s card on the run screen when a rank is spoken.';

/// Credit lines of every installed pack, each once.
List<PackCredit> _packCredits(PackManager topo) {
  final seen = <String>{};
  return [
    for (final p in topo.installed)
      for (final c in p.region.credits)
        if (seen.add(c.text)) c,
  ];
}

/// Settings (design brief §4.11, plan D3 / §18): units, heart rate (strap,
/// max HR + source, reset observed max, pending-max sheet, birth year),
/// voice (cues, km splits, coaching tips, show while running; A10.7),
/// recording (screen on, volume-key lap, haptics, battery shortcut),
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

  /// Why a Send-runs target could not be switched on (permission refused,
  /// app missing), by target id.
  final Map<String, TargetSetup> _setupProblems = {};

  /// Switch an automatic target on or off. On: ask for what it needs first
  /// (a permission prompt from this tap); if that fails it stays off and the
  /// row says why.
  Future<void> _toggleAuto(ExportTarget target, bool on) async {
    final services = AppServices.of(context);
    if (on) {
      final setup = await target.prepare();
      if (!mounted) return;
      if (!setup.isReady) {
        setState(() => _setupProblems[target.id] = setup);
        return;
      }
    }
    setState(() => _setupProblems.remove(target.id));
    await services.settings.update(
      (x) => x.withAutoSend(target.id, on, services.now()),
    );
  }

  /// False on Android 14: the volume-key toggle is disabled with a reason.
  bool _volumeKeyLaps = true;
  bool _volumeKeyChecked = false;

  /// Lowest resting-HR proxy across the 30 newest runs, offered to the
  /// reserve method; null until history loads or when no run has one.
  int? _restingSuggestion;
  bool _suggestionLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _backfill.dispose();
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

  /// Switching Intervals.icu on without a key opens the Connect sheet first
  /// and only turns on once a key is saved.
  Future<void> _toggleIntervals(
    BuildContext context,
    IntervalsIcuTarget target,
    bool on,
    Future<void> Function(AppSettings Function(AppSettings)) set,
    DateTime now,
  ) async {
    if (on && !target.connected) {
      final saved = await showIntervalsConnectSheet(context, target: target);
      if (saved != true) return;
    }
    await set((x) => x.withAutoSend(target.id, on, now));
  }

  /// Backfill progress as (done, total); null when none is running.
  final ValueNotifier<(int, int)?> _backfill = ValueNotifier(null);

  /// "Send all past runs": permissions first, then confirm with the count,
  /// then one pass with inline progress. Idempotent (a health write replaces
  /// the record with the same run id).
  Future<void> _sendAllPast(ExportTarget target) async {
    final services = AppServices.of(context);
    final setup = await target.prepare();
    if (!mounted) return;
    if (!setup.isReady) {
      setState(() => _setupProblems[target.id] = setup);
      return;
    }
    final runs = [
      for (final r in await services.history.list())
        if (!r.missing) r,
    ];
    if (!mounted) return;
    if (runs.isEmpty) {
      _toast('No runs to send yet.');
      return;
    }
    final n = runs.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Send $n run${n == 1 ? '' : 's'} to ${target.label}?'),
        content: const Text('Runs already there are updated, not doubled.'),
        actions: [
          TextButton(
            key: const ValueKey('backfill-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            key: const ValueKey('backfill-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('SEND'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _backfill.value = (0, n);
    try {
      final r = await services.sender.sendAllPast(
        target.id,
        onProgress: (done, total) => _backfill.value = (done, total),
      );
      if (!mounted) return;
      if (r.failed == 0) {
        await services.settings.update(
          (x) => x.copyWith(
            pastRunsSent: {
              ...x.pastRunsSent,
              target.id: PastRunsSent(
                count: r.sent,
                at: services.now().toUtc(),
              ),
            },
          ),
        );
      }
      _toast(
        r.failed == 0
            ? 'Sent ${r.sent} run${r.sent == 1 ? '' : 's'} to ${target.label}.'
            : 'Sent ${r.sent} of ${r.total}. ${r.firstError ?? 'Some failed'}. '
                  'Tap Send all past runs to try the rest again.',
      );
    } finally {
      _backfill.value = null;
    }
  }

  /// "Move all runs (one file)": every run, edits and verdict in ONE
  /// gzipped file through the share sheet (logic in run_transfer.dart).
  Future<void> _moveRuns(BuildContext context) async {
    final services = AppServices.of(context);
    setState(() => _busy = true);
    try {
      final out = await RunTransfer(
        history: services.history,
        transfer: services.transfer,
        now: services.now,
      ).exportAll();
      if (out == null) {
        _toast('No runs to move yet.');
      } else {
        _toast(out.message);
      }
    } catch (e) {
      _toast('Could not move runs. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Import runs: the one-file export or the old per-run files, uuid dedupe.
  Future<void> _importRuns(BuildContext context) async {
    final services = AppServices.of(context);
    setState(() => _busy = true);
    try {
      final picked = await services.transfer.pickRunSources();
      if (picked.isEmpty) return;
      final result = await RunTransfer(
        history: services.history,
        transfer: services.transfer,
      ).importPicked(picked);
      // Plan §4: imported runs count against the backup budget too.
      final archived = await services.storage.enforceBackupBudget().catchError(
        (_) => <String>[],
      );
      _toast(
        '${result.summary}.'
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
    _loadRestingSuggestion();
    if (_volumeKeyChecked) return;
    _volumeKeyChecked = true;
    AppServices.of(context).permissions.volumeKeyLapsSupported().then((ok) {
      if (mounted && ok != _volumeKeyLaps) setState(() => _volumeKeyLaps = ok);
    });
  }

  void _loadRestingSuggestion() {
    if (_suggestionLoaded) return;
    _suggestionLoaded = true;
    AppServices.of(context).history.list().then((runs) {
      final recent = [...runs.where((r) => !r.missing)]
        ..sort((a, b) => b.start.compareTo(a.start));
      final bpm = [
        for (final r in recent.take(30))
          if (r.restingHrBpm != null) r.restingHrBpm!,
      ];
      if (!mounted || bpm.isEmpty) return;
      setState(() => _restingSuggestion = bpm.reduce((a, b) => a < b ? a : b));
    }, onError: (Object _) {});
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
          appBar: const RunAppBar(title: 'SETTINGS'),
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
              if (HostCaps.strapPairing)
                SettingsRow(
                  label: 'Strap',
                  value: s.strap?.label ?? 'Pair',
                  onTap: () => Navigator.of(context).pushNamed(Routes.pairing),
                ),
              SettingsRow(
                key: const ValueKey('max-hr-row'),
                label: 'Max HR',
                value: maxHrRowValue(resolved),
                valueColor: s.pendingObservedMaxHr != null ? t.semWarn : null,
                onTap: () => _maxHrSheet(context, now),
              ),
              SettingsRow(
                label: 'Birth year',
                value: s.birthYear == null ? 'Not entered' : '${s.birthYear}',
                onTap: () => _editNumber(
                  context,
                  title: 'BIRTH YEAR',
                  hint: 'Used for max heart rate (220 minus age) and age comparisons',
                  initial: s.birthYear,
                  validate: (v) => MaxHrRules.validBirthYear(v, now.year),
                  onSave: (v) => set(
                    (x) => v == null
                        ? x.copyWith(clearBirthYear: true)
                        : x.copyWith(birthYear: v),
                  ),
                ),
              ),
              HrZonesSection(
                settings: s,
                now: now,
                onChange: services.settings.update,
                restingSuggestion: _restingSuggestion,
              ),
              // A10.7: Profile, under Heart rate (birth year stays there).
              const _Section('Profile'),
              SettingsRow(
                key: const ValueKey('profile-sex'),
                label: 'Sex (for comparisons)',
                value: s.profileSex.label,
                onTap: () => _pickSex(context, s.profileSex, set),
              ),
              // A10.7: Voice sits above Recording; voice cues moved here.
              const _Section('Voice'),
              _Toggle(
                label: 'Voice cues',
                value: s.cues,
                onChanged: (v) => set((x) => x.copyWith(cues: v)),
              ),
              _Toggle(
                label: 'Km check-in (Free and Trail)',
                value: s.cues && s.kmSplits,
                onChanged: s.cues
                    ? (v) => set((x) => x.copyWith(kmSplits: v))
                    : null,
                reason: s.cues ? null : 'Turn on voice cues first',
              ),
              if (s.cues && s.kmSplits)
                SettingsRow(
                  key: const ValueKey('check-in-metrics'),
                  label: 'Check-in says',
                  value:
                      '${s.checkInMetrics.where(CheckInMetric.pickable.contains).length} of '
                      '${CheckInMetric.pickable.length}',
                  onTap: () => _pickCheckIn(context, s.checkInMetrics, set),
                ),
              _Toggle(
                label: 'Spoken summary',
                value: s.cues && s.spokenSummary,
                onChanged: s.cues
                    ? (v) => set((x) => x.copyWith(spokenSummary: v))
                    : null,
                reason: s.cues
                    ? 'Says what the run is at the start and how it went at the end.'
                    : 'Turn on voice cues first',
              ),
              _Toggle(
                label: 'Voice coaching',
                value: s.cues && s.voiceCoaching,
                onChanged: s.cues
                    ? (v) => set((x) => x.copyWith(voiceCoaching: v))
                    : null,
                reason: s.cues
                    ? 'Says what is next, and whether you are on pace.'
                    : 'Turn on voice cues first',
              ),
              if (s.cues && s.voiceCoaching)
                SettingsRow(
                  key: const ValueKey('coaching-detail'),
                  label: 'Coaching detail',
                  value: s.coachingDetail.label,
                  onTap: () => _pickDetail(context, s.coachingDetail, set),
                ),
              _Toggle(
                label: 'Coaching tips',
                value: s.tipsSpoken,
                onChanged: s.cues
                    ? (v) => set((x) => x.copyWith(coachingTips: v))
                    : null,
                reason: s.cues ? kCoachingTipsLine : 'Needs voice cues',
              ),
              _Toggle(
                label: 'Show while running',
                value: s.showWhileRunning,
                onChanged: (v) => set((x) => x.copyWith(showWhileRunning: v)),
                reason: kShowWhileRunningLine,
              ),
              const _Section('Recording'),
              SettingsRow(
                key: const ValueKey('countdown-row'),
                label: 'Countdown',
                value: _countdownLabel(s.countdownSeconds),
                onTap: () => _pickCountdown(context, s.countdownSeconds, set),
              ),
              _Toggle(
                label: 'Auto-pause',
                value: s.autoPause,
                onChanged: (v) {
                  set((x) => x.copyWith(autoPause: v));
                  services.recorder.setAutoPause(v);
                },
                reason: kAutoPauseLine,
              ),
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
              Padding(
                padding: const EdgeInsets.only(bottom: Space.x12),
                child: Text(
                  'True pace is your pace with the hills and the heat taken '
                  'out: what it would be on flat ground on a cool day. Every '
                  'comparison, score, board and trend uses it, and your '
                  'actual pace is always shown beside it. Hills come from an '
                  'energy model and heat from temperature and dew point '
                  '(research-based), so a run with no weather or no '
                  'barometer reading is only adjusted for what we know.',
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ),
              if (services.topo case final topo?)
                ListenableBuilder(
                  listenable: topo,
                  builder: (context, _) => SettingsRow(
                    label: 'Offline maps',
                    value: topo.installed.isEmpty
                        ? ''
                        : '${topo.installed.length} on phone',
                    onTap: () =>
                        Navigator.of(context).pushNamed(Routes.offlineMaps),
                  ),
                ),
              SettingsRow(
                label: 'Move all runs (one file)',
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
                  'Save the file to Drive or Files, then open Import runs in '
                  'the other Run Supreme (runs already there are skipped).',
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ),
              if (services.companion case final companion?) ...[
                const _Section('Companion'),
                ListenableBuilder(
                  listenable: companion,
                  builder: (context, _) => SettingsRow(
                    label: 'Run companion',
                    value: companion.enrolled ? 'On' : 'Off',
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => const CompanionScreen(),
                      ),
                    ),
                  ),
                ),
              ],
              const _Section('Send runs to'),
              Padding(
                padding: const EdgeInsets.only(bottom: Space.x8),
                child: Text(
                  kSendPrivacyLine,
                  key: const ValueKey('send-settings-line'),
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ),
              for (final target in services.sender.targets.where(
                (t) => t.listed,
              )) ...[
                if (target is HealthTarget && !HostCaps.healthExport)
                  const SizedBox.shrink()
                else if (target is IntervalsIcuTarget)
                  ListenableBuilder(
                    listenable: target,
                    builder: (context, _) => Column(
                      children: [
                        _Toggle(
                          label: target.label,
                          value: target.isEnabled(s) && target.connected,
                          onChanged: (v) => _toggleIntervals(
                            context,
                            target,
                            v,
                            set,
                            services.now(),
                          ),
                          reason: target.connected
                              ? 'Sends each run when it finishes.'
                              : 'Connect your account to switch it on.',
                        ),
                        SettingsRow(
                          label: target.connected
                              ? 'Manage connection'
                              : 'Connect',
                          value: target.connected
                              ? 'Connected'
                              : 'Not connected',
                          onTap: () => showIntervalsConnectSheet(
                            context,
                            target: target,
                          ),
                        ),
                      ],
                    ),
                  )
                else if (target.supportsAutomatic)
                  _Toggle(
                    label: target.label,
                    value: target.isEnabled(s),
                    onChanged: target.comingSoon
                        ? null
                        : (v) => _toggleAuto(target, v),
                    reason: target.comingSoon
                        ? 'Coming soon'
                        : _setupProblems[target.id]?.message ??
                              'Sends each run when it finishes.',
                  )
                else
                  _StaticRow(
                    label: target.label,
                    reason: 'Only when you tap Send on a run.',
                  ),
                if (target is HealthTarget && target.isEnabled(s))
                  ValueListenableBuilder<(int, int)?>(
                    valueListenable: _backfill,
                    builder: (context, p, _) => p == null
                        ? switch (s.pastRunsSent[target.id]) {
                            final done? => SettingsRow(
                              key: const ValueKey('backfill-done'),
                              label:
                                  'All ${done.count} past run'
                                  '${done.count == 1 ? '' : 's'} sent on '
                                  '${Fmt.dayMonth(done.at.toLocal())}',
                              value: 'Send again',
                              onTap: () => _sendAllPast(target),
                            ),
                            null => SettingsRow(
                              label: 'Send all past runs',
                              value: '',
                              onTap: () => _sendAllPast(target),
                            ),
                          }
                        : Padding(
                            key: const ValueKey('backfill-progress'),
                            padding: const EdgeInsets.symmetric(
                              vertical: Space.x12,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Sending ${p.$1} of ${p.$2}',
                                  style: RunSoloType.body15.copyWith(
                                    color: t.inkPrimary,
                                  ),
                                ),
                                const SizedBox(height: Space.x8),
                                LinearProgressIndicator(
                                  value: p.$2 == 0 ? null : p.$1 / p.$2,
                                  minHeight: 6,
                                  color: t.inkPrimary,
                                  backgroundColor: t.bgSunken,
                                ),
                              ],
                            ),
                          ),
                  ),
                if (_setupProblems[target.id]?.canInstall ?? false)
                  SettingsRow(
                    label: 'Open the Play Store',
                    value: '',
                    onTap: target.openInstall,
                  ),
              ],
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
              if (services.topo case final topo?)
                ListenableBuilder(
                  listenable: topo,
                  builder: (context, _) => Column(
                    key: const ValueKey('topo-credits'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: Space.x8),
                      Text(
                        kTopoAttributionLine,
                        style: RunSoloType.label13.copyWith(
                          color: t.inkSecondary,
                        ),
                      ),
                      for (final c in _packCredits(topo))
                        Padding(
                          padding: const EdgeInsets.only(top: Space.x4),
                          child: Text(
                            c.license == null
                                ? c.text
                                : '${c.text} (${c.license})',
                            style: RunSoloType.micro11.copyWith(
                              color: t.inkSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              if (kPerfDiagnostics) ...[
                const _Section('Diagnostics'),
                ListenableBuilder(
                  listenable: PerfDiagnostics.instance,
                  builder: (context, _) => Column(
                    key: const ValueKey('perf-diagnostics'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in PerfDiagnostics.instance.lines)
                        Padding(
                          padding: const EdgeInsets.only(top: Space.x8),
                          child: Text(
                            line,
                            style: RunSoloType.label13.copyWith(
                              color: t.inkSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: Space.x32),
            ],
          ),
        );
      },
    );
  }

  /// A10.7: three choices and why it is asked; "Not set" stays until one
  /// is picked.
  Future<void> _pickSex(
    BuildContext context,
    ProfileSex current,
    Future<void> Function(AppSettings Function(AppSettings)) set,
  ) async {
    final picked = await showModalBottomSheet<ProfileSex>(
      context: context,
      builder: (context) {
        final t = Theme.of(context).extension<RunSoloTokens>()!;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Space.screenGutter),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('SEX (FOR COMPARISONS)', style: RunSoloType.title28),
                const SizedBox(height: Space.x8),
                Text(
                  'Only used to compare your estimates with research '
                  'tables. It stays on this phone.',
                  style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                ),
                const SizedBox(height: Space.x8),
                RadioGroup<ProfileSex>(
                  groupValue: current,
                  onChanged: (v) => Navigator.of(context).pop(v),
                  child: Column(
                    children: [
                      for (final o in const [
                        ProfileSex.male,
                        ProfileSex.female,
                        ProfileSex.preferNot,
                      ])
                        RadioListTile<ProfileSex>(
                          key: ValueKey('sex-${o.name}'),
                          value: o,
                          contentPadding: EdgeInsets.zero,
                          title: Text(o.label),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) await set((x) => x.copyWith(profileSex: picked));
  }

  Future<void> _pickDetail(
    BuildContext context,
    CoachingDetail current,
    Future<void> Function(AppSettings Function(AppSettings)) set,
  ) async {
    final picked = await showModalBottomSheet<CoachingDetail>(
      context: context,
      builder: (context) {
        final t = Theme.of(context).extension<RunSoloTokens>()!;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Space.screenGutter),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('COACHING DETAIL', style: RunSoloType.title28),
                const SizedBox(height: Space.x8),
                Text(
                  'How much the voice says while you run.',
                  style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                ),
                const SizedBox(height: Space.x8),
                RadioGroup<CoachingDetail>(
                  groupValue: current,
                  onChanged: (v) => Navigator.of(context).pop(v),
                  child: Column(
                    children: [
                      for (final o in CoachingDetail.values)
                        RadioListTile<CoachingDetail>(
                          key: ValueKey('coaching-detail-${o.name}'),
                          value: o,
                          contentPadding: EdgeInsets.zero,
                          title: Text(o.label),
                          subtitle: Text(o.blurb),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) await set((x) => x.copyWith(coachingDetail: picked));
  }

  static String _countdownLabel(int seconds) =>
      seconds == 0 ? 'Off' : '$seconds s';

  /// Recording -> Countdown: the 3-2-1-GO after START on the Ready screen.
  Future<void> _pickCountdown(
    BuildContext context,
    int current,
    Future<void> Function(AppSettings Function(AppSettings)) set,
  ) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (context) {
        final t = Theme.of(context).extension<RunSoloTokens>()!;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Space.screenGutter),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('COUNTDOWN', style: RunSoloType.title28),
                const SizedBox(height: Space.x8),
                Text(
                  'A 3-2-1-GO after you tap START. Recording starts at GO. '
                  'Tap the screen to cancel.',
                  style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                ),
                const SizedBox(height: Space.x8),
                RadioGroup<int>(
                  groupValue: current,
                  onChanged: (v) => Navigator.of(context).pop(v),
                  child: Column(
                    children: [
                      for (final o in AppSettings.countdownChoices)
                        RadioListTile<int>(
                          key: ValueKey('countdown-$o'),
                          value: o,
                          contentPadding: EdgeInsets.zero,
                          title: Text(_countdownLabel(o)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) await set((x) => x.copyWith(countdownSeconds: picked));
  }

  /// Which metrics the km check-in says. Importance order is fixed (the
  /// list order); a metric with no data is skipped when it comes up.
  Future<void> _pickCheckIn(
    BuildContext context,
    List<CheckInMetric> current,
    Future<void> Function(AppSettings Function(AppSettings)) set,
  ) async {
    final picked = await showModalBottomSheet<List<CheckInMetric>>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final t = Theme.of(context).extension<RunSoloTokens>()!;
        final chosen = {...current};
        return StatefulBuilder(
          builder: (context, setSheet) => SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Space.screenGutter),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('CHECK-IN SAYS', style: RunSoloType.title28),
                  const SizedBox(height: Space.x8),
                  Text(
                    'Said at each km, most important first. Anything with no '
                    'data is skipped, and the line stays short. Changes '
                    'apply from your next run.',
                    style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                  ),
                  const SizedBox(height: Space.x8),
                  for (final m in CheckInMetric.pickable)
                    CheckboxListTile(
                      key: ValueKey('check-in-${m.name}'),
                      value: chosen.contains(m),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(m.label),
                      subtitle: Text(m.blurb),
                      onChanged: (v) => setSheet(
                        () => v == true ? chosen.add(m) : chosen.remove(m),
                      ),
                    ),
                  const SizedBox(height: Space.x8),
                  FilledButton(
                    key: const ValueKey('check-in-done'),
                    onPressed: () => Navigator.of(context).pop([
                      for (final m in CheckInMetric.values)
                        if (chosen.contains(m)) m,
                    ]),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked != null) await set((x) => x.copyWith(checkInMetrics: picked));
  }

  /// One Max HR row opens this: the entered value, the observed value, the
  /// strap reading waiting for review, and reset. Presentation only; the
  /// zones read the same resolved value as before.
  Future<void> _maxHrSheet(BuildContext context, DateTime now) async {
    final services = AppServices.of(context);
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.bgRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: services.settings,
          builder: (ctx, _) {
            final s = services.settings.settings;
            final r = MaxHr.resolve(s, now);
            return Padding(
              padding: const EdgeInsets.all(Space.screenGutter),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const RunSheetHeader(
                    key: ValueKey('max-hr-sheet'),
                    title: 'MAX HR',
                  ),
                  const SizedBox(height: Space.x8),
                  Text(
                    'Zones use ${r.maxHr}, ${maxHrSourceWords(r)}.',
                    key: const ValueKey('max-hr-sheet-summary'),
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                  SettingsRow(
                    key: const ValueKey('max-hr-entered'),
                    label: 'Entered',
                    value: s.typedMaxHr == null
                        ? 'Not entered'
                        : '${s.typedMaxHr}',
                    onTap: () => _editNumber(
                      ctx,
                      title: 'MAX HR',
                      hint:
                          'Beats per minute, ${MaxHrRules.min}–${MaxHrRules.max}',
                      initial: s.typedMaxHr,
                      validate: MaxHrRules.validTyped,
                      onSave: (v) => services.settings.update(
                        (x) => v == null
                            ? x.copyWith(clearTypedMaxHr: true)
                            : x.copyWith(typedMaxHr: v),
                      ),
                    ),
                  ),
                  SettingsRow(
                    key: const ValueKey('max-hr-observed'),
                    label: 'Seen on your strap',
                    value: s.observedMaxHr == null
                        ? 'None yet'
                        : '${s.observedMaxHr}',
                    onTap: null,
                  ),
                  if (s.pendingObservedMaxHr != null)
                    SettingsRow(
                      key: const ValueKey('max-hr-pending'),
                      label: 'Strap saw ${s.pendingObservedMaxHr} bpm',
                      value: 'Review',
                      valueColor: t.semWarn,
                      onTap: () => showPendingMaxSheet(ctx),
                    ),
                  SettingsRow(
                    key: const ValueKey('max-hr-reset'),
                    label: 'Reset observed max',
                    value: '',
                    onTap:
                        s.observedMaxHr == null &&
                            s.pendingObservedMaxHr == null
                        ? null
                        : () => services.settings.update(
                            (x) => x.copyWith(
                              clearObservedMaxHr: true,
                              clearPendingObservedMaxHr: true,
                            ),
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
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
              RunSheetHeader(title: title),
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
/// The one line under run detail's time in zone: which zones were used.
String zonesSourceLine(engine.HrZoneMethod m, MaxHrResolution r) => switch (m) {
  engine.HrZoneMethod.percentMax => maxHrSourceLine(r),
  engine.HrZoneMethod.reserve => 'Heart rate reserve zones, max HR ${r.maxHr}',
  engine.HrZoneMethod.custom => 'Your custom zones',
};

/// The Settings row value: "192 · seen on your strap" / "185 · you entered".
String maxHrRowValue(MaxHrResolution r) =>
    '${r.maxHr} · ${switch (r.source) {
      MaxHrSource.observed => 'seen on your strap',
      MaxHrSource.typed => 'you entered',
      MaxHrSource.age => 'from your age',
      MaxHrSource.fallback => 'default',
    }}';

/// Lower-case source phrase for the sheet summary.
String maxHrSourceWords(MaxHrResolution r) => switch (r.source) {
  MaxHrSource.observed => 'seen on your strap',
  MaxHrSource.typed => 'entered by you',
  MaxHrSource.age => 'from your age',
  MaxHrSource.fallback => 'the default until you enter one',
};

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
            RunSheetHeader(
              key: const ValueKey('pending-max-sheet'),
              title: 'STRAP SAW $pending BPM',
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

/// A settings line with no switch: the target has no automatic mode.
class _StaticRow extends StatelessWidget {
  const _StaticRow({required this.label, required this.reason});
  final String label;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineHair)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: RunSoloType.body17.copyWith(color: t.inkPrimary)),
          Text(
            reason,
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
        ],
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
