/// Odometer-style distance (Ricki 11-Oct, softened 12-Oct): digits that roll
/// like odometer wheels, with no boxes or fills. Every digit, the point and
/// the unit share one style, so it reads like the other run-screen numbers.
/// On by default since Ricki's 12-Oct "odo yes". Tests default
/// [kOdometerDistance] off (see test/flutter_test_config.dart) and the
/// run-page goldens cover both.
library;

import 'package:flutter/material.dart';

/// The variant flag. No setting, no UI.
bool kOdometerDistance = true;

class OdometerDistance extends StatelessWidget {
  const OdometerDistance({super.key, required this.value, required this.style});

  /// "0.40 km" or "12.07 mi": number, then the unit.
  final String value;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final parts = value.split(' ');
    final number = parts.first;
    final unit = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    final dot = number.indexOf('.');
    final whole = dot < 0 ? number : number.substring(0, dot);
    final dec = dot < 0 ? '' : number.substring(dot + 1);
    // No leading zero (24-Oct review #23: "07.41" read like a fault). Wheels
    // are keyed by their place from the point, so 9.99 -> 10.00 rolls each
    // place on and the new tens wheel just appears.
    // One style for everything; height 1 keeps the wheel window tight.
    final s = style.copyWith(
      height: 1,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget wheel(String ch, String place) {
      final d = int.tryParse(ch);
      final key = ValueKey('odo-cell-$place');
      return d == null
          ? Text(ch, key: key, softWrap: false, style: s)
          : _Wheel(key: key, digit: d, style: s);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < whole.length; i++)
          wheel(whole[i], 'w${whole.length - 1 - i}'),
        if (dec.isNotEmpty) ...[
          Text('.', softWrap: false, style: s),
          for (var i = 0; i < dec.length; i++) wheel(dec[i], 'd$i'),
        ],
        if (unit.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(left: (style.fontSize ?? 48) * 0.18),
            child: Text(unit, softWrap: false, style: s),
          ),
      ],
    );
  }
}

/// One digit that scrolls vertically to its new value, always forwards (9
/// rolls on to 0), clipped to a single line.
class _Wheel extends StatefulWidget {
  const _Wheel({super.key, required this.digit, required this.style});
  final int digit;
  final TextStyle style;

  @override
  State<_Wheel> createState() => _WheelState();
}

class _WheelState extends State<_Wheel> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  late double _from = widget.digit.toDouble();
  late double _to = widget.digit.toDouble();

  /// Where the wheel sits now, in digits (can pass 9 towards 10, 11...).
  double get _pos =>
      _from + (_to - _from) * Curves.easeOutCubic.transform(_ctl.value);

  @override
  void didUpdateWidget(_Wheel old) {
    super.didUpdateWidget(old);
    if (old.digit == widget.digit) return;
    final here = _pos;
    var target = widget.digit.toDouble();
    // Forwards only: lift the target above where the wheel is now.
    while (target <= here) {
      target += 10;
    }
    // Keep the numbers small.
    final base = (here / 10).floor() * 10;
    _from = here - base;
    _to = target - base;
    _ctl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final size = style.fontSize ?? 48;
    final h = size;
    // Fixed-width cell so the number never jitters.
    final w = size * 0.44;
    return Semantics(
      label: '${widget.digit}',
      excludeSemantics: true,
      child: SizedBox(
        width: w,
        height: h,
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _ctl,
            builder: (context, _) {
              final p = _pos;
              final i = p.floor();
              final frac = p - i;
              Widget at(int d, double dy) => Positioned(
                left: 0,
                right: 0,
                top: dy,
                height: h,
                child: Center(
                  child: Text('${d % 10}', softWrap: false, style: style),
                ),
              );
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  at(i, -frac * h),
                  if (frac > 0) at(i + 1, (1 - frac) * h),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
