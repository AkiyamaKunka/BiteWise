/// Why an analysis failed, as a KIND the UI can localize.
///
/// The analyzers build user-facing English prose (parity-pinned by tests,
/// and the only thing the headless paths ever had). Rather than thread a
/// code through fifteen construction sites in two analyzer files, this
/// classifies that prose — all of it ours, all of it stable — so the
/// dialog and the meal card can say it in the app language and fall back
/// to the raw line for anything unrecognised (2026-09-28).
library;

enum AnalysisErrorKind {
  none,
  noApiKey,
  noServerKey,
  rejectedKey,
  rateLimited,
  quotaPaused,
  network,
  badModel,
  badResponse,
  badPhoto,
  serverBusy,
  serverError,
  serverRejected,
  unknown,
}

AnalysisErrorKind classifyAnalysisError(String? error) {
  if (error == null || error.trim().isEmpty) return AnalysisErrorKind.none;
  final e = error.toLowerCase();
  if (e.contains('server upload key') || e.contains('server address')) {
    return AnalysisErrorKind.noServerKey;
  }
  if (e.startsWith('no ') && e.contains('api key')) {
    return AnalysisErrorKind.noApiKey;
  }
  if (e.contains('rejected the api key')) return AnalysisErrorKind.rejectedKey;
  // Order matters: the Gemini pause line also mentions the free tier, and
  // the provider pause line says "(quota)" — both are pauses, not limits.
  if (e.contains('quota exhausted') || e.contains('analysis paused')) {
    return AnalysisErrorKind.quotaPaused;
  }
  if (e.contains('rate limit') || e.contains('rate/spend limit')) {
    return AnalysisErrorKind.rateLimited;
  }
  if (e.contains('network or service')) return AnalysisErrorKind.network;
  if (e.contains('model error') || e.contains('model name')) {
    return AnalysisErrorKind.badModel;
  }
  if (e.contains("couldn't understand") || e.contains('unusable analysis')) {
    return AnalysisErrorKind.badResponse;
  }
  if (e.contains('decode failed') || e.contains('could not process this photo')) {
    return AnalysisErrorKind.badPhoto;
  }
  if (e.contains('busy')) return AnalysisErrorKind.serverBusy;
  if (e.contains('rejected this request')) {
    return AnalysisErrorKind.serverRejected;
  }
  if (e.contains('cannot analyze right now')) return AnalysisErrorKind.serverError;
  return AnalysisErrorKind.unknown;
}
