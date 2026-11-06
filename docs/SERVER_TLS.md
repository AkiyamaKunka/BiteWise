# HTTPS for your own server (Caddy in front of Flask)

The app's "your own server" provider talks to the Flask API over plain
HTTP until you set this up. That means the upload key, every meal photo
and every reply cross the network unencrypted, and anyone on the path
who sees the key can use your Claude plan. This page puts
[Caddy](https://caddyserver.com) in front of Flask: Caddy gets a free
Let's Encrypt certificate, renews it on its own, and forwards to Flask
on localhost. Flask itself does not change, and plain http keeps working
next to https until you close it on purpose (section 6).

It is also the switch for the restaurant lookup's location path: the app
sends chain names derived from a photo's location to your server **only
over `https://`**. Over `http://` it looks up only the chains a printed
brand or the receipt names (the request still lists them in `chains`).
Do sections 1–4 before setting `CLAUDE_LOOKUP_ENABLED=1`; the order for
a server that is already live is in
[SERVER_DEPLOY.md](SERVER_DEPLOY.md#restaurant-lookup-websearch-on-your-server).

## Which route

- **A. No domain: a certificate for the server's own IP address.**
  Let's Encrypt issues these only as short-lived certificates (160
  hours, a little under seven days); Caddy renews them on its own. You
  need a reserved (static) address, Caddy 2.11.1 or newer, and port 443
  open to the internet. The app's address becomes `https://203.0.113.5`:
  the same host as before.
- **B. A DNS name you control** (for example `food.example.com`) whose
  `A` record points at the VM. The app's address becomes
  `https://food.example.com`: a new host.

Pick A when you have no domain, B when you have one. The steps are the
same; each section says where B differs.

Route A is the one that was run, up to and including section 4, on
2026-11-05: a Google Cloud e2-micro VM (Ubuntu 22.04, 1 GB of memory, no
swap) and Caddy 2.11.9. "The first rollout" on this page means that run.
Route B was not run there.

Placeholders: `$HOST` is what follows `https://` in the app, so the VM's
external IPv4 address on route A (the examples use `203.0.113.5`) or
your DNS name on route B. `$VM`, `$ZONE`, `$PROJECT` come from your
private notes, as in SERVER_DEPLOY.md. Never commit the real name or the
VM address to this repository — `scripts/check_public_safety.sh` exists
for exactly that.

## Before you start (on the VM)

Look at what answers on ports 80 and 5000 today. These commands change
nothing.

```bash
# who listens: expect only Flask, on 0.0.0.0:5000
sudo ss -ltnpH | awk '$4 ~ /:(80|443|5000)$/ {print $4, $6}'
# is port 80 redirected to Flask?
sudo iptables -t nat -S PREROUTING
# is that rule saved anywhere? (no output: no)
ls /etc/iptables 2>/dev/null; systemctl is-enabled netfilter-persistent 2>/dev/null
# memory, and whether needrestart is installed
free -m; dpkg -l needrestart 2>/dev/null | tail -1
```

If the second command prints a rule with
`--dport 80 -j REDIRECT --to-ports 5000`, port 80 from outside is handed
straight to Flask before anything that listens on port 80 sees it. Then:

- A phone whose server address is `http://203.0.113.5` (no port) depends
  on that rule.
- Caddy's own port 80 cannot be reached from outside while the rule is
  there. The certificate has to come over port 443 alone, and section 4
  sets Caddy up that way.
- If the third command prints nothing, the rule lives only in memory: a
  reboot drops it. The `:80` block in section 4 is the safety net for
  that day (port 80 then reaches Caddy, which passes it on to Flask).

The first rollout found exactly this: the rule, saved nowhere, and a
phone on plain http.

So while you work through this page: do not reboot, do not run
`apt upgrade`, and leave whichever port the phone's address uses (80
through the redirect, or 5000) untouched until section 6.

## 1. An address that does not change

