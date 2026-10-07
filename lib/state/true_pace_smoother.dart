/// A rolling mean of the live True Pace over the last [window], for the
/// target band's marker: the coach judges the smoothed pace (about 30 s), so
/// the screen shows that, not the twitchy 15 s reading on the dial.
class TruePaceSmoother {
  TruePaceSmoother({
    this.window = const Duration(seconds: 30),
    this.minSamples = 5,
  });

  final Duration window;

  /// Fewer samples than this and there is no pace worth showing yet.
  final int minSamples;

  final List<({DateTime at, double pace})> _samples = [];

  /// Add a reading; a null pace (not moving, no fix) adds nothing.
  void add(DateTime now, double? pace) {
    _drop(now);
    if (pace == null || !pace.isFinite || pace <= 0) return;
    _samples.add((at: now, pace: pace));
  }

  /// A new rep or segment starts the window afresh, as the coach does.
  void reset() => _samples.clear();

  /// The mean of the window, or null while there are too few readings.
  double? value(DateTime now) {
    _drop(now);
    if (_samples.length < minSamples) return null;
    var sum = 0.0;
    for (final s in _samples) {
      sum += s.pace;
    }
    return sum / _samples.length;
  }

  void _drop(DateTime now) =>
      _samples.removeWhere((s) => now.difference(s.at) > window);
}
