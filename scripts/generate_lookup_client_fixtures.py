"""Builds the lookup-client response fixtures from the vendors' documented
shapes (Anthropic web-search tool page, OpenRouter web-search guide, OpenAI
web-search guide, xAI citations + API reference), read 2026-10-23.

No live call was made (no ~/.bitewise/provider_keys.env on this Mac); every
id, token count and encrypted blob below is synthetic. Indices for
url_citation spans are computed here so they are exact.

Usage (from the repo root):
    python3 scripts/generate_lookup_client_fixtures.py \
        app/test/assist/clients/fixtures
"""
import json
import os
import sys

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

BIGMAC = "https://www.mcdonalds.com/us/en-us/product/big-mac.html"
CALC = "https://www.mcdonalds.com/us/en-us/about-our-food/nutrition-calculator.html"
THIRD = "https://www.fastfoodnutrition.org/mcdonalds/big-mac"
BIGMAC_TITLE = "Big Mac®: McDonald's Iconic Burger | McDonald's"


def write(name, obj):
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)
        f.write("\n")


def enc(tag):
    # Shape of encrypted_content / encrypted_index: opaque base64. Synthetic.
    return "EqgfCioIARgBIiQ" + tag + "AAAA" * 6


def results(urls):
    pages = {
        BIGMAC: (BIGMAC_TITLE, "October 2, 2026"),
        CALC: ("Nutrition Calculator | McDonald's", "September 18, 2026"),
        THIRD: ("McDonald's Big Mac Nutrition Facts", "March 3, 2024"),
    }
    out = []
    for u in urls:
        title, age = pages[u]
        out.append({
            "type": "web_search_result",
            "url": u,
            "title": title,
            "encrypted_content": enc("r" + str(len(out))),
            "page_age": age,
        })
    return out


def cite(url, text, title=BIGMAC_TITLE):
    return {
        "type": "web_search_result_location",
        "url": url,
        "title": title,
        "encrypted_index": enc("i"),
        "cited_text": text,
    }


CITED_590 = ("Big Mac® | 590 Cal. The one and only McDonald's Big Mac® "
             "Burger. Mouthwatering perfection starts with two 100% pure "
             "all beef patties")
CITED_MACROS = ("Nutrition: Calories 590, Total Fat 34g, Carbohydrates 46g, "
                "Protein 25g. Serving size 1 sandwich (219 g)")
assert len(CITED_590) <= 150 and len(CITED_MACROS) <= 150


def answer_blocks(source_url=BIGMAC, cited=True):
    """The final JSON split the way citations split it: the cited number
    is its own text block."""
    head = ('{"status": "found", "chain_key": "mcdonalds", "restaurant_name":'
            ' "McDonald\'s", "matches": [{"item_index": 0, "menu_item": '
            '"Big Mac", "match_type": "exact_item", "is_drink": false, '
            '"components": [], "options": [{"label": "Big Mac", "serving": '
            '"1 sandwich (219 g)", "unit": "sandwich", "calories": ')
    mid = "590"
    tail = (', "calories_range": null, "protein_g": 25, "carbs_g": 46, '
            '"fat_g": 34}]}], "source_url": "' + source_url + '", '
            '"source_title": "Big Mac®: McDonald\'s Iconic Burger | '
            'McDonald\'s", "source_type": "official_site", "source_year": '
            '2026, "match_confidence": 0.95, "notes": ""}')
    if not cited:
        return [{"type": "text", "text": head + mid + tail}]
    return [
        {"type": "text", "text": head},
        {"type": "text", "text": mid,
         "citations": [cite(BIGMAC, CITED_590)]},
        {"type": "text", "text": tail,
         "citations": [cite(BIGMAC, CITED_MACROS)]},
    ]


def anthropic(content, stop="end_turn", searches=1, inp=9812, out=402):
    return {
        "id": "msg_01XFDUDYJgAACzvnptvVoYEL",
        "type": "message",
        "role": "assistant",
        "model": "claude-haiku-5-5",
        "content": content,
        "stop_reason": stop,
        "stop_sequence": None,
        "usage": {
            "input_tokens": inp,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
            "output_tokens": out,
            "server_tool_use": {"web_search_requests": searches},
        },
    }


THINK = {"type": "thinking", "thinking": "", "signature": enc("sig")}
PRE = {"type": "text",
       "text": "I'll look up McDonald's published nutrition for the Big Mac."}


def search(i, query):
    return {"type": "server_tool_use", "id": "srvtoolu_01" + str(i) * 22,
            "name": "web_search", "input": {"query": query}}


def result_block(i, urls):
    return {"type": "web_search_tool_result",
            "tool_use_id": "srvtoolu_01" + str(i) * 22,
            "content": results(urls)}


def error_block(i, code):
    return {"type": "web_search_tool_result",
            "tool_use_id": "srvtoolu_01" + str(i) * 22,
            "content": {"type": "web_search_tool_result_error",
                        "error_code": code}}


