import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';

/// Preset editor row: label, big tabular value, 56 dp minus / plus. A locked
/// row (work 4:00 in v1, plan §6) shows the value with no controls. Holding
/// minus / plus repeats (A8: 400 ms delay, then every 120 ms).
class ValueStepper extends StatelessWidget {
  const ValueStepper({
    super.key,
    required this.label,
    required this.value,
    this.onMinus,
    this.onPlus,
    this.lockedNote,
  });

  final String label;
  final String value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  /// When set, the row is read-only and this explains why.
  final String? lockedNote;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final locked = lockedNote != null;
    Widget button(IconData icon, VoidCallback? cb, String semantic) =>
        Semantics(
          button: true,
          enabled: cb != null,
          label: semantic,
          child: _RepeatButton(
            onStep: cb,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: t.bgRaised,
                borderRadius: BorderRadius.circular(Radii.button),
                border: Border.all(color: t.lineHair),
              ),
              child: Icon(
                icon,
                size: 24,
                color: cb == null ? t.inkMuted : t.inkPrimary,
              ),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                ),
                const SizedBox(height: Space.x4),
                Text(
                  value,
                  style: RunSoloType.display44.copyWith(
                    color: locked ? t.inkSecondary : t.inkPrimary,
                  ),
                ),
                if (locked)
                  Text(
                    lockedNote!,
                    style: RunSoloType.label13.copyWith(
                      color: t.inkMuted,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
              ],
            ),
          ),
          if (!locked) ...[
            button(Icons.remove, onMinus, '$label minus'),
            const SizedBox(width: Space.x12),
            button(Icons.add, onPlus, '$label plus'),
          ],
        ],
      ),
    );
  }
}

/// Tap = one step; hold = repeat after 400 ms, every 120 ms, until release
/// or the callback goes null (the value hit its limit).
class _RepeatButton extends StatefulWidget {
  const _RepeatButton({required this.onStep, required this.child});
  final VoidCallback? onStep;
  final Widget child;

  @override
  State<_RepeatButton> createState() => _RepeatButtonState();
}

class _RepeatButtonState extends State<_RepeatButton> {
  Timer? _delay;
  Timer? _repeat;

  /// A hold already stepped; the tap that ends it must not step again.
  bool _repeated = false;

  void _stop() {
    _delay?.cancel();
    _repeat?.cancel();
    _delay = null;
    _repeat = null;
  }

  void _step() {
    final cb = widget.onStep;
    if (cb == null) {
      _stop();
      return;
    }
    HapticFeedback.selectionClick();
    cb();
  }

  @override
  void didUpdateWidget(_RepeatButton old) {
    super.didUpdateWidget(old);
    if (widget.onStep == null) _stop();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onStep != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.button),
        onTap: enabled
            ? () {
                if (!_repeated) _step();
                _repeated = false;
              }
            : null,
        onTapDown: enabled
            ? (_) {
                _stop();
                _repeated = false;
                _delay = Timer(const Duration(milliseconds: 400), () {
                  _repeat = Timer.periodic(const Duration(milliseconds: 120), (
                    _,
                  ) {
                    _repeated = true;
                    _step();
                  });
                });
              }
            : null,
        onTapUp: (_) => _stop(),
        onTapCancel: _stop,
        child: widget.child,
      ),
    );
  }
}
