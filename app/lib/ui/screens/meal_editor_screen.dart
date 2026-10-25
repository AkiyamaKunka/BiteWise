/// Meal editor: create a meal by hand or edit/delete an existing one.
///
/// Every rule lives in ui/meal_edit_logic.dart (parsing, bounds, the
/// analysis merge) — this file is the form around it. Saving an EXISTING
/// meal goes through updateMealFields (keeps the row id, the photo's ledger
/// provenance, and marks corrected=1). A NEW meal's provenance depends on
/// how it arrived: MealSource.appManual (typed numbers, no photo, no hash),
/// MealSource.manualText (describe-a-meal preview, no hash), or
/// MealSource.appManualPhoto WITH the photo's md5 when the user hand-enters
/// a photo the model refused.
///
/// Write safety (design R6a): an existing meal's save is a compare-and-set
/// against the analysis text the draft was loaded from
/// (MealsDao.updateMealFieldsIfUnchanged). The row is read once more as the
/// editor opens (mealSnapshot): if the list handed over an older copy and
/// nothing was typed yet, the form shows the meal as stored. A meal that
/// changed while the editor was open (a leftover deduction, a chat fix, a
/// restaurant lookup) is never overwritten with the older copy: the save
/// says so and the form reloads. While open, the editor holds the meal in
/// the [MealInUseRegistry], so the restaurant assist leaves it alone.
///
/// The restaurant source card (design R7b; widgets/assist_source_card.dart)
/// sits at the top of a stored meal: where a chain's published numbers came
/// from, and the user's answers — Use AI estimate, Use published numbers,
/// Wrong restaurant (then 'Which restaurant?', our chain table only, and a
/// lookup of the chain picked), Not from a restaurant, Correct, and Look up
/// restaurant nutrition. Each writes at once, as the user's own change,
/// against the stored text the form was loaded from (MealAssist.act /
/// lookupNow); a meal that changed meanwhile says "This meal was just
/// updated — please review." and shows the newer meal. The buttons wait
/// while the form has unsaved typing, so a write never lands under it.
/// Opening a meal clears its 'updated' dot.
library;

import 'dart:convert' show jsonEncode;
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../../core/coerce.dart'
    show finiteAnalysis, isFoodTruthy, normalizeImageHash;
import '../../core/contracts.dart';
import '../../core/restaurant_assist_logic.dart'
    show acceptAssistSuggestion, dropAssistClaims, normalizeSourceUrl;
import '../../services/assist/meal_assist.dart'
    show
        AssistActionResult,
        AssistActionStatus,
        AssistRun,
        AssistSkip,
        AssistUserAction,
        kAssistPollInterval,
        kAssistPollWindow;
import '../../services/photo/filename_dates.dart'
    show captureWallClock, exifWallAndOffset;
import '../../services/photo/glasses.dart'
    show captureAnalysis, isMetaGlassesAnalysis;
import '../assist_view.dart';
import '../format.dart' show formatKcal, isoDate;
import '../l10n.dart';
import '../large_text.dart';
import '../meal_edit_logic.dart';
import '../meal_in_use.dart';
import '../restaurant_assist_controls.dart';
import '../services.dart' show SettingsStore;
import '../widgets/assist_source_card.dart';
import '../widgets/chain_picker_sheet.dart';
import '../widgets/glasses_badge.dart';
import '../widgets/restaurant_consent_sheet.dart'
    show restaurantManualLookupChoice;
import '../widgets/macro_chart.dart';
import '../widgets/small_spinner.dart';

class MealEditorScreen extends StatefulWidget {
  const MealEditorScreen({
    super.key,
    required this.dao,
    this.meal,
    this.initialDate,
    this.now,
    this.fromPhoto,
    this.makeThumb,
    this.initialAnalysis,
    this.newMealSource = MealSource.appManual,
    this.inUse,
    this.assist,
    this.settings,
    this.openUrl,
    this.assistPollInterval = kAssistPollInterval,
  });

  final MealsDao dao;

  /// The restaurant assist (design R7b): the source card's answers, the
  /// manual lookup, the card's dot. Null (tests, a new meal) shows none of
  /// it.
  final RestaurantAssistControls? assist;

  /// The assist's mode and consent (the manual lookup asks for a consent
  /// that names the current recipient first). Null hides the lookup.
  final SettingsStore? settings;

  /// Opens the source page; injectable so widget tests need no
  /// url_launcher.
  final Future<bool> Function(Uri url)? openUrl;

  /// How often a manual lookup still running on the owner's server is
  /// asked again while the editor is open (for [kAssistPollWindow]).
  final Duration assistPollInterval;

  /// Held for [meal] while the editor is open (design R6a): the restaurant
  /// assist skips a meal the user is editing. Null: nothing to tell.
  final MealInUseRegistry? inUse;

  /// null = create a new meal.
  final Meal? meal;

  /// Pre-selected date for a new meal (the day the user came from).
  final String? initialDate;

  /// Injectable clock for tests.
  final DateTime Function()? now;

  /// Pre-fill for a NEW meal (describe-by-text preview): the model's
  /// analysis lands in the form so the user can check and correct the
  /// numbers BEFORE anything is written. [meal] stays null, so this is
  /// still an insert, not an in-place edit.
  final Map<String, dynamic>? initialAnalysis;

  /// source column for the inserted row — 'manual_text' for describe-by-text
  /// (server parity, spec §4.6), 'app_manual' for a hand-typed meal.
  final String newMealSource;

