import 'package:flutter/material.dart';

import '../state/inrun_moments.dart';
import '../theme/theme.dart';
import '../theme/zones.dart';

/// The in-run moment (21-Oct UI review, finding 2): a scrim over the whole
/// run screen so the numbers underneath recede, and one full-width band with
/// a big label and key figure that scales in, glows, holds, and goes, in
/// [shownFor]. Calm between moments, drama at one. Never takes a tap, never
/// outlasts [shownFor], and with [reduced] it only appears and disappears
/// (no scale, no glow).
///
/// Colours: a deep shade of the zone flood ([accent]) for scrim and band,
/// the zone colour itself for the key figure, bone for the label.
class InrunMomentOverlay extends StatefulWidget {
  const InrunMomentOverlay({
    super.key,
    required this.moment,
    required this.accent,
    this.reduced = false,
    this.onDone,
  });

  final InrunMoment moment;

  /// The zone flood the plate sits on (its own colour for the headline).
  final Color accent;
  final bool reduced;
  final VoidCallback? onDone;

  /// How long a moment is on the screen.
  static const Duration shownFor = Duration(milliseconds: 1500);

  /// Headline and label sizes (sp): both clear the 36 sp number floor.
  static const double headlineSize = 96;
  static const double labelSize = 28;

  @override
  State<InrunMomentOverlay> createState() => _InrunMomentOverlayState();
}

class _InrunMomentOverlayState extends State<InrunMomentOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: InrunMomentOverlay.shownFor,
  );

  // 0 to 0.16 in, to 0.84 hold, to 1 out.
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 0.82,
        end: 1.0,
      ).chain(CurveTween(curve: MotionCurves.emphasized)),
      weight: 16,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 84),
  ]).animate(_c);

  late final Animation<double> _fade = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 12),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 72),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 16),
  ]).animate(_c);

  @override
  void initState() {
    super.initState();
    _c.forward().whenComplete(() {
      if (mounted) widget.onDone?.call();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.moment;
    final deep = Color.lerp(widget.accent, const Color(0xFF000000), 0.82)!;
    const bone = Color(0xFFF3EFE6);
    // The zone colour for the key figure where it reads on the deep band
    // (a dark flood does not), else bone.
    final figure = HrZones.contrast(widget.accent, deep) >= 4.5
        ? widget.accent
        : bone;
    final reduced = widget.reduced;
    return IgnorePointer(
      child: Semantics(
        liveRegion: true,
        label: '${m.label} ${m.headline}${m.sub == null ? '' : ', ${m.sub}'}',
        excludeSemantics: true,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final fade = reduced ? (_c.value < 0.96 ? 1.0 : 0.0) : _fade.value;
            final scale = reduced ? 1.0 : _scale.value;
            return SizedBox.expand(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Everything under the moment recedes: nothing peeks out
                  // from behind the band.
                  Opacity(
                    opacity: fade,
                    child: ColoredBox(
                      key: const ValueKey('inrun-moment-scrim'),
                      color: deep.withValues(alpha: 0.9),
                    ),
                  ),
                  Center(
                    child: Opacity(
                      opacity: fade,
                      child: Transform.scale(
                        scale: scale,
                        child: Container(
                          key: ValueKey('inrun-moment-${m.kind.name}'),
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.x16,
                            vertical: Space.x24,
                          ),
                          decoration: BoxDecoration(
                            color: deep,
                            boxShadow: reduced
                                ? null
                                : [
                                    BoxShadow(
                                      color: widget.accent.withValues(
                                        alpha: 0.6,
                                      ),
                                      blurRadius: 56,
                                      spreadRadius: 8,
                                    ),
                                  ],
                          ),
                          child: _band(m, bone, figure),
                        ),
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

  Widget _band(InrunMoment m, Color bone, Color figure) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          m.label,
          key: const ValueKey('inrun-moment-label'),
          softWrap: false,
          style: RunSoloType.title28.copyWith(
            fontSize: InrunMomentOverlay.labelSize,
            fontWeight: FontWeight.w800,
            color: bone,
          ),
        ),
      ),
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          m.headline,
          key: const ValueKey('inrun-moment-headline'),
          softWrap: false,
          style: RunSoloType.display44.copyWith(
            fontSize: RunSoloType.runSize(InrunMomentOverlay.headlineSize),
            fontWeight: FontWeight.w800,
            color: figure,
            height: 1.0,
          ),
        ),
      ),
      if (m.sub != null) ...[
        const SizedBox(height: Space.x4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            m.sub!,
            key: const ValueKey('inrun-moment-sub'),
            softWrap: false,
            style: RunSoloType.title28.copyWith(
              fontSize: InrunMomentOverlay.labelSize,
              color: bone,
            ),
          ),
        ),
      ],
    ],
  );
}