Q1 = "McDonald's Big Mac calories nutrition"

write("anthropic_found.json", anthropic(
    [THINK, PRE, search(1, Q1), result_block(1, [BIGMAC, CALC, THIRD])]
    + answer_blocks()))

write("anthropic_pause_1.json", anthropic(
    [PRE, search(1, Q1), result_block(1, [BIGMAC, CALC])],
    stop="pause_turn", inp=7012, out=96))
write("anthropic_pause_2.json", anthropic(
    answer_blocks(), searches=0, inp=8890, out=380))

write("anthropic_search_error.json", anthropic(
    [PRE, search(1, Q1), error_block(1, "too_many_requests"),
     {"type": "text", "text": "I could not search right now."}],
    searches=0, inp=2100, out=60))

write("anthropic_max_uses.json", anthropic(
    [PRE, search(1, Q1), result_block(1, [BIGMAC, CALC]),
     search(2, "Big Mac nutrition PDF"), error_block(2, "max_uses_exceeded")]
    + answer_blocks(), searches=1))

UNCITED = "https://www.mcdonalds.com/us/en-us/product/big-mac-nutrition-facts.html"
write("anthropic_uncited_source.json", anthropic(
    [PRE, search(1, Q1), result_block(1, [BIGMAC, CALC])]
    + answer_blocks(source_url=UNCITED)))

write("anthropic_no_citations.json", anthropic(
    [PRE, search(1, Q1), result_block(1, [BIGMAC, CALC])]
    + answer_blocks(cited=False)))

write("anthropic_third_party.json", anthropic(
    [PRE, search(1, Q1), result_block(1, [THIRD])]
    + [{"type": "text", "text": json.dumps({
        "status": "found", "chain_key": "mcdonalds",
        "restaurant_name": "McDonald's",
        "matches": [{"item_index": 0, "menu_item": "Big Mac",
                     "match_type": "exact_item", "is_drink": False,
                     "components": [], "options": [{
                         "label": "Big Mac", "serving": "1 burger",
                         "unit": "burger", "calories": 563,
                         "calories_range": None, "protein_g": 26,
                         "carbs_g": 44, "fat_g": 33}]}],
        "source_url": THIRD, "source_title": "Big Mac Nutrition Facts",
        "source_type": "third_party_db", "source_year": 2024,
        "match_confidence": 0.7, "notes": "official page not found"}),
        "citations": [cite(THIRD, "Big Mac: 563 calories, 33g fat",
                           "McDonald's Big Mac Nutrition Facts")]}]))

write("anthropic_refusal.json", anthropic(
    [{"type": "text", "text": ""}], stop="refusal", searches=0,
    inp=1500, out=5))

# ---------------------------------------------------------------- OpenRouter
OR_JSON = json.dumps({
    "status": "found", "chain_key": "mcdonalds",
    "restaurant_name": "McDonald's",
    "matches": [{"item_index": 0, "menu_item": "Big Mac",
                 "match_type": "exact_item", "is_drink": False,
                 "components": [], "options": [{
                     "label": "Big Mac", "serving": "1 sandwich (219 g)",
                     "unit": "sandwich", "calories": 590,
                     "calories_range": None, "protein_g": 25, "carbs_g": 46,
                     "fat_g": 34}]}],
    "source_url": BIGMAC, "source_title": "Big Mac®",
    "source_type": "official_site", "source_year": 2026,
    "match_confidence": 0.93, "notes": ""}, ensure_ascii=False)
OR_TEXT = "```json\n" + OR_JSON + "\n```"


def openrouter(annotations, text=OR_TEXT, finish="stop", cost=0.00912):
    return {
        "id": "gen-1761234567-AbCdEfGhIjKlMnOpQrSt",
        "provider": "Google",
        "model": "google/gemini-3.8-flash",
        "object": "chat.completion",
        "created": 1761234567,
        "choices": [{
            "logprobs": None,
            "finish_reason": finish,
            "native_finish_reason": "STOP",
            "index": 0,
            "message": {"role": "assistant", "content": text,
                        "refusal": None, "reasoning": None,
                        "annotations": annotations},
        }],
        "usage": {"prompt_tokens": 3120, "completion_tokens": 380,
                  "total_tokens": 3500, "cost": cost, "is_byok": False,
                  "prompt_tokens_details": {"cached_tokens": 0},
                  "completion_tokens_details": {"reasoning_tokens": 0}},
    }


def or_ann(url, title, content=None):
    c = {"url": url, "title": title, "start_index": 0, "end_index": 0}
    if content is not None:
        c["content"] = content
    return {"type": "url_citation", "url_citation": c}


