// Shared harness for the lookup-client tests: fixture loading, a scripted
// MockClient that records every request, and a standard request.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

/// A fixture's raw text (test/assist/clients/fixtures/[name]).
String fixtureText(String name) =>
    File('${_appRoot().path}/test/assist/clients/fixtures/$name')
        .readAsStringSync();

Map<String, dynamic> fixture(String name) =>
    jsonDecode(fixtureText(name)) as Map<String, dynamic>;

/// One scripted answer.
typedef Reply = FutureOr<http.Response> Function(http.Request req);

http.Response json200(Map<String, dynamic> body) => http.Response(
    jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

http.Response fixture200(String name) => http.Response(fixtureText(name), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

/// Serves [replies] in order (the last one repeats) and records requests.
class ScriptedClient {
  ScriptedClient(this.replies);
  final List<Reply> replies;
  final List<http.Request> requests = [];

  late final http.Client client = MockClient((req) async {
    requests.add(req);
    final i = requests.length - 1;
    final r = replies[i < replies.length ? i : replies.length - 1];
    return r(req);
  });

  List<Map<String, dynamic>> get bodies => [
        for (final r in requests) jsonDecode(r.body) as Map<String, dynamic>
      ];
}

/// The standard lookup: one Big Mac, item brand printed on the box.
const LookupRequest bigMacRequest = LookupRequest(
  items: [
    LookupRequestItem(name: 'Big Mac', qty: 1, unit: 'sandwich', brand: "McDonald's")
  ],
  chains: [LookupRequestChain(key: 'mcdonalds', name: "McDonald's")],
);

const List<String> mcdDomains = ['mcdonalds.com'];

/// The `<data>…</data>` JSON at the end of a prompt (the instructions
/// mention the tags too, so the LAST pair is the data).
Map<String, dynamic> dataBlock(String prompt) {
  final s = prompt.lastIndexOf('<data>');
  final e = prompt.lastIndexOf('</data>');
  return jsonDecode(prompt.substring(s + 6, e)) as Map<String, dynamic>;
}
