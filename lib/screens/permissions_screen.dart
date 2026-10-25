import 'package:flutter/material.dart';

import '../app/services.dart';
import '../platform/gateway.dart';
import '../platform/host_caps.dart';
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

    final privacy = <Widget>[
      // The full paragraph used to sit clipped and faded under the pinned
      // button on short phones. Both modes say the short version and open
      // the whole paragraph on a tap, and the rows come first.
      Text(
        kOnboardingInternetLine,
        key: const ValueKey('onboarding-privacy-short'),
        style: text.bodyMedium?.copyWith(color: t.inkSecondary),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const ValueKey('onboarding-privacy-more'),
          onPressed: () => _showPrivacy(context),
          child: Text(
            'Privacy details',
            style: text.labelLarge?.copyWith(color: t.inkPrimary),
          ),
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
        why: 'LAP and Pause from the lock screen, plus the phase countdown.',
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
          why: 'Some phones end a recording once the screen is off.',
          state: s.batteryUnrestricted ? SetupState.ok : SetupState.needed,
          onTap: () async {
            // Phase 2 backlog: in-app exemption prompt (system dialog),
            // the settings page is the gateway's own fallback.
            await perms.requestBatteryExemption();
            await _refresh();
          },
        ),
      ),
      if (HostCaps.strapPairing)
        SetupRow(
          icon: Icons.bluetooth,
          title: 'Nearby devices',
          why: 'Only for a heart-rate strap.',
          detail: _deniedHint(
            PermissionKind.bluetooth,
            'Denied. Allow it under',
          ),
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
      appBar: RunAppBar(
        title: widget.onboarding ? 'SET UP' : 'CHECKLIST',
        showBack: widget.onboarding ? false : null,
      ),
      body: PinnedFooterLayout(
        content: [
          const SizedBox(height: Space.x8),
          ...rows,
          const SizedBox(height: Space.x24),
          ...privacy,
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
          RunButton(
            label: widget.onboarding ? 'CONTINUE' : 'DONE',
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
          ),
          if (widget.onboarding) ...[
            const SizedBox(height: Space.x12),
            Center(
              child: TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
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

/// The full privacy paragraph, whole and readable, on a sheet.
Future<void> _showPrivacy(BuildContext context) {
  final t = Theme.of(context).extension<RunSoloTokens>()!;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: t.bgRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    ),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.screenGutter),
        child: Column(
          key: const ValueKey('privacy-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PRIVACY',
              style: RunSoloType.title28.copyWith(color: t.inkPrimary),
            ),
            const SizedBox(height: Space.x12),
            Text(
              kPrivacyParagraph,
              style: Theme.of(ctx).textTheme.bodyMedium
                  ?.copyWith(color: t.inkSecondary),
            ),
          ],
        ),
      ),
    ),
  );
}

/// A warn tint behind the row CONTINUE pointed at. A background, not a
/// border: a border moves the row (2 dp) or, as a foreground, cuts through
/// the NEEDED pill at the row's edge.
class _Marked extends StatelessWidget {
  const _Marked({super.key, required this.marked, required this.child});
  final bool marked;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.button),
        color: marked ? t.semWarn.withValues(alpha: 0.16) : Colors.transparent,
      ),
      child: child,
    );
  }
}
