import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'chrome.dart';

enum SetupState { needed, ok, optional, blocked }

/// Permission / checklist row (design brief §4.2): icon, label, one line of
/// why, status pill; the whole row is the 56 dp tap target.
class SetupRow extends StatelessWidget {
  const SetupRow({
    super.key,
    required this.icon,
    required this.title,
    required this.why,
    required this.state,
    required this.onTap,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String why;
  final SetupState state;
  final VoidCallback? onTap;

  /// Extra red line under [why], e.g. "Approximate only. Choose Precise."
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final pill = switch (state) {
      SetupState.ok => const StatusPill(label: 'OK', tone: PillTone.ok),
      SetupState.needed => const StatusPill(
        label: 'NEEDED',
        tone: PillTone.warn,
      ),
      SetupState.blocked => const StatusPill(
        label: 'DENIED',
        tone: PillTone.danger,
      ),
      SetupState.optional => const StatusPill(
        label: 'OPTIONAL',
        tone: PillTone.muted,
      ),
    };
    return Semantics(
      button: onTap != null,
      label: '$title, ${state.name}',
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(vertical: Space.x12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.lineHair)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 24,
                color: state == SetupState.ok ? t.inkPrimary : t.inkSecondary,
              ),
              const SizedBox(width: Space.x16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      why,
                      style: RunSoloType.label13.copyWith(
                        color: t.inkSecondary,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        detail!,
                        style: RunSoloType.label13.copyWith(color: t.semDanger),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Space.x12),
              pill,
            ],
          ),
        ),
      ),
    );
  }
}
