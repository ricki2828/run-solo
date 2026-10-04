/// What works on a phone in 2026 for each watch brand, in plain words.
/// Researched 4 Oct 2026; sources are listed in the PR that added this. A
/// workout file only reaches a Garmin, and only through a computer. A GPX
/// course goes to every brand below, most of them from the phone.
library;

enum WatchBrand { garmin, coros, suunto, wahoo, polar }

class WatchGuideEntry {
  const WatchGuideEntry({
    required this.brand,
    required this.label,
    required this.workoutWorks,
    required this.intervals,
    required this.workout,
    required this.route,
  });
  final WatchBrand brand;
  final String label;

  /// True only when a workout file really reaches the watch.
  final bool workoutWorks;

  /// What the Intervals.icu push does for this brand.
  final String intervals;
  final String workout;
  final String route;
}

abstract final class WatchGuide {
  static const List<WatchGuideEntry> entries = [
    WatchGuideEntry(
      brand: WatchBrand.garmin,
      label: 'Garmin',
      workoutWorks: true,
      intervals: 'Goes to Garmin Connect once you link Garmin there (Settings, Connections, tick Upload planned workouts). It reaches the watch up to a week ahead.',
      workout:
          'Needs a computer. Garmin Connect on your phone cannot take a '
          'workout file. Plug the watch into a computer with its USB cable '
          'and copy the file into the watch folder GARMIN/NewFiles (some '
          'older models use GARMIN/Workouts). This is how TrainingPeaks and '
          'other coaching sites describe it; Garmin does not document it '
          'and we have not tried it on a watch.',
      route:
          'Import the file on the Garmin Connect website (Training, Courses, '
          'Import), then send the course to your watch from the app. '
          'Sharing it straight to the Garmin Connect app on your phone may '
          'also work, but we could not confirm it.',
    ),
    WatchGuideEntry(
      brand: WatchBrand.coros,
      label: 'COROS',
      workoutWorks: false,
      intervals: 'Goes to COROS. Add the Intervals.icu Training Plan to your calendar in the COROS app once.',
      workout:
          'Not supported. COROS documents imports of finished activities '
          'only. Build the session in the COROS app by hand.',
      route:
          'Choose the COROS app when the share sheet opens and save the '
          'route, then sync it to your watch. Runner guides describe it this '
          'way; we have not tried it.',
    ),
    WatchGuideEntry(
      brand: WatchBrand.suunto,
      label: 'Suunto',
      workoutWorks: false,
      intervals: 'Goes through SuuntoPlus Guides. Documented for Suunto 3, 5 and 9 watches; newer ones are not confirmed.',
      workout:
          'No workout import found. Suunto documents importing routes and '
          'finished activities only. Build the session in the app by hand.',
      route:
          'Save the file. In the Suunto app open the map, tap the plus '
          'and import the GPX. Save it and sync your watch.',
    ),
    WatchGuideEntry(
      brand: WatchBrand.wahoo,
      label: 'Wahoo',
      workoutWorks: false,
      intervals: 'Not confirmed. Sources disagree on whether Intervals.icu sends workouts to Wahoo.',
      workout:
          'No workout import found. Wahoo documents importing routes only.',
      route:
          'Choose the Wahoo app when the share sheet opens. Wahoo documents '
          'this for the ELEMNT ACE, BOLT 3 and ROAM 3.',
    ),
    WatchGuideEntry(
      brand: WatchBrand.polar,
      label: 'Polar',
      workoutWorks: false,
      intervals: 'Not possible. Intervals.icu cannot send workouts to Polar.',
      workout:
          'No workout import found. Polar documents importing routes only.',
      route:
          'Polar Flow takes routes on its website only. On a computer, '
          'open Flow, import the file under Favorites, then sync the '
          'watch.',
    ),
  ];
}
