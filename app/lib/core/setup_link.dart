/// One-click server setup (2026-09-28): the phone never types a server
/// address or a 48-character upload key. A link of the form
///
///   `bitewise://setup?server=<http(s) origin>&key=<upload key>[&backend=claude]`
///
/// arrives via the OS (a QR scanned by the camera, or `devicectl
/// --payload-url` from the Mac) and the app asks ONE question — confirm —
/// before saving. Parsing is pure and strict: anything malformed is
/// rejected rather than guessed, because a crafted link could otherwise
/// point the app's photo uploads at a stranger's server.
library;

const Set<String> kSetupBackends = {'claude', 'glm', 'doubao'};

class SetupLink {
  const SetupLink(
      {required this.server, required this.key, required this.backend});

  /// Origin only (scheme://host[:port]); the client appends /api/... itself.
  final String server;
  final String key;
  final String backend;

  /// The last four characters of the key, for the confirmation sheet.
  String get keyTail =>
      key.length <= 4 ? key : key.substring(key.length - 4);
}

/// Null for anything that is not a well-formed setup link.
SetupLink? parseSetupLink(Uri uri) {
  if (uri.scheme.toLowerCase() != 'bitewise') return null;
  if (uri.host.toLowerCase() != 'setup') return null;
  final q = uri.queryParameters;
  final server = (q['server'] ?? '').trim();
  final key = (q['key'] ?? '').trim();
  final backend = (q['backend'] ?? 'claude').trim().toLowerCase();

  final s = Uri.tryParse(server);
  if (s == null) return null;
  if (s.scheme != 'http' && s.scheme != 'https') return null;
  if (s.host.isEmpty || s.hasQuery || s.fragment.isNotEmpty) return null;
  if (s.path.isNotEmpty && s.path != '/') return null; // origin only
  if (s.userInfo.isNotEmpty) return null;

  if (key.length < 8 || key.length > 256) return null;
  if (RegExp(r'\s').hasMatch(key)) return null;
  if (!kSetupBackends.contains(backend)) return null;

  final origin = '${s.scheme}://${s.host}${s.hasPort ? ':${s.port}' : ''}';
  return SetupLink(server: origin, key: key, backend: backend);
}
