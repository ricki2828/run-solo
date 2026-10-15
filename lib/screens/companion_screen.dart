import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/services.dart';
import '../state/companion.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/section_card.dart';

/// What the consent screen says, in one place so the screen, the privacy page
/// and the store copy can be checked against it. Plain words, no em dashes.
const String kCompanionIntro =
    'After a run, the companion sends you a short note in Telegram with the '
    'numbers that matter. It may ask how a run felt, suggest up to two '
    'sessions a week, and check in with you before and after a planned run. '
    'WhatsApp is coming later.';

/// The check-ins disclosure. Same words as privacy section 2b, "Check-ins".
const String kCompanionCheckins =
    'The companion can check in with buttons and nothing typed: how your '
    'body feels the evening before a planned session, going or skipping on '
    'the morning (with why, if you skip), what was behind an easy run that '
    'came out slower and harder than usual, and on Sunday how many runs you '
    'want next week. If you skip, the session moves to a later day. Sore '
    'and ill are health information; the companion uses them only to go '
    'lighter, and they never leave our server, so no writing service or '
    'weather service ever sees them. Answers are kept 14 days, then '
    'deleted, and they are left out of backups. They show below under '
    'Check-ins, and Delete everything removes them at once. Home asks our '
    'server for your next session and the coach\'s latest note; the reply '
    'says whether a session moved and nothing else about your answers.';

const String kCompanionSent =
    'Each run\'s summary: type, date and start time, time zone, duration, '
    'distance, pace, True Pace, verdict, minutes in each heart rate zone, '
    'climb, and the name of the area where you started. Plus your pace for '
    'each km, the time of each rep in a structured session, and an outline '
    'of your route with the first and last stretch cut off. It has no '
    'coordinates, but a distinctive route could still be recognised by '
    'someone who knows it. You can switch it off in Settings, Companion. For an '
    'interval session it also sends its name (a session you built yourself '
    'goes only as a short code, the words never leave your phone), reps '
    'done, work pace, how far apart the reps were and recovery pace. Plus how '
    'a run felt when '
    'you tap Easy, Right or Hard. Never your GPS points, never the street, '
    'never your heart rate trace.';

const String kCompanionWhere =
    'To our server, which keeps it to write your notes. A writing service '
    '(OpenRouter) turns the numbers into a few words; it is asked not to keep '
    'anything. Notes reach you through Telegram. When WhatsApp arrives, Meta '
    'keeps WhatsApp messages for up to 30 days.';

const String kCompanionDelete =
    'Settings, Companion, Delete everything wipes your data from our server. '
    'You can also send DELETE to the companion in Telegram. Notes already in '
    'your chat stay there until you delete them.';

/// "Show route shape on cards" (on until the runner turns it off). One line
/// under the switch; same words as privacy section 2b.
const String kCompanionRouteBlurb =
    'Draws your route on the card as an outline with the ends cut off. No '
    'coordinates are sent, but a distinctive route could be recognised.';

/// "Show trail names on cards" (off until the runner turns it on). One line
/// under the switch.
const String kCompanionPlaceNamesBlurb =
    'Puts the name of your trail on its cards, like "Kastro loop". It comes '
    'from the street or place you started in. Off, no name leaves your phone.';

/// "Weather in suggestions" (off until the runner turns it on). The blurb
/// sits under the switch; the sheet is the disclosure shown before it turns
/// on. Same words as privacy section 2b.
const String kCompanionWeatherBlurb =
    'Lets a suggestion say if tomorrow looks hot or wet. Off, no area leaves '
    'your phone.';

const String kCompanionWeatherSheetTitle = 'WEATHER IN SUGGESTIONS';

const List<String> kCompanionWeatherSheet = [
  'What is sent: the rough area where each run started, rounded to about '
      '11 km. No place name, no street, no route, nothing that says who you '
      'are.',
  'To whom: our server passes that area, and your time zone, to Open-Meteo, '
      'a weather service, to ask for the forecast there. Our server also '
      'keeps your latest area for up to 30 days after the run it came from.',
  'Why: so a suggestion can say tomorrow looks hot or wet. Weather is the '
      'reason, never the suggestion.',
  'You can turn it off any time here. Our server forgets your area as soon '
      'as your phone can reach it. Backups keep data for up to 14 days.',
];

/// The companion's setup step (onboarding) and Settings > Companion. Off:
/// the consent copy with "Turn on" and "Not now" at equal weight, neither
/// pre-selected. Waiting and failed: the enrolment state with a retry. On:
/// what the companion knows, with Delete everything and Turn off.
class CompanionScreen extends StatefulWidget {
  const CompanionScreen({super.key, this.onboarding = false});

