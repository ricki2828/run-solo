import 'package:flutter/material.dart';

import '../platform/gateway.dart';
import '../theme/theme.dart';
import '../theme/zones.dart';

/// The mid-run two-button coach prompt (decisions 22-Oct): the in-run moment's
/// look (a deep scrim over the whole run screen so the numbers recede, bone
/// type on a deep shade of the zone flood), extended with two half-screen
/// buttons, one tap, big enough to hit mid-stride.
///
/// The voice has already asked; the sentence is on screen at 36 sp (the
/// run-screen number floor, it carries numbers), the two answers are 56 sp on
/// buttons that take the lower half of the screen, and a bar runs down the
/// 8 s the prompt stays open. No tap holds the current target (native owns the
/// clock and sends the resolved event; this widget never decides). The scrim
/// absorbs taps so nothing under it (pause, lap, stop) is hit by accident.
///
/// The first button is the single headset press, the second the double press;
/// a hint line says so.
class InrunPromptOverlay extends StatefulWidget {
  const InrunPromptOverlay({
    super.key,
    required this.prompt,
    required this.accent,
    required this.onChoose,
    this.reduced = false,
  });

  final PromptEvent prompt;

  /// The zone flood the plate sits on.
  final Color accent;
  final bool reduced;

  /// The button picked: its index (0 = the first).
  final ValueChanged<int> onChoose;

  /// The sentence's size (sp): the number floor, since it holds numbers.
  static const double textSize = 36;

  /// The button labels' size (sp).
  static const double buttonSize = 56;

  /// The headset hint under each answer (sp): readable mid-stride.
  static const double hintSize = 16;

  /// The smallest height of a button (dp): the lower half of a short phone.
  static const double buttonMinHeight = 160;

  static String eyebrow(String kind) => switch (kind) {
    'last2k' => 'LAST STRETCH',
    'behindTarget' => 'BEHIND',
    'aheadOfPb' => 'AHEAD',
    'betweenReps' => 'NEXT REP',
    _ => 'COACH',
  };

  @override
  State<InrunPromptOverlay> createState() => _InrunPromptOverlayState();
}

class _InrunPromptOverlayState extends State<InrunPromptOverlay>
    with SingleTickerProviderStateMixin {
  // The countdown bar: full to empty over the prompt's own window.
  // The bar waits out the question (leadMs, an estimate) and then runs down the answer window.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(
      milliseconds: widget.prompt.leadMs + widget.prompt.timeoutMs,
    ),
  )..forward();

  double get _bar {
    final lead = widget.prompt.leadMs;
    final total = lead + widget.prompt.timeoutMs;
    final spent = _c.value * total;
    return (1 - ((spent - lead) / widget.prompt.timeoutMs)).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.prompt;
    final deep = HSLColor.fromColor(widget.accent)
        .withLightness(0.07)
        .toColor();
    final bone = RunSoloTokens.dark.inkPrimary;
    final figure = HrZones.contrast(widget.accent, deep) >= 4.5
        ? widget.accent
        : bone;
    final safe = MediaQuery.paddingOf(context);
    return Semantics(
      liveRegion: true,
      label: p.text,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Everything under the prompt is covered and takes no taps: an
          // opaque scrim, so no run number shows through the question
          // (24-Oct review #7).
          AbsorbPointer(
            child: ColoredBox(
              key: const ValueKey('inrun-prompt-scrim'),
              color: deep,
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              Space.x16,
              safe.top + Space.x16,
              Space.x16,
              safe.bottom + Space.x16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    InrunPromptOverlay.eyebrow(p.kind),
                    key: const ValueKey('inrun-prompt-eyebrow'),
                    softWrap: false,
                    style: RunSoloType.title28.copyWith(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: figure,
                    ),
                  ),
                ),
                const SizedBox(height: Space.x8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      p.text,
                      key: const ValueKey('inrun-prompt-text'),
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: RunSoloType.title28.copyWith(
                        fontSize: RunSoloType.runSize(
                          InrunPromptOverlay.textSize,
                        ),
                        fontWeight: FontWeight.w800,
                        color: bone,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Space.x12),
                // The 8 s window: a bar that runs down.
                AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) => ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      key: const ValueKey('inrun-prompt-bar'),
                      value: _bar,
                      minHeight: 8,
                      color: figure,
                      backgroundColor: bone.withValues(alpha: 0.18),
                    ),
                  ),
                ),
                const SizedBox(height: Space.x12),
                SizedBox(
                  height: _buttonHeight(context),
                  child: Row(
                    children: [
                      for (var i = 0; i < p.options.length; i++) ...[
                        if (i > 0) const SizedBox(width: Space.x12),
                        Expanded(
                          child: _PromptButton(
                            key: ValueKey('inrun-prompt-$i'),
                            label: p.options[i],
                            filled: i == 0,
                            fill: figure,
                            bone: bone,
                            deep: deep,
                            hint: i == 0 ? '1 press' : '2 presses',
                            onTap: () => widget.onChoose(i),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The buttons take the lower half of the screen, never under the minimum.
  double _buttonHeight(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return (h * 0.36).clamp(InrunPromptOverlay.buttonMinHeight, 360.0);
  }
}

class _PromptButton extends StatelessWidget {
  const _PromptButton({
    super.key,
    required this.label,
    required this.filled,
    required this.fill,
    required this.bone,
    required this.deep,
    required this.hint,
    required this.onTap,
  });

  final String label;
  final bool filled;
  final Color fill;
  final Color bone;
  final Color deep;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = filled ? deep : bone;
    return Semantics(
      button: true,
      label: '$label, $hint on the headset',
      excludeSemantics: true,
      child: Material(
        color: filled ? fill : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.card),
          side: BorderSide(color: filled ? fill : bone, width: 3),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.card),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 16 dp each side: a long label (EASE OFF) scales down
                // rather than touch the button's edge.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.x16),
                    child: Text(
                      label.toUpperCase(),
                      softWrap: false,
                      style: RunSoloType.display44.copyWith(
                        fontSize: RunSoloType.runSize(
                          InrunPromptOverlay.buttonSize,
                        ),
                        fontWeight: FontWeight.w800,
                        color: ink,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Space.x4),
                Text(
                  hint,
                  key: const ValueKey('inrun-prompt-hint'),
                  style: RunSoloType.label13.copyWith(
                    fontSize: InrunPromptOverlay.hintSize,
                    color: ink.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
