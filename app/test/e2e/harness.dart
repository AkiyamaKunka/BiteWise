/// The owner's phone for the end-to-end stories (test/e2e).
///
/// Everything between the edges is the app's own code, wired the way
/// lib/ui/di.dart wires it:
///   * `SqfliteMealsDao` on an in-memory SQLite database (the real schema,
///     opened by `openAppDatabase`);
///   * `AppSettings` and its `SettingsStore` adapter on mocked
///     preferences, with the owner's setup: their own server on Claude Plan,
///     AI sharing allowed for it;
///   * `UsualFoods` over `UsualChoices` on the same preferences, with the
///     `lookupTakesIt` rule di.dart hands it, and the app's own
///     `mealsChangedSignal`;
///   * `PhotoPipeline`, `DefaultNlExecutor`, `MealInUseRegistry`;
///   * `MealAssist` with its `AssistLocalState`, `AssistDailyBudget` and
///     the `RestaurantAssistControls` the screens get;
///   * the screens: Today, the meal editor, the Log sheet, My usual foods,
///     Fix a meal, Settings (for Stop Sharing).
///
/// The seams that are faked, and why:
///   * [StubAi] (AnalyzerService): the model. Every photo and sentence that
///     would leave the phone lands here and is counted.
///   * [StubLookups] (LookupClient): the restaurant lookup's network call.
///     It counts against the real daily ledger as the server client does.
///   * [MemoryDocStore]: the disk under `LocalNoBackupStore`. A widget test
///     runs in fake time, where real file I/O never completes; the store
///     keeps the same JSON text, name rule, version stamp and size cap in
///     memory. (A story with no widgets can pass a real folder instead.)
///   * the photo's hash and thumbnail (`compute()` isolates and an image
///     decode): md5 inline, no thumbnail.
///   * the photo library, the share sheet, notifications, Apple Maps and
///     the photo's GPS: not built. Lookups take the brand path only.
///   * [StoryShell] stands in for HomeShell (lib/ui/app.dart), which builds
///     Today with the device clock: it repeats HomeShell's wiring for
///     Today, the + button and the meals signal, with the story's clock.
///   * the consent sheet for turning lookups on is not shown:
///     [Phone.turnLookupsOn] writes what its answer writes, through the
///     real settings adapter. Twenty lookups in a day (the daily cap) are
///     written to the real ledger directly.
///
/// Two things inside real parts read the device clock and take no other:
///   * the pipeline stamps a photo meal's `timestamp` column with it.
///     [Phone.photo] sets that column to the story's clock right after
///     the save, which is what the owner's phone would have written;
///   * the screens the Log sheet pushes label days with it. The stories
///     are dated before any day a test can run on, so a label never reads
///     "Today" by accident. Enter manually and the describe preview date
///     the new meal with it, so a story pushes that editor itself with its
///     own clock ([pushFromLog]) instead of going through the sheet.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/assist/assist_local_state.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/meal_assist.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:calorie_tracker/services/nl/executor.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/services/usual/usual_choices.dart'
    show usualChoicesPrefsKey;
import 'package:calorie_tracker/services/usual/usual_foods.dart';
import 'package:calorie_tracker/ui/di.dart' show createSettingsStore;
import 'package:calorie_tracker/ui/format.dart'
    show byMealClock, displayClock, friendlyHistoryDay;
import 'package:calorie_tracker/ui/meal_in_use.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/refresh_signal.dart';
import 'package:calorie_tracker/ui/restaurant_assist_controls.dart';
import 'package:calorie_tracker/ui/screens/add_flow.dart';
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/assist_fixtures.dart' show assistMcdUrl, bigMacFound;
import '../ui/fakes.dart' show FakeIntake, FakePicker;

export 'package:calorie_tracker/l10n/app_localizations.dart'
    show AppLocalizations, lookupAppLocalizations;

export '../support/assist_fixtures.dart' show bigMacAnalysis, bigMacFound;
export '../ui/fakes.dart' show foodItem;

/// SQLite in this isolate (no worker isolate): its futures complete in
/// microtasks, so the real DAO also runs inside a widget test's fake time.
void useInProcessSqlite() => sqfliteFfiInit();

