/// Odometer-style distance (Ricki 11-Oct, "decision for Ricki"): rolling
/// digit wheels in individual cells, the whole kilometres dark and the
/// decimals inverted so "07.42" reads at arm's length. Off by default: only
/// [kOdometerDistance] (flipped by the golden test) turns it on.
library;

import 'package:flutter/material.dart';

/// The hidden variant flag. No setting, no UI: goldens flip it so Ricki can
/// judge the look from a picture before anything ships.
bool kOdometerDistance = false;

class OdometerDistance extends StatelessWidget {
  const OdometerDistance({
    super.key,
    required this.value,
    required this.style,
    required this.wholeFill,
    required this.wholeInk,
    required this.decimalFill,
    required this.decimalInk,
  });

  /// "0.40 km" or "12.07 mi": number, then the unit.
  final String value;
  final TextStyle style;
  final Color wholeFill;
  final Color wholeInk;
  final Color decimalFill;
  final Color decimalInk;

  @override
  Widget build(BuildContext context) {
    final parts = value.split(' ');
    final number = parts.first;
    final unit = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    final dot = number.indexOf('.');
    var whole = dot < 0 ? number : number.substring(0, dot);
    final dec = dot < 0 ? '' : number.substring(dot + 1);
    if (whole.length < 2) whole = whole.padLeft(2, '0');
    final size = style.fontSize ?? 48;
    var n = 0;
    Widget cell(String ch, Color fill, Color ink) => Container(
      key: ValueKey('odo-cell-${n++}'),
      width: size * 0.62,
      height: size * 1.04,
      margin: EdgeInsets.only(right: size * 0.05),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(size * 0.1),
        // The wheel: a hint of shade at the top and bottom edge.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(const Color(0x66000000), fill),
            fill,
            fill,
            Color.alphaBlend(const Color(0x66000000), fill),
          ],
          stops: const [0, 0.22, 0.78, 1],
        ),
      ),
      child: Text(
        ch,
        softWrap: false,
        style: style.copyWith(color: ink, height: 1),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (final ch in whole.split('')) cell(ch, wholeFill, wholeInk),
        Padding(
          padding: EdgeInsets.only(right: size * 0.07),
          child: Text('.', style: style.copyWith(color: decimalFill)),
        ),
        for (final ch in dec.split('')) cell(ch, decimalFill, decimalInk),
        if (unit.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(left: size * 0.1),
            child: Text(
              unit,
              softWrap: false,
              style: style.copyWith(fontSize: size * 0.5),
            ),
          ),
      ],
    );
  }
}