  /// Part of first-run setup: no back arrow, and the screen closes by itself
  /// once the runner has answered.
  final bool onboarding;

  @override
  State<CompanionScreen> createState() => _CompanionScreenState();
}

class _CompanionScreenState extends State<CompanionScreen> {
  CompanionController? _ctl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = AppServices.of(context).companion;
    if (identical(c, _ctl)) return;
    _ctl?.removeListener(_changed);
    _ctl = c?..addListener(_changed);
  }

  @override
  void dispose() {
    _ctl?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (widget.onboarding && _ctl!.enrolled) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ctl = _ctl;
    if (ctl == null) return const Scaffold(body: SizedBox.shrink());
    return Scaffold(
      appBar: widget.onboarding ? null : const RunAppBar(title: 'COMPANION'),
      body: ctl.enrolled
          ? const CompanionKnowsView()
          : CompanionConsentView(
              controller: ctl,
              onboarding: widget.onboarding,
              onNotNow: () async {
                await ctl.notNow();
                if (context.mounted) Navigator.of(context).pop(false);
              },
            ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(top: Space.x24, bottom: Space.x8),
      child: Text(
        text.toUpperCase(),
        style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
      ),
    );
  }
}

/// A choice button. "Turn on" and "Not now" use the same one, so neither
/// looks like the default.
class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.button),
        child: Container(
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.button),
            border: Border.all(color: t.inkPrimary, width: 2),
          ),
          child: Text(
            label,
            style: RunSoloType.body17.copyWith(
              fontWeight: FontWeight.w700,
              color: onTap == null ? t.inkMuted : t.inkPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class CompanionConsentView extends StatefulWidget {
  const CompanionConsentView({
    super.key,
    required this.controller,
    required this.onNotNow,
    this.onboarding = false,
  });
  final CompanionController controller;
  final Future<void> Function() onNotNow;
  final bool onboarding;

  @override
  State<CompanionConsentView> createState() => _CompanionConsentViewState();
}

class _CompanionConsentViewState extends State<CompanionConsentView> {
  final _code = TextEditingController();

  CompanionController get controller => widget.controller;
  bool get onboarding => widget.onboarding;
  Future<void> Function() get onNotNow => widget.onNotNow;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final services = AppServices.of(context);
    final coding = controller.phase == CompanionPhase.awaitingCode;
    final waiting = controller.phase == CompanionPhase.waiting || coding;
    final failed = controller.phase == CompanionPhase.failed;
    Widget body(String s) =>
        Text(s, style: RunSoloType.body15.copyWith(color: t.inkSecondary));
    return PinnedFooterLayout(
      content: [
        SizedBox(height: onboarding ? Space.x32 : Space.x16),
        Text('RUN COMPANION', style: text.displayMedium),
        const SizedBox(height: Space.x12),
        body(kCompanionIntro),
        const _Heading('What leaves your phone'),
        body(kCompanionSent),
        const _Heading('Check-ins'),
        body(kCompanionCheckins),
        const _Heading('Where it goes'),
        body(kCompanionWhere),
        const _Heading('How to delete it'),
        body(kCompanionDelete),
        const SizedBox(height: Space.x12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('companion-privacy'),
            onPressed: () =>
                services.transfer.openUrl(Uri.parse(kCompanionPrivacyUrl)),
            child: const Text('Read the privacy page'),
          ),
        ),
        const SizedBox(height: Space.x12),
      ],
      footer: [
        if (waiting)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x12),
            child: Text(
              coding
                  ? 'Type the 6-digit code Telegram just sent you.'
                  : 'In Telegram, tap Start. Waiting for your message.',
              key: const ValueKey('companion-waiting'),
              style: RunSoloType.body15.copyWith(color: t.inkPrimary),
            ),
          ),
        if (coding) ...[
          TextField(
            key: const ValueKey('companion-code'),
            controller: _code,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 6,
            style: RunSoloType.display44.copyWith(color: t.inkPrimary),
            decoration: InputDecoration(
              hintText: '123456',
              hintStyle: RunSoloType.display44.copyWith(color: t.inkMuted),
              counterText: '',
            ),
          ),
          if (controller.problem != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.x12),
              child: Text(
                controller.problem!,
                key: const ValueKey('companion-problem'),
                style: RunSoloType.body15.copyWith(color: t.semDanger),
              ),
            ),
          _ChoiceButton(
            key: const ValueKey('companion-confirm'),
            label: 'Confirm',
            onTap: () => controller.submitCode(_code.text),
          ),
          const SizedBox(height: Space.x12),
        ],
        if (failed && controller.problem != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x12),
            child: Text(
              controller.problem!,
              key: const ValueKey('companion-problem'),
              style: RunSoloType.body15.copyWith(color: t.semDanger),
            ),
          ),
        if (waiting)
          _ChoiceButton(
            key: const ValueKey('companion-cancel'),
            label: 'Cancel',
            onTap: controller.cancel,
          )
        else
          Row(
            children: [
              Expanded(
                child: _ChoiceButton(
                  key: const ValueKey('companion-turn-on'),
                  label: failed ? 'Try again' : 'Turn on',
                  onTap: controller.turnOn,
                ),
              ),
              const SizedBox(width: Space.x12),
              Expanded(
                child: _ChoiceButton(
                  key: const ValueKey('companion-not-now'),
                  label: 'Not now',
                  onTap: onNotNow,
                ),
              ),
            ],
          ),
        const SizedBox(height: Space.x24),
      ],
    );
  }
}

