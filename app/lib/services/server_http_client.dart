/// The one way a request reaches the user's own server.
///
/// ServerAnalyzer, ServerLookupClient and the Garmin fetch each send
/// through an [HttpsOnlyServerClient] wrapped around whatever client they
/// were given. It is the choke point for the https rule
/// (core/server_transport.dart): a request whose address the app sends
/// nothing to — not https:// while the switch is on; a debug build keeps
/// http:// to the phone itself — never reaches the network, so a server
/// method added later cannot send to such an address by forgetting a
/// check. The per-method checks in those three stay only where they word
/// what the user sees.
///
/// It also turns redirects off. dart:io follows a 3xx by itself and
/// copies every header but Authorization and Cookie onto the next
/// request, so an https:// server (or something answering for it) that
/// redirected to an http:// address got the X-API-Key upload key sent
/// there in clear, and the reply read there taken as the server's
/// (review of the privacy lane, finding 3). With redirects off a 3xx is
/// an answer like any other: the callers already read it as a portal or
/// proxy page, never as the server.
library;

import 'package:http/http.dart' as http;

import '../core/server_transport.dart'
    show kServerNeedsHttpsMessage, serverAddressRefused;

/// Raised instead of sending a request to an address the app sends
/// nothing to. A ClientException, so every caller's transport handling
/// treats it as a request that could not be made.
class ServerNeedsHttpsException extends http.ClientException {
  ServerNeedsHttpsException(Uri url) : super(kServerNeedsHttpsMessage, url);
}

class HttpsOnlyServerClient extends http.BaseClient {
  HttpsOnlyServerClient(this._inner);

  /// [client] (a new http.Client when null) behind the https rule; one
  /// that already is an [HttpsOnlyServerClient] as it is.
  static HttpsOnlyServerClient wrap(http.Client? client) =>
      client is HttpsOnlyServerClient
          ? client
          : HttpsOnlyServerClient(client ?? http.Client());

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (serverAddressRefused(request.url.toString())) {
      throw ServerNeedsHttpsException(request.url);
    }
    request.followRedirects = false;
    return _inner.send(request);
  }

  /// Not passed on: the client given may be shared with the other
  /// providers (MultiProviderAnalyzer hands one to all of them).
  @override
  void close() {}
}