  /// Creating a meal FROM a photo the analyzer refused (not-food verdict or
  /// a permanent failure): the saved meal carries the photo's identity, so
  /// the ledger is closed (no re-offer loop) and the row gets its picture.
  /// The user supplies the numbers the model wouldn't.
  final IntakePhoto? fromPhoto;

  /// Thumbnail generator seam (production: makeMealThumb in a compute
  /// isolate); null skips the thumb.
  final Future<Uint8List?> Function(Uint8List original)? makeThumb;

  bool get isNew => meal == null;

  @override
  State<MealEditorScreen> createState() => _MealEditorScreenState();
}

class _MealEditorScreenState extends State<MealEditorScreen> {
  late MealDraft _draft;
  late final TextEditingController _desc;
  late final TextEditingController _cal;
  late final TextEditingController _pro;
  late final TextEditingController _carb;
  late final TextEditingController _fat;
  final List<({TextEditingController name, TextEditingController cal,
      TextEditingController pro, TextEditingController carb,
      TextEditingController fat})> _itemCtrls = [];
  List<String> _errors = const [];
  bool _saving = false;
  final ScrollController _scroll = ScrollController();

  /// The stored meal the form shows (design R6a): [MealEditorScreen.meal]
  /// at first, the row as re-read after a reload. Null for a new meal.
  Meal? _meal;

  /// The open-time re-read of the row ([_confirmBasis]) while it runs; a
  /// save of an existing meal waits for it. Never completes with an error.
  Future<void>? _basisRead;

  /// The stored row no longer matches what the form was loaded from (or is
  /// gone), and the user already typed over the older copy: the next save
  /// is answered with the conflict dialog instead of a write.
  bool _basisStale = false;

  /// The form's contents right after a load: equal to [_signature] while
  /// the user has typed nothing.
  String _loadedSignature = '';

  MealInUseHold? _hold;

  /// An answer to the restaurant source card is being written.
  bool _assistBusy = false;

  /// A manual restaurant lookup is running (polled while a server job).
  bool _lookingUp = false;

