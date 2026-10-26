import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/screens/companion_screen.dart';

/// The consent sheets lead with short summary rows. They are the main
/// disclosure, so each one must still carry its key facts, and each fact must
/// be backed by the published privacy page (docs/privacy/index.html).
void main() {
  late String privacy;

  setUpAll(() {
    privacy = File('docs/privacy/index.html')
        .readAsStringSync()
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&#39;', "'")
        .replaceAll('&rsquo;', "'")
        .replaceAll(RegExp(r'\s+'), ' ');
  });

  // summary -> [fact in the summary, wording it needs on the privacy page]
  final facts = <String, List<(String, String)>>{
    kCompanionConsentSent: [
      (
        'name of the area where you started',
        'name of the area where you started',
      ),
      ('could still be recognised', 'could still be recognised'),
    ],
    kCompanionConsentWho: [
      ('OpenRouter', 'OpenRouter'),
      ('Telegram', 'delivers the notes'),
    ],
    kCompanionConsentHowLong: [
      ('14 days', '14 days'),
      ('six months', 'six months'),
    ],
    kCompanionReconsentSent: [
      ('health information', 'health information'),
      ('go lighter', 'go lighter'),
      ('later day', 'a later day'),
    ],
    kCompanionReconsentWho: [
      ('Claude models through OpenRouter', 'OpenRouter'),
      ('zero data retention', 'zero data retention'),
    ],
    kCompanionReconsentHowLong: [('14 days', '14 days')],
    kCompanionCoachSent: [('run notes', 'run notes')],
    kCompanionCoachWho: [
      ('OpenRouter', 'OpenRouter'),
      ('zero data retention', 'zero data retention'),
    ],
    kCompanionCoachHowLong: [('30 days', '30 days')],
    kCompanionMemorySent: [('summary of your chats', 'Health notes')],
    kCompanionMemoryWho: [
      ('Claude models via OpenRouter', 'Claude models via OpenRouter'),
      (
        'Google Cloud or Amazon Web Services',
        'Google Cloud or Amazon Web Services',
      ),
      ('zero data retention', 'zero-data-retention'),
    ],
    kCompanionMemoryHowLong: [('Turn off memory', 'Turn off memory')],
    kCompanionWeatherSent: [('11 km', 'about 11 km')],
    kCompanionWeatherWho: [('Open-Meteo', 'Open-Meteo')],
    kCompanionWeatherHowLong: [
      ('30 days', '30 days'),
      ('14 days', 'up to 14 days'),
    ],
  };

  facts.forEach((summary, pairs) {
    for (final (inSummary, onPage) in pairs) {
      test(
        '"$inSummary" is in the summary and "$onPage" on the privacy page',
        () {
          expect(summary, contains(inSummary));
          expect(privacy, contains(onPage));
        },
      );
    }
  });

  test('no summary uses an em dash', () {
    for (final s in facts.keys) {
      expect(s, isNot(contains('—')));
    }
  });
}
