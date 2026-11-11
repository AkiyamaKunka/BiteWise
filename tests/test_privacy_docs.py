"""The privacy policy and the in-app consent copy say what the restaurant
lookup really sends (design R7a, "Consent" and "Chain-first data
minimization").

docs/PRIVACY.md is the published policy (English and 中文). The consent
sheet's copy lives in the app's ARB files. Both must name the recipient
chain (Apple Maps for the photo location; Anthropic web search; OpenRouter
and Exa), say what never leaves the phone (the photo, its location, the
city, the street), state the https rule for the owner's own server, and say
that Claude Plan lookups are suggestions only (the server's search text is
not verbatim page text, amendment to decision 13). Copy accuracy is the
deliverable of R7a, so this pins it in both languages.
"""

import json
import os

import lookup_jobs

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def _read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def _policy_halves():
    """The English and the Chinese policy, line breaks kept."""
    text = _read("docs", "PRIVACY.md")
    en_at = text.index("## English")
    zh_at = text.index("## 中文")
    assert en_at < zh_at
    return text[en_at:zh_at], text[zh_at:]


def _flat(text):
    """[text] with every run of whitespace one space (the policy wraps)."""
    return " ".join(text.split())


def _lookup_section(half, title):
    start = half.index(title)
    end = half.find("\n### ", start + len(title))
    return _flat(half[start:] if end == -1 else half[start:end])


def test_policy_names_apple_maps_and_the_search_recipients_in_both_languages():
    en, zh = map(_flat, _policy_halves())
    for needle in ("Apple Maps", "Anthropic", "OpenRouter", "Exa",
                   "Claude web search"):
        assert needle in en, needle
    for needle in ("Apple 地图", "Anthropic", "OpenRouter", "Exa",
                   "Claude 网页搜索"):
        assert needle in zh, needle


def test_the_only_to_the_ai_service_sentence_is_rewritten():
    en, zh = map(_flat, _policy_halves())
    # It was true before restaurant lookup; with it on, Apple Maps and the
    # search sub-processors receive data too.
    assert "Data leaves your phone only to reach the AI service" not in en
    assert "只有在需要连接你在设置中选择的 AI 服务时，数据才会离开手机" not in zh
    assert "Restaurant nutrition" in en
    assert "餐厅营养" in zh


def test_policy_says_what_a_lookup_sends_and_never_sends():
    en, zh = _policy_halves()
    en_lookup = _lookup_section(en, "### Restaurant nutrition lookup")
    zh_lookup = _lookup_section(zh, "### 餐厅营养查询")
    # Sent: chain names from the app's own table, food names and amounts.
    assert "up to three chain names" in en_lookup
    assert "food names" in en_lookup
    assert "最多三个" in zh_lookup and "食物名称" in zh_lookup
    # Never sent.
    never_en = en_lookup[en_lookup.index("never sends"):]
    for word in ("the photo", "its location", "the city", "the street",
                 "distance"):
        assert word in never_en, word
    never_zh = zh_lookup[zh_lookup.index("绝不会发送"):]
    for word in ("照片本身", "拍摄位置", "城市", "街道", "距离"):
        assert word in never_zh, word
    # Android reads no photo location.
    assert "Android the app never reads a photo's location" in en_lookup
    assert "在 Android 上，应用绝不读取照片的拍摄位置" in zh_lookup


def test_policy_states_the_https_rule_and_suggestion_only_claude_plan():
    en, zh = _policy_halves()
    en_lookup = _lookup_section(en, "### Restaurant nutrition lookup")
    zh_lookup = _lookup_section(zh, "### 餐厅营养查询")
    assert "https://" in en_lookup and "http://" in en_lookup
    assert "https://" in zh_lookup and "http://" in zh_lookup
    assert "only *suggests*" in en_lookup
    assert "只会*建议*" in zh_lookup