/// A new, empty in-memory database with the app's schema, opened by the
/// app's own `openAppDatabase`. Each call gets its own database: sqflite
/// keeps one instance per path and factory, and ':memory:' is one path,
/// so every database here is opened through a factory of its own.
Future<Database> openEmptyDatabase() {
  databaseFactoryOrNull = createDatabaseFactoryFfi(noIsolate: true);
  return openAppDatabase(path: inMemoryDatabasePath);
}

// ─── The faked edges ───────────────────────────────────────────────────

/// The model. Counts every call; a photo gets [nextPhoto], a sentence
/// [nextText].
class StubAi implements AnalyzerService {
  int photoCalls = 0;
  int textCalls = 0;
  int leftoverCalls = 0;

  /// Every call that would have reached a model.
  int get calls => photoCalls + textCalls + leftoverCalls;

  Map<String, dynamic>? nextPhoto;
  Map<String, dynamic>? nextText;
  String? lastPrompt;
  List<Map<String, dynamic>>? lastRecentMeals;

  static Map<String, dynamic>? _copy(Map<String, dynamic>? m) => m == null
      ? null
      : (jsonDecode(jsonEncode(m)) as Map).cast<String, dynamic>();

  @override
  Future<AnalysisOutcome> analyzePhoto(Uint8List originalBytes,
      {List<Map<String, dynamic>>? recentMeals}) async {
    photoCalls++;
    lastRecentMeals = recentMeals;
    final reply = _copy(nextPhoto);
    return AnalysisOutcome(
        analysis: reply,
        isFood: reply != null && reply['is_food'] == true,
        error: reply == null ? 'no reply scripted' : null,
        wall: Duration.zero);
  }

  @override
  Future<Map<String, dynamic>?> textIntent(String prompt) async {
    textCalls++;
    lastPrompt = prompt;
    return _copy(nextText);
  }

  @override
  Future<Map<String, dynamic>?> leftoverIntent(
      Uint8List originalBytes, String originalCompact) async {
    leftoverCalls++;
    return null;
  }

  @override
  Future<String?> validateKey(String apiKey) async => null;

  @override
  Future<KeyProbe> probeKey(String apiKey) async =>
      const KeyProbe(KeyProbeResult.ok);
}

/// The owner's server on Claude Plan, as the lookup router names it.
const LookupSupport claudePlanSupport = LookupSupport(
  supported: true,
  recipient: LookupRecipient.claudePlan,
  locationAllowed: false,
  recipientHostTag: 'abcd1234',
);

/// A finished lookup from the owner's server. Its text is a search
/// summary, not the page's own words, so the app may only suggest it.
LookupOutcome planAnswer(Map<String, dynamic> json) => LookupOutcome(
      kind: LookupOutcomeKind.done,
      provider: LookupRecipient.claudePlan,
      result: LookupResult.parse(json, itemCount: 12),
      citedUrls: const [assistMcdUrl],
      evidence: const [
        LookupEvidence(
          url: assistMcdUrl,
          text: 'Big Mac 590 Cal. 25 g protein, 46 g carbs, 34 g fat.',
          verbatim: false,
        ),
      ],
    );

/// A lookup that found no published nutrition.
Map<String, dynamic> nothingPublished() => {
      ...bigMacFound(),
      'status': 'not_published',
      'matches': <Object>[],
    };

/// The restaurant lookup's network call. A lookup counts against the real
/// daily ledger before it is sent, as ServerLookupClient counts it; at the
/// cap nothing is sent.
class StubLookups implements LookupClient {
  StubLookups(this._budget);

  final AssistDailyBudget _budget;
  LookupSupport support = claudePlanSupport;

  /// Every request that was sent.
  final List<LookupRequest> submits = [];
  final List<String> polls = [];

  /// The answer to the next submit (default: McDonald's published Big Mac).
  Future<LookupOutcome> Function(LookupRequest request)? onSubmit;
  Future<LookupOutcome> Function(String jobId)? onPoll;

  @override
  LookupSupport lookupSupport() => support;