/// "What the companion knows": GET /v1/me in plain words.
class CompanionKnowsView extends StatefulWidget {
  const CompanionKnowsView({super.key});

  @override
  State<CompanionKnowsView> createState() => _CompanionKnowsViewState();
}

class _CompanionKnowsViewState extends State<CompanionKnowsView> {
  CompanionMe? _me;
  bool _loading = true;
  bool _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  Future<void> _fetch() async {
    final ctl = AppServices.of(context).companion!;
    final me = await ctl.fetchMe();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (me != null) {
        _me = me;
        _problem = null;
      } else {
        _problem = ctl.problem ?? 'Could not read it. Try again.';
      }
    });
  }

  Future<void> _setWeather(bool on) async {
    final ctl = AppServices.of(context).companion!;
    if (on) {
      final yes = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).extension<RunSoloTokens>()!.bgRaised,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(Radii.sheet),
          ),
        ),
        builder: (_) => const CompanionWeatherSheet(),
      );
      if (yes != true || !mounted) return;
    }
    setState(() => _problem = null);
    await ctl.setWeather(on);
    if (!mounted) return;
    setState(() => _problem = ctl.problem);
  }

  Future<void> _setPlaceNames(bool on) async {
    final ctl = AppServices.of(context).companion!;
    setState(() => _problem = null);
    await ctl.setPlaceNames(on);
    if (!mounted) return;
    setState(() => _problem = ctl.problem);
  }

  Future<void> _setRouteShape(bool on) async {
    final ctl = AppServices.of(context).companion!;
    setState(() => _problem = null);
    await ctl.setRouteShape(on);
    if (!mounted) return;
    setState(() => _problem = ctl.problem);
  }

  Future<void> _remove() async {
    final ctl = AppServices.of(context).companion!;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final done = await ctl.deleteEverything();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!done) _problem = ctl.problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final me = _me;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
      children: [
        if (services.companion?.connectedTo case final who?)
          Padding(
            padding: const EdgeInsets.only(top: Space.x16),
            child: Text(
              'Connected to $who. If that is not you, tap Turn off now.',
              key: const ValueKey('companion-connected'),
              style: RunSoloType.body17.copyWith(
                color: t.inkPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ListenableBuilder(
          listenable: services.companion!,
          builder: (context, _) => !services.companion!.needsReconsent
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: Space.x16),
                  child: SectionCard(
                    key: const ValueKey('companion-reconsent'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'NEW: CHECK-INS',
                          style: RunSoloType.micro11.copyWith(
                            color: t.inkSecondary,
                          ),
                        ),
                        const SizedBox(height: Space.x8),
                        Text(
                          kCompanionCheckins,
                          style: RunSoloType.body15.copyWith(
                            color: t.inkPrimary,
                          ),
                        ),
                        const SizedBox(height: Space.x16),
                        Row(
                          children: [
                            Expanded(
                              child: _ChoiceButton(
                                key: const ValueKey('companion-agree'),
                                label: 'Agree',
                                onTap: _busy
                                    ? null
                                    : services.companion!.acceptConsent,
                              ),
                            ),
                            const SizedBox(width: Space.x12),
                            Expanded(
                              child: _ChoiceButton(
                                key: const ValueKey('companion-decline'),
                                label: 'Turn off',
                                onTap: _busy ? null : _remove,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
        ),
        const _Heading('What the companion knows'),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Space.x24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (me != null) ...[
          for (final (what, answer) in me.lines)
            _FactRow(what: what, answer: answer),
        ],
        if (me != null) ...[
          const _Heading('Check-ins'),
          Text(
            'Your answers to the coach\'s check-ins. Kept 14 days, then '
            'deleted. Delete everything removes them now.',
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
          if (me.checkinLines.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Space.x12),
              child: Text(
                'None in the last 14 days',
                key: const ValueKey('companion-checkins-none'),
                style: RunSoloType.body15.copyWith(
                  color: t.inkPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          for (final (what, answer) in me.checkinLines)
            _FactRow(what: what, answer: answer),
        ],
        if (_problem != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.x12),
            child: Text(
              _problem!,
              key: const ValueKey('companion-problem'),
              style: RunSoloType.body15.copyWith(color: t.semDanger),
            ),
          ),
        if (!_loading && me == null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                setState(() => _loading = true);
                _fetch();
              },
              child: const Text('Try again'),
            ),
          ),
        const _Heading('Cards'),
        ListenableBuilder(
          listenable: services.companion!,
          builder: (context, _) => _SwitchRow(
            title: 'Show route shape on cards',
            blurb: kCompanionRouteBlurb,
            switchKey: const ValueKey('companion-route-switch'),
            on: services.companion!.routeShapeOn,
            onChanged: _busy ? null : _setRouteShape,
          ),
        ),
        ListenableBuilder(
          listenable: services.companion!,
          builder: (context, _) => _SwitchRow(
            title: 'Show trail names on cards',
            blurb: kCompanionPlaceNamesBlurb,
            switchKey: const ValueKey('companion-place-names-switch'),
            on: services.companion!.placeNamesOn,
            onChanged: _busy ? null : _setPlaceNames,
          ),
        ),
        const _Heading('Weather'),
        ListenableBuilder(
          listenable: services.companion!,
          builder: (context, _) => _SwitchRow(
            title: 'Weather in suggestions',
            blurb: kCompanionWeatherBlurb,
            switchKey: const ValueKey('companion-weather-switch'),
            on: services.companion!.weatherOn,
            onChanged: _busy ? null : _setWeather,
          ),
        ),
        const _Heading('Your data'),
        Text(
          'Notes go to you through Telegram. Delete everything wipes your '
          'data from our server and turns the companion off. Turn off does '
          'the same.',
          style: RunSoloType.body15.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x16),
        _ChoiceButton(
          key: const ValueKey('companion-delete'),
          label: 'Delete everything',
          onTap: _busy ? null : _remove,
        ),
        const SizedBox(height: Space.x12),
        _ChoiceButton(
          key: const ValueKey('companion-turn-off'),
          label: 'Turn off',
          onTap: _busy ? null : _remove,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () =>
                services.transfer.openUrl(Uri.parse(kCompanionPrivacyUrl)),
            child: const Text('Read the privacy page'),
          ),
        ),
        const SizedBox(height: Space.x32),
      ],
    );
  }
}

/// One fact: what on the left, the answer on the right.
class _FactRow extends StatelessWidget {
  const _FactRow({required this.what, required this.answer});
  final String what;
  final String answer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Space.x12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineHair)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(
              what,
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
          ),
          const SizedBox(width: Space.x12),
          Expanded(
            flex: 6,
            child: Text(
              answer,
              textAlign: TextAlign.end,
              style: RunSoloType.body15.copyWith(
                color: t.inkPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A switch row: label, one line of why, and a Switch.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.blurb,
    required this.switchKey,
    required this.on,
    required this.onChanged,
  });
  final String title;
  final String blurb;
  final Key switchKey;
  final bool on;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(vertical: Space.x8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineHair)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                ),
                Text(
                  blurb,
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.x12),
          Switch(key: switchKey, value: on, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// What turning weather on means, in plain words, before it turns on.
/// Pops true for "Turn on weather", false for "Not now".
class CompanionWeatherSheet extends StatelessWidget {
  const CompanionWeatherSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    // The words scroll if the screen is small or the text is large; the two
    // buttons stay pinned underneath so they are always reachable.
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.screenGutter),
        child: Column(
          key: const ValueKey('companion-weather-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kCompanionWeatherSheetTitle,
                      style: RunSoloType.title28.copyWith(color: t.inkPrimary),
                    ),
                    for (final p in kCompanionWeatherSheet) ...[
                      const SizedBox(height: Space.x12),
                      Text(
                        p,
                        style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.x24),
            Row(
              children: [
                Expanded(
                  child: _ChoiceButton(
                    key: const ValueKey('companion-weather-on'),
                    label: 'Turn on',
                    onTap: () => Navigator.of(context).pop(true),
                  ),
                ),
                const SizedBox(width: Space.x12),
                Expanded(
                  child: _ChoiceButton(
                    key: const ValueKey('companion-weather-not-now'),
                    label: 'Not now',
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