def test_policy_keeps_learned_places_local_and_out_of_backups_and_exports():
    en, zh = map(_flat, _policy_halves())
    assert "Clear learned places" in en
    assert "清除已记住的地点" in zh
    assert "kept outside your phone's backups and are never exported" in en
    assert "不会进入手机的备份，也不会被导出" in zh
    # The meal's own lookup record carries no location.
    assert "This holds no location" in en
    assert "其中不含任何位置" in zh


def _arb(lang):
    return json.loads(_read("app", "lib", "l10n", "app_%s.arb" % lang))


def test_consent_copy_exists_in_both_languages_and_matches_the_policy():
    en, zh = _arb("en"), _arb("zh")
    keys = [k for k in en if k.startswith("restaurantConsent")]
    assert len(keys) >= 10
    for k in keys:
        assert k in zh, k
        assert zh[k].strip(), k
    # The recipients, as the policy names them.
    assert "Claude web search" in en["restaurantRecipientNameClaudePlan"]
    assert "Anthropic" in en["restaurantRecipientNameAnthropic"]
    assert "Exa" in en["restaurantRecipientNameOpenrouter"]
    assert "Exa" in zh["restaurantRecipientNameOpenrouter"]
    # Apple Maps receives the photo location, on iPhone.
    assert "Apple Maps" in en["restaurantConsentMaps"]
    assert "Apple 地图" in zh["restaurantConsentMaps"]
    # What leaves the phone: the chain name and food names, never the photo,
    # its location, the city or the street.
    for k in ("restaurantConsentSent", "restaurantConsentSentAndroid"):
        assert "{recipient}" in en[k] and "{recipient}" in zh[k], k
        assert "chain's name" in en[k], k
        assert "photo" in en[k] and "never sent" in en[k], k
        assert "照片本身" in zh[k], k
    for word in ("its location", "the city", "the street", "the distance"):
        assert word in en["restaurantConsentSent"], word
    for word in ("拍摄位置", "城市", "街道", "距离"):
        assert word in zh["restaurantConsentSent"], word
    # The https rule for the own server.
    assert "https" in en["restaurantConsentHttps"]
    assert "https" in zh["restaurantConsentHttps"]
    # Claude Plan: suggestions only.
    assert "only suggests" in en["restaurantConsentSuggestOnly"]
    assert "只会建议" in zh["restaurantConsentSuggestOnly"]
    assert "only suggested" in en["restaurantSuggestOnly"]


def test_openrouter_lookups_also_name_the_maker_of_the_picked_model():
    """An OpenRouter lookup is a chat completion for the model picked in
    Settings (openrouter_lookup_client.dart sends `model: lookupModel`;
    only the search engine is pinned), so OpenRouter passes it on to that
    model's maker, exactly as the AI consent says for photos
    (aiConsentRelayRecipient). The lookup has its own consent and never
    reads the AI one, so its sheet, its Settings footer and the policy must
    name that recipient too (RC 1.6.0 review, 2026-11-10)."""
    en, zh = _arb("en"), _arb("zh")
    for k in ("restaurantRecipientNameOpenrouter",
              "restaurantRecipientOpenrouter"):
        assert "maker of the model you picked" in en[k], k
        assert "Exa" in en[k], k
        assert "所选模型的厂商" in zh[k], k
        assert "Exa" in zh[k], k
    en_p, zh_p = _policy_halves()
    en_lookup = _lookup_section(en_p, "### Restaurant nutrition lookup")
    zh_lookup = _lookup_section(zh_p, "### 餐厅营养查询")
    assert ("**OpenRouter** (your API key): OpenRouter (which passes the "
            "request on to the company behind the model you picked) and its "
            "search partner Exa.") in en_lookup
    assert ("**OpenRouter**（你的 API Key）：OpenRouter（它会把请求转交给你所选"
            "模型背后的公司）及其搜索合作方 Exa。") in zh_lookup