**Route A.** The certificate and the app's server address both name the
VM's external address, so it must not change. An *ephemeral* address can
change when the VM is stopped and started; reserve the one the VM
already has. On the Mac:

```bash
IP=$(gcloud compute instances describe "$VM" --zone "$ZONE" --project "$PROJECT" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
gcloud compute addresses create caloriebot-ip --addresses="$IP" \
  --region="$REGION" --network-tier=PREMIUM --project "$PROJECT"
gcloud compute addresses list --project "$PROJECT"   # the new row: your address, IN_USE
```

`$REGION` is the zone without its last part (`europe-west1-b` →
`europe-west1`), and `--network-tier` must be the tier the address
already has (Premium unless you chose Standard). In the first rollout
the address stayed the same, nothing was interrupted, and the new entry
showed `IN_USE`. It costs the same as before for as long as it stays
attached to the VM.

**Route B.** You need a name whose `A` record is the VM's external
address.

- **A domain you own:** add an `A` record such as `food` → the VM's
  external address at your registrar or DNS host.
- **A free dynamic-DNS name** works too (for example a DuckDNS
  subdomain). Follow that provider's instructions to point the name at
  the VM's address.

Reserve the address as above, or update the record whenever it changes.
Check the record from the Mac before continuing: `dig +short "$HOST"`
must print the VM's address.

## 2. Open port 443

Caddy needs **443** open to the whole internet: the app connects there,
and so does Let's Encrypt when it checks that the address or name is
yours. In the Cloud Console (VPC network → Firewall) add an ingress rule
allowing `tcp:443` from `0.0.0.0/0` to the VM (by network tag), or:

```bash
gcloud compute firewall-rules create caloriebot-https \
  --project "$PROJECT" --direction INGRESS --action allow \
  --rules tcp:443 --source-ranges 0.0.0.0/0 --target-tags "$TAG"
```

where `$TAG` is a network tag on the VM (add one under the VM's
*Network tags* if it has none). If `ufw` is active on the VM,
`sudo ufw allow 443/tcp` as well.

Port 80 is not needed for the certificate. Leave the rules for ports 80
and 5000 as they are: the phone still uses one of them.

## 3. Install Caddy (on the VM)

Caddy's official Debian/Ubuntu repository (caddyserver.com/docs/install),
with three precautions: refresh only Caddy's package list, install
exactly one package, and do not let the package start Caddy before your
Caddyfile is in place.

```bash
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
sudo chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
# refresh only Caddy's list
sudo -E apt-get update -o Dir::Etc::sourcelist="sources.list.d/caddy-stable.list" \
  -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
# dry run: what would apt do?
sudo -E apt-get install --no-install-recommends -s caddy | grep -E '^(Inst|Remv|Conf) '
```

Go on only if the dry run printed exactly one `Inst` line, the one for
`caddy` (its `Conf caddy` line belongs to it), and no `Remv` line.
Anything else means apt would install or remove more than Caddy: stop
here and find out why. Then install (the first line is the same as
above, in case this is a new terminal):

```bash
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
# install without starting the service, then take the block away again
printf '#!/bin/sh\nexit 101\n' | sudo tee /usr/sbin/policy-rc.d >/dev/null; sudo chmod 755 /usr/sbin/policy-rc.d
sudo -E apt-get install -y --no-install-recommends caddy
sudo rm -f /usr/sbin/policy-rc.d
sudo systemctl stop caddy 2>/dev/null || true
caddy version; systemctl is-active caddy; systemctl is-enabled caddy
sudo ss -ltnpH | awk '$4 ~ /:(80|443)$/ {print $4, $6}'   # still nothing on 80 or 443
```

`caddy version` must be 2.11.1 or newer for route A (the first rollout
installed 2.11.9). Caddy is `inactive` for now and should be `enabled`,
so that it starts at boot once its Caddyfile is right.

What the precautions are for:

- **The package starts Caddy the moment it is installed**, with a
  packaged Caddyfile that serves a page on port 80. The `policy-rc.d`
  file stops that for this one install. Remove it right after, as
  shown: while it exists, no package can start its service on this VM.
  If you installed Caddy the ordinary way instead, run
  `sudo systemctl stop caddy` at once and write your Caddyfile before
  you start it again.
- **`NEEDRESTART_MODE=l`** makes `needrestart`, where it is installed,
  only list services after an install instead of restarting them.
- **One package, nothing else.** The dry run shows what apt would do.
  No `apt upgrade` in the same session, and no reboot.
- **Memory.** Run `free -m` again after section 4. Caddy used 13–26 MB
  in the first rollout
  (`systemctl show caddy -p MemoryCurrent --value` prints it in bytes).
  That is little, but a 1 GB VM without swap has little to give: the
  service together with one CLI run peaked at about 555 MB there
  (SERVER_DEPLOY.md, "Before you start").

## 4. Point Caddy at Flask

Keep the packaged file
(`sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.pkg-default`), then
replace `/etc/caddy/Caddyfile` with this. Route A, with your address
instead of `203.0.113.5` in both places:

```caddyfile
{
	default_sni 203.0.113.5
	auto_https disable_redirects
}

203.0.113.5 {
	tls {
		issuer acme {
			dir https://acme-staging-v02.api.letsencrypt.org/directory
			profile shortlived
			disable_http_challenge
		}
	}
	reverse_proxy 127.0.0.1:5000
}

:80 {
	reverse_proxy 127.0.0.1:5000
}
```

On Google Cloud the VM can print its own external address, so you can
copy it instead of typing it:
`curl -s -m 5 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip`

What each part is for:

- `default_sni`: a client that connects to an IP address sends no
  server name. On a cloud VM whose network card holds only an internal
  address (on Google Cloud the external one is translated on the way
  in), Caddy would then look for a certificate for the internal address
  and find none. This line names the certificate to use.
- `auto_https disable_redirects` and the `:80` block: plain http must
  answer the API itself, never with a redirect to https. The current app
  build reads any `3xx` answer as a captive portal and leaves the photo
  waiting, so a redirect would break every phone that is still on
  `http://`. The `:80` block hands a plain-http request to Flask
  whenever one reaches Caddy (see "Before you start").
- `issuer acme` with `profile shortlived`: for an IP address Caddy would
  otherwise sign the certificate with its own local authority, which no
  phone trusts. Naming the issuer makes it ask Let's Encrypt, which
  issues certificates for IP addresses only under this profile.
- `disable_http_challenge`: Caddy proves control of the address over
  port 443 only (the TLS-ALPN-01 challenge). The other challenge needs
  port 80 to reach Caddy from outside, which a redirect rule prevents.
- `dir …staging…`: the first attempt goes to Let's Encrypt's staging
  service. Nobody trusts its certificates, but a mistake there costs
  nothing against the limits of the real service. The line comes out
  again below.

**Route B** is the same file with the name in place of the address,
without `default_sni` (a client that connects to a name sends it) and
without the `profile` line (only an IP address needs the short-lived
profile):

```caddyfile
{
	auto_https disable_redirects
}

food.example.com {
	tls {
		issuer acme {
			dir https://acme-staging-v02.api.letsencrypt.org/directory
			disable_http_challenge
		}
	}
	reverse_proxy 127.0.0.1:5000
}

:80 {
	reverse_proxy 127.0.0.1:5000
}
```

This variant has not been run on a server yet: `caddy validate` below is
its first test.

Validate, start, and watch for the certificate:

```bash
sudo caddy validate --config /etc/caddy/Caddyfile     # must end with "Valid configuration"
sudo systemctl start caddy
sudo ss -ltnpH | awk '$4 ~ /:(80|443)$/ {print $4, $6}'   # Caddy now holds 80 and 443
sudo journalctl -u caddy --since '-10min' --no-pager \
  | grep -E 'served key authentication certificate|certificate obtained successfully|could not get certificate|challenge failed'
```