  @override
  Future<LookupOutcome> submit(
    LookupRequest request, {
    List<String> chainDomains = const [],
    LookupCancelToken? cancel,
    LookupRecipient? expectedRecipient,
    String? expectedRecipientStamp,
  }) async {
    if (!_budget.tryStartLookup(0)) {
      return const LookupOutcome(
        kind: LookupOutcomeKind.failed,
        provider: LookupRecipient.claudePlan,
        failure: LookupFailure(LookupFailureCode.dailyCap, transient: true),
      );
    }
    submits.add(request);
    final f = onSubmit;
    return f == null ? planAnswer(bigMacFound()) : f(request);
  }

  @override
  Future<LookupOutcome> poll(String jobId) async {
    polls.add(jobId);
    final f = onPoll;
    return f == null ? planAnswer(bigMacFound()) : f(jobId);
  }
}

/// `LocalNoBackupStore` with a map where the folder was: the same document
/// names, `v` stamp, JSON text and size cap, and no file I/O. It records
/// which documents were read and written.
class MemoryDocStore extends LocalNoBackupStore {
  MemoryDocStore()
      : super(
          root: () async => Directory.systemTemp,
          createMissingDirectory: false,
        );

  static final RegExp _name = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
  final Map<String, String> files = {};
  final List<String> reads = [];
  final List<String> writes = [];

  @override
  Future<Map<String, Object?>> read(String name, {int? version}) async {
    reads.add(name);
    if (!_name.hasMatch(name)) return {};
    final raw = files[name];
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final document = <String, Object?>{
        for (final e in decoded.entries) '${e.key}': e.value,
      };
      if (version != null && document['v'] != version) return {};
      return document;
    } catch (_) {
      return {};
    }
  }

  @override
  Future<bool> write(
    String name,
    Map<String, Object?> document, {
    required int version,
  }) async {
    if (!_name.hasMatch(name)) return false;
    final String text;
    try {
      text = jsonEncode(<String, Object?>{
        'v': version,
        for (final e in document.entries)
          if (e.key != 'v') e.key: e.value,
      });
    } catch (_) {
      return false;
    }
    if (utf8.encode(text).length > localDocumentMaxBytes) return false;
    writes.add(name);
    files[name] = text;
    return true;
  }

  @override
  Future<bool> delete(String name) async {
    if (!_name.hasMatch(name)) return false;
    files.remove(name);
    return true;
  }
}

class _MemoryKeys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

// ─── The phone ─────────────────────────────────────────────────────────

class Phone {
  Phone._(this.now);

  /// The phone's clock. A story moves it by assigning.
  DateTime now;
  DateTime clock() => now;

  late final Database db;
  late final SqfliteMealsDao dao;
  late final SharedPreferences prefs;
  late final AppSettings settings;
  late final SettingsStore store;
  final StubAi ai = StubAi();
  late final StubLookups lookups;
  late final AssistDailyBudget budget;
  late final LocalNoBackupStore docs;
  late final AssistLocalState assistState;
  late final PhotoPipeline pipeline;
  late final DefaultNlExecutor executor;
  final MealInUseRegistry mealInUse = MealInUseRegistry();
  late final MealAssist assist;
  late final RestaurantAssistControls controls;
  late final UsualChoices choices;
  late final UsualFoods usual;
  late final UiServices services;
  int _photos = 0;

  /// Which phone of the test file this is: its photos are its own (an
  /// import brings the other phone's photo ledger along).
  static int _booted = 0;
  final int _serial = ++_booted;

  /// The in-memory documents, when the phone was booted without a folder.
  MemoryDocStore get memory => docs as MemoryDocStore;

  /// The mode, 'Use photo location' and the consent, read fresh: the one
  /// view MealAssist and usual foods both read (di.dart).
  AssistSettingsView assistSettingsView() => AssistSettingsView(
        mode: AssistMode.fromWire(settings.restaurantAssist),
        useLocation: settings.restaurantAssistLocation,
        consentAt: settings.restaurantAssistConsentAt,
        consentRecipient: settings.restaurantAssistConsentRecipient,
      );