def test_photo_permission_text_mentions_the_photo_location():
    plist = _read("app", "ios", "Runner", "Info.plist")
    en = _read("app", "ios", "Runner", "en.lproj", "InfoPlist.strings")
    zh = _read("app", "ios", "Runner", "zh-Hans.lproj", "InfoPlist.strings")
    # Run 6: also, on the phone, whether a restaurant or takeout photo was
    # taken in the US.
    for text in (plist, en):
        assert "where a restaurant or takeout meal photo was taken" in text
        assert ("only to check on this phone whether it was taken in the US, "
                "to ask Apple Maps") in text
    assert "仅用于在本机判断照片是否在美国拍摄、向 Apple 地图查询" in zh


def test_policy_and_consent_say_lookups_are_for_us_meals_only():
    """Run 6: the chain table is US-only, so a meal eaten elsewhere is never
    looked up; the photo's position (where it may be read) is checked on
    the phone against an outline of the US, else the phone's region."""
    en, zh = _policy_halves()
    en_lookup = _lookup_section(en, "### Restaurant nutrition lookup")
    zh_lookup = _lookup_section(zh, "### 餐厅营养查询")
    assert "only a meal eaten in the US is looked up" in en_lookup
    assert "the check sends nothing" in en_lookup
    assert "a photo taken close to a border counts as outside" in en_lookup
    assert "phone's region setting" in en_lookup
    assert "always US: meals from elsewhere are not looked up" in en_lookup
    assert "只有在美国吃的餐才会被查询" in zh_lookup
    assert "这一判断不会发送任何内容" in zh_lookup
    assert "靠近国境线拍摄的照片按不在美国处理" in zh_lookup
    assert "手机的地区设置" in zh_lookup
    assert "总是 US：不在美国吃的餐不会被查询" in zh_lookup
    ena, zha = _arb("en"), _arb("zh")
    assert "checks whether it was in the US" in ena["restaurantConsentMaps"]
    assert "判断是否在美国" in zha["restaurantConsentMaps"]
    for k in ("assistLookupOutsideUs", "assistLookupRegionUnknown"):
        assert "US" in ena[k] and "美国" in zha[k], k


def test_policy_and_consent_say_what_the_review_found_unsaid():
    """Review 2026-10-25: the editor's answers read the photo's location to
    keep a ~100 m cell (only with 'Use photo location' on); the meal's
    record keeps the lookup's notes and how the chain was found; 'Clear
    learned places' also drops the saved answers; the consent names the
    region code and reply language a lookup sends."""
    en, zh = _policy_halves()
    en_lookup = _lookup_section(en, "### Restaurant nutrition lookup")
    zh_lookup = _lookup_section(zh, "### 餐厅营养查询")
    assert "reads that photo's location once more" in en_lookup
    assert "for lookups and for your answers alike" in en_lookup
    assert "再读取一次这张照片的拍摄位置" in zh_lookup
    assert "查询和你的回答都一样" in zh_lookup
    assert "the lookup's notes (at most 200 characters" in en_lookup
    assert "the photo's location, or your own pick" in en_lookup
    assert "查询的备注（最多 200 个字符" in zh_lookup
    assert "照片的拍摄位置，或你自己选的" in zh_lookup
    en_flat, zh_flat = _flat(en), _flat(zh)
    assert ("deletes the places, the saved lookup answers and the lookups "
            "still waiting") in en_flat
    assert "会删除这些地点、保存的查询结果和还在等待的查询" in zh_flat
    ena, zha = _arb("en"), _arb("zh")
    for k in ("restaurantConsentSent", "restaurantConsentSentAndroid"):
        assert "reply language" in ena[k], k
        assert "回复语言" in zha[k], k
    # One "which" once the recipient's name is spliced in.
    sent = ena["restaurantConsentSent"].replace(
        "{recipient}", ena["restaurantRecipientNameClaudePlan"])
    assert sent.count(" which ") == 1
    for f in (("Info.plist",), ("en.lproj", "InfoPlist.strings")):
        assert "to remember, on this phone" in _read(
            "app", "ios", "Runner", *f)
    assert "在本机记住" in _read(
        "app", "ios", "Runner", "zh-Hans.lproj", "InfoPlist.strings")


