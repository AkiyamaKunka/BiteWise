/// A glasses-session photo → the pipeline's [IntakePhoto] (feat/meta-dat
/// prototype). The only place the session meets the photo pipeline.
///
/// Deliberate intake, written as [MealSource.appGlasses]: the wearer took
/// the photo for this, so a failed or skipped verdict may be retried like a
/// picked photo, and the meal says where it came from.
///
/// Dating: the phone's receive time (seconds after the shutter), validated
/// like any capture time. Not the EXIF clock: the glasses' clock zone is
/// unverified (the design's dating guard exists for exactly that), and a
/// live session photo was taken just now by definition. The pipeline keeps
/// its own rule on top — an EXIF time naming the same instant re-expresses
/// the meal in the zone it was taken in.
library;

import '../../core/contracts.dart';
import '../photo/filename_dates.dart' show validateCapturedAt;
import 'meta_dat_channel.dart';

class GlassesIntakePhoto extends IntakePhoto {
  const GlassesIntakePhoto(
    super.bytes,
    super.assetId,
    super.fileName, {
    super.capturedAt,
  }) : super(deliberate: true);

  @override
  String get source => MealSource.appGlasses;
}

/// [photo] as pipeline intake. No library asset exists for it (DAT hands
/// over bytes, not a Photos item), so the asset id is empty, as for the
/// share sheet; the thumbnail comes from the bytes.
GlassesIntakePhoto glassesIntakePhoto(
  MetaDatPhoto photo, {
  DateTime Function() now = DateTime.now,
}) {
  final at = photo.receivedAt.toLocal();
  final ext = photo.format == MetaDatPhotoFormat.heic ? 'heic' : 'jpg';
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${at.year}${two(at.month)}${two(at.day)}_'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}';
  return GlassesIntakePhoto(
    photo.bytes,
    '',
    'meta_glasses_$stamp.$ext',
    capturedAt: validateCapturedAt(at, now: now()),
  );
}
