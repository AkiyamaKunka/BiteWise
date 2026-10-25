# HTTPS for your own server (Caddy in front of Flask)

The app's "your own server" provider talks to the Flask API on port 5000
over plain HTTP. That means the upload key, every meal photo and every
reply cross the network unencrypted, and anyone on the path who sees the
key can use your Claude plan. This page puts [Caddy](https://caddyserver.com)
in front of Flask: Caddy gets a free Let's Encrypt certificate for a DNS
name you control, renews it on its own, and forwards to Flask on
localhost. Flask itself does not change.

It is also the switch for the restaurant lookup's location path: the app
sends chain names derived from a photo's location to your server **only
over `https://`**. Over `http://` it looks up only the chains a printed
brand or the receipt names (the request still lists them in `chains`).
Do this before setting `CLAUDE_LOOKUP_ENABLED=1` (see
[SERVER_DEPLOY.md](SERVER_DEPLOY.md)).

About 30–45 minutes. Placeholders: `$HOST` is the DNS name you choose
(for example `food.example.com`), and `$VM`, `$ZONE`, `$PROJECT` come
from your private notes, as in SERVER_DEPLOY.md. Never commit the real
name or the VM address to this repository —
`scripts/check_public_safety.sh` exists for exactly that.

## 1. A DNS name that points at the VM

You need a name whose `A` record is the VM's external IPv4 address.

- **A domain you own:** add an `A` record such as `food` → the VM's
  external address at your registrar or DNS host.
- **No domain:** a free dynamic-DNS name works too (for example a
  DuckDNS subdomain). Follow that provider's instructions to point the
  name at the VM's address.

Find the address in the Cloud Console (Compute Engine → VM instances →
External IP) or with
`gcloud compute instances describe "$VM" --zone "$ZONE" --project "$PROJECT" --format='value(networkInterfaces[0].accessConfigs[0].natIP)'`.
If that address is *ephemeral*, it can change when the VM is stopped and
started; either reserve it as static (VPC network → IP addresses) or
update the DNS record whenever it changes. Check the record from the
Mac before continuing: `dig +short "$HOST"` must print the VM's address.

## 2. Open ports 80 and 443

Caddy needs **443** for the app and **80** for the certificate challenge
and the http→https redirect. In the Cloud Console (VPC network →
Firewall) add an ingress rule allowing `tcp:80,tcp:443` from
`0.0.0.0/0` to the VM (by network tag), or:

```bash
gcloud compute firewall-rules create caloriebot-https \
  --project "$PROJECT" --direction INGRESS --action allow \
  --rules tcp:80,tcp:443 --source-ranges 0.0.0.0/0 --target-tags "$TAG"
```

where `$TAG` is a network tag on the VM (add one under the VM's
*Network tags* if it has none). If `ufw` is active on the VM,
`sudo ufw allow 80,443/tcp` as well. Leave port 5000 open for now: the
phone still uses it until step 5.

## 3. Install Caddy (on the VM)

Caddy's official Debian/Ubuntu package (from caddyserver.com/docs/install):

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy
caddy version
```

The package installs a `caddy` systemd service. It needs roughly
20–40 MB of memory, which the 1 GB VM can spare.

## 4. Point Caddy at Flask

Replace `/etc/caddy/Caddyfile` with (your real name instead of `$HOST`):

```caddyfile
$HOST {
	reverse_proxy 127.0.0.1:5000
}
```

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
sudo journalctl -u caddy --since '-5min' --no-pager | grep -iE 'certificate obtained|error'
```

Within a minute Caddy should log that it obtained a certificate. That is
the whole configuration:

- **Renewal** is automatic. Caddy renews well before expiry and keeps
  certificates under `/var/lib/caddy`. Nothing to schedule.
- **No access log**: the Caddyfile has no `log` directive, so Caddy does
  not record requests. Keep it that way. The Flask journal already logs
  one line per refusal and never logs payloads.
- **Slow replies**: a photo or text analysis can take up to about two
  minutes. Caddy's `reverse_proxy` has no response timeout by default, so
  nothing to tune.
- **Upload size**: Caddy imposes no body limit by default; Flask's own
  `MAX_API_UPLOAD_BYTES` (25 MB) stays in charge.

Test from the Mac (no key, so no plan usage — expect `401`):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "https://$HOST/api/auth_check"
```

## 5. Switch the app to https

In the app: **Settings → Your server → Server address** →
`https://$HOST` (no port, no trailing slash). Keep the same upload key.
Tap **Test connection**; it must succeed. Then take one food photo and
check that it analyzes.

Changing the address also changes who the restaurant lookup's consent
names (it is tied to the server host), so the app asks for that consent
again the next time the feature needs it. That is expected.

If you still run the Android Termux watcher or the iOS Shortcut, switch
their server URL to `https://$HOST` too (`SERVER_URLS` in
`~/.calorie_tracker_upload.json`; the Shortcut's URL field).

## 6. Close plain HTTP

Once every client uses `https://$HOST`:

1. In the VM's `.env`, add

   ```env
   API_BIND_HOST=127.0.0.1
   TRUSTED_PROXY_ENABLED=1
   ```

   `API_BIND_HOST=127.0.0.1` makes Flask listen on localhost only, so
   port 5000 is unreachable from the network even if a firewall rule
   still allows it. `TRUSTED_PROXY_ENABLED=1` makes the VPN evidence use
   the client address Caddy forwards (Caddy overwrites any
   `X-Forwarded-For` a client sends, so it cannot be spoofed through it).
2. `sudo systemctl restart caloriebot`, then
   `sudo ss -ltnp | grep ':5000'` must show `127.0.0.1:5000`, not
   `0.0.0.0:5000`.
3. Remove the firewall rule that allowed `tcp:5000` from the internet
   (VPC network → Firewall; `gcloud compute firewall-rules list --project "$PROJECT"`
   shows its name, then `gcloud compute firewall-rules delete <name> --project "$PROJECT"`).
4. From the Mac, `curl -sS --max-time 5 -X POST "http://$HOST:5000/ping"`
   must now fail to connect, while Test connection in the app still
   succeeds.

## Rollback

Remove `API_BIND_HOST` (or set it to `0.0.0.0`) and
`TRUSTED_PROXY_ENABLED` from `.env`, restart `caloriebot`, re-allow
`tcp:5000` in the firewall, and set the app's server address back to the
`http://` one. `sudo systemctl disable --now caddy` stops Caddy. Nothing
in the database depends on the address.

## Checks later

- `sudo systemctl is-active caddy` → `active`.
- `sudo journalctl -u caddy --since '-7d' --no-pager | grep -iE 'renew|obtain|error'`
  shows renewals and no repeated errors.
- If the DNS name ever changes, edit the Caddyfile, `systemctl reload
  caddy`, and update the app's server address (the lookup consent is
  asked again).
