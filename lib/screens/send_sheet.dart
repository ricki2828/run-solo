import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/services.dart';
import '../state/send_runs.dart';
import '../theme/theme.dart';

/// Privacy promise, one line, on every Send surface (founder 2 Oct).
const String kSendPrivacyLine =
    'Runs stay on your phone unless you choose to send them.';

/// The Send sheet on run detail: every target, what each does, and where the
/// run already went. Resolves true when something was sent (run detail then
/// refreshes its state line).
Future<bool?> showSendSheet(
  BuildContext context, {
  required String runId,
  required engine.RunSidecar sidecar,
}) {
  final t = Theme.of(context).extension<RunSoloTokens>()!;
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: t.bgBase,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    ),
    builder: (_) => SendSheet(runId: runId, sidecar: sidecar),
  );
}

class SendSheet extends StatefulWidget {
  const SendSheet({super.key, required this.runId, required this.sidecar});
  final String runId;
  final engine.RunSidecar sidecar;

  @override
  State<SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends State<SendSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _share(ExportFormat format, {bool thenStrava = false}) async {
    final services = AppServices.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await services.sender.sendManual(
      widget.runId,
      ShareFileTarget.targetId,
      format: format,
    );
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _busy = false;
        _error = r.error;
      });
      return;
    }
    if (thenStrava) {
      final opened = await services.transfer.openUrl(
        Uri.parse(kStravaUploadUrl),
      );
      if (!mounted) return;
      if (!opened) {
        setState(() {
          _busy = false;
          _error = 'Could not open the browser';
        });
        return;
      }
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final settings = services.settings.settings;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.screenGutter,
          Space.x4,
          Space.screenGutter,
          Space.x24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'SEND THIS RUN',
              style: RunSoloType.title28.copyWith(color: t.inkPrimary),
            ),
            const SizedBox(height: Space.x8),
            Text(
              kSendPrivacyLine,
              key: const ValueKey('send-privacy'),
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x16),
            for (final target in services.sender.targets) ...[
              if (target.id == ShareFileTarget.targetId) ...[
                _Block(
                  label: target.label,
                  blurb: target.blurb,
                  state: sendStateLine(
                    target,
                    widget.sidecar.sends[target.id],
                    autoOn: target.isEnabled(settings),
                  ),
                  child: Wrap(
                    spacing: Space.x12,
                    runSpacing: Space.x8,
                    children: [
                      for (final f in ExportFormat.values)
                        _SheetButton(
                          key: ValueKey('send-${f.extension}'),
                          label: '${f.label} file',
                          onTap: _busy ? null : () => _share(f),
                        ),
                    ],
                  ),
                ),
                // Strava takes a file the runner uploads themselves.
                _Block(
                  label: 'Strava',
                  blurb: kStravaLine,
                  child: _SheetButton(
                    key: const ValueKey('send-strava'),
                    label: 'Open Strava upload page',
                    onTap: _busy
                        ? null
                        : () => _share(ExportFormat.tcx, thenStrava: true),
                  ),
                ),
              ] else
                _Block(
                  label: target.label,
                  blurb: target.comingSoon ? 'Coming soon' : target.blurb,
                  muted: target.comingSoon,
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: Space.x12),
              Text(
                _error!,
                key: const ValueKey('send-error'),
                style: RunSoloType.body15.copyWith(color: t.semWarn),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({
    required this.label,
    required this.blurb,
    this.state,
    this.child,
    this.muted = false,
  });
  final String label;
  final String blurb;
  final String? state;
  final Widget? child;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Space.x16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.lineHair)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: RunSoloType.body17.copyWith(
              color: muted ? t.inkMuted : t.inkPrimary,
            ),
          ),
          const SizedBox(height: Space.x4),
          Text(
            blurb,
            style: RunSoloType.label13.copyWith(
              color: muted ? t.inkMuted : t.inkSecondary,
            ),
          ),
          if (state != null) ...[
            const SizedBox(height: Space.x4),
            Text(
              state!,
              style: RunSoloType.label13.copyWith(color: t.inkSecondary),
            ),
          ],
          if (child != null) ...[const SizedBox(height: Space.x12), child!],
        ],
      ),
    );
  }
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        foregroundColor: t.inkPrimary,
        side: BorderSide(color: t.lineHair),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.button),
        ),
      ),
      child: Text(label, style: RunSoloType.body15),
    );
  }
}