write("openrouter_found.json", openrouter([
    or_ann(BIGMAC, BIGMAC_TITLE,
           "Big Mac® 590 Cal. Two 100% pure all beef patties, Big Mac "
           "sauce... Nutrition: Calories 590 | Total Fat 34g | Carbs 46g | "
           "Protein 25g"),
    or_ann(CALC, "Nutrition Calculator | McDonald's",
           "Build your meal and see calories for every item."),
    or_ann(THIRD, "McDonald's Big Mac Nutrition Facts",
           "Big Mac: 563 calories"),
]))
write("openrouter_no_content.json", openrouter([
    or_ann(BIGMAC, BIGMAC_TITLE),
]))
write("openrouter_error_in_200.json", {
    "error": {"code": 502, "message": "Provider returned error",
              "metadata": {"provider_name": "Google"}}})
write("openrouter_length.json", openrouter([], text='{"status": "fo',
                                           finish="length"))

# -------------------------------------------------------------------- OpenAI
OA_JSON = OR_JSON
oa_link = " ([mcdonalds.com](" + BIGMAC + "?utm_source=openai))"
OA_TEXT = OA_JSON + oa_link
s = OA_TEXT.index("([mcdonalds.com]")
OA_ANN = [{"type": "url_citation", "start_index": s,
           "end_index": len(OA_TEXT),
           "url": BIGMAC + "?utm_source=openai", "title": BIGMAC_TITLE}]


def openai(output, status="completed", incomplete=None):
    return {
        "id": "resp_68c9fa0502748190b7dd390736892e100be649c1a5ff9609",
        "object": "response",
        "created_at": 1761234567,
        "status": status,
        "background": False,
        "error": None,
        "incomplete_details": incomplete,
        "instructions": None,
        "max_output_tokens": 1500,
        "max_tool_calls": 2,
        "model": "gpt-4.1-mini-2025-04-14",
        "output": output,
        "parallel_tool_calls": True,
        "previous_response_id": None,
        "store": False,
        "tools": [{"type": "web_search", "search_context_size": "low",
                   "user_location": {"type": "approximate",
                                     "country": "US"}}],
        "usage": {"input_tokens": 8721,
                  "input_tokens_details": {"cached_tokens": 0},
                  "output_tokens": 412,
                  "output_tokens_details": {"reasoning_tokens": 0},
                  "total_tokens": 9133},
    }


OA_CALL = {"type": "web_search_call",
           "id": "ws_68c9fa0574548190a0ad8d0e8b6a64b50be649c1a5ff9609",
           "status": "completed",
           "action": {"type": "search",
                      "query": "McDonald's Big Mac calories",
                      "sources": [{"type": "url", "url": BIGMAC},
                                  {"type": "url", "url": THIRD}]}}
write("openai_found.json", openai([
    OA_CALL,
    {"id": "msg_68c9fa077bc48190b6d7b2e3d6d1c0f40be649c1a5ff9609",
     "type": "message", "status": "completed", "role": "assistant",
     "content": [{"type": "output_text", "text": OA_TEXT,
                  "annotations": OA_ANN, "logprobs": []}]},
]))
write("openai_incomplete.json", openai(
    [OA_CALL], status="incomplete",
    incomplete={"reason": "max_output_tokens"}))

# ----------------------------------------------------------------------- xAI
# Inline citation INSIDE the JSON, right after the number — the case that
# breaks a naive parse.
XA_TEXT = OR_JSON.replace('"calories": 590,', '"calories": 590 [[1]](' +
                          BIGMAC + '),')
assert XA_TEXT != OR_JSON
cs = XA_TEXT.index("[[1]]")
ce = XA_TEXT.index(")", cs) + 1
write("xai_found.json", {
    "id": "a4d1f7c2-3b0e-4c7e-9a52-7f0b6c1d2e3f",
    "object": "response",
    "created_at": 1761234567,
    "completed_at": 1761234579,
    "model": "grok-4.7",
    "status": "completed",
    "error": None,
    "incomplete_details": None,
    "output": [
        {"type": "web_search_call", "id": "ws_9f1c", "status": "completed",
         "action": {"type": "search", "query": "Big Mac calories"}},
        {"type": "message", "id": "msg_2b7e", "role": "assistant",
         "status": "completed",
         "content": [{"type": "output_text", "text": XA_TEXT,
                      "annotations": [{"type": "url_citation",
                                       "url": BIGMAC, "start_index": cs,
                                       "end_index": ce, "title": "1"}],
                      "logprobs": None}]},
    ],
    "citations": [BIGMAC, THIRD],
    "store": False,
    "usage": {"input_tokens": 6230, "output_tokens": 455,
              "total_tokens": 6685,
              "input_tokens_details": {"cached_tokens": 0},
              "output_tokens_details": {"reasoning_tokens": 210},
              "num_sources_used": 0,
              "num_server_side_tools_used": 1,
              "server_side_tool_usage_details": {"web_search_calls": 1},
              "cost_in_usd_ticks": 196700000},
})
print("ok", sorted(os.listdir(OUT)))
