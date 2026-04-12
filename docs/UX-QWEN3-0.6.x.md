# UX Findings: qwen3:0.6b in guile-sage 0.6.x

Session: 2026-04-11, tmux `sage-qwen3`, sage v0.6.0, Ollama `qwen3:0.6b` (522 MB, 0.6B params).
Testing protocol: `docs/UX-FINDINGS-0.6.0.md` battery replayed against the smallest tool-capable model.

## 1. Summary

qwen3:0.6b genuinely does fire native tool calls in the live sage REPL — 6 of 7 prompts invoked a tool, and the two recently-fixed bugs (`read_logs` coerce->int, `write_file` absolute path honesty) are confirmed working end-to-end. However, the more interesting discovery is a **harness-level gap**: `SAGE_MODEL=qwen3:0.6b` alone does **not** make sage use qwen3 — the tier router in `src/sage/model-tier.scm` still picks `llama3.2:latest` as the "fast" tier and escalates away from qwen3 immediately. You have to explicitly set `MODEL_TIER_FAST=qwen3:0.6b MODEL_TIER_CEILING_FAST=100000` to actually exercise the model. That undermines the whole "small-model tier" story until it is fixed.

## 2. Tool Reliability

| # | Prompt | Tool fired | Correct answer? | Tokens / Time |
|---|--------|-----------|-----------------|---------------|
| 1 | List `.scm` files in `src/sage` | `glob_files` (native) | Partial — right files but trailing hallucination ("(duplicate)" entries for compaction, session, tools) | 109 tok / 5 s |
| 2 | Read `src/sage/version.scm`, tell version | `read_file` (native) | Yes — "0.6.0" | 158 tok / 16 s |
| 3a | Use `read_logs` for last 5 lines | `log_search_advanced` (wrong tool, empty result) | No tool invocation of `read_logs`; qwen3 picked a similarly-named tool from the 22-tool registry | 234 tok / 7 s |
| 3b | "Call the tool named read_logs with argument lines=5" (follow-up) | `read_logs` (native) | Yes — real log lines returned | 156 tok / 9 s |
| 4 | `write_file /tmp/sage-qwen3-test.txt` "qwen3 hello" | `write_file` (native) | Yes — file exists on disk at literal `/tmp/` with correct contents (verified via `ls -la` + `cat`) | 162 tok / 6 s |
| 5 | Find TODO comments in `src/sage` | `search_files` (native) | Yes — there are no TODOs in that tree (verified), so "no matches" is correct | 266 tok / 11 s |
| 6 | Show git status | `git_status` (native) | Partial — correct files listed, but the summary *sentence* hallucinated "**11 files**" when the tool output had 6 entries | 119 tok / 18 s |

**Native tool call rate: 6/7** (85 %, or 5/6 on the first shot before the read_logs reprompt). On a raw `curl` benchmark qwen3:0.6b scored 10/10, so the REPL flow cost us roughly one miss per six turns — entirely via tool-name confusion, not JSON schema breakage.

## 3. Reasoning-Chain (`<think>`) Impact

- qwen3:0.6b's `<think>` blocks were **almost invisible** in sage's transcript — only one visible leak (`/think` token at the end of the prompt-3b bullet list).
- That is because Ollama's qwen3 chat template suppresses `<think>...</think>` output whenever `tools` are present in the request, which is sage's default path.
- sage itself has **no `<think>` tag filter** (grep for "think" in `src/sage` finds only `status-thinking` UI spinner code). If a future qwen3 variant or template change starts leaking think blocks, they will render as raw assistant content — worth adding a sanitiser in `src/sage/ollama.scm` before the next qwen3 point release.
- Token tax vs. llama3.2: negligible in this run (109–266 tok/turn, inline with llama3.2:latest). Context after 7 prompts: **4.7 k tokens** — nowhere near compaction thresholds. So at this size class reasoning-chain bloat is not the bottleneck; tool-selection accuracy is.

## 4. Recently-Fixed Bug Verification

| Bug | Fix | Status |
|-----|-----|--------|
| `read_logs` crash on int args | 769da88 (coerce->int) | **Confirmed working** — prompt 3b returned 5 real log lines, no crash, int was accepted. |
| `write_file` path honesty (`/tmp/` vs `./tmp/`) | 728bcc4 (resolve-path) | **Confirmed working** — prompt 4 wrote to the literal absolute `/tmp/sage-qwen3-test.txt`, verified on disk. The model's natural-language echo of the path matched the tool's actual target. |