def test_the_time_zone_check_and_the_us_country_code_are_said_everywhere():
    """Review (run 6): the phone's time zone vetoes a lookup where no photo
    position may be read (the owner's region stays US in China). The
    policy, the consent and Settings say so; the consent names the country
    code the request really carries (always US), not a region code."""
    en, zh = _policy_halves()
    en_lookup = _lookup_section(en, "### Restaurant nutrition lookup")
    zh_lookup = _lookup_section(zh, "### 餐厅营养查询")
    assert "While your phone's time zone is outside the US" in en_lookup
    assert "nothing is looked up at all, whatever else says" in en_lookup
    assert "between UTC−10, Hawaii, and UTC−4" in en_lookup
    assert "stores and sends nothing about it" in en_lookup
    assert "只要手机当前的时区不在美国" in zh_lookup
    assert "就完全不会查询，不论其他信息如何" in zh_lookup
    assert "UTC−10（夏威夷）到 UTC−4" in zh_lookup
    assert "不会保存或发送任何与它有关的内容" in zh_lookup

    ena, zha = _arb("en"), _arb("zh")
    for k in ("restaurantConsentSent", "restaurantConsentSentAndroid"):
        assert ("the country code US (only meals eaten in the US are looked "
                "up)") in ena[k], k
        assert "国家代码 US（只查询在美国吃的餐）" in zha[k], k
        for stale in ("region code", "such as US"):
            assert stale not in ena[k], (k, stale)
        assert "地区代码" not in zha[k], k
        assert "time zone" in ena[k], k
        assert "时区" in zha[k], k
    assert ("While your phone's time zone is outside the US, nothing is "
            "looked up.") in ena["restaurantConsentSent"]
    assert "手机的时区不在美国时，不会进行任何查询" in zha["restaurantConsentSent"]
    # Settings: US meals only, in the line every phone shows; and why
    # nothing would be looked up on this phone now.
    assert "Only meals eaten in the US are looked up." in \
        ena["restaurantModeHelper"]
    assert "只查询在美国吃的餐" in zha["restaurantModeHelper"]
    assert "time zone is outside the US" in ena["restaurantTimeZoneHint"]
    assert "时区不在美国" in zha["restaurantTimeZoneHint"]
    assert "region is not the US" in ena["restaurantRegionHint"]
    assert "地区不是美国" in zha["restaurantRegionHint"]
    assert "time zone" in ena["assistLookupOutsideUs"]
    assert "时区" in zha["assistLookupOutsideUs"]


