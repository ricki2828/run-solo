import 'package:flutter/material.dart';

import '../app/services.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/setup_row.dart';
import 'settings_screen.dart';

/// Setup checklist (design brief §4.2, plan §10): each row explains why,
/// tap = the system prompt only. Denials stay red and honest; the only
/// deep-link is the battery-optimisation page. Location is the one hard
/// block for recording; everything else lets the runner continue.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key, this.onboarding = false});

  /// First-run flow: "Continue" instead of "Done", explains the app.
  final bool onboarding;

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  PermissionSnapshot? _snap;

  /// The battery row: the one NEEDED step CONTINUE can pass (location
  /// disables it). On a short phone it can sit below the fold, so the first
  /// CONTINUE with it undone scrolls to it and marks it instead of leaving
  /// (lead P2 on #30); the next CONTINUE goes on.
  final _batteryKey = GlobalKey();
  bool _neededShown = false;

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

  /// Back from a system settings page (battery, app info): re-read.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _snap ??= const PermissionSnapshot();
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await AppServices.of(context).permissions.status();
    if (mounted) setState(() => _snap = s);
  }

  /// Rows the runner asked for and Android refused; a second refusal is
  /// usually "don't ask again", so the copy points at app settings.
  final Set<PermissionKind> _denied = {};

  Future<void> _request(PermissionKind kind) async {
    final perms = AppServices.of(context).permissions;
    final granted = await perms.request(kind);
    final s = await perms.status();
    if (!mounted) return;
    setState(() {
      _snap = s;
      if (granted) {
        _denied.remove(kind);
      } else {
        _denied.add(kind);
      }
    });
  }

  String? _deniedHint(PermissionKind kind, String base) =>
      _denied.contains(kind)
      ? '$base Settings > Apps > Run Supreme > Permissions.'
      : null;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final s = _snap ?? const PermissionSnapshot();
    final perms = AppServices.of(context).permissions;

    final locationState = s.fineLocation && s.locationServicesOn
        ? SetupState.ok
        : (s.coarseOnly ? SetupState.blocked : SetupState.needed);
    final locationDetail = !s.locationServicesOn
        ? 'Location is off on this phone. Turn it on in quick settings.'
        : s.coarseOnly
        ? 'Approximate only. Choose Precise when asked, or GPS pace is off.'
        : _deniedHint(PermissionKind.location, 'Denied. Allow it under');

    // Set-up (onboarding) lists the rows first: on a short phone the
    // privacy text pushed "Battery optimisation off" under the fold, just
    // above CONTINUE (#30 review P2). The checklist keeps the text on top.
    final privacy = <Widget>[
      Text(
        kPrivacyParagraph,
        style: text.bodyMedium?.copyWith(color: t.inkSecondary),
      ),
      if (widget.onboarding)
        Padding(
          padding: const EdgeInsets.only(top: Space.x8),
          child: Text(
            kOnboardingInternetLine,
            style: text.bodyMedium?.copyWith(color: t.inkMuted),
          ),
        ),
    ];
    final rows = <Widget>[
      SetupRow(
        icon: Icons.location_on_outlined,
        title: 'Location while using',
        why: 'GPS is the pace. Precise, only while you record.',
        state: locationState,
        detail: locationDetail,
        onTap: () => _request(PermissionKind.location),
      ),
      SetupRow(
        icon: Icons.notifications_none,
        title: 'Notifications',
        why:
            'The run lives in a notification: LAP and Pause from the '
            'lock screen, phase countdown in your pocket.',
        state: s.notifications ? SetupState.ok : SetupState.blocked,
        detail: s.notifications
            ? null
            : _deniedHint(
                    PermissionKind.notifications,
                    'Denied: no lock-screen LAP. Allow it under',
                  ) ??
                  'Denied: no lock-screen LAP and Android may stop the run.',
        onTap: () => _request(PermissionKind.notifications),
      ),
      _Marked(
        key: _batteryKey,
        marked: _neededShown && !s.batteryUnrestricted,
        child: SetupRow(
          icon: Icons.battery_saver_outlined,
          title: 'Battery optimisation off',
          why:
              'Some phones kill a recording after a few minutes. '
              'Tap to let Run Supreme keep recording with the screen off.',
          state: s.batteryUnrestricted ? SetupState.ok : SetupState.needed,
          onTap: () async {
            // Phase 2 backlog: in-app exemption prompt (system dialog),
            // the settings page is the gateway's own fallback.
            await perms.requestBatteryExemption();
            await _refresh();
          },
        ),
      ),
      SetupRow(
        icon: Icons.bluetooth,
        title: 'Nearby devices',
        why: 'Only for a heart-rate strap. Skip it if you run without one.',
        detail: _deniedHint(PermissionKind.bluetooth, 'Denied. Allow it under'),
        state: s.bluetooth ? SetupState.ok : SetupState.optional,
        onTap: () => _request(PermissionKind.bluetooth),
      ),
      if (_denied.contains(PermissionKind.notifications) ||
          _denied.contains(PermissionKind.bluetooth)) ...[
        const SizedBox(height: Space.x12),
        TextButton(
          onPressed: perms.openAppSettings,
          child: Text(
            'Open app settings',
            style: text.labelLarge?.copyWith(color: t.inkPrimary),
          ),
        ),
      ],
    ];

    // Onboarding only: the checklist in Settings is a status page.
    final neededLeft = widget.onboarding && !s.batteryUnrestricted ? 1 : 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.onboarding ? 'SET UP' : 'CHECKLIST'),
        automaticallyImplyLeading: !widget.onboarding,
      ),
      body: PinnedFooterLayout(
        content: [
          const SizedBox(height: Space.x8),
          if (widget.onboarding) ...[
            ...rows,
            const SizedBox(height: Space.x24),
            ...privacy,
          ] else ...[
            ...privacy,
            const SizedBox(height: Space.x24),
            ...rows,
          ],
          const SizedBox(height: Space.x24),
        ],
        footer: [
          if (neededLeft > 0 && s.canRecord)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.x12),
              child: Text(
                neededLeft == 1
                    ? '1 needed step left'
                    : '$neededLeft needed steps left',
                key: const ValueKey('needed-left'),
                style: text.labelLarge?.copyWith(color: t.semWarn),
              ),
            ),
          if (!s.canRecord)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.x12),
              child: Text(
                'Recording needs precise location. Everything else can wait.',
                style: text.labelLarge?.copyWith(color: t.semDanger),
              ),
            ),
          FilledButton(
            onPressed: s.canRecord
                ? () async {
                    if (neededLeft > 0 && !_neededShown) {
                      setState(() => _neededShown = true);
                      final row = _batteryKey.currentContext;
                      if (row != null) {
                        await Scrollable.ensureVisible(
                          row,
                          duration: const Duration(milliseconds: 300),
                          alignment: 0.5,
                        );
                      }
                      return;
                    }
                    if (widget.onboarding) {
                      await AppServices.of(context).settings
                          .update((x) => x.copyWith(onboardingDone: true));
                    }
                    if (context.mounted) Navigator.of(context).pop(true);
                  }
                : null,
            child: Text(widget.onboarding ? 'CONTINUE' : 'DONE'),
          ),
          if (widget.onboarding) ...[
            const SizedBox(height: Space.x12),
            Center(
              child: TextButton(
                onPressed: () async {
                  await AppServices.of(context).settings
                      .update((x) => x.copyWith(onboardingDone: true));
                  if (context.mounted) Navigator.of(context).pop(false);
                },
                child: Text(
                  'Skip for now',
                  style: text.labelLarge?.copyWith(color: t.inkSecondary),
                ),
              ),
            ),
          ],
          const SizedBox(height: Space.x24),
        ],
      ),
    );
  }
}

/// A 2 dp warn outline around a row CONTINUE pointed at.
class _Marked extends StatelessWidget {
  const _Marked({super.key, required this.marked, required this.child});
  final bool marked;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    // Foreground: the outline never moves the row (an unmarked border would
    // shift every row below it by 2 dp).
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.button),
        border: Border.all(
          color: marked ? t.semWarn : Colors.transparent,
          width: 2,
        ),
      ),
      child: child,
    );
  }
}
