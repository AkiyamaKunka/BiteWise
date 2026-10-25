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
    learned places' also drops recent answers; the consent names the region
    code and reply language a lookup sends."""
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
    assert ("deletes the places, the recent lookup answers and the lookups "
            "still waiting") in en_flat
    assert "会删除这些地点、最近的查询结果和还在等待的查询" in zh_flat
    ena, zha = _arb("en"), _arb("zh")
    for k in ("restaurantConsentSent", "restaurantConsentSentAndroid"):
        assert "region code" in ena[k] and "reply language" in ena[k], k
        assert "地区代码" in zha[k] and "回复语言" in zha[k], k
    # One "which" once the recipient's name is spliced in.
    sent = ena["restaurantConsentSent"].replace(
        "{recipient}", ena["restaurantRecipientNameClaudePlan"])
    assert sent.count(" which ") == 1
    for f in (("Info.plist",), ("en.lproj", "InfoPlist.strings")):
        assert "to remember, on this phone" in _read(
            "app", "ios", "Runner", *f)
    assert "在本机记住" in _read(
        "app", "ios", "Runner", "zh-Hans.lproj", "InfoPlist.strings")