def test_when_unsure_also_looks_up_a_fairly_sure_meal_with_a_printed_brand():
    """Owner decision 2026-11-05: "When unsure" also looks up a restaurant
    or takeout meal the AI was fairly sure about (medium confidence) when a
    chain's brand is printed (the app's auto_branding trigger). The
    policy's "Which meals" bullet, Settings' footer and the Diagnostics
    line say so in both languages, and the policy lists the code, saved
    with the meal, that says why a lookup ran."""
    en, zh = _policy_halves()
    en_lookup = _lookup_section(en, "### Restaurant nutrition lookup")
    zh_lookup = _lookup_section(zh, "### 餐厅营养查询")

    # Which meals: When unsure, in both of its cases.
    assert ('"When unsure" looks one up only when the AI says its estimate '
            "is unsure, or when the AI is fairly sure and a cup, bag, box or "
            "receipt in the photo shows a chain's brand.") in en_lookup
    assert "only when the AI also says its estimate is unsure" not in en_lookup
    assert ("「不确定时」模式下，只有当 AI 表示自己的估算没有把握，或者 AI "
            "比较有把握、但照片里的杯子、袋子、盒子或小票上印有连锁品牌时，"
            "才会查询这样的餐。") in zh_lookup
    assert "比较有把握" in zh_lookup
    assert "还要 AI 表示自己的估算没有把握" not in zh_lookup
    # Always is said on its own: every restaurant or takeout meal, and any
    # other photo meal only by its OWN packaging (not a receipt).
    assert ('"Always" does not wait for either: every such meal can be looked '
            "up, and so can any other photo meal whose own cup, bag or box "
            "shows a chain's brand.") in en_lookup
    assert ("「总是」模式下不看这两个条件：这样的餐都可能被查询，其他照片餐食"
            "只要自己的杯子、袋子或盒子上印有连锁品牌，也可能被查询。") in zh_lookup
    assert "You can also look up any meal yourself." in en_lookup
    assert "你也可以自己手动查询任意一餐。" in zh_lookup
    # Unchanged by it: which meals never have their location read.
    assert ("A meal marked as home-cooked, packaged or unknown never has its "
            "location read.") in en_lookup
    assert "被标记为家里做的、包装食品或无法判断的餐，绝不会读取其位置。" in zh_lookup
    # The Apple Maps sentence is as it was, with no exception for these
    # meals: the automatic lookup of a fairly sure, branded meal does not
    # ask Apple Maps, but the same meal looked up from the editor with "Use
    # photo location" on, or in Always, does. The policy may describe more
    # than the app does for a meal, never less.
    assert ("For a restaurant meal taken in the US, it also asks Apple Maps, "
            "on the phone, which food places are nearby. Apple receives that "
            "location") in en_lookup
    assert ("对在美国拍摄的餐厅餐，还会在手机上向 Apple 地图查询附近的餐饮场所。"
            "Apple 会收到该位置") in zh_lookup

    # What is saved with the meal: the code that says why the lookup ran.
    assert ("why a suggestion was not used by itself (a code), why the "
            "lookup ran (a code), and how the meal was tied to the "
            "chain") in en_lookup
    assert ("建议没有被自动采用的原因（一个代码）、这次查询的起因（一个代码），"
            "以及这一餐是如何与该连锁店对应上的") in zh_lookup

    ena, zha = _arb("en"), _arb("zh")
    # Settings' footer, the line every phone shows.
    assert ("When your AI is unsure about a restaurant meal, or fairly sure "
            "about one that shows a chain's brand on a cup, bag or "
            "receipt,") in ena["restaurantModeHelper"]
    assert "fairly sure" in ena["restaurantModeHelper"]
    assert ("当 AI 对餐厅餐的估算没有把握，或者比较有把握但杯子、袋子或小票上"
            "印有连锁品牌时，") in zha["restaurantModeHelper"]
    assert "比较有把握" in zha["restaurantModeHelper"]
    # Diagnostics: what the confidence counts mean for "When unsure".
    assert ("looks up low-confidence restaurant meals, and medium-confidence "
            "ones that show a chain's brand.") in ena["diagConfidenceIntro"]
    assert "medium-confidence" in ena["diagConfidenceIntro"]
    assert "only low-confidence" not in ena["diagConfidenceIntro"]
    assert ("会查询把握低的餐厅餐，以及把握中等且印有连锁品牌的餐厅餐。"
            ) in zha["diagConfidenceIntro"]
    assert "把握中等" in zha["diagConfidenceIntro"]
    assert "只查询把握低" not in zha["diagConfidenceIntro"]
    # The mode keeps its name, and the translator's note states the rule.
    assert ena["restaurantModeAuto"] == "When unsure"
    assert zha["restaurantModeAuto"] == "不确定时"
    note = ena["@restaurantModeAuto"]["description"]
    assert "unsure (low confidence), or fairly sure (medium)" in note
    assert "only when the AI says" not in note


def _paragraph(half, start):
    """The paragraph of [half] that begins with [start], whitespace flat."""
    at = half.index(start)
    end = half.find("\n\n", at)
    return _flat(half[at:] if end == -1 else half[at:end])