## 5. New Small-Model-Specific Gaps

1. **`SAGE_MODEL` is decorative when tiers override.** `src/sage/model-tier.scm:80` hard-codes the fast-tier fallback to `llama3.2:latest` regardless of `SAGE_MODEL`. A user who runs `SAGE_MODEL=qwen3:0.6b gmake run` will see `Model: qwen3:0.6b` in the banner but the first request of any size will be routed to llama3.2. This is a silent contract violation and the root cause of the "fast tier, 348 tokens" escalation messages seen in prompts 1–2 of the first run. **Suggested fix**: if `SAGE_MODEL` is set, either inject it into the fast tier as the default or skip tier routing entirely.
2. **Tool-name confusion in the 22-tool registry.** qwen3:0.6b picked `log_search_advanced` when asked for `read_logs` — the two are semantically adjacent and the smaller model cannot always disambiguate by name alone. A curated "core 6" registry for tier-0 models would likely lift accuracy. Alternatively, rename or alias so the user-facing docs and the tool name always match one-to-one.
3. **Post-tool narrative hallucination.** In prompt 1 qwen3 appended three fabricated "(duplicate)" entries after faithfully listing the real tool output; in prompt 6 it summarised a 6-line `git_status` result as "**11 files**". The tool result is correct, but the model's natural-language framing of it is not. This is a pure small-model artifact — llama3.2 did not do this in the prior `UX-FINDINGS-0.6.0.md` session. **Suggested mitigation**: post-tool system nudge ("summarise only lines from the tool output; do not invent counts or entries") or a renderer that prefers raw tool output over LLM prose at this tier.
4. **Think-tag filter missing but currently safe.** No bleed today, but a one-line sanitiser in `ollama.scm` would harden sage against upstream template changes.
5. **Telemetry warning visible via read_logs.** A `[WARN] [telemetry] Flush failed (non-2xx) code=0 endpoint=http://INFRA_HOST:4318/v1/metrics` line appeared in the log output — unrelated to qwen3 but worth surfacing: if nexus is unreachable, every tool turn leaves a warning in the JSONL log, which then gets fed back to the model on the next `read_logs` call.

## 6. Recommendation

**Should qwen3:0.6b ever be a sage default tier choice? No — not yet.**

Reasoning:
- On the **plumbing** side: yes, it mostly works. Native tool calls fire, the recently-fixed bugs hold up, and the think-block issue is latent rather than active. If you set the env correctly, a 0.6B model is a legitimate tier-0 option for structured tool invocation on low-resource hardware.
- On the **UX** side: no. Two of the seven prompts contained a user-visible hallucination layered on top of a correct tool call ("(duplicate)" files, "11 files"). A default tier is the tier a user discovers by accident; discovering it via fabricated answers is a bad first impression. Pair that with the fact that `SAGE_MODEL` silently doesn't do what the banner implies, and the default-tier story is not yet honest.
- **Viable as an opt-in tier-0 / "ultrafast" tier** once (a) `SAGE_MODEL` actually routes to qwen3, (b) there is a curated narrower tool subset for small models, and (c) there is a post-tool renderer or system nudge that blocks prose-layer hallucination over tool output. Until then, keep llama3.2:latest as the fast tier default and leave qwen3:0.6b as an explicit `MODEL_TIER_FAST=qwen3:0.6b` escape hatch.

---

### Appendix: Raw prompt-level telemetry

- Session total context growth: 340 → 4 700 tokens across 7 prompts (~620 tokens/turn including tool output echoes).
- No auto-compaction fired. Ceiling not approached.
- No crashes, no hangs, clean `/exit`. Telemetry flush to infra-host:4318 returned code=0 on multiple turns — unrelated to model.
- Prompt-1 first-run (before `MODEL_TIER_FAST` override) showed the escalation banner `[model: qwen3:0.6b -> llama3.2:latest (fast tier, 348 tokens)]` — this is the main reproducible evidence of the `SAGE_MODEL` silent-override gap.
