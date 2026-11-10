# Contributing to Chopstats

Thanks for your interest! Issues and pull requests are welcome. This is a
personal project published in the hope it is useful — responses may be slow,
but every report gets read.

## The two rules that matter more than style

1. **Never commit a credential.** Run the safety gate before every push:

   ```bash
   bash scripts/check_public_safety.sh
   PUBLIC_SAFETY_SCAN_HISTORY=1 bash scripts/check_public_safety.sh   # scans full git history, incl. binary blobs
   ```

   The published history was deliberately rewritten so that no credential
   exists anywhere in it. Keep it that way — a key removed in a later commit
   is still published.

2. **Server and app must stay in parity.** This repo contains two full
   implementations of the same behavior — a Python server and a Dart app —
   kept in step by [docs/APP_PORT_SPEC.md](docs/APP_PORT_SPEC.md), the
   constants/prompts in [shared/](shared/), and the golden vectors in
   [shared/vectors/](shared/vectors/) replayed by both test suites
   ([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the diagram). If you
   change behavior:

   - Edit the source of truth in `shared/` (constants, prompts) or the Python
     reference implementation (for logic the vectors pin).
   - Regenerate bindings: `python3 scripts/sync_shared.py`
   - Regenerate vectors if behavior legitimately changed:
     `python3 scripts/generate_shared_vectors.py` — and review the JSON diff;
     a surprising diff means a bug, not a regeneration.
   - Run **both** suites. A deliberate one-sided divergence needs a row in
     spec §9 and a test that pins it.

## Development setup

**App** (Flutter, Dart SDK ≥ 3.12.2):

```bash
cd app
flutter pub get
flutter test
flutter run
```

**Server** (Python 3.9+):

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python3 -m pytest -q
```

The README's [For developers](README.md#for-developers) section covers the
iPhone signing step, the Android APK build and the live check of every AI
provider (`scripts/test_providers_live.sh`).

## Before opening a PR

All four gates green, please:

```bash
python3 -m pytest -q                         # server suite
(cd app && flutter analyze && flutter test)  # app suite
python3 scripts/sync_shared.py --check       # parity bindings unchanged or regenerated
bash scripts/check_public_safety.sh          # no secrets/PII
```

CI runs the same gates on every push. A few more expectations:

- Match the surrounding code's style and comment density; comments explain
  constraints the code can't show, not what the next line does.
- Tests accompany behavior changes — and should be able to *fail*. Several
  suites here were rewritten after being caught passing while broken; don't
  add one of those.
- UI changes: include a screenshot or screen recording in the PR.
- Keep PRs focused; unrelated refactors make review slower, not faster.

## Reporting bugs

Use the bug report template. The single most useful thing you can attach is
the output of the app's **Settings › AI Provider › Test This Provider** page — it names the
failing stage (configuration, reachability, auth/credit, text round-trip,
photo round-trip, quota) and usually answers the question before we ask it.

## Security issues

Please do **not** open a public issue for anything security-sensitive. Use
the email address in the [Contact section of the support page](docs/SUPPORT.md#contact).
[SECURITY.md](SECURITY.md) has the rules for keeping secrets out of the
repository.