  /// [_load] is setting the fields one by one: their listener must not copy
  /// a half-updated form into the draft.
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final clock = widget.now ?? DateTime.now;
    final meal = widget.meal;
    final photo = widget.fromPhoto;
    final prefill = widget.initialAnalysis;
    // The photo's capture moment in the zone it was TAKEN in — the same
    // clock the automatic pipeline dates by, so a manual log of a photo
    // from before a flight agrees with an automatic one.
    final captured = photo?.capturedAt;
    final shot = (photo == null || captured == null)
        ? null
        : captureWallClock(captured, exifWallAndOffset(photo.bytes));
    _draft = meal != null
        ? MealDraft.fromMeal(meal)
        : (prefill != null
            // Describe-by-text preview: load the model's estimate into the
            // form. The synthetic row exists only to reuse the draft loader;
            // widget.meal stays null, so saving INSERTS.
            ? MealDraft.fromMeal(Meal(
                id: 0,
                date: shot != null
                    ? isoDate(shot)
                    : (widget.initialDate ?? isoDate(clock())),
                time: shot != null ? formatClock(shot) : formatClock(clock()),
                timestamp: clock().toIso8601String(),
                source: widget.newMealSource,
                analysis: prefill,
              ))
            : (MealDraft.blank(clock())
              // A photo's own capture moment beats "now" for a manual log.
              ..dateIso = shot != null
                  ? isoDate(shot)
                  : (widget.initialDate ?? MealDraft.blank(clock()).dateIso)
              ..time = shot != null
                  ? formatClock(shot)
                  : MealDraft.blank(clock()).time));
    _desc = TextEditingController(text: _draft.description);
    _cal = TextEditingController(text: _draft.calories);
    _pro = TextEditingController(text: _draft.protein);
    _carb = TextEditingController(text: _draft.carbs);
    _fat = TextEditingController(text: _draft.fat);
    for (final it in _draft.items) {
      _itemCtrls.add(_controllersFor(it));
    }
    // Live macro chart: rebuild as the user types.
    for (final c in [_cal, _pro, _carb, _fat]) {
      c.addListener(_syncTotals);
    }
    _meal = meal;
    if (meal != null) {
      _hold = widget.inUse?.acquire(meal.id);
      _loadedSignature = _signature();
      _basisRead = _confirmBasis();
      // Opened: the card's 'updated' dot goes (design R7b).
      final seen = widget.assist?.markSeen;
      if (seen != null) {
        seen(meal.id).then((_) {}, onError: (Object _) {});
      }
    }
  }

  /// Everything the form shows, as one string: unchanged while the user has
  /// typed nothing since the last load.
  String _signature() => [
        _desc.text,
        _cal.text,
        _pro.text,
        _carb.text,
        _fat.text,
        _draft.dateIso,
        _draft.time,
        for (final r in _itemCtrls) ...[
          r.name.text,
          r.cal.text,
          r.pro.text,
          r.carb.text,
          r.fat.text,
        ],
      ].join('\u0000');

  static String? _analysisText(Map<String, dynamic> analysis) {
    try {
      return jsonEncode(finiteAnalysis(analysis));
    } catch (_) {
      return null;
    }
  }

  /// [stored] is the meal [shown] was: same day, clock and analysis.
  static bool _sameBasis(Meal stored, Meal shown) {
    if (stored.date != shown.date || stored.time != shown.time) return false;
    final a = _analysisText(stored.analysis);
    return a != null && a == _analysisText(shown.analysis);
  }

  /// Reads the stored row behind the form (design R6a). Still the meal the
  /// form shows: its raw text becomes the save's compare-and-set basis. A
  /// newer row while nothing was typed and no save is under way: the form
  /// shows it instead (the list was a moment stale). A newer row the user
  /// is already typing over or saving, or a meal that is gone: the save
  /// answers with the conflict dialog. A failed read leaves the basis
  /// unknown; the save reads again.
  Future<void> _confirmBasis() async {
    final shown = _meal;
    if (shown == null) return;
    try {
      final MealSnapshot? snap;
      try {
        snap = await widget.dao.mealSnapshot(shown.id);
      } catch (_) {
        return;
      }
      if (!mounted || !identical(shown, _meal)) return;
      if (snap == null) {
        _basisStale = true;
      } else if (_sameBasis(snap.meal, shown)) {
        _draft.expectedRaw = snap.rawAnalysis;
      } else if (!_saving && _signature() == _loadedSignature) {
        _load(snap);
        setState(() {});
      } else {
        _basisStale = true;
      }
    } finally {
      _basisRead = null;
    }
  }

  /// The form, rebuilt from [snap]: the draft, every field and the item
  /// rows, with [snap]'s raw text as the save's basis.
  void _load(MealSnapshot snap) {
    _meal = snap.meal;
    final fresh = MealDraft.fromMeal(snap.meal)..expectedRaw = snap.rawAnalysis;
    for (final row in _itemCtrls) {
      row.name.dispose();
      row.cal.dispose();
      row.pro.dispose();
      row.carb.dispose();
      row.fat.dispose();
    }
    _itemCtrls.clear();
    // The total fields' listener (_syncTotals) copies all four into the
    // draft. Unmuted, setting kcal first copied the macros the form still
    // showed from the OLDER meal over the fresh draft's, so after an
    // accept (or Use AI estimate, a manual lookup, a conflict reload) the
    // form read the new kcal over the old macros, and Save wrote them.
    _loading = true;
    try {
      _desc.text = fresh.description;
      _cal.text = fresh.calories;
      _pro.text = fresh.protein;
      _carb.text = fresh.carbs;
      _fat.text = fresh.fat;
    } finally {
      _loading = false;
    }
    _draft = fresh;
    for (final it in fresh.items) {
      _itemCtrls.add(_controllersFor(it));
    }
    _basisStale = false;
    _loadedSignature = _signature();
  }

  ({TextEditingController name, TextEditingController cal,
      TextEditingController pro, TextEditingController carb,
      TextEditingController fat}) _controllersFor(MealItemDraft it) {
    final row = (
      name: TextEditingController(text: it.name),
      cal: TextEditingController(text: it.calories),
      pro: TextEditingController(text: it.protein),
      carb: TextEditingController(text: it.carbs),
      fat: TextEditingController(text: it.fat),
    );
    // Totals are DERIVED from the items (user decision 2026-08-06):
    // editing any item number moves the meal total in the same frame,
    // so a deleted or corrected row can never leave a stale total.
    for (final c in [row.cal, row.pro, row.carb, row.fat]) {
      c.addListener(_recomputeTotalsFromItems);
    }
    return row;
  }

  /// True when the totals are owned by the item rows. With no items the
  /// totals stay hand-editable — that is the manual-entry path.
  bool get _totalsDerived => _draft.items.isNotEmpty;

  /// Push the item sum into the total fields. Silent on the no-item path,
  /// and guarded against the listener loop (_cal's own listener fires
  /// _syncTotals, never this).
  /// [afterRemoval] lets the LAST item's deletion zero the totals.
  /// Without it the guard below trips — the row is already gone, so
  /// `_totalsDerived` is false — and the meal keeps the totals of an item
  /// that no longer exists (found on-device 2026-08-17: deleting the only
  /// item of a 350 kcal meal left the totals reading 350). The guard still
  /// protects a meal that never had an item breakdown, where hand-typed
  /// totals are the only source of truth.
  void _recomputeTotalsFromItems({bool afterRemoval = false}) {
    if (!_totalsDerived && !afterRemoval) return;
    for (var i = 0; i < _draft.items.length && i < _itemCtrls.length; i++) {
      final c = _itemCtrls[i];
      _draft.items[i]
        ..name = c.name.text
        ..calories = c.cal.text
        ..protein = c.pro.text
        ..carbs = c.carb.text
        ..fat = c.fat.text;
    }
    final t = _draft.itemTotals();
    final next = [
      _plain(t.calories.clamp(0, maxMealCalories)),
      _plain(t.protein.clamp(0, maxMacroGrams)),
      _plain(t.carbs.clamp(0, maxMacroGrams)),
      _plain(t.fat.clamp(0, maxMacroGrams)),
    ];
    final ctrls = [_cal, _pro, _carb, _fat];
    for (var i = 0; i < ctrls.length; i++) {
      // Assign only on CHANGE: an unconditional write would move the
      // caret and re-enter through the controller's own listener.
      if (ctrls[i].text != next[i]) ctrls[i].text = next[i];
    }
  }

  @override
  void dispose() {
    _hold?.release();
    _scroll.dispose();
    for (final c in [_desc, _cal, _pro, _carb, _fat]) {
      c.dispose();
    }
    for (final row in _itemCtrls) {
      row.name.dispose();
      row.cal.dispose();
      row.pro.dispose();
      row.carb.dispose();
      row.fat.dispose();
    }
    super.dispose();
  }

  void _syncTotals() {
    if (_loading) return;
    setState(() {
      _draft.calories = _cal.text;
      _draft.protein = _pro.text;
      _draft.carbs = _carb.text;
      _draft.fat = _fat.text;
    });
  }

  void _harvest() {
    _draft.description = _desc.text;
    _draft.calories = _cal.text;
    _draft.protein = _pro.text;
    _draft.carbs = _carb.text;
    _draft.fat = _fat.text;
    for (var i = 0; i < _draft.items.length; i++) {
      final c = _itemCtrls[i];
      _draft.items[i]
        ..name = c.name.text
        ..calories = c.cal.text
        ..protein = c.pro.text
        ..carbs = c.carb.text
        ..fat = c.fat.text;
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    // The open-time read decides what this save compares against: wait for
    // it (milliseconds). Landing now, a newer row no longer replaces the
    // form — the user pressed Save on what they saw — it is a conflict.
    final basis = _basisRead;
    if (basis != null) {
      _saving = true; // also the re-entry guard
      try {
        await basis;
      } finally {
        _saving = false;
      }
      if (!mounted) return;
    }
    _harvest();
    final errors = _draft.validate(context.l10n);
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      // The error card is the FIRST list child while Save is a pinned FAB:
      // on a scrolled form the rejection would be invisible and Save would
      // look like a dead button. Say it where the finger is, then scroll.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(errors.length == 1
              ? errors.single
              : context.l10n.editorErrsNeedFixing(errors.length))));
      if (_scroll.hasClients) {
        await _scroll.animateTo(0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
      return;
    }
    setState(() {
      _errors = const [];
      _saving = true;
    });
    try {
      final analysis = _draft.toAnalysis();
      if (widget.isNew) {
        final photo = widget.fromPhoto;
        // How the photo was taken (design G2a), from the intake's reading
        // of its bytes — never from a model's preview — as the automatic
        // pipeline stores it. Nor an assist block or a published flag a
        // describe preview's model wrote (design R6a): only a verified
        // restaurant lookup writes those.
        analysis.remove('capture');
        dropAssistClaims(analysis);
        final capture = photo?.capture;
        if (capture != null) analysis['capture'] = captureAnalysis(capture);
        // md5 of the ORIGINAL bytes: the same identity the watcher uses, so
        // marking the ledger 'saved' stops this photo being re-offered
        // forever (spec §6.2/§2.3).
        final hash = photo == null
            ? ''
            : normalizeImageHash(md5.convert(photo.bytes).toString());
        final result = await widget.dao.saveMealWithOutcome(
          Meal(
            id: 0, // assigned on insert
            date: _draft.dateIso.trim(),
            time: _draft.time.trim(),
            timestamp: (widget.now ?? DateTime.now)().toIso8601String(),
            // Photo-backed manual logs keep their own source; otherwise the
            // caller decides ('manual_text' for describe-by-text, server
            // parity spec §4.6; 'app_manual' for a hand-typed meal).
            source: photo == null
                ? widget.newMealSource
                : MealSource.appManualPhoto,
            imageHash: hash,
            fileId: photo?.assetId ?? '',
            analysis: analysis,
          ),
          markStatus: photo == null ? null : IngestionStatus.saved,
        );
        if (!result.inserted) {
          // The meals-table backstop: this photo already has a meal (a
          // background scan or an import settled it while the editor was
          // open) and the typed numbers were NOT written. Say so instead of
          // closing as a plain success, and go back with true so the add
          // flow closes too — Today then shows the meal that IS logged,
          // which is where the snackbar sends the user to edit it.
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              key: const Key('editorPhotoAlreadyLogged'),
              content: Text(context.l10n.editorPhotoAlreadyLogged)));
          Navigator.of(context).pop(true);
          return;
        }
        if (photo != null && widget.makeThumb != null) {
          try {
            final thumb = await widget.makeThumb!(photo.bytes);
            if (thumb != null) {
              await widget.dao.saveMealThumb(result.id, thumb);
            }
          } catch (_) {
            // A missing thumb is cosmetic; the meal is already saved.
          }
        }
      } else if (!await _saveExisting(analysis)) {
        if (!mounted) return;
        await _conflict();
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(true); // changed
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errors = [context.l10n.editorSaveFailed('$e')];
      });
    }
  }

  /// The compare-and-set save of a stored meal (design R6a). False — nothing
  /// written — when the row changed since the form was loaded, is gone, or
  /// the basis could not be read.
  Future<bool> _saveExisting(Map<String, dynamic> analysis) async {
    final meal = _meal!;
    if (_basisStale) return false;
    if (_draft.expectedRaw == null) {
      // The open-time read failed: try once more (typing since then means a
      // newer row cannot replace the form — it becomes a conflict).
      await _confirmBasis();
      if (!mounted) return false;
    }
    final raw = _draft.expectedRaw;
    if (raw == null || _basisStale) return false;
    return widget.dao.updateMealFieldsIfUnchanged(
      meal.id,
      expectedRaw: raw,
      analysis: analysis,
      date: _draft.dateIso.trim(),
      time: _draft.time.trim(),
    );
  }

  /// The meal changed while the editor was open: say so, then show it as
  /// it is now. The user's typed changes are not written over the newer
  /// meal; they redo them on the fresh form. A meal deleted meanwhile
  /// closes the editor.
  Future<void> _conflict() async {
    // The spinner stops before the dialog (an animating FAB behind a modal
    // never settles), and until the reload below every save is this
    // conflict again.
    setState(() {
      _saving = false;
      _basisStale = true;
    });
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('editorSaveConflict'),
        content: Text(ctx.l10n.editorSaveConflict),
        actions: [
          TextButton(
              key: const Key('editorSaveConflictOk'),
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(ctx.l10n.okButton)),
        ],
      ),
    );
    if (!mounted) return;
    final MealSnapshot? snap;
    try {
      snap = await widget.dao.mealSnapshot(_meal!.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errors = [context.l10n.editorSaveFailed('$e')]);
      return;
    }
    if (!mounted) return;
    if (snap == null) {
      Navigator.of(context).pop(true);
      return;
    }
    _load(snap);
    setState(() => _errors = const []);
  }

  // ── The restaurant source card (design R7b) ──

  /// The form shows something the user typed since the last load.
  bool get _dirty => _meal != null && _signature() != _loadedSignature;

  bool get _assistOn =>
      widget.settings != null && widget.settings!.restaurantAssist != 'off';

  /// The app has left the foreground (unknown counts as foreground).
  static bool _inBackground() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state != null && state != AppLifecycleState.resumed;
  }

  void _say(String text, {Key? key}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(key: key, content: Text(text)));
  }

  /// Re-reads the row behind the form after an assist write: an untouched
  /// form shows the newer meal; typing over an older copy becomes the
  /// save's conflict ([_confirmBasis]).
  Future<void> _refreshBasis() async {
    final read = _confirmBasis();
    _basisRead = read;
    await read;
    if (mounted) setState(() {});
  }

  /// The meal changed under an answer: say so, show the meal as it is now.
  Future<void> _assistConflict() async {
    _say(context.l10n.editorSaveConflict, key: const Key('assistConflict'));
    final MealSnapshot? snap;
    try {
      snap = await widget.dao.mealSnapshot(_meal!.id);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (snap == null) {
      Navigator.of(context).pop(true);
      return;
    }
    _load(snap);
    setState(() {});
  }

  /// One of the source card's answers, written at once against the stored
  /// text the form shows. 'Wrong restaurant' then asks which chain it was
  /// and looks that one up (mode on).
  Future<void> _assistAct(AssistUserAction action) async {
    final meal = _meal;
    final act = widget.assist?.act;
    if (meal == null || act == null) return;
    if (_assistBusy || _saving || _lookingUp) return;
    final l = context.l10n;
    if (_dirty) {
      _say(l.assistEditFirst, key: const Key('assistEditFirstSnack'));
      return;
    }
    final view = AssistView.of(meal.analysis);
    // A shared plate, a combo, an unclear size or unit: the published
    // numbers may not be what was eaten, so the user sees the new total
    // and confirms first.
    if (action == AssistUserAction.acceptSuggestion &&
        view.acceptNeedsConfirm &&
        await _confirmAccept(meal, view) != true) {
      return;
    }
    if (!mounted || !identical(meal, _meal)) return;
    setState(() => _assistBusy = true);
    AssistActionResult result;
    try {
      final basis = _basisRead;
      if (basis != null) await basis;
      final raw = _draft.expectedRaw;
      if (!mounted) return;
      if (raw == null || _basisStale || !identical(meal, _meal)) {
        result = const AssistActionResult(AssistActionStatus.changed);
      } else {
        result = await act(meal.id, action, expectedRaw: raw);
      }
    } finally {
      if (mounted) setState(() => _assistBusy = false);
    }
    if (!mounted) return;
    if (result.status == AssistActionStatus.changed) {
      await _assistConflict();
      return;
    }
    await _refreshBasis();
    if (!mounted) return;
    if (result.status == AssistActionStatus.done) {
      if (action == AssistUserAction.notFromRestaurant) {
        _say(l.assistNotRestaurantDone, key: const Key('assistDoneSnack'));
      } else if ((action == AssistUserAction.correct ||
              action == AssistUserAction.acceptSuggestion) &&
          result.placeLearned) {
        // Never a silent confirmation: the spot is remembered.
        _say(l.assistCorrectDone(view.brandLabel(l)),
            key: const Key('assistDoneSnack'));
      }
    }
    if (action == AssistUserAction.wrongRestaurant &&
        _assistOn &&
        widget.assist?.lookupNow != null &&
        _pickSendable()) {
      final pick = await showChainPickerSheet(context, exclude: view.chainKey);
      if (pick != null && mounted) await _lookUp(chainKey: pick);
    }
  }

  /// A chain the user picks can be looked up: not to the owner's server
  /// over http, whose https gate sends printed brands only (the pick is
  /// neither), and not where lookups cannot run at all.
  bool _pickSendable() {
    try {
      final support = widget.assist!.lookupSupport();
      return support.supported && support.locationAllowed;
    } catch (_) {
      return false;
    }
  }

  /// 'Use published numbers' on a suggestion whose numbers may not fit what
  /// was eaten: why, and the meal's total after it. True to go on.
  Future<bool?> _confirmAccept(Meal meal, AssistView view) {
    final l = context.l10n;
    final clock = widget.now ?? DateTime.now;
    final after = acceptAssistSuggestion(meal.analysis, now: clock());
    final total = after?['total_calories'];
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('assistAcceptConfirm'),
        title: Text(l.assistAcceptTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (view.whyText(l) case final why?) Text(why),
            if (total is num) ...[
              const SizedBox(height: 8),
              Text(l.assistAcceptTotal(formatKcal(total))),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.cancel)),
          FilledButton(
              key: const Key('assistAcceptConfirmOk'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.assistUsePublished)),
        ],
      ),
    );
  }

  /// 'Look up restaurant nutrition' (or the chain picked after 'Wrong
  /// restaurant'): the consent first when it does not name the current
  /// recipient, then MealAssist.lookupNow — asked again every
  /// [MealEditorScreen.assistPollInterval] while the owner's server still
  /// runs it, for up to [kAssistPollWindow] (later, the sweep collects it).
  Future<void> _lookUp({String? chainKey}) async {
    final meal = _meal;
    final assist = widget.assist;
    final settings = widget.settings;
    final lookupNow = assist?.lookupNow;
    if (meal == null || assist == null || settings == null) return;
    if (lookupNow == null || _lookingUp || _assistBusy || _saving) return;
    final l = context.l10n;
    if (_dirty) {
      _say(l.assistEditFirst, key: const Key('assistEditFirstSnack'));
      return;
    }
    final choice = await restaurantManualLookupChoice(context,
        settings: settings, controls: assist);
    if (choice == null || !mounted) return;
    final useLocation = chainKey == null && choice.useLocation;
    setState(() => _lookingUp = true);
    var run = const AssistRun(AssistSkip.error);
    try {
      final tries = kAssistPollWindow.inMicroseconds ~/
              widget.assistPollInterval.inMicroseconds +
          1;
      for (var i = 0; i < tries; i++) {
        if (i > 0) {
          await Future<void>.delayed(widget.assistPollInterval);
          if (!mounted) return;
          // Foreground only: in the background the server's job is left
          // to the sweep, which collects it when the app is back.
          if (_inBackground()) {
            run = const AssistRun(AssistSkip.background);
            break;
          }
        }
        run = await lookupNow(meal.id,
            useLocation: useLocation, chainKey: chainKey);
        if (!mounted) return;
        // Pending on the server, or the automatic lookup of this meal
        // still running here (its result is dropped: the editor holds the
        // meal): asked again shortly.
        if (run.code != AssistSkip.pending && run.code != AssistSkip.working) {
          break;
        }
      }
    } finally {
      if (mounted) setState(() => _lookingUp = false);
    }
    if (!mounted) return;
    if (run.wrote) {
      await _refreshBasis();
      return;
    }
    if (run.code == AssistSkip.casMiss) {
      _say(l.editorSaveConflict, key: const Key('assistConflict'));
      await _refreshBasis();
      return;
    }
    final message = run.code == AssistSkip.pending ||
            run.code == AssistSkip.working ||
            run.code == AssistSkip.background
        ? l.assistLookupStillRunning
        : run.decision != null
            // Answered, but nothing usable to write (another chain, items
            // that changed meanwhile, a malformed answer).
            ? l.assistContextOnly
            : _lookupFailureText(l, run.code);
    if (message != null) {
      _say(message, key: const Key('assistLookupSnack'));
    }
  }

  /// Why a manual lookup wrote nothing, or null when there is nothing to
  /// say (it was not started, or already runs).
  static String? _lookupFailureText(AppLocalizations l, String code) {
    switch (code) {
      case AssistSkip.consentNeeded:
      case AssistSkip.off:
      case AssistSkip.cancelled:
        return null;
      case AssistSkip.working:
      case AssistSkip.background:
        return l.assistLookupStillRunning;
      case AssistSkip.pickNeedsHttps:
        return l.assistLookupPickNeedsHttps;
      case AssistSkip.dailyCap:
      case 'lookup_daily_cap':
        return l.assistLookupDailyCap;
      case 'lookup_server_outdated':
        return l.restaurantServerOutdated;
      case 'lookup_disabled':
        return l.restaurantServerDisabled;
      case AssistSkip.placeThrottled:
      case AssistSkip.placeError:
      case AssistSkip.error:
      case AssistSkip.unsupported:
        return l.assistLookupFailed;
    }
    if (code.startsWith('lookup_')) return l.assistLookupFailed;
    // No chain to ask about: nothing printed, none nearby, a zone.
    return l.assistLookupNoChain;
  }

  /// Opens the source page: only a normalized https address, in the
  /// browser.
  Future<void> _openSource(String url) async {
    if (normalizeSourceUrl(url) != url) return;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return;
    final open = widget.openUrl ??
        (u) => launcher.launchUrl(u,
            mode: launcher.LaunchMode.externalApplication);
    try {
      await open(uri);
    } catch (_) {}
  }

  /// The source card for the stored meal, or null when there is nothing to
  /// show or do.
  Widget? _assistSection() {
    final meal = _meal;
    final assist = widget.assist;
    if (meal == null || assist == null) return null;
    final view = AssistView.of(meal.analysis);
    var supported = false;
    // Off never asks who a lookup would reach (that builds the lookup
    // client).
    if (_assistOn) {
      try {
        supported = assist.lookupSupport().supported;
      } catch (_) {}
    }
    final photoMeal = meal.source == MealSource.appWatch ||
        meal.source == MealSource.appPhoto;
    final canLookUp = _assistOn &&
        supported &&
        photoMeal &&
        assist.lookupNow != null &&
        isFoodTruthy(meal.analysis['is_food']);
    final act = assist.act;
    if (!view.hasSource &&
        view.kind != AssistViewKind.contextOnly &&
        !canLookUp &&
        !_lookingUp) {
      return null;
    }
    var canLearn = false;
    try {
      canLearn = assist.canLearnPlace?.call(meal) ?? false;
    } catch (_) {}
    VoidCallback? answer(AssistUserAction a) =>
        act == null ? null : () => _assistAct(a);
    return AssistSourceCard(
      key: const Key('editorAssistCard'),
      view: view,
      busy: _assistBusy || _saving,
      lookingUp: _lookingUp,
      editFirst: _dirty,
      onUseEstimate: answer(AssistUserAction.useEstimate),
      onAccept: answer(AssistUserAction.acceptSuggestion),
      onWrongRestaurant: answer(AssistUserAction.wrongRestaurant),
      onNotRestaurant: answer(AssistUserAction.notFromRestaurant),
      // Correct teaches the spot, so only where the place step named the
      // chain there: a printed brand says nothing about where it was eaten.
      onCorrect: canLearn && view.namedByPlace
          ? answer(AssistUserAction.correct)
          : null,
      onLookUp: canLookUp ? () => _lookUp() : null,
      onOpenSource: _openSource,
    );
  }

  Future<void> _delete() async {
    final meal = widget.meal;
    if (meal == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.editorDeleteTitle),
        content: Text(ctx.l10n.editorDeleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(ctx.l10n.cancel)),
          FilledButton(
              key: const Key('confirmDeleteMeal'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ctx.l10n.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.dao.deleteMeal(meal.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errors = [context.l10n.editorDeleteFailed('$e')];
      });
    }
  }

  Future<void> _pickDate() async {
    final current = DateTime.tryParse(_draft.dateIso) ?? (widget.now ?? DateTime.now)();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: (widget.now ?? DateTime.now)().add(const Duration(days: 1)),
    );
    if (picked == null || !mounted) return;
    setState(() => _draft.dateIso = isoDate(picked));
  }

  Future<void> _pickTime() async {
    final parsed = parseClock(_draft.time);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: parsed?.hour ?? 12, minute: parsed?.minute ?? 0),
    );
    if (picked == null || !mounted) return;
    setState(() => _draft.time = formatClock(DateTime(
        2026, 1, 1, picked.hour, picked.minute)));
  }

  /// Remove by IDENTITY, never by the index captured at build time: two
  /// taps inside one frame otherwise delete the wrong row (or throw
  /// RangeError on the second).
  void _removeItem(MealItemDraft item) {
    _harvest();
    final i = _draft.items.indexOf(item);
    if (i < 0) return; // already gone (double tap)
    setState(() {
      final row = _itemCtrls.removeAt(i);
      row.name.dispose();
      row.cal.dispose();
      row.pro.dispose();
      row.carb.dispose();
      row.fat.dispose();
      _draft.items.removeAt(i);
    });
    // The whole point of the report: removing a row must move the total —
    // including the last row, whose sum is zero.
    _recomputeTotalsFromItems(afterRemoval: true);
  }

  static String _plain(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  /// The meal's photo came from Meta glasses (design G2a): the stored
  /// meal says so, or the photo being logged by hand does.
  bool get _fromMetaGlasses {
    final meal = _meal;
    if (meal != null) return isMetaGlassesAnalysis(meal.analysis);
    return widget.fromPhoto?.capture?.isMetaGlasses ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kcalNow =
        parseNumberField(_cal.text, label: 'Calories', max: maxMealCalories)
                .value ??
            0;
    final assistCard = _assistSection();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew
            ? context.l10n.editorTitleAdd
            : context.l10n.editorTitleEdit),
        actions: [
          if (!widget.isNew)
            IconButton(
              key: const Key('deleteMealButton'),
              tooltip: context.l10n.editorDeleteTooltip,
              icon: const Icon(Icons.delete_outline),
              onPressed: _saving ? null : _delete,
            ),
        ],
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          if (_errors.isNotEmpty)
            Card(
              key: const Key('editorErrors'),
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final e in _errors)
                      Text(e,
                          style: TextStyle(
                              color: theme.colorScheme.onErrorContainer)),
                  ],
                ),
              ),
            ),
          if (_fromMetaGlasses)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: MetaGlassesBadge(key: Key('editorMetaGlassesBadge')),
              ),
            ),
          if (assistCard != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: assistCard,
            ),
          TextField(
            key: const Key('editorDescription'),
            controller: _desc,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: context.l10n.editorDescriptionLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          // At large text the two pills stack: side by side, the date
          // wrapped onto two lines.
          _fieldGrid(
            perRow: isLargeText(context) ? 1 : 2,
            gap: 8,
            [
              OutlinedButton.icon(
                key: const Key('editorDateButton'),
                onPressed: _pickDate,
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text(_draft.dateIso),
              ),
              OutlinedButton.icon(
                key: const Key('editorTimeButton'),
                onPressed: _pickTime,
                icon: const Icon(Icons.schedule_outlined, size: 18),
                // Locale clock (24h in zh), like every other time in the UI.
                label: Text(context.clock(_draft.time)),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(context.l10n.editorTotalsHeader, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          // Bare name + unit suffix, like the macro fields below: at the
          // largest iOS text size a NEW meal's empty field rested
          // 'Calories (kcal)' at the full 3.1x and cut it to 'Calories (kc…'
          // until tapped (a filled meal floats the label at 0.75x and fits).
          _NumberField(
            fieldKey: const Key('editorCalories'),
            controller: _cal,
            label: context.l10n.editorCaloriesLabel,
            suffixText: context.l10n.editorKcalSuffix,
          ),
          const SizedBox(height: 8),
          // At large text each macro field takes the full width, like
          // Calories: a third of the row cut 'Protein (g)' / '蛋白质（克）'
          // to 'Pr…'. At the default size a NEW meal's empty fields rest
          // their labels inside that third, and on a 375–411 pt phone
          // 'Protein (g)' / '蛋白质（克）' (and even '蛋白（克）') still cut,
          // so the label is the bare name and the unit is a suffix — shown
          // once the field is focused or filled, i.e. once the label has
          // floated, so the unit is never out of sight while typing.
          _fieldGrid(
            perRow: isLargeText(context) ? 1 : 3,
            gap: 8,
            [
              _NumberField(
                  fieldKey: const Key('editorProtein'),
                  controller: _pro,
                  label: context.l10n.editorProteinLabel,
                  suffixText: context.l10n.editorGramsSuffix),
              _NumberField(
                  fieldKey: const Key('editorCarbs'),
                  controller: _carb,
                  label: context.l10n.editorCarbsLabel,
                  suffixText: context.l10n.editorGramsSuffix),
              _NumberField(
                  fieldKey: const Key('editorFat'),
                  controller: _fat,
                  label: context.l10n.editorFatLabel,
                  suffixText: context.l10n.editorGramsSuffix),
            ],
          ),
          const SizedBox(height: 16),
          // Live composition of what's typed above.
          Text('~${context.l10n.kcalAmount(formatKcal(kcalNow))}',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          MacroBreakdownBar(
            proteinG: _num(_pro.text),
            carbsG: _num(_carb.text),
            fatG: _num(_fat.text),
          ),
          const SizedBox(height: 24),
          // A Wrap, not a Row: the unflexed hint took the whole width at
          // the largest text sizes, drawing 'Items' one glyph per line and
          // overflowing the row. Side by side when both fit, the hint drops
          // under the header (and wraps there) when they don't.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 2,
            children: [
              Text(context.l10n.editorItemsHeader,
                  style: theme.textTheme.titleSmall),
              if (_totalsDerived)
                Text(context.l10n.editorTotalsDerivedHint,
                    key: const Key('totalsDerivedHint'),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          for (var i = 0; i < _draft.items.length; i++)
            _ItemRow(
              // Identity key: element (and focus) state must travel WITH the
              // item when a row above it is removed. Without it, removing a
              // row left the keyboard bound to the next item's controller
              // and silently typed into the wrong food.
              key: ObjectKey(_draft.items[i]),
              index: i,
              ctrls: _itemCtrls[i],
              onRemove: () => _removeItem(_draft.items[i]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('addItemRow'),
              onPressed: () {
                _harvest();
                setState(() {
                  // The first row is seeded from the hand-typed totals
                  // (MealDraft.addItem), so the recompute below reproduces
                  // them instead of wiping them.
                  _itemCtrls.add(_controllersFor(_draft.addItem()));
                });
                _recomputeTotalsFromItems();
              },
              icon: const Icon(Icons.add, size: 18),
              label: Text(context.l10n.editorAddItem),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('saveMealButton'),
        onPressed: _saving ? null : _save,
        icon: _saving
            ? const SmallSpinner(size: 18)
            : const Icon(Icons.check),
        label: Text(widget.isNew ? context.l10n.editorAdd : context.l10n.save),
      ),
    );
  }

  static num _num(String raw) =>
      parseNumberField(raw, label: 'x', max: maxMacroGrams).value ?? 0;
}

/// [children] [perRow] to a row, sharing each row's width equally, [gap]
/// apart both ways. With every child in one row it is exactly the plain
/// Row of Expanded children the editor used before large-text stacking.
Widget _fieldGrid(List<Widget> children,
    {required int perRow, required double gap}) {
  final rows = <Widget>[];
  for (var i = 0; i < children.length; i += perRow) {
    final chunk = children.sublist(i, min(i + perRow, children.length));
    if (rows.isNotEmpty) rows.add(SizedBox(height: gap));
    rows.add(Row(children: [
      for (var j = 0; j < chunk.length; j++) ...[
        if (j > 0) SizedBox(width: gap),
        Expanded(child: chunk[j]),
      ],
    ]));
  }
  return rows.length == 1 ? rows.single : Column(children: rows);
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.suffixText,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;

  /// The unit, kept out of [label] where a third of the row can't hold it.
  final String? suffixText;

  @override
  Widget build(BuildContext context) => TextField(
        key: fieldKey,
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          suffixText: suffixText,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      );
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.index,
    required this.ctrls,
    required this.onRemove,
  });

  final int index;
  final ({TextEditingController name, TextEditingController cal,
      TextEditingController pro, TextEditingController carb,
      TextEditingController fat}) ctrls;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: Key('itemName$index'),
                    controller: ctrls.name,
                    decoration: InputDecoration(
                      labelText: context.l10n.editorItemLabel,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  key: Key('removeItem$index'),
                  tooltip: context.l10n.editorRemoveItemTooltip,
                  icon: const Icon(Icons.close),
                  onPressed: onRemove,
                ),
              ],
            ),
            const SizedBox(height: 6),
            // At large text a 2x2 grid: a quarter of the row cut 'kcal'
            // to 'k…'. The labels are short enough for half.
            _fieldGrid(
              perRow: isLargeText(context) ? 2 : 4,
              gap: 6,
              [
                _NumberField(
                    fieldKey: Key('itemCal$index'),
                    controller: ctrls.cal,
                    label: context.l10n.editorItemKcalLabel),
                _NumberField(
                    fieldKey: Key('itemPro$index'),
                    controller: ctrls.pro,
                    label: '${context.l10n.macroProteinShort} g'),
                _NumberField(
                    fieldKey: Key('itemCarb$index'),
                    controller: ctrls.carb,
                    label: '${context.l10n.macroCarbsShort} g'),
                _NumberField(
                    fieldKey: Key('itemFat$index'),
                    controller: ctrls.fat,
                    label: '${context.l10n.macroFatShort} g'),
              ],
            ),
          ],
        ),
      );
}
