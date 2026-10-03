import '../model/verdict.dart';
import 'trail_verdict.dart';

/// The verdict as the voice says it at the end of a run: the result screen's
/// own headline in sentence case (FASTER becomes "Faster."), so what is said
/// always matches what is shown. Nothing here judges; a run with no verdict
/// returns null and the summary speaks its stats alone. Plain, casual, no em
/// dashes (TTS reads the text).
abstract final class SpokenVerdict {
  /// A 4x4 (or any intervals session): the headline, plus "New best ..." when
  /// the verdict itself flags a 365-day best. [sessionName] is how the voice
  /// names the session ("Norwegian 4x4").
  static String? ofSession(Verdict? v, {String? sessionName}) {
    if (v == null) return null;
    switch (v.headline) {
      case VerdictHeadline.noVerdict:
      case VerdictHeadline.indoorRun:
        return null;
      case VerdictHeadline.faster:
      case VerdictHeadline.holding:
      case VerdictHeadline.slower:
      case VerdictHeadline.noRealChange:
      case VerdictHeadline.baselineSet:
        final head = _sentence(v.headline.text);
        if (!v.bestIn365Days) return head;
        return '$head New best${sessionName == null ? '' : ' $sessionName'}.';
    }
  }

  /// A Trail run: on the same trail it names the gap ("Faster on this trail,
  /// 2 minutes 10 quicker than last time."); on effort pace, or with a
  /// baseline, just the headline.
  static String? ofTrail(TrailResult r) {
    if (r.basis == TrailBasis.none) return null;
    final delta = r.deltaSec;
    if (r.basis == TrailBasis.sameTrail && delta != null) {
      final gap = gapWords(delta.abs().round());
      switch (r.tone) {
        case TrailTone.faster:
          return 'Faster on this trail, $gap quicker than last time.';
        case TrailTone.slower:
          return 'Slower on this trail, $gap slower than last time.';
        case TrailTone.same:
        case TrailTone.baseline:
        case TrailTone.none:
          return 'No real change.';
      }
    }
    return _sentence(r.headline);
  }

  /// Whole seconds as the voice says a gap: "17 seconds", "2 minutes 17",
  /// "1 minute" (the same rule as Kotlin `CueWords.gap`).
  static String gapWords(int seconds) {
    final s = seconds.abs();
    if (s < 60) return s == 1 ? '1 second' : '$s seconds';
    final m = s ~/ 60;
    final rest = s % 60;
    final mins = m == 1 ? '1 minute' : '$m minutes';
    return rest == 0 ? mins : '$mins $rest';
  }

  static String _sentence(String caps) {
    final lower = caps.toLowerCase();
    return '${lower[0].toUpperCase()}${lower.substring(1)}.';
  }
}