  /// Boots the phone at [now]. [preferences] are what is already stored
  /// (a corrupt value, say); [folder] puts the lookup's documents on a
  /// real disk (a story without widgets only).
  static Future<Phone> boot(
    DateTime now, {
    Map<String, Object> preferences = const {},
    Directory? folder,
  }) async {
    final p = Phone._(now);
    SharedPreferences.setMockInitialValues(preferences);
    p.prefs = await SharedPreferences.getInstance();
    p.settings =
        await AppSettings.load(prefs: p.prefs, keyStore: _MemoryKeys());
    // The owner's setup: their own server on Claude Plan (a made-up
    // address and key; nothing here opens a connection).
    await p.settings.setServerBaseUrl('https://chopstats.test');
    await p.settings.setServerApiKey('test-key');
    await p.settings.setServerBackend('claude');
    await p.settings.setProvider(AiProvider.server);
    await p.settings.setAiConsent('server:claude', granted: true);
    p.store = createSettingsStore(p.settings);

    p.db = await openEmptyDatabase();
    p.dao = SqfliteMealsDao(p.db, clock: p.clock);

    p.budget = AssistDailyBudget(p.prefs, clock: p.clock);
    p.lookups = StubLookups(p.budget);
    p.pipeline = PhotoPipeline(
      dao: p.dao,
      analyzer: p.ai,
      onMealSaved: signalMealsChanged,
      hasher: (bytes) async => md5.convert(bytes).toString(),
      thumbnailer: (_) async => null,
      clock: p.clock,
    );
    p.executor = DefaultNlExecutor(p.dao, p.ai, p.settings);

    p.docs = folder == null
        ? MemoryDocStore()
        : LocalNoBackupStore(
            root: () async => folder,
            createMissingDirectory: true,
            clock: p.clock,
          );
    p.assistState = AssistLocalState(p.docs, clock: p.clock);
    p.assist = MealAssist(
      dao: p.dao,
      lookups: p.lookups,
      analyzerBusy: ValueNotifier<int>(0),
      pipelineIdle: () => p.pipeline.isIdle,
      inUse: p.mealInUse.isInUse,
      budget: p.budget,
      state: p.assistState,
      settings: p.assistSettingsView,
      settingsChanges: p.settings,
      mealsChanged: mealsChangedSignal,
      onMealsChanged: signalMealsChanged,
      inForeground: () => true,
      country: () => 'US',
      // US Central: the meal country's time-zone check passes wherever
      // the tests run (TZ=UTC, Asia/Shanghai).
      utcOffset: () => const Duration(hours: -6),
      clock: p.clock,
    );
    p.controls = RestaurantAssistControls(
      lookupSupport: p.lookups.lookupSupport,
      clearLearnedPlaces: p.assist.clearLearnedPlaces,
      consentNeeded: p.assist.consentNeeded,
      now: p.clock,
      lookupNow: p.assist.lookupNow,
      act: p.assist.act,
      canLearnPlace: p.assist.canLearnPlace,
      unseen: p.assist.unseen,
      markSeen: p.assist.markSeen,
    );

    p.choices = UsualChoices(p.prefs, clock: p.clock);
    p.usual = UsualFoods(
      dao: p.dao,
      choices: p.choices,
      mealsChanged: mealsChangedSignal,
      onMealsChanged: signalMealsChanged,
      lookupTakesIt: (analysis) {
        final view = p.assistSettingsView();
        if (view.mode == AssistMode.off) return false;
        return usualLookupTakesIt(analysis,
            settings: view, support: p.lookups.lookupSupport());
      },
      clock: p.clock,
    );

    p.services = UiServices(
      dao: p.dao,
      analyzer: p.ai,
      executor: p.executor,
      settings: p.store,
      settingsChanges: p.settings,
      picker: FakePicker(),
      photoIntake: FakeIntake(),
      requestPhotoPermission: () async => true,
      processPhoto: p.pipeline.enqueue,
      mealInUse: p.mealInUse,
      restaurantAssist: p.controls,
      usualFoods: p.usual,
    );
    return p;
  }

