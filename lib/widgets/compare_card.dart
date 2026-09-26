import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import '../theme/theme.dart';
import 'delta_glyph.dart';

/// The live overlay card (design brief A10.1, plan §3.2 / §7): shows what the
/// voice just said for 2 s, in the secondary-number slot. Black 85 % over the
/// zone background, a 1 px Bone 20 % border, every glyph Bone 70 %: below
/// the primary number in size (44 / 36 sp against 168 / 128) and in
/// brightness, and ≥ 8:1 on its own ground on every zone. No Arc, no
/// Vermillion: direction is the glyph plus the words.
class CompareCard extends StatelessWidget {
  const CompareCard({
    super.key,
    required this.card,
    this.compact = false,
    this.backdrop,
  });

  final engine.LiveCard card;

  /// Short screen (< 720 dp): 92 dp tall, rank at 36 sp.
  final bool compact;

  /// The zone background under the card. Black 85 % is composited onto it
  /// into one opaque colour, so the same shade shows but the covered number
  /// never ghosts through the text (A10.1: hidden for the 2 s).
  final Color? backdrop;

  static const Color ink = Color(0xB3EDEAE3); // Bone 70 %
  static const Color ground = Color(0xD9000000); // black 85 %
  static const Color border = Color(0x33EDEAE3); // Bone 20 %

  static double heightFor({required bool compact}) => compact ? 92 : 104;

  static TextStyle rankStyle({required bool compact}) =>
      RunSoloType.display44.copyWith(fontSize: compact ? 36 : 44, color: ink);

