# Deploying the server (checklist)

The server on your VM only changes when you deploy it. This page is the
procedure that matches [SERVER.md](SERVER.md): `git archive` tarball,
systemd `caloriebot.service`. Placeholders `$VM`, `$ZONE`, `$PROJECT`
come from your private notes. Never paste the VM address, the upload key
or the OAuth token into a terminal transcript or a chat.

"The first rollout" on this page is the deploy of 2026-11-05: commit
f800801 on a Google Cloud e2-micro VM (Ubuntu 22.04, Python 3.10.12,
1 GB of memory, no swap). The numbers quoted from it are what that one
run showed, not promises.

## What is on the VM, and what is waiting (as of 2026-11-05)

On the VM since the first rollout (f800801). The commits this page
listed as waiting on 2026-10-12 are all part of it. New for the phone:

| Commit | What changes for the phone |
|---|---|
| 70952e8 | Photo replies carry the meal-context fields `estimate_confidence`, `restaurant_context`, `portion_state`, `order_merchant` and, on every item, `brand` / `qty` / `unit`. The photo prompt grew to ask for them. |
| d362226, e246648, c42c077 | `POST /api/restaurant_lookup` and `POST /api/restaurant_lookup/status`, off until you switch them on: see [Restaurant lookup](#restaurant-lookup-websearch-on-your-server). |
| c42c077 | `/api/auth_check` also returns `features`, so the app can tell "the server needs an update" from "the feature is switched off". New knob `API_BIND_HOST`. |

Waiting:

| Commit | What changes |
|---|---|
| 3758ff7 | The default lookup limit is 180 s instead of 75 s. Until it is deployed, keep `CLAUDE_LOOKUP_TIMEOUT_SECONDS=180` in `.env`, as the first rollout did. |

No new pip packages, no new required env vars, no database migration.
For app builds that are already installed the changes are additive: new
fields in a reply, and endpoints an older app never calls.

## Before you start

- `pillow_heif` must import in the VM venv (step 2). Without it the server
  still starts, but HEIC uploads from old iOS builds get `bad_image_format`.
- HEIC decoding is memory-hungry on a 1 GB VM (a 48 MP photo can take
  150–300 MB for a moment). Current app builds send small JPEGs, so only
  old iOS builds trigger it.
- Memory is the tight resource on a 1 GB VM without swap. In the first
  rollout the VM had about 380–540 MB available, and the service
  together with one CLI run peaked at about 555 MB. So never start a
  second CLI run next to the service's; the one exception is the
  one-second init check in step 2 of the lookup order below.
- Importing `telegram_bot` opens `~/CalorieTracker/meals.db`. Every
  preflight/smoke import below sets `HOME` to a throwaway folder so the live
  database is never touched by the new code before the restart.

## On the Mac

The blocks below carry `#` comment lines. The Mac's Terminal (zsh) does
not skip them until you tell it to: run `setopt interactivecomments`
once in that Terminal window first, or each comment prints
`command not found: #`.

```bash
cd ~/CalorieTracker && git fetch origin
# one exact commit: the branch of the open pull request, and origin/main once that is merged
REF=$(git rev-parse origin/feat/glasses-restaurant-assist)
SHA=$(git rev-parse --short "$REF")
# that commit must have the lookup routes: this prints routes ok, or STOP
git grep -q API_BIND_HOST "$REF" -- telegram_bot.py && echo "routes ok" || echo "STOP: $SHA has no lookup routes"
# the gate: the jobs CI ran on exactly this commit
gh run view "$(gh run list --commit "$REF" --workflow Tests --limit 1 \
  --json databaseId --jq '.[0].databaseId')" --json jobs --jq '.jobs[] | "\(.name): \(.conclusion)"'
```

Go on only if that printed `routes ok` and `test (3.10): success` (see
"Which commit" and "The gate is CI on Python 3.10" below). Then, in the
same terminal:

```bash
PYTHONDONTWRITEBYTECODE=1 python3.12 -m pytest -q -p no:cacheprovider
bash scripts/check_public_safety.sh
OUT="$TMPDIR/ct_deploy_$SHA.tgz"
git archive --format=tar.gz -o "$OUT" "$REF"
gcloud compute scp "$OUT" "$VM":/tmp/ct_deploy.tgz --zone "$ZONE" --project "$PROJECT"
echo "$SHA"
gcloud compute ssh "$VM" --zone "$ZONE" --project "$PROJECT"
```

**Which commit.** `REF` is one exact commit, so the test result you read,
the tarball and `DEPLOYED_SHA` all name the same code. While the
restaurant-assist work is still an open pull request, `origin/main` does
not contain it, so the block names that branch,
`origin/feat/glasses-restaurant-assist` (the first rollout deployed
f800801, its head at the time). Do not deploy `origin/main` until the
pull request is merged: `main` has no lookup routes and no
`API_BIND_HOST`, so that deploy would take both away without any error,
and the script on the VM could not tell. The `routes ok` line is the
check for it: it looks for `API_BIND_HOST`, which arrived with the
lookup routes, in that commit's `telegram_bot.py`. Once the pull request
is merged, change the `REF` line to `REF=$(git rev-parse origin/main)`;
the check stays as it is and passes there too.

**The gate is CI on Python 3.10.** The VM runs Python 3.10 and the Mac
runs the tests on 3.12, so the result that counts is the `test (3.10)`
job of the Tests workflow on that commit: the `gh` line must print
`test (3.10): success` (the commit's page on GitHub shows the same
checks). If it prints an error instead, CI never ran on that commit:
push it and wait. The local `pytest` and the safety check look at your
working tree, which is a second opinion only: `git archive` ships the
commit, not the working tree.

## On the VM

Run these steps as one script, not line by line: `set -eu` and the
explicit gates stop it before the live directory is touched. Save the
block as `/tmp/deploy_vm.sh` on the VM and run
`bash /tmp/deploy_vm.sh <SHA from the Mac>`.

```bash
set -eu
SHA="$1"
APP=/home/ubuntu/CalorieTracker; PY=$APP/venv/bin/python; TS=$(date +%Y%m%d%H%M%S)
test -s /tmp/ct_deploy.tgz
# 1. stage the new tree outside the live directory
sudo -u ubuntu rm -rf /tmp/ct_new /tmp/ct_preflight_home
sudo -u ubuntu mkdir -p /tmp/ct_new /tmp/ct_preflight_home
sudo -u ubuntu tar -xzf /tmp/ct_deploy.tgz -C /tmp/ct_new
# 2. dependency gate: must print versions, not an ImportError, and
#    requirements.txt must be the one already installed
sudo -u ubuntu $PY -c 'import sys,PIL,pillow_heif; print(sys.version.split()[0], "Pillow", PIL.__version__, "pillow_heif", pillow_heif.__version__)'
sudo diff -q /tmp/ct_new/requirements.txt $APP/requirements.txt \
  || { echo "requirements.txt changed: stop and review"; exit 3; }
# 3. import gate for the NEW code, throwaway HOME. The output is captured
#    and searched for the "import ok" line: piping this command into tail
#    would hide a failed import behind tail's own exit status.
GATE=$( (cd /tmp/ct_new && sudo -u ubuntu env HOME=/tmp/ct_preflight_home $PY -c 'import telegram_bot; print("import ok")') 2>&1 ) \
  || { echo "IMPORT GATE FAILED"; printf '%s\n' "$GATE" | tail -6; exit 4; }
printf '%s\n' "$GATE" | grep -q '^import ok$' || { echo "IMPORT GATE: no ok line"; exit 4; }
# 4. backups: code-only (for rollback) and full (disaster only; contains .env)
sudo -u ubuntu tar -czf /home/ubuntu/calorietracker_code_predeploy_$TS.tgz -C $APP \
  --exclude=./venv --exclude=./logs --exclude=./reports --exclude='./meals.db*' \
  --exclude=./.env --exclude=./dietary_profile.txt --exclude='*/__pycache__' .
sudo -u ubuntu tar -czf /home/ubuntu/calorietracker_backup_predeploy_$TS.tgz -C /home/ubuntu \
  --exclude=CalorieTracker/venv --exclude=CalorieTracker/logs CalorieTracker
sudo chmod 600 /home/ubuntu/calorietracker_*predeploy_$TS.tgz
# 5. quiet check: no /api/ request and no analysis line in the last 90 s, or stop
RECENT=$(sudo journalctl -u caloriebot --since '-90s' --no-pager | grep -c -E 'POST /api/|analy' || true)
[ "$RECENT" = "0" ] || { echo "NOT QUIET ($RECENT lines in the last 90 s): try again in a few minutes"; exit 5; }
#    then extract, record the SHA, restart
sudo -u ubuntu tar -xzf /tmp/ct_deploy.tgz -C $APP
echo "$SHA" | sudo -u ubuntu tee $APP/DEPLOYED_SHA >/dev/null
sudo systemctl restart caloriebot
sleep 6
sudo systemctl is-active caloriebot
sudo systemctl show caloriebot -p NRestarts -p ActiveEnterTimestamp
```

Then run the smoke test below and clean up:
`sudo rm -rf /tmp/ct_new /tmp/ct_preflight_home /tmp/ct_deploy.tgz /tmp/deploy_vm.sh`.

Do not run `pip install -r requirements.txt` unless step 2 fails: nothing
in requirements changed, and an unpinned install could upgrade Pillow.

About the quiet check: a restart cuts off a request that is being
answered, and the journal gets its line for an analysis only when the
analysis ends. So the check shows that the phone was idle a moment ago,
not that nothing started in the last two minutes. If you just took a
photo yourself, wait for it to finish first.

## Smoke test (on the VM; A–E spend no Claude usage, F spends one run; the key is never printed)

```bash
B=http://127.0.0.1:5000
# A. no tracebacks since the restart
sudo journalctl -u caloriebot --since '-3min' --no-pager | grep -E 'Traceback|ImportError|Error' || echo 'A ok'
# B. auth is enforced: expect "401 401"
curl -s -o /dev/null -w '%{http_code} ' -X POST $B/api/auth_check; curl -s -o /dev/null -w '%{http_code}\n' -X POST $B/ping
# C. new code is live. The key goes in via stdin, never argv or echo. Expect
#    features= {'estimate_confidence': True, 'lookup_jobs': True, 'restaurant_lookup': False}
#    ('restaurant_lookup': True when CLAUDE_LOOKUP_ENABLED is already set on this server)
K=$(sudo sed -n 's/^ANDROID_API_KEY=//p' /home/ubuntu/CalorieTracker/.env | head -1 | tr -d "\"'")
printf 'X-API-Key: %s\n' "$K" | curl -s -X POST -H @- -H 'X-Client-Platform: smoke' $B/api/auth_check \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("C ok=",d.get("ok"),"claude_login=",d.get("claude_login"),"features=",d.get("features"))'
# D. the 400 path is logged and rejected before the CLI: expect {"error":"bad_image_format"}, then 400
IMG=$(printf '\x00\x00\x00\x18ftypheic%064d' 0 | base64 -w0)
printf 'X-API-Key: %s\n' "$K" | curl -s -w ' %{http_code}\n' -X POST -H @- -H 'Content-Type: application/json' \
  -H 'X-Client-Platform: smoke' --data "{\"image_b64\":\"$IMG\"}" $B/api/analyze_photo
# E. the lookup routes exist. The body is one the server refuses either way, so no lookup runs:
#    lookups off: {"error":"disabled","reason":"disabled"}, then 403
#    lookups on:  {"error":"bad_request","field":"items","reason":"bad_request"}, then 400
#    (a 404 means the old code is still running)
printf 'X-API-Key: %s\n' "$K" | curl -s -w ' %{http_code}\n' -X POST -H @- -H 'Content-Type: application/json' \
  -H 'X-Client-Platform: smoke' --data '{"items":[]}' $B/api/restaurant_lookup
# F. one whole analysis through the API (ONE plan run; the endpoint stores nothing): expect http 200
sudo cat /home/ubuntu/CalorieTracker/app/test_live/fixtures/plate.jpg \
  | python3 -c 'import base64,json,sys; json.dump({"image_b64": base64.b64encode(sys.stdin.buffer.read()).decode()}, open("/tmp/photo_body.json","w"))'
printf 'X-API-Key: %s\n' "$K" | curl -s -m 170 -o /tmp/photo_reply.json -w 'F http %{http_code} in %{time_total}s\n' -X POST -H @- \
  -H 'Content-Type: application/json' -H 'X-Client-Platform: smoke' --data-binary @/tmp/photo_body.json $B/api/analyze_photo
python3 -c 'import json; d=json.load(open("/tmp/photo_reply.json")); a=d.get("analysis") or {}; i=(a.get("food_items") or [{}])[0]; print("F analyzed_by=",d.get("analyzed_by"),"is_food=",a.get("is_food"),"estimate_confidence=",a.get("estimate_confidence"),"restaurant_context=",a.get("restaurant_context"),"portion_state=",a.get("portion_state"),"item keys=",sorted(i))'
rm -f /tmp/photo_body.json /tmp/photo_reply.json
unset K IMG
```

F is part of this deploy, not an extra: the photo prompt grew, and a
whole analysis is the only proof that it still works. It sends a test
picture that ships with the code (a drawing of a plate). Expect
`F http 200`, the three context fields filled in, and `brand`, `qty` and
`unit` among the item keys; in the first rollout the answer came after
12 seconds. The model may also decide that a drawing is not food, which
the prompt allows: then F prints `F http 200` with `is_food= False`, the
three fields `None` and `item keys= []`. That is a pass too, for the
endpoint, the CLI and the JSON contract. Do not roll back for it and do
not repeat F (each try is one plan run): the meal-context fields are
then proven by the phone photo.

Then take one food photo with the phone. That is not optional for this
deploy either: it is the only end-to-end proof for the app build that is
installed. Check `systemctl show caloriebot -p NRestarts` is still 0 an
hour later.

## Restaurant lookup (WebSearch on your server)

The restaurant-assist work adds two app endpoints,
`POST /api/restaurant_lookup` and `POST /api/restaurant_lookup/status`,
and a `features` object on `/api/auth_check`. The endpoints are **off**
until you switch them on. Apart from the new fields in a photo reply,
deploying the code changes nothing: photos, leftovers and text run as
before (a running lookup always yields the CLI to them).

What switching it on means: for a meal from a chain restaurant, the app
sends item names, quantities, the brand printed on an item or receipt
and up to 3 chain names from Chopstats' own US chain table — never
coordinates, street, city, the photo or your meal history. Your server
then runs the Claude CLI on your plan with **WebSearch only** (no
WebFetch, no MCP, no plugins, `--safe-mode`, a minimal environment
without the upload key or any plan key). The first event of every run
is checked and the run is killed if any tool, MCP server, plugin or
memory path appears that should not. Each lookup takes about 25–135 s of
plan usage (measured in the first live runs; the default limit is
180 s); results are cached for 24 h.

New `.env` knobs (all optional):

| Knob | Default | Meaning |
|---|---|---|
| `CLAUDE_LOOKUP_ENABLED` | off | `1` turns the endpoints on. Off → `403 {"reason":"disabled"}`. |
| `CLAUDE_LOOKUP_MODEL` | `sonnet` | `haiku` uses less plan usage but was wrong on build-your-own items in the first live runs. |
| `CLAUDE_LOOKUP_TIMEOUT_SECONDS` | `180` | Per-lookup wall clock (20–300). |
| `CLAUDE_LOOKUP_INIT_SECONDS` | `10` | How long the CLI may take to print its first (init) event (5–30). Raise it only if the smoke's `init latency` is close to the limit. |
| `CLAUDE_LOOKUP_DAILY_CAP` | `30` | Lookup runs started per day, counted in `logs/service_health.json`. |
| `CLAUDE_LOOKUP_KEY_SOURCE` | `none` | The `apiKeySource` the guard accepts. Change it only if the smoke tells you to. |
| `API_BIND_HOST` | `0.0.0.0` | `127.0.0.1` only when you close plain HTTP ([SERVER_TLS.md](SERVER_TLS.md#6-close-plain-http)). Leave it unset while http and https run side by side. |

The recommended order for a server that is already live:

1. **Deploy** as above, with the lookups off. Smoke A–F must pass; E
   proves that the routes are there and, when it answers `403`, that the
   knob is off.
2. **Smoke the guard without spending usage** (on the VM, while the
   service runs no photo and no lookup). Look first:

   ```bash
   APP=/home/ubuntu/CalorieTracker
   PID=$(systemctl show caloriebot -p MainPID --value)
   pgrep -P "$PID"   # the processes the service has started: must print nothing
   ```

   Every CLI run is a process the service starts, so a number here means
   that one is running now (a photo, a text or a lookup): wait and look
   again. Go on only when it prints nothing:

   ```bash
   # the service's PATH, and only that line: the same file holds the keys
   SPATH=$(sudo cat /proc/$PID/environ | tr '\0' '\n' | sed -n 's/^PATH=//p')
   sudo -u ubuntu -H env PATH="$SPATH" DISABLE_AUTOUPDATER=1 \
     $APP/venv/bin/python $APP/scripts/lookup_smoke.py --init-only; echo "exit code: $?"
   ```

   It passes only when the `status` line says `init_ok` **and** the exit
   code is 0. `guard : pass` and `memory_paths : absent` are not enough:
   both are also printed when the CLI exits before its first event
   (`init tools` then shows `-`, `status` says `cli_error (no_init)` and
   the exit code is 1). A pass also shows
   `init tools : StructuredOutput, WebSearch` and the `apiKeySource` the
   CLI reports, never a key. `init latency` is how long the CLI took to
   start (0.9 s in the first rollout; if it is near the 10 s limit, set
   `CLAUDE_LOOKUP_INIT_SECONDS=20`).

   The service's `PATH` matters because the service and the smoke both
   find `claude` through it, unless `.env` sets `CLAUDE_ANALYZER_BIN` to
   a full path, which both then use instead. Under plain `sudo` the
   smoke could test a different `claude` than the one the service runs,
   or find none.

   The guard was written against CLI 2.1.233 and also passes on 2.1.210,
   which the first rollout ran. If it says `FAIL guard_fail:apiKeySource`
   and shows a value you expect for your sign-in, add
   `CLAUDE_LOOKUP_KEY_SOURCE=<that value>` to `.env` and run it again.
   `FAIL guard_fail:init_timeout` (with `init latency : -`) means that
   the CLI printed nothing within `CLAUDE_LOOKUP_INIT_SECONDS`: set that
   knob to `20` (at most `30`) in `.env`, on a line of its own as in
   step 4, and run the smoke again. Treat it as a different CLI only if
   it still fails.
   Any other `FAIL`, or any `status` other than `init_ok`, means this CLI
   version behaves differently: do not enable the feature; report the
   printed lines instead. For `cli_error (no_init)`, this prints which
   `claude` that `PATH` leads to, then the flags the lookup uses and
   whether this CLI's help knows them (the last line is the `dontAsk`
   permission mode, which must say `yes` too):

   ```bash
   sudo -u ubuntu -H env PATH="$SPATH" DISABLE_AUTOUPDATER=1 /bin/bash -c 'C=claude; command -v "$C" || echo "$C: NOT FOUND"; H=$("$C" --help 2>&1); for f in --safe-mode --json-schema --no-session-persistence --strict-mcp-config --tools --allowedTools --disallowedTools --permission-mode --output-format --verbose --model dontAsk; do case "$H" in *"$f"*) echo "$f yes";; *) echo "$f NO";; esac; done'
   ```

   If `.env` sets `CLAUDE_ANALYZER_BIN`, write that path in place of
   `claude` in `C=claude`. The line takes nothing from the service's
   `PATH` but the CLI itself, so it also works where that `PATH` holds
   little else (the example unit in [SERVER.md](SERVER.md) has only the
   venv's `bin`).

   A different CLI version changes the photo path too, because it is
   the same program. After any CLI change, check
   `CLAUDE_ANALYZER_EXTRA_FLAGS` against `claude --help` and analyze one
   real photo (smoke F) before you rely on it.

   Why "no photo and no lookup": for about a second the smoke runs a
   second CLI process next to the service's, on a VM that has no memory
   to spare. If the kernel kills a photo's CLI run for memory, the server
   answers that the run produced nothing usable (`retry: false`), and
   the phone gives up on that photo. An idle phone is not enough once
   lookups are on: a lookup the phone asked for runs for up to
   `CLAUDE_LOOKUP_TIMEOUT_SECONDS`, and longer when it waited behind a
   photo. The `pgrep` line is new on this page: the first rollout did
   not run it.
3. **HTTPS next to http** ([SERVER_TLS.md](SERVER_TLS.md), "Before you
   start" and sections 1–4). This puts https on the server. What it is
   for arrives only once the app's own address is `https://` (step 7):
   until then the app keeps lookups to printed brands only, and the
   upload key that now also unlocks a web-searching model still travels
   in clear text. Closing plain http (section 6 there) is a separate,
   later step and not part of switching lookups on.
4. **Switch it on.** Add the knob to `.env` and restart. Two things to
   get right: the file must end with a newline before you append to it
   (otherwise the new line is glued onto the last one), and its owner
   and mode must stay as they are.

   ```bash
   ENVF=/home/ubuntu/CalorieTracker/.env
   sudo stat -c '%U %a' $ENVF      # note owner and mode, for example: ubuntu 600
   if [ -n "$(sudo tail -c1 $ENVF)" ]; then echo | sudo tee -a $ENVF >/dev/null; fi
   if sudo grep -q '^CLAUDE_LOOKUP_ENABLED=' $ENVF; then
     echo 'already there: edit that line instead of adding a second one'
   else
     echo 'CLAUDE_LOOKUP_ENABLED=1' | sudo tee -a $ENVF >/dev/null
   fi
   sudo stat -c '%U %a' $ENVF      # unchanged
   ```

   Then `sudo systemctl restart caloriebot`, while the phone is idle
   (the quiet check of the deploy script).
5. **Check without spending usage**:

   ```bash
   B=http://127.0.0.1:5000
   K=$(sudo sed -n 's/^ANDROID_API_KEY=//p' /home/ubuntu/CalorieTracker/.env | head -1 | tr -d "\"'")
   # features: expect 'restaurant_lookup': True
   printf 'X-API-Key: %s\n' "$K" | curl -s -X POST -H @- $B/api/auth_check \
     | python3 -c 'import json,sys; print("features:", json.load(sys.stdin).get("features"))'
   # the same through Caddy, with the certificate checked (skip without https).
   # HOST is what follows https:// in the app: your address or name
   HOST=203.0.113.5
   printf 'X-API-Key: %s\n' "$K" | curl -s -X POST -H @- --connect-to "$HOST:443:127.0.0.1:443" "https://$HOST/api/auth_check" \
     | python3 -c 'import json,sys; print("features over https:", json.load(sys.stdin).get("features"))'
   # a location key is refused before any CLI run: expect
   # {"error":"bad_request","field":"lat","reason":"bad_request"}, then 400
   printf 'X-API-Key: %s\n' "$K" | curl -s -w ' %{http_code}\n' -X POST -H @- \
     -H 'Content-Type: application/json' -H 'X-Client-Platform: smoke' \
     --data '{"items":[{"name":"bowl","brand":"Chipotle"}],"lat":1}' $B/api/restaurant_lookup
   unset K
   ```

   The journal shows one `restaurant_lookup refused (400 bad_request)`
   line and nothing about the payload.

   If `restaurant_lookup` is still `False`, the server did not read the
   knob as on or cannot run the Claude backend: `CLAUDE_LOOKUP_ENABLED`
   must be on a line of its own with the value `1`,
   `CLAUDE_ANALYZER_ENABLED` must be on as well, the service must find
   the CLI (`claude` on its `PATH`, or the full path in
   `CLAUDE_ANALYZER_BIN`), and the service must have been restarted
   since the edit.
6. **One real lookup, inside the service** (spends one search run on
   your plan and counts as one of the day's `CLAUDE_LOOKUP_DAILY_CAP`
   runs). It goes through the API, so it runs under the service's own
   CLI lock and a photo that arrives pre-empts it:

   ```bash
   sudo -u ubuntu -H /home/ubuntu/CalorieTracker/venv/bin/python - <<'PY'
   import json, time, urllib.error, urllib.request
   from urllib.parse import urlsplit

   ENV = '/home/ubuntu/CalorieTracker/.env'
   KEY = next(l.split('=', 1)[1].strip().strip('"\'') for l in open(ENV) if l.startswith('ANDROID_API_KEY='))

   def load(raw):
       try:
           return json.loads(raw or '{}')
       except ValueError:
           return {}

   def post(path, body):
       req = urllib.request.Request(
           'http://127.0.0.1:5000' + path, data=json.dumps(body).encode(), method='POST',
           headers={'Content-Type': 'application/json', 'X-API-Key': KEY, 'X-Client-Platform': 'smoke'})
       try:
           with urllib.request.urlopen(req, timeout=40) as r:
               return r.status, load(r.read().decode())
       except urllib.error.HTTPError as e:
           return e.code, load(e.read().decode())

   sample = {"items": [{"name": "chicken burrito bowl", "qty": 1, "unit": "bowl", "brand": "Chipotle"}],
             "order_merchant": "", "chains": [{"key": "chipotle", "size": "20_plus"}],
             "country": "US", "backend": "claude"}
   start = time.time()
   code, body = post('/api/restaurant_lookup', sample)
   print('submit: http', code, 'state', body.get('state'), body.get('error') or '')
   job = body.get('job_id')
   while job and body.get('state') in ('queued', 'running'):
       time.sleep(4)
       code, body = post('/api/restaurant_lookup/status', {"job_id": job})
   lookup = body.get('lookup') or {}
   urls = body.get('cited_urls') or []
   hosts = {urlsplit(u).hostname or '' for u in urls}
   print('final :', body.get('state'), body.get('reason') or '', 'after', round(time.time() - start, 1), 's')
   print('lookup:', lookup.get('status'), '| chain', lookup.get('chain_key'), '| matches', len(lookup.get('matches') or []))
   print('search:', body.get('searches'), 'searches |', len(urls), 'cited urls | chipotle.com cited:',
         any(h == 'chipotle.com' or h.endswith('.chipotle.com') for h in hosts),
         '| analyzed_by', body.get('analyzed_by'))
   PY
   ```

   Expect `submit: http 202 state queued`, then `final : done`,
   `lookup: found | chain chipotle`, at least 1 search,
   `chipotle.com cited: True` and `analyzed_by claude`. The journal has
   one line for the run,
   `Restaurant lookup ok (ok) in <s>s; searches=<n> lines=<n>`, and never
   restaurant names, dishes, queries or URLs. In the first live runs
   this sample came back `found` both times on `sonnet` (after 43.7 s
   and 91.6 s, with 3 and 7 searches). A `final : failed timeout` means
   the lookup ran into `CLAUDE_LOOKUP_TIMEOUT_SECONDS`. Asking again
   within 24 hours gives `submit: http 200 state done` straight from the
   cache, with no new run.

   On a 1 GB VM without swap, do **not** use `lookup_smoke.py` without
   `--init-only` for this. It runs a whole lookup in a second CLI
   process outside the service's lock, and two CLI processes at once do
   not fit in that memory.
7. **Switch the app to https**
   ([SERVER_TLS.md, section 5](SERVER_TLS.md#5-switch-the-app-to-https)):
   the server address in the app becomes `https://…`. Until you do, the
   app sends your server only the chains a printed brand or the receipt
   names, never the ones found by a photo's location, and the upload
   key still travels in clear text with every photo. The first rollout
   stopped before this step.
8. **Record a real stream** (optional; only on a machine with memory
   for a second CLI process, and it spends one more search run). With
   `APP` and `SPATH` set as in step 2:

   ```bash
   sudo -u ubuntu -H env PATH="$SPATH" DISABLE_AUTOUPDATER=1 \
     $APP/venv/bin/python $APP/scripts/lookup_smoke.py --record /tmp/lookup_stream.jsonl
   ```

   Expect `status : ok`, a `lookup : found, chain=chipotle …` line and
   `chipotle.com cited: yes`. The `--record` file is the stream with ids,
   paths and every secret-looking value redacted (mode 0600); copy it
   back to the Mac as `tests/fixtures/lookup_streams/vm_<version>.jsonl`
   if you want the tests to pin the real WebSearch shape, then delete it
   from `/tmp`.

To switch it off again, remove `CLAUDE_LOOKUP_ENABLED` (or set `0`) and
restart. The restart drops the queued jobs and the 24 h cache with them:
both live in memory.

## Rollback

```bash
APP=/home/ubuntu/CalorieTracker
B=$(ls -t /home/ubuntu/calorietracker_code_predeploy_*.tgz | head -1); echo "$B"
sudo systemctl stop caloriebot
sudo -u ubuntu tar -xzf "$B" -C $APP     # code only: meals.db, .env, venv, logs untouched
sudo -u ubuntu rm -f $APP/DEPLOYED_SHA
sudo systemctl start caloriebot
sudo systemctl is-active caloriebot
```

The deploy changes no data, so rollback has nothing else to undo. The
full archive restores everything but also rolls `meals.db` back to before
the deploy — last resort only.

What a rollback leaves behind: the files the deploy added stay on disk,
and so do the new `.env` knobs. The old code ignores both. Two things
follow from that. The lookup routes are gone, so they answer `404` and
an app with the restaurant assist says that the server needs an update.
And `API_BIND_HOST` is ignored, so a server that listened on localhost
only listens on every interface again: repeat the check in
[SERVER_TLS.md](SERVER_TLS.md#6-close-plain-http) after a code rollback.
