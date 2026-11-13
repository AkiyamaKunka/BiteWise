/// Meal-thumbnail resolution for the list UIs (spec §9 app-only).
///
/// Resolution order:
///   1. the stored meal_thumbs JPEG (written by the pipeline at save time);
///   2. for meals logged BEFORE thumbs existed: the photo library by the
///      meal's fileId (asset id) — for an Android id only once the md5 of
///      that asset's original bytes proves it is the meal's own photo — and
///      on success the result is written back to meal_thumbs, so the
///      backfill happens lazily exactly once per meal;
///   3. null → the caller renders a placeholder (text/manual meals, or the
///      gallery original is gone or no longer the meal's photo).
///
/// A small in-memory cache keeps scrolling smooth; negative results are
/// cached for the session too (a missing thumb would otherwise re-query the
/// library on every list rebuild).
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import '../core/coerce.dart' show normalizeImageHash;
import '../core/contracts.dart';
import '../services/photo/photo_hash.dart' show originalBytesMd5;
import '../services/photo/photo_library.dart';

class MealThumbResolver {
  MealThumbResolver(
      {required MealsDao dao,
      PhotoLibrary? library,
      Future<String> Function(Uint8List original)? hasher})
      : _dao = dao,
        _library = library,
        _hash = hasher ?? _md5OffTheUiIsolate;

  final MealsDao _dao;
  final PhotoLibrary? _library;

  /// md5 of a photo's ORIGINAL bytes (spec §6.2), the meal's image_hash.
  final Future<String> Function(Uint8List original) _hash;

  /// An original is up to 25 MB: hashed on a worker isolate, as intake does.
  static Future<String> _md5OffTheUiIsolate(Uint8List original) =>
      compute(originalBytesMd5, original);

  static const int _cacheCap = 200; // ~200 × ~10 KB ≈ 2 MB ceiling
  final Map<int, Uint8List?> _cache = {};
  // In-flight dedup: a list build calls thumbFor for every visible row at
  // once; without this, each rebuild before resolve re-hits the DB/library.
  final Map<int, Future<Uint8List?>> _inFlight = {};

  /// The last of the photo checks, which run one at a time: each holds an
  /// original, and a list build asks for every visible meal at once.
  Future<void> _checks = Future.value();

  Future<Uint8List?> thumbFor(Meal meal) {
    if (_cache.containsKey(meal.id)) {
      return Future.value(_cache[meal.id]);
    }
    return _inFlight.putIfAbsent(
        meal.id,
        // Braces matter: Map.remove RETURNS the removed value — the future
        // itself — and whenComplete awaits a returned future, so the arrow
        // form makes the future await itself (verified deadlock).
        () => _resolve(meal).whenComplete(() {
              _inFlight.remove(meal.id);
            }));
  }

  Future<Uint8List?> _resolve(Meal meal) async {
    var bytes = await _dao.mealThumb(meal.id);
    if (bytes == null &&
        meal.fileId.isNotEmpty &&
        meal.imageHash.isNotEmpty &&
        _library != null) {
      // Lazy backfill for pre-thumb meals; persists so it happens once.
      bytes = await _library.thumbnailByAssetId(meal.fileId);
      if (bytes != null && bytes.isNotEmpty) {
        if (!_canNameAnotherPhoto(meal.fileId) || await _isMealPhoto(meal)) {
          try {
            await _dao.saveMealThumb(meal.id, bytes);
          } catch (_) {
            // Cache-only is fine; the next launch retries the persist.
          }
        } else {
          // An asset id alone does not make the photo the meal's. Android's
          // are small integers that repeat on another phone, so after an
          // import or a restored backup an old meal's id can name an
          // unrelated, maybe private, photo here: it was shown as the
          // meal's picture and saved for good (review 171, C39).
          bytes = null;
        }
      }
    }
    if (_cache.length >= _cacheCap) {
      _cache.remove(_cache.keys.first); // drop oldest inserted
    }
    return _cache[meal.id] = bytes;
  }

  /// Whether [assetId] can name a photo other than the meal's: Android's
  /// MediaStore ids are all digits and repeat on another phone. An iOS
  /// localIdentifier (`<UUID>/L0/001`) names one photo on one device, the
  /// meal's own or none, so there the check could only cost: photo_manager
  /// copies each original into tmp (origin_cache.dart) and fetches an
  /// offloaded one from iCloud, and a photo edited in Photos since it was
  /// logged no longer hashes to the meal's image_hash.
  static bool _canNameAnotherPhoto(String assetId) =>
      _mediaStoreId.hasMatch(assetId);
  static final RegExp _mediaStoreId = RegExp(r'^\d+$');

  /// Whether [meal]'s library asset is the photo it was logged from: an
  /// image (another phone's id can name a video) whose original bytes hash
  /// to the meal's image_hash; intake never logs one over the §8 cap. False
  /// when it cannot be read — no picture rather than a wrong one.
  Future<bool> _isMealPhoto(Meal meal) {
    final check = _checks.then((_) async {
      try {
        final found = await _library?.imagesByIds([meal.fileId]);
        final original = await found?[meal.fileId]?.originBytes();
        return original != null &&
            original.isNotEmpty &&
            original.length <= maxPhotoBytes &&
            await _hash(original) == normalizeImageHash(meal.imageHash);
      } catch (_) {
        return false;
      }
    });
    _checks = check;
    return check;
  }

  /// Called by the Today/day screens when returning from the editor: the
  /// meal may have been deleted (SQLite can reuse the rowid later) or its
  /// photo association changed, and a session-cached negative result would
  /// otherwise stick until restart.
  void evict(int mealId) {
    _cache.remove(mealId);
    _inFlight.remove(mealId);
  }

  /// Drops every cached result (1.7.0): an import or an iCloud restore
  /// may have brought pictures for meals cached as having none.
  void clear() {
    _cache.clear();
    _inFlight.clear();
  }
}