In the first rollout the certificate arrived in under a minute: a
`served key authentication certificate` line (challenge `tls-alpn-01`,
with a server name ending in `.in-addr.arpa`) and then
`certificate obtained successfully`. Look at what Caddy serves:

```bash
# the certificate (route B: add  -servername food.example.com, with your name)
echo | timeout 8 openssl s_client -connect 127.0.0.1:443 2>/dev/null \
  | openssl x509 -noout -issuer -dates -ext subjectAltName
# Caddy's :80 block reaches Flask: expect 401
curl -s -o /dev/null -m 8 -w '%{http_code}\n' -X POST http://127.0.0.1:80/api/auth_check
```

The issuer has `(STAGING)` in its name and the alternative name is your
address or name. On route A `notAfter` is 160 hours after `notBefore`.

If no certificate arrives, nothing is broken: plain http is untouched.
Read the journal lines, then check that the firewall rule from section 2
applies to this VM, that `caddy version` is 2.11.1 or newer, and that
the address in the Caddyfile is the external one. If the address cannot
be validated at all, a DNS name (route B) is the way out.

**Now the real certificate.** Delete the `dir` line, validate again and
**restart** Caddy. A reload is not enough: in the first rollout Caddy
kept serving the staging certificate after `systemctl reload caddy`, and
asked for the real one only after a restart.

```bash
grep -c 'acme-staging' /etc/caddy/Caddyfile            # 0
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl restart caddy
```

The `&&` matters: Caddy is restarted only when the file is valid. A
restart with a broken Caddyfile would leave Caddy stopped.

Give it a minute and run the journal and `openssl` checks again. The
issuer no longer says `(STAGING)`; the first rollout got `YE2`, one of
Let's Encrypt's intermediates.

That is the whole configuration:

- **Renewal** is automatic. Caddy keeps certificates under
  `/var/lib/caddy` and renews them before they expire; nothing to
  schedule. A 160-hour certificate leaves far less slack than an
  ordinary one, and no renewal had happened yet when this page was
  written, so read "Checks later".
- **Let's Encrypt account**: starting Caddy with this file registers an
  account with Let's Encrypt and accepts its subscriber agreement for
  you. No email address is needed.
- **No access log**: the Caddyfile has no `log` directive, so Caddy does
  not record requests. Keep it that way. The service's journal already
  has one line per refusal, without the payload.
- **Slow replies**: a photo or text analysis can take up to about two
  minutes. In the first rollout a test request whose answer started
  only after 100 seconds came back through Caddy 2.11.9 with its default
  timeouts, so there is nothing to tune.
- **Upload size**: Caddy imposes no body limit by default; Flask's own
  `MAX_API_UPLOAD_BYTES` (25 MB) stays in charge.

Test from the Mac (no key, so no plan usage):

```bash
# https: prints 401 only if the certificate verifies and Flask answered
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "https://$HOST/api/auth_check"
# plain http still answers the API itself: 401, never 308
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "http://$HOST/api/auth_check"
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "http://$HOST:5000/api/auth_check"
# issuer and dates of the certificate the internet sees (route B: add  -servername "$HOST")
echo | openssl s_client -connect "$HOST:443" 2>/dev/null | openssl x509 -noout -issuer -dates
```

The check with the upload key stays on the VM: it is step 5 of the
lookup order in SERVER_DEPLOY.md.

## 5. Switch the app to https

In the app: **Settings → AI Provider → Your own server → Server
address** → `https://$HOST` (no port, no trailing slash). Keep the same
upload key. Go back one page, tap **Test This Provider** and then **Run
the checks**. The test must reach the server, accept the key and get an
answer for its test picture; it spends one text run and one photo run on
your plan. Then take one food photo and check that it analyzes.

If the test cannot connect, put the `http://` address back. Nothing
else changed, and plain http still answers.

