import 'package:flutter/material.dart';

/// Saira Extra Condensed cap height (OS/2 sCapHeight 688 / 1000 upm).
const double kSairaCapEm = 0.688;

/// How far (px, positive = low) the caps' vertical middle sits below the
/// middle of the line box for a Saira [style]. Measured with the engine's own
/// metrics, so it holds on whatever the platform reports. Saira's ascent and
/// descent are lopsided, so a plain `Text` in a button parks the caps ~0.12 em
/// high ("Start not in middle of button", Ricki 14-Oct).
double sairaCapsOffset(TextStyle style, {String text = 'H'}) {
  final size = style.fontSize ?? 14;
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final baseline = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
  final offset = baseline - kSairaCapEm * size / 2 - tp.height / 2;
  tp.dispose();
  return offset;
}

/// A Saira display label with its caps optically centred in the box it is
/// laid out in. Use for every big display-type button label so the fix lives
/// in one place. Inside a button the style comes from the button's textStyle.
class CapsText extends StatelessWidget {
  const CapsText(this.data, {super.key, this.style, this.maxLines = 1});

  final String data;
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final resolved = DefaultTextStyle.of(context).style.merge(style);
    final dy = sairaCapsOffset(resolved);
    return Transform.translate(
      offset: Offset(0, -dy),
      child: Text(data, style: style, maxLines: maxLines, softWrap: false),
    );
  }
}
