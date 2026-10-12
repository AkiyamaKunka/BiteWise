# Deploying the server (checklist)

The server on your VM only changes when you deploy it. This page is the
procedure that matches [SERVER.md](SERVER.md): `git archive` tarball,
systemd `caloriebot.service`. Placeholders `$VM`, `$ZONE`, `$PROJECT`
come from your private notes. Never paste the VM address, the upload key
or the OAuth token into a terminal transcript or a chat.

## What is waiting to be deployed (as of 2026-10-12)

| Commit | What changes for the phone |
|---|---|
| cdb121c | `/api/auth_check` also says whether the Claude login token is set (`claude_login`), additive. |
| 201d7a8 | Every app-facing 400 logs one line (code + `X-Client-Platform`), body unchanged. |
| 050abd5 | Non-JPEG uploads (HEIC/PNG/WebP/…) are converted to JPEG; an undecodable container gets `400 bad_image_format`. |
| 96d876c | A closed usage window or a CLI timeout answers `503 retry:"later"` instead of discarding the photo. |
| fbfc859 | Optional `"lang": "zh"` on `/api/analyze_photo` and `/api/text_intent`: dish names in Chinese. |
| 9cde098, c5235c4, fc32d38 | Logging, retired-path model default, shared-constant refactor — no API change. |

No new pip packages, no new required env vars, no database migration.
Older app builds keep working (every change is additive or strictly
better for them).

## Before you start

- `pillow_heif` must import in the VM venv (step 2). Without it the server
  still starts, but HEIC uploads from old iOS builds get `bad_image_format`.
- HEIC decoding is memory-hungry on a 1 GB VM (a 48 MP photo can take
  150–300 MB for a moment). Current app builds send small JPEGs, so only
  old iOS builds trigger it.
- Importing `telegram_bot` opens `~/CalorieTracker/meals.db`. Every
  preflight/smoke import below sets `HOME` to a throwaway folder so the live
  database is never touched by the new code before the restart.

## On the Mac

```bash
cd ~/CalorieTracker && git fetch origin
REF=origin/main   # after the PR stack is merged
SHA=$(git rev-parse --short "$REF")
PYTHONDONTWRITEBYTECODE=1 python3.12 -m pytest -q -p no:cacheprovider
bash scripts/check_public_safety.sh
OUT="$TMPDIR/ct_deploy_$SHA.tgz"
git archive --format=tar.gz -o "$OUT" "$REF"
gcloud compute scp "$OUT" "$VM":/tmp/ct_deploy.tgz --zone "$ZONE" --project "$PROJECT"
echo "$SHA"
gcloud compute ssh "$VM" --zone "$ZONE" --project "$PROJECT"
```

## On the VM

```bash
set -eu
APP=/home/ubuntu/CalorieTracker; PY=$APP/venv/bin/python; TS=$(date +%Y%m%d%H%M%S)
# 1. stage the new tree outside the live directory
sudo -u ubuntu rm -rf /tmp/ct_new /tmp/ct_preflight_home
sudo -u ubuntu mkdir -p /tmp/ct_new /tmp/ct_preflight_home
sudo -u ubuntu tar -xzf /tmp/ct_deploy.tgz -C /tmp/ct_new
# 2. dependency gate: must print versions, not an ImportError
sudo -u ubuntu $PY -c 'import sys,PIL,pillow_heif; print(sys.version.split()[0], "Pillow", PIL.__version__, "pillow_heif", pillow_heif.__version__)'
# 3. import gate for the NEW code, throwaway HOME
(cd /tmp/ct_new && sudo -u ubuntu env HOME=/tmp/ct_preflight_home $PY -c 'import telegram_bot; print("import ok")')
# 4. backups: code-only (for rollback) and full (disaster only; contains .env)
sudo -u ubuntu tar -czf /home/ubuntu/calorietracker_code_predeploy_$TS.tgz -C $APP \
  --exclude=./venv --exclude=./logs --exclude=./reports --exclude='./meals.db*' \
  --exclude=./.env --exclude=./dietary_profile.txt --exclude='*/__pycache__' .
sudo -u ubuntu tar -czf /home/ubuntu/calorietracker_backup_predeploy_$TS.tgz -C /home/ubuntu \
  --exclude=CalorieTracker/venv --exclude=CalorieTracker/logs CalorieTracker
sudo chmod 600 /home/ubuntu/calorietracker_*predeploy_$TS.tgz
# 5. make sure no photo is mid-analysis, then extract, record the SHA, restart
sudo journalctl -u caloriebot --since '-3min' --no-pager | tail -5
sudo -u ubuntu tar -xzf /tmp/ct_deploy.tgz -C $APP
echo '<SHA from the Mac>' | sudo -u ubuntu tee $APP/DEPLOYED_SHA >/dev/null
sudo systemctl restart caloriebot
sudo systemctl is-active caloriebot
sudo systemctl show caloriebot -p NRestarts -p ActiveEnterTimestamp
# 6. smoke test (below), then clean up
sudo rm -rf /tmp/ct_new /tmp/ct_preflight_home /tmp/ct_deploy.tgz
```

Do not run `pip install -r requirements.txt` unless step 2 fails: nothing
in requirements changed, and an unpinned install could upgrade Pillow.

## Smoke test (on the VM; spends no Claude usage, never prints the key)

```bash
B=http://127.0.0.1:5000
# A. no tracebacks since the restart
sudo journalctl -u caloriebot --since '-3min' --no-pager | grep -E 'Traceback|ImportError|Error' || echo 'A ok'
# B. auth is enforced: expect "401 401"
curl -s -o /dev/null -w '%{http_code} ' -X POST $B/api/auth_check; curl -s -o /dev/null -w '%{http_code}\n' -X POST $B/ping
# C. new code is live: claude_login appears. The key goes in via stdin, never argv or echo
K=$(sudo sed -n 's/^ANDROID_API_KEY=//p' /home/ubuntu/CalorieTracker/.env | head -1 | tr -d "\"'")
printf 'X-API-Key: %s\n' "$K" | curl -s -X POST -H @- -H 'X-Client-Platform: smoke' $B/api/auth_check \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("C ok=",d.get("ok"),"claude_login=",d.get("claude_login"))'
# D. the 400 path is logged and rejected before the CLI: expect {"error":"bad_image_format"} 400
IMG=$(printf '\x00\x00\x00\x18ftypheic%064d' 0 | base64 -w0)
printf 'X-API-Key: %s\n' "$K" | curl -s -w ' %{http_code}\n' -X POST -H @- -H 'Content-Type: application/json' \
  -H 'X-Client-Platform: smoke' --data "{\"image_b64\":\"$IMG\"}" $B/api/analyze_photo
unset K IMG
```

Optional (spends one plan run): with the Chinese UI and a current app
build, take one food photo — the journal shows the analysis and the meal
gets a Chinese name. Check `systemctl show caloriebot -p NRestarts` is
still 0 an hour later.

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