def test_stop_sharing_also_stops_restaurant_lookups_to_that_recipient():
    """The owner's requirement before PR #19 ships (docs/RELEASING.md):
    Settings > Stop Sharing with ... says "nothing more is sent to ...", and
    no lookup reads the AI consent, so the row also turns restaurant lookup
    off, and forgets its consent, when its lookups go to that recipient.
    The policy, the dialog and the snackbar say so in both languages; the
    strings shown when the assist is not touched keep their wording."""
    en, zh = _policy_halves()
    en_p = _paragraph(en, "**Withdrawing consent.**")
    zh_p = _paragraph(zh, "**撤回同意。**")
    assert "Stop Sharing with …" in en_p
    assert "stops all sending to that recipient" in en_p
    assert "turns off Watch Camera Roll" in en_p
    assert ("restaurant nutrition lookup too when its lookups go to that "
            "recipient") in en_p
    assert "lookups still waiting are dropped" in en_p
    assert ("asks again before it sends anything there, lookups "
            "included") in en_p
    assert "停止发送给 …" in zh_p
    assert "关闭「监控相册」" in zh_p
    assert "如果餐厅营养查询也是发给这个接收方，查询也会一并关闭" in zh_p
    assert "待处理的查询会被丢弃" in zh_p
    assert "之后再向它发送任何内容（包括查询）前，应用都会重新询问" in zh_p

    ena, zha = _arb("en"), _arb("zh")
    # The dialog when the row also turns the assist off, and its snackbar.
    for k in ("aiStopSharingBodyWithLookups", "aiStopSharingDoneWithLookups"):
        assert "{provider}" in ena[k], k
        assert "{provider}" in zha[k], k
        assert ena["@" + k]["placeholders"]["provider"]["type"] == "String"
    body_en = ena["aiStopSharingBodyWithLookups"]
    body_zh = zha["aiStopSharingBodyWithLookups"]
    assert "photos, meal text and restaurant lookups to {provider}" in body_en
    assert "Watch Camera Roll and restaurant lookups turn off" in body_en
    assert "pending lookups are cancelled" in body_en
    assert "照片、餐食文字和餐厅营养查询发送给 {provider}" in body_zh
    assert "「监控相册」和餐厅营养查询都会关闭" in body_zh
    assert "未完成的查询会被取消" in body_zh
    # What it promises is scoped to the recipient, so it is always true: a
    # consent the assist holds for ANOTHER recipient is kept, and turning
    # lookups on for that one asks nothing.
    assert body_en.endswith(
        "Chopstats asks again before it sends anything to {provider}.")
    assert body_zh.endswith("再向 {provider} 发送任何内容之前，筷拍会再次征求你的同意。")
    assert "turn restaurant lookups back on" not in body_en
    assert "重新开启餐厅营养查询" not in body_zh
    assert ena["aiStopSharingDoneWithLookups"] == (
        "Stopped — nothing more is sent to {provider}. Restaurant lookups "
        "are off.")
    assert zha["aiStopSharingDoneWithLookups"] == (
        "已停止 — 不再向 {provider} 发送任何内容，餐厅营养查询已关闭。")

    # Unchanged: what is shown when the assist is left alone.
    assert ena["aiStopSharingDone"] == (
        "Stopped — nothing more is sent to {provider}.")
    assert zha["aiStopSharingDone"] == "已停止 — 不再向 {provider} 发送任何内容。"
    assert ena["aiStopSharingBody"] == (
        "Chopstats stops sending photos and meal text to {provider}, and "
        "Watch Camera Roll turns off. Meals already logged stay on this "
        "phone. The next time you use AI analysis, Chopstats asks again.")
    assert zha["aiStopSharingBody"] == (
        "筷拍不再把照片和餐食文字发送给 {provider}，「监控相册」也会关闭。"
        "已记录的餐食仍保存在这台手机上。下次使用 AI 分析时，筷拍会再次征求你的同意。")

    # The release notes no longer list it as still to do, and the support
    # page says it too.
    releasing = _flat(_read("docs", "RELEASING.md"))
    assert "must also turn the assist off" not in releasing
    assert ("*Stop Sharing with …* also turns the assist off when its "
            "lookups go to the same company or server") in releasing
    assert "`stopRestaurantAssistFor`" in releasing
    support = _flat(_read("docs", "SUPPORT.md"))
    assert ("turns off Watch Camera Roll (and restaurant lookups that go to "
            "it)") in support


