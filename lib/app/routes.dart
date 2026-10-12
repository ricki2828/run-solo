/// Named routes. Kept as constants so tests and screens agree.
abstract final class Routes {
  static const String shell = '/';
  static const String start = '/start';
  static const String permissions = '/permissions';
  static const String pairing = '/pairing';
  static const String recording = '/recording';

  /// Arguments: run id (String). `verdictJustFinished` folds observed max HR.
  static const String verdict = '/verdict';
  static const String verdictJustFinished = '/verdict/just-finished';
  static const String runDetail = '/run';
  static const String fixLaps = '/fix-laps';
  static const String settings = '/settings';
  static const String offlineMaps = '/settings/offline-maps';
  static const String plan = '/plan';

  /// Last week's story. Optional argument: a `WeeklyStory` to show.
  static const String weeklyStory = '/weekly-story';
}
