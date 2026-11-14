# Google Play Data safety: the answers for Chopstats

Paste-ready answers for **Play Console › Monitor and improve › Policy and
programs › App content › Data safety**, written 2026-11-13 for the first Google Play release (1.7.0).
The console moves things around: match the meaning of each question, not
its position. `docs/RELEASING.md` § 6.5 says where this fits; the App
Store's own label is a different form with different definitions
(`docs/RELEASING.md` § 4.3).

## Before you answer

1. **The build must be the Play build without broad photo access**
   (owner decision 1, 2026-11-13: no `READ_MEDIA_IMAGES`, no Watch
   Camera Roll on Play). The answers below hold for it. They would not
   change for the GitHub APK's Watch Camera Roll, but the reasoning for
   "Shared: No" would then also rest on the camera-roll notice.
2. **The build must refuse plain `http://` server addresses** (owner
   decision 2, 2026-11-13). "Encrypted in transit: Yes" is true only
   then: `app/lib/core/server_transport.dart` must say
   `kRequireHttpsServer = true` at the commit the bundle was built from.
   release.yml's Android job stops before building otherwise, and
   `docs/RELEASING.md` § 6.8 step 8 has you check it.
   <!-- gated: release_decisions_test and release.yml's Android job check kRequireHttpsServer = true -->
3. Google requires the form for closed testing, open testing and
   production; an app that is only on internal testing is exempt. Fill it
   in before the first closed-test release.

## Google's definitions these answers use

From "Provide information for Google Play's Data safety section"
(<https://support.google.com/googleplay/android-developer/answer/10787469>,
read 2026-11-13):

- **Collect** means transmitting data off the user's device, whether to
  the developer or to a third party. Chopstats has no developer backend,
  but every photo, typed request and lookup it sends to the user's AI
  service leaves the device, so it is **collected** in Google's sense.
  "Nothing is collected by the developer" is not the test.
- **Share** means transferring data to a third party. Google exempts,
  among others, a transfer that follows **a specific user-initiated
  action** where the user reasonably expects the data to go there, and a
  transfer made after **a prominent in-app disclosure and the user's
  consent** that meets the User Data policy. These two exemptions are
  why the answer below is "Shared: No".
- **Processed ephemerally** means the data is kept only in memory and no
  longer than needed for the real-time request. Chopstats cannot promise
  that for the AI services: each keeps requests under its own terms (for
  example, Google's unpaid Gemini tier may use inputs to improve its
  products, with human review). So the answer is "No".
- **Optional** means users can choose whether the data is collected, or
  can use the app without it. The same help page says the opposite case
  is **required**: data the app's primary functionality needs, which users
  cannot turn off (paraphrased; the page's wording, read 2026-11-13, is
  the reference). Why "optional" holds here:
  - every send is the user's choice: the consent dialog before anything
    goes to a recipient, then picking or sharing a photo, or typing a
    request;
  - **Photos:** meals are logged without any photo, by *Describe a meal*
    (text only) or *Enter manually*, so the core function, a calorie log,
    does not need photos;
  - **Health info, Fitness info, Other user-generated content:** *Enter
    manually* and *My usual foods* log meals with no AI call at all, so
    nothing leaves the phone, and Body and History work on what is
    already there;
  - **Approximate location:** only with Restaurant nutrition lookups,
    which are off by default.

  AI estimates are still the headline feature, so a stricter reading
  would mark Photos and Health info "required". Either is allowed;
  "optional" is the answer here. Keep the same answer in every update.

## Section 1: Data collection and security

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **Yes** |
| Is all of the user data collected by your app encrypted in transit? | **Yes** — every request goes over HTTPS: the nine AI providers' endpoints are all `https://`, Anthropic's and OpenRouter's web search too, and your own server is refused unless its address starts with `https://` (decision 2). |
| Which of the following methods of account creation does your app support? | **My app does not allow users to create an account** (no accounts, no sign-in). |
| Do you provide a way for users to request that their data is deleted? | **No.** The developer holds none of the data, so there is nothing to delete on request. What the user's AI service received is kept under that service's own terms. Users delete what is on the phone in the app or by uninstalling; that is not what this question asks about. |

If the console asks about an independent security review, leave it
unticked (none was done).

## Section 2: Data types

Tick exactly these five types. For each one the answers are the same:

- **Collected:** Yes
- **Shared:** No (exemptions above)
- **Processed ephemerally:** No
- **Required or optional:** Optional (users can choose whether it is collected)
- **Purposes:** **App functionality** only (no analytics, no developer
  communications, no advertising or marketing, no fraud prevention, no
  personalization beyond the feature itself, no account management)

| Category › Type | What leaves the phone, and when |
|---|---|
| **Photos and videos › Photos** | Each photo the user picks or shares into the app, and a leftover photo, goes to the AI service the user chose, re-encoded with its embedded metadata (time, camera, location) removed. |
| **Health and fitness › Health info** | Meal descriptions, food names, portions, calories and macros (a photo carries a short summary of the day's other meals; *Fix or delete a meal* carries the last 7 days of meals), the dietary profile the user wrote (sent with every photo), and a weight the user types into *Fix or delete a meal*. |
| **Health and fitness › Fitness info** | A workout the user types into *Fix or delete a meal* (for example "burned 450 calories on my 5 km run"); the app then logs it as an activity. No stored workout, step or weight record is attached to any request by the app itself. |
| **App activity › Other user-generated content** | The free text typed into *Describe a meal* and *Fix or delete a meal*. Google reserves this type for content no other type covers, so it overlaps Health info and Fitness info; ticking it as well is harmless and matches what users type. |
| **Location › Approximate location** | Only when the user turns on **Restaurant nutrition** lookups (off by default; needs the user's own server or an Anthropic or OpenRouter key): each lookup carries the country code `US`, which the app infers on the phone from the time zone and region setting (a meal outside the US is not looked up at all). Google counts an inferred location of a city or larger area as approximate location. Android never reads a photo's position, and no GPS coordinate is ever sent. |

Everything else: **not collected**.

- Location › Precise location: No (GPS is stripped from every upload,
  `lib/services/analyzer/platform_decode.dart`; no location permission;
  Android lookups use printed brands only).
- Personal info (name, email, user IDs, address, phone, race and
  ethnicity, political or religious beliefs, sexual orientation, other
  info): No.
- Financial info: No. Messages: No. Audio: No. Files and docs: No.
  Calendar: No. Contacts: No.
- App activity › App interactions, In-app search history, Installed
  apps, Other actions: No.
- Web browsing: No.
- App info and performance (crash logs, diagnostics, other performance
  data): No. There is no crash reporting or analytics SDK; the
  Diagnostics screen stays on the phone.
- Device or other IDs: No (no advertising ID, no `AD_ID` permission).

### Why Location is Yes

This differs from the App Store label (§ 4.3 there keeps Location at No
under Apple's definitions). Google's form asks for inferred approximate
location too, and a lookup request carries `US` only because the phone
judged that the meal was eaten there (`lib/core/meal_country.dart`; the
request field is `user_location` {type: approximate, country} in
`anthropic_lookup_client.dart` and `responses_lookup_client.dart`, and
the policy's *Restaurant nutrition lookup* section says so). Declaring it
costs one line on the store page; leaving it out risks an inaccurate
form. The alternative, if you prefer Location: No, is to stop sending the
country from Android first. That is a code change, not a form choice.

### Why "Shared: No" is defensible

- Photos and typed requests go to the AI service **the user set up with
  their own API key** (or their own server), right after a **specific
  user action**: picking or sharing a photo, tapping Describe, Fix,
  Leftovers or Test This Provider.
- Before the first send to a recipient the app shows a **consent
  dialog** that names the company, lists what is sent, and offers
  **Allow** / **Not now**; *Stop Sharing with …* in Settings withdraws
  it. Restaurant lookups, which can run without a tap once turned on,
  ask for their **own consent** first (the restaurant consent sheet).
- The developer receives nothing, sells nothing and links no third-party
  SDK that sends data.

**Conservative alternative:** tick **Shared: Yes** for all five types
(purpose App functionality). Google allows it; it makes the store page
say the data is shared with third parties, which is also true in plain
language (the AI company receives it). Pick one and keep it for every
update.

## When to revisit these answers

Change the form, `docs/PRIVACY.md` and this file together when:

- the Play build gains **Watch Camera Roll** (decision 1 = A): no new
  type, but the automatic sending rests on the camera-roll notice;
- an on-device food check that reports to Google is added (ML Kit sends
  usage metrics to Google: App info and performance, shared) — decision 8;
- **Health Connect** sync is built (decision 12): its own declaration and
  data types;
- the restaurant lookup stops sending the country from Android
  (Location could then go back to No), or starts reading photo locations;
- the app ever gains a developer-run service, crash reporting or
  analytics.