  /// Ends the story: the assist's timers are cancelled and the database
  /// closed.
  Future<void> shutDown() async {
    assist.dispose();
    await db.close();
  }

  /// Restaurant lookups on ([mode]: 'auto' or 'always'), consented to the
  /// owner's server just now.
  Future<void> turnLookupsOn(String mode) => store.updateRestaurantAssist(
        mode: mode,
        consentAt: now,
        consentRecipient: lookups.support.recipientStamp,
      );

  // ── Photos ──

  /// A photo taken now reaches the pipeline (the watcher's path unless
  /// [deliberate]) and the model answers [analysis]. The saved meal's id.
  Future<int> photo(Map<String, dynamic> analysis,
      {bool deliberate = false}) async {
    ai.nextPhoto = analysis;
    final n = ++_photos;
    final outcome = await pipeline.enqueue(IntakePhoto(
      Uint8List.fromList(utf8.encode('phone $_serial photo $n')),
      'asset-$_serial-$n',
      'IMG_$n.jpg',
      capturedAt: now,
      deliberate: deliberate,
    ));
    expect(outcome.kind, PhotoOutcomeKind.saved, reason: outcome.message);
    final id = await lastMealId();
    // The pipeline stamps the row's `timestamp` with the device clock,
    // which it does not take from outside. On the owner's phone that is
    // the story's clock, so the story writes it: the restaurant lookup
    // measures a meal's age from this column.
    await db.update('meals', {'timestamp': now.toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
    return id;
  }

  /// The clock moves on by [span] (seconds or minutes), in the story and
  /// in the test's fake time alike, so a timer the app set fires.
  Future<void> wait(WidgetTester tester, Duration span) async {
    now = now.add(span);
    await tester.pump(span);
    await tester.pumpAndSettle();
  }

  // ── What is stored ──

  Future<int> lastMealId() async =>
      (await db.rawQuery('SELECT MAX(id) AS id FROM meals')).single['id']
          as int;

  Future<int> mealCount() async =>
      (await db.rawQuery('SELECT COUNT(*) AS n FROM meals')).single['n']
          as int;

  /// The meals row [id], as stored.
  Future<Map<String, Object?>> row(int id) async =>
      (await db.query('meals', where: 'id = ?', whereArgs: [id])).single;

  /// The analysis column of meal [id], byte for byte.
  Future<String> raw(int id) async => (await row(id))['analysis'] as String;

  Future<Map<String, dynamic>> analysis(int id) async =>
      (jsonDecode(await raw(id)) as Map).cast<String, dynamic>();

  Future<Map<String, dynamic>> item(int id, [int index = 0]) async =>
      (((await analysis(id))['food_items'] as List)[index] as Map)
          .cast<String, dynamic>();

  Future<bool> corrected(int id) async => (await row(id))['corrected'] == 1;

  /// Where meal [id] stands in the list the Fix screen's model is shown
  /// (the last 7 days in meal-clock order): the index its reply names.
  Future<int> chatIndexOf(int id) async {
    final shown = byMealClock(await dao.recentMeals(days: textEditWindowDays));
    final at = shown.indexWhere((m) => m.id == id);
    expect(at, isNot(-1), reason: 'meal $id is in the 7-day list');
    return at;
  }

  /// The stored choices document (hidden foods, offers turned down).
  Map<String, dynamic> storedChoices() {
    final text = prefs.getString(usualChoicesPrefsKey);
    return text == null
        ? const {}
        : (jsonDecode(text) as Map).cast<String, dynamic>();
  }
}

/// A photo reply as the model writes it: [items] with totals that are
/// their sums, eaten [context] ('home', 'restaurant', …), the model
/// [confidence] sure.
Map<String, dynamic> aiSays(
  List<Map<String, dynamic>> items, {
  String? description,
  String confidence = 'medium',
  String context = 'home',
}) {
  num sum(String key) =>
      items.fold<num>(0, (s, i) => s + (i[key] as num? ?? 0));
  return {
    'is_food': true,
    'meal_description':
        description ?? items.map((i) => i['name']).join(', '),
    'total_calories': sum('estimated_calories'),
    'total_protein_g': sum('protein_g'),
    'total_carbs_g': sum('carbs_g'),
    'total_fat_g': sum('fat_g'),
    'estimate_confidence': confidence,
    'restaurant_context': context,
    'portion_state': 'whole',
    'order_merchant': '',
    'food_items': items,
  };
}

// ─── The screens ───────────────────────────────────────────────────────

/// HomeShell's Today tab with the story's clock: Today as HomeShell
/// builds it (app.dart), the + button that opens the Log sheet and sends
/// the meals signal when it closes, a reload on every meals signal, and a
/// reload when the app comes back to the foreground.
class StoryShell extends StatefulWidget {
  const StoryShell({super.key, required this.phone});
  final Phone phone;

  @override
  State<StoryShell> createState() => _StoryShellState();
}

class _StoryShellState extends State<StoryShell>
    with WidgetsBindingObserver {
  final GlobalKey<TodayScreenState> _today = GlobalKey<TodayScreenState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    mealsChangedSignal.addListener(_reload);
  }

  @override
  void dispose() {
    mealsChangedSignal.removeListener(_reload);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _reload() {
    if (mounted) _today.currentState?.reload();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.phone;
    final s = p.services;
    return Scaffold(
      body: TodayScreen(
        key: _today,
        dao: s.dao,
        mealInUse: s.mealInUse,
        restaurantAssist: s.restaurantAssist,
        settings: s.settings,
        usual: s.usualFoods,
        now: p.clock,
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('addMealFab'),
        onPressed: () => openAddFlow(context, s,
            onChanged: () async => signalMealsChanged()),
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// The app in [locale] around [home] (default: the [StoryShell]), on a
/// tall phone so nothing a story taps is off screen.
Future<void> pumpApp(
  WidgetTester tester,
  Phone phone, {
  Locale locale = const Locale('en'),
  Widget? home,
  Size size = const Size(800, 2400),
  double textScale = 1.0,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    key: UniqueKey(),
    locale: locale,
    theme: theme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: textScale == 1.0
        ? null
        : (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
    home: home ?? StoryShell(phone: phone),
  ));
  await tester.pumpAndSettle();
}

/// The app is left and opened again (a new morning): Today reloads, as
/// HomeShell reloads it on resume.
Future<void> reopen(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

/// Pushes [screen] over the app the way the Log sheet pushes one, and
/// sends the meals signal when it closes (openAddFlow's onChanged). For
/// the screens the Log sheet would build with the device clock (Enter
/// manually, the describe preview): the story passes its own clock.
Future<void> pushFromLog(WidgetTester tester, Widget screen) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  unawaited(navigator
      .push(MaterialPageRoute<Object?>(builder: (_) => screen))
      .then((_) => signalMealsChanged()));
  await tester.pumpAndSettle();
}

/// The screen's back button (whatever the language calls it).
Future<void> goBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}

/// The day's eaten total as Today shows it: the number in the ring's
/// centre. Run 7 (U15, one hero number) took the "N kcal" line beside the
/// ring away, so the centre is where the owner reads the total; its unit
/// is the caption under it (`ringKcalToday`).
String todayEaten(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('ringCenterValue'))).data!;

/// The snackbar on screen goes away (its Undo with it).
Future<void> dismissSnackBar(WidgetTester tester) async {
  for (final m in tester
      .stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
    m.clearSnackBars();
  }
  await tester.pumpAndSettle();
}

// ─── Copy ──────────────────────────────────────────────────────────────

AppLocalizations copyFor(Locale locale) => lookupAppLocalizations(locale);

/// A stored clock ('07:40 AM') as the screens show it in [l]'s language.
String shownClock(AppLocalizations l, String stored) =>
    displayClock(stored, localeName: l.localeName);

/// A day as the screens label it in [l]'s language, read at [now].
String shownDay(AppLocalizations l, String date, DateTime now) =>
    friendlyHistoryDay(date,
        now: now,
        localeName: l.localeName,
        pattern: l.historyDayPattern,
        todayLabel: l.tabToday);