def test_policy_usual_foods_and_saved_answers():
    """Usual foods (spec section 7): a lookup answer that found a chain's
    published numbers is kept up to a year, any other up to 30 days, each
    with when it was last used; Android gets its own clear row; My usual
    foods and your usual numbers are worked out on the phone and send
    nothing; a meal changed or logged with them is sent like any other
    meal; the hidden foods and turned-down offers are stored as codes, not
    food names; turning lookups off keeps the answers unless cleared. The
    policy names the controls as the app shows them."""
    en, zh = _policy_halves()
    en_phone = _lookup_section(en, "### What stays on your phone")
    zh_phone = _lookup_section(zh, "### 留在你手机上的数据")
    en_lookup = _lookup_section(en, "### Restaurant nutrition lookup")
    zh_lookup = _lookup_section(zh, "### 餐厅营养查询")
    en_delete = _lookup_section(en, "### Deleting your data")
    zh_delete = _lookup_section(zh, "### 删除数据")
    ena, zha = _arb("en"), _arb("zh")

    # How long the saved answers are kept, and that the last use is kept.
    assert ("saved lookup answers (an answer that found a chain's published "
            "numbers for up to a year, any other for up to 30 days;") \
        in en_phone
    assert "for up to a year" in en_phone
    assert "any other for up to 30 days" in en_phone
    assert ("each with when it was last used, so the one used longest ago "
            "goes first when space runs out") in en_phone
    assert ("保存的查询结果（找到连锁店公布数值的最长保存一年，其他的最长 30 天；"
            ) in zh_phone
    assert "最长保存一年" in zh_phone
    assert "其他的最长 30 天" in zh_phone
    assert "每条都记录最后一次使用的时间" in zh_phone
    assert "最后一次使用的时间" in zh_phone
    # The old wording is gone (a 3-way merge could bring it back silently).
    for stale in ("recent lookup answers", "recent answers",
                  "up to 30 days, each marked"):
        assert stale not in _flat(en), stale
    for stale in ("最近的查询结果", "（最长 30 天；"):
        assert stale not in _flat(zh), stale

    # Android's clear row, named as Settings shows it.
    row_en = "**%s**" % ena["settingsRowClearSavedAnswers"]
    row_zh = "**「%s」**" % zha["settingsRowClearSavedAnswers"]
    assert ("On Android, where no places are kept, %s deletes the saved "
            "lookup answers and the lookups still waiting." % row_en) \
        in en_phone
    assert ("在不保存地点的 Android 上，%s会删除保存的查询结果和还在等待的查询。"
            % row_zh) in zh_phone
    assert ("(Settings › Restaurant nutrition; on Android %s)" % row_en) \
        in en_delete
    assert "learned and its saved answers" in en_delete
    assert ("（设置 › 餐厅营养；Android 上是%s）" % row_zh) in zh_delete
    assert "删除餐厅查询记住的地点和保存的查询结果" in zh_delete

    # My usual foods and your usual numbers: worked out on the phone,
    # nothing sent, the changed meal is like any other, codes not names.
    usual_en = "**%s**" % ena["addUsual"]
    usual_zh = "**「%s」**" % zha["addUsual"]
    assert ("- %s and **your usual numbers** are worked out on the phone "
            "from the meals you logged in the last 90 days" % usual_en) \
        in en_phone
    assert ("- %s和**「%s」**都是在手机上根据你最近 90 天记录的餐食算出来的"
            % (usual_zh, zha["usualCardTitle"])) in zh_phone
    assert "or by tapping **%s**" % ena["usualChipUse"] in en_phone
    assert "或点按**「%s」**" % zha["usualChipUse"] in zh_phone
    # What the mark holds: that you set the numbers and, for a food you
    # renamed, the AI's first name for it (user.ai_name).
    assert ("The meal keeps a small mark on that food saying you set them "
            "and, for a food you renamed, the name the AI first gave it.") \
        in en_phone
    assert ("这一餐会在该食物上保存一个小标记，说明数值是你设定的，"
            "以及你改过名的食物最初由 AI 给出的名称。") in zh_phone
    assert "Working them out sends nothing: no AI call, no lookup." \
        in en_phone
    assert "算出这些内容不会发送任何东西：不调用 AI，也不查询。" in zh_phone
    assert ("A meal you log or change with them is then like any other "
            "meal") in en_phone
    assert "is then like any other meal" in en_phone
    assert "用它们记录或修改的餐食之后和其他餐食一样" in zh_phone
    assert "之后和其他餐食一样" in zh_phone
    # Like any other meal, it also goes with a photo taken before 4 a.m. the
    # next day (run 7's previous-day leftover context, photo_pipeline.dart),
    # the same as the policy's "What is sent with a photo" and "What that
    # recipient receives" bullets say (#22 merge step, docs/RELEASING.md).
    assert ("its summary goes with the next photo you log that day (and "
            "with one taken before 4 a.m. the next day), as described "
            "under \"What is sent, and to whom\".") in en_phone
    assert ("当天你再记录照片时（第二天凌晨 4 点前拍的照片也一样），它的简短摘要会"
            "一起发送，见「发送了什么、发给谁」。") in zh_phone
    for half, needle in ((_flat(en), "before 4 a.m."),
                         (_flat(zh), "凌晨 4 点前")):
        # The usual-foods bullet, "What is sent with a photo" and "What
        # that recipient receives": every place that says which meals go
        # with a photo names the day before too.
        assert half.count(needle) >= 3, needle
    assert ("Which foods you hid from %s and which offers you turned down "
            "are kept with the app's settings as short codes, not food "
            "names." % usual_en) in en_phone
    assert "as short codes, not food names" in en_phone
    assert ("你在「%s」里隐藏了哪些食物、拒绝过哪些建议，会以简短代码"
            "（不是食物名称）和设置一起保存。" % zha["addUsual"]) in zh_phone
    assert "简短代码（不是食物名称）" in zh_phone
    assert ("Delete meals inside the app (%s and your usual numbers are "
            "worked out from them, so they change with them)"
            % ena["addUsual"]) in en_delete
    assert ("在应用内删除餐食（「%s」和你平时的数值都根据餐食算出，会随之改变）"
            % zha["addUsual"]) in zh_delete

    # The meal's lookup record: the day a saved answer was looked up.
    assert ("the date (and, for a saved answer, the day it was looked up),"
            ) in en_lookup
    assert "日期（使用保存的结果时，还有当初查询的日期）、" in zh_lookup

    # Turning lookups off keeps the saved answers unless they are cleared.
    assert ("can clear learned places and the saved lookup answers at the "
            "same time (on Android, the saved lookup answers). If you do "
            "not clear them, they are kept as described above.") in en_lookup
    assert "If you do not clear them, they are kept as described above." \
        in en_lookup
    assert ("并可同时清除已记住的地点和保存的查询结果（Android 上是保存的查询结果）。"
            "如果不清除，它们会按上文所述保存。") in zh_lookup
    assert "如果不清除，它们会按上文所述保存。" in zh_lookup


def test_the_policys_own_server_retention_is_the_servers_cache_ttl():
    """The policy tells the user how long their own server keeps a lookup's
    request and answer; lookup_jobs.CACHE_TTL_SECONDS is what makes it
    true. The hours are built from the constant, so the code and the policy
    (English and 中文) cannot move apart (RC 1.6.0 review, 2026-11-10)."""
    ttl = lookup_jobs.CACHE_TTL_SECONDS
    assert ttl % 3600 == 0, ttl
    hours = ttl // 3600
    en, zh = map(_flat, _policy_halves())
    assert ("Your server keeps a lookup's request and answer in memory for "
            "up to %d hours." % hours) in en
    assert ("你的服务器会在内存中保留一次查询的请求和结果，最长 %d 小时。"
            % hours) in zh