The first rollout stopped before this step. What it did check, from a
Mac: Dart's `HttpClient`, the network code the app is built on,
connected to the `https://` address and accepted the certificate. The
test on the phone is the real proof.

The restaurant lookup's consent is tied to the server's host, not to
the scheme or the port. On route A the host stays the same
(`http://203.0.113.5` becomes `https://203.0.113.5`), so the app does not
ask again. On route B the host changes from the address to the name, so
the app asks for that consent again the next time the feature needs it.
That is expected.

An app build without the restaurant assist has no lookups at all. For
it, https protects the upload key, the photos and the replies, and
nothing else changes.

If you still run the Android Termux watcher or the iOS Shortcut, switch
their server URL to `https://$HOST` too (`SERVER_URLS` in
`~/.calorie_tracker_upload.json`; the Shortcut's URL field).

## Running http and https side by side

After section 4 the server answers at three addresses, and it can stay
that way for as long as you like. The first rollout ended in this
state.

| Address | Who answers | Encrypted |
|---|---|---|
| `https://$HOST` | Caddy on port 443, which forwards to Flask | yes |
| `http://$HOST` | Flask through the redirect rule, or Caddy's `:80` block when there is no rule | no |
| `http://$HOST:5000` | Flask directly | no |

While both run:

- **Leave `API_BIND_HOST` and `TRUSTED_PROXY_ENABLED` unset.** Flask has
  to keep listening on every interface, because the redirect rule and
  port 5000 deliver to it directly. And while clients can still reach
  Flask directly, it must not believe an `X-Forwarded-For` header: any
  of them could send one.
- **Leave the redirect rule and the firewall rules for 80 and 5000
  alone.**
- **Plain http answers the API itself, never a redirect** (section 4
  says why). Check it from the Mac after every change to the Caddyfile:
  `401`, never `308`.
- One side effect: a request that arrives through Caddy reaches Flask
  from `127.0.0.1`. Only the VPN evidence for the old Termux watcher and
  iOS Shortcut looks at the client's address, and for a request through
  Caddy it reads "unknown". The app's own `/api/` routes do not use it.
- **After a reboot, run the test from the Mac again.** An unsaved
  redirect rule is gone by then, and port 80 should be answered by
  Caddy's `:80` block. The first rollout checked that block only on the
  VM itself (`401` from `http://127.0.0.1:80`); it did not reboot.

Move on to section 6 only when every client has used `https://` for
about a week and, on route A, "Checks later" has shown at least two
renewals.

## 6. Close plain HTTP

A separate step for a later day. The restaurant lookup does not need it,
and none of it was part of the first rollout. The order matters: the
moment Flask listens on localhost only, the redirect rule points at
nothing, so port 80 would be dead as well.

Three things first:

- Every client uses `https://$HOST`.
- The server runs a build with the restaurant lookup or newer. An older
  build ignores `API_BIND_HOST` without a word.
- On the VM,
  `curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:80/api/auth_check`
  prints `401`. That proves Caddy's `:80` block.

1. **Take the redirect rule away** (skip this if the look at the VM in
   "Before you start" showed none). Port 80 then reaches Caddy's `:80`
   block instead of Flask.

   ```bash
   sudo iptables -t nat -S PREROUTING | tee ~/iptables_nat_prerouting.txt   # keep the rule's text
   # delete it with the same text, -D in place of -A, for example:
   sudo iptables -t nat -D PREROUTING -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 5000
   sudo iptables -t nat -S PREROUTING                                        # the rule is gone
   ```

   From the Mac,
   `curl -sS -o /dev/null -w '%{http_code}\n' -X POST "http://$HOST/api/auth_check"`
   must still print `401`.
2. **Bind Flask to localhost and trust the proxy, in the same edit.** In
   the VM's `.env`, add

   ```env
   API_BIND_HOST=127.0.0.1
   TRUSTED_PROXY_ENABLED=1
   ```

   `API_BIND_HOST=127.0.0.1` makes Flask listen on localhost only, so
   port 5000 is unreachable from the network even if a firewall rule
   still allows it. Write the address, not `localhost`: a value that is
   not an IP address is ignored. `TRUSTED_PROXY_ENABLED=1` makes the VPN
   evidence use the client address Caddy forwards (Caddy overwrites any
   `X-Forwarded-For` a client sends, so it cannot be spoofed through
   it). It is safe only together with the first line, when Caddy is the
   only way in.
3. `sudo systemctl restart caloriebot`, then
   `sudo ss -ltnp | grep ':5000'` must show `127.0.0.1:5000`, not
   `0.0.0.0:5000`. This check is the proof that the running build knows
   the knob.
4. **Close the firewall.**
   `gcloud compute firewall-rules list --project "$PROJECT"` shows each
   rule and what it allows. Remove the ones that let `tcp:5000` and
   `tcp:80` in from the internet
   (`gcloud compute firewall-rules delete <name> --project "$PROJECT"`).
   Look first: a rule that also allows `tcp:22` is your ssh access, so
   change that one in the console instead of deleting it.
5. From the Mac, `curl -sS --max-time 5 -X POST "http://$HOST:5000/ping"`
   and `curl -sS --max-time 5 -X POST "http://$HOST/ping"` must now fail
   to connect, while `https://$HOST` still answers and the app's test
   still passes.

## Rollback

Every step is undone on its own, and nothing in the database depends on
the address.

- **The app:** set the server address back to the `http://` one. While
  http and https run side by side, that always works.
- **Section 6:** remove `API_BIND_HOST` (or set it to `0.0.0.0`) and
  `TRUSTED_PROXY_ENABLED` from `.env`, restart `caloriebot`, and
  re-allow `tcp:5000` and `tcp:80` in the firewall. Port 80 then works
  through Caddy's `:80` block. To hand it straight to Flask again, put
  the saved rule back: `sudo iptables -t nat` followed by the
  `-A PREROUTING …` line you kept in `~/iptables_nat_prerouting.txt`. Do
  that before you stop Caddy, or port 80 has nothing behind it.
- **Caddy:** `sudo systemctl disable --now caddy` stops it and keeps it
  from starting at boot. Then delete the firewall rule for 443
  (`gcloud compute firewall-rules delete caloriebot-https --project "$PROJECT"`).
  The reserved address can stay.
- **A code rollback** (SERVER_DEPLOY.md) to a build from before
  `API_BIND_HOST` existed makes Flask listen on `0.0.0.0` again, whatever
  `.env` says. Repeat step 3 of section 6 after any code rollback.

## Checks later

- `systemctl is-active caddy` → `active`, and
  `systemctl is-enabled caddy` → `enabled`.
- Renewals:
  `sudo journalctl -u caddy --since '-7d' --no-pager | grep -iE 'renew|obtain|error'`
  shows renewals and no repeated errors. On route A look every few days
  at first: the certificate lives only 160 hours.
- The expiry date, from the Mac (route B: add `-servername "$HOST"`):
  `echo | openssl s_client -connect "$HOST:443" 2>/dev/null | openssl x509 -noout -dates`.
  `notAfter` should always be days away. If it is less than two days
  away, read the journal.
- If a certificate ever does expire, the app cannot connect: its test
  says that it could not reach the server, and new photos wait and are
  tried again later. Plain http still works if you have not closed it.
- Do not reinstall Caddy or empty `/var/lib/caddy` to start over: Let's
  Encrypt issues only a few new certificates a week for the same address
  or name, while the stored certificate renews without that limit. After
  any change to the Caddyfile, run
  `sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl restart caddy`,
  as one line: the restart then happens only when the file is valid.
- If the address (route A) or the name (route B) ever changes, edit the
  Caddyfile, restart Caddy and update the app's server address. The
  host changed, so the lookup consent is asked again.