  @override
  Widget build(BuildContext context) {
    final glyph = switch (card.direction) {
      engine.LiveCardDirection.ahead => DeltaDirection.up,
      engine.LiveCardDirection.behind => DeltaDirection.down,
      engine.LiveCardDirection.level => null,
    };
    // Not a live region: the voice has already said it.
    return Semantics(
      key: const ValueKey('compare-card'),
      container: true,
      label: card.semantics,
      child: ExcludeSemantics(
        child: Container(
          height: heightFor(compact: compact),
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
              : const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: backdrop == null
                ? ground
                : Color.alphaBlend(ground, backdrop!),
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(color: border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    // Ellipsised past this, never shrunk (A10.1).
                    constraints: const BoxConstraints(maxWidth: 200),
                    child: Text(
                      card.rank,
                      key: const ValueKey('compare-card-rank'),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: rankStyle(compact: compact).copyWith(height: 1),
                    ),
                  ),
                  const SizedBox(width: Space.x12),
                  Expanded(
                    child: Text(
                      card.eyebrow,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: RunSoloType.label13.copyWith(color: ink),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  if (glyph != null) ...[
                    DeltaGlyph(direction: glyph, color: ink, size: 14),
                    const SizedBox(width: Space.x8),
                  ],
                  Expanded(
                    child: Text(
                      card.detail,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: RunSoloType.body17.copyWith(
                        color: ink,
                        fontWeight: FontWeight.w500,
                        height: 1.2,
                      ),
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

/// Shows the card for each new [CompareEvent] for 2.0 s in all: 150 ms fade
/// in (`e.standard`), hold, 150 ms fade out (`e.exit`); with [reduced] it
/// cuts in and out. One card at a time, never queued: a new compare replaces
/// the one showing. An event already 2 s old when it is seen (a screen
/// recreated late) is dropped. [enabled] false hides it at once (paused,
/// END REP, the last 10 s of a recovery, Show while running off, tips
/// muted); its time keeps running, so it never comes back late.
class CompareCardHost extends StatefulWidget {
  const CompareCardHost({
    super.key,
    required this.events,
    required this.receivedAt,
    required this.now,
    required this.enabled,
    this.compact = false,
    this.reduced = false,
    this.units = Units.km,
    this.targetM,
    this.backdrop,
  });

  final ValueListenable<CompareEvent?> events;
  final DateTime? Function() receivedAt;
  final DateTime Function() now;
  final bool enabled;
  final bool compact;
  final bool reduced;
  final Units units;

  /// A target compare's distance (the timed 5 km), for the projected finish.
  final double? targetM;

  /// The zone background, for [CompareCard.backdrop].
  final Color? backdrop;

  static const Duration shown = Duration(milliseconds: 2000);
  static const Duration fade = Duration(milliseconds: 150);

  @override
  State<CompareCardHost> createState() => _CompareCardHostState();
}

class _CompareCardHostState extends State<CompareCardHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: CompareCardHost.fade,
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _fade,
    curve: MotionCurves.standard,
    reverseCurve: MotionCurves.exit,
  );
  CompareEvent? _event;
  Timer? _out;
  Timer? _end;

  @override
  void initState() {
    super.initState();
    widget.events.addListener(_onEvent);
    _onEvent();
  }

  @override
  void didUpdateWidget(CompareCardHost old) {
    super.didUpdateWidget(old);
    if (old.events != widget.events) {
      old.events.removeListener(_onEvent);
      widget.events.addListener(_onEvent);
    }
  }

  void _onEvent() {
    final e = widget.events.value;
    final at = widget.receivedAt();
    _out?.cancel();
    _end?.cancel();
    if (e == null || at == null || !e.overlay) return _clear();
    final left = CompareCardHost.shown - widget.now().difference(at);
    if (left <= Duration.zero) return _clear();
    if (widget.reduced) {
      _fade.value = 1;
    } else {
      _fade.forward(from: 0);
    }
    _out = Timer(widget.reduced ? left : left - CompareCardHost.fade, _fadeOut);
    _end = Timer(left, _clear);
    setState(() => _event = e);
  }

  void _fadeOut() {
    if (!mounted) return;
    if (widget.reduced) {
      _fade.value = 0;
    } else {
      _fade.reverse();
    }
  }

  void _clear() {
    if (!mounted) return;
    _fade.value = 0;
    if (_event != null) setState(() => _event = null);
  }

  @override
  void dispose() {
    widget.events.removeListener(_onEvent);
    _out?.cancel();
    _end?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = _event;
    if (e == null || !widget.enabled) return const SizedBox.shrink();
    final card = engine.LiveCard.of(
      kind: e.kind,
      boardLabel: e.boardLabel,
      index: e.index,
      rank: e.rank,
      of: e.of,
      deltaMs: e.deltaMs,
      deltaSecPerKm: e.deltaSecPerKm,
      deltaVo2: e.deltaVo2,
      value: e.value,
      targetM: widget.targetM,
      units: engine.Units.values.byName(widget.units.name),
    );
    if (card == null) return const SizedBox.shrink();
    return FadeTransition(
      opacity: _opacity,
      child: CompareCard(
        card: card,
        compact: widget.compact,
        backdrop: widget.backdrop,
      ),
    );
  }
}

/// Marks a layout's secondary number as the card's slot (A10.1 bounds). The
/// card itself is drawn by [CompareCardLayer] at the top of the screen's
/// stack, so nothing laid out after the number (the pace dial, the rep row)
/// paints over it; it follows this slot through [link]. Null [link]: this
/// layout has no card.
class CompareSlot extends StatelessWidget {
  const CompareSlot({super.key, required this.link, required this.child});

  final LayerLink? link;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l = link;
    return l == null ? child : CompositedTransformTarget(link: l, child: child);
  }
}

/// The card, pinned to the [CompareSlot] holding [link]: its top edge on
/// the slot's top, content width ([width]), running down over the line
/// beneath. [anchorBottom] (the Laps row, shorter than the card with the GPS
/// bar right under it): the card's bottom on the slot's bottom instead, so
/// it grows up into the free space (never over the GPS bar). Draws nothing
/// while no slot holds the link.
class CompareCardLayer extends StatelessWidget {
  const CompareCardLayer({
    super.key,
    required this.link,
    required this.width,
    required this.card,
    this.anchorBottom = false,
  });

  final LayerLink link;
  final double width;
  final Widget card;
  final bool anchorBottom;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    top: 0,
    width: width,
    child: IgnorePointer(
      child: CompositedTransformFollower(
        link: link,
        showWhenUnlinked: false,
        targetAnchor: anchorBottom ? Alignment.bottomLeft : Alignment.topLeft,
        followerAnchor: anchorBottom ? Alignment.bottomLeft : Alignment.topLeft,
        child: card,
      ),
    ),
  );
}
