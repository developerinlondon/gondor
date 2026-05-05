# 03 — Axiom + notebooklm research analysis

Status: analysis. Not an implementation plan. Captures findings from a session
spent connecting the dots between the production Python research tool on
`fc-joy`, the axiom Rust port-in-progress at `/home/eda/code/fcar/axiom`, and
gondor's workflow surface.

Date: 2026-05-04

## TL;DR

- The production research stack is a 1,997-LOC Python tool living at
  `fc-joy:/home/info/scripts/notebooklm-engine.py` (decomposed into a
  `notebooklm/` package). It's an interactive CLI, not a service.
- It manages **17 sqlite-backed notebooks** (5 FCAR business + 12 Deep
  Audit codebase corpora), backed by a single 80 MB sqlite db with
  FTS5 BM25 retrieval and Claude-driven Q&A, gap analysis, and audio
  generation.
- The Rust **axiom** project is a port-in-progress of that tool, plus a
  deterministic plan-runner runtime around it. Only the substrate
  (chunker, FTS5 retrieve, ingest adapters) is library-complete; the
  installable bins and the LLM Provider impl are upstream-deferred.
- Axiom is **not deployed in production anywhere today**. Our gondor
  `/axiom` workflow is the first end-user surface for it.
- The case for axiom over the Python tool is runtime discipline
  (capability gates, events.jsonl court record, approval gates,
  replay/inspect), not new user-visible features.

## 1. Where source data comes from (no proprietary feeds)

| Adapter                    | Pulls                                                                                                          | How                                                                                                                                                                                                                                                                |
| -------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `add` / `search` (YouTube) | Full transcripts of YouTube videos (auto-captions). Currently the only source for the FCAR business notebooks. | `yt-dlp` for search (no API key); `youtube_transcript_api` for transcripts with VTT fallback through yt-dlp. Per-segment timestamps preserved so retrieval can render `~Xm:Yys` locators.                                                                          |
| `ingest-github <repo>`     | Public GitHub repos. Source for the Deep Audit notebooks.                                                      | `git clone --depth 1 --single-branch` into `/tmp/notebooklm-clones/`, then ingests as files. License-aware: skips repos without LICENSE/manifest unless `--allow-unlicensed-pattern-only` is passed (marks rows so verbatim quotes can be stripped at query time). |
| `ingest-url <urls>`        | Any HTTP(S) URL — articles, statutes, county docs.                                                             | Plain `urllib.request` fetch, stdlib `HTMLParser` strips HTML (skips `script`/`style`/`nav`/`header`/`footer`/`aside`, inserts newlines on block tags). Result cached at `/tmp/notebooklm-url-cache/` keyed by sha256(url).                                        |
| `ingest-local <path>`      | Local files — markdown notes, downloaded PDFs/text, output of other scripts.                                   | Walks directory; default code/doc globs (`.md/.rs/.py/.ts/.tsx/.js/.go/.toml`) plus standard excludes (`.git`, `node_modules`, `target`).                                                                                                                          |

So **no premium APIs, no scrapers, no purchased data**. The universe of source material is:

- YouTube transcripts via yt-dlp (free)
- public GitHub repos (cached locally)
- HTML pages via plain `urllib`
- whatever the operator drops in a folder

FCAR business notebooks (Surplus Funds, Probate, Medicaid, AI Agent Ops,
Competitor Intelligence) get fed YouTube how-tos from established
operators. Deep Audit notebooks get fed competitor/peer GitHub repos.

## 2. FTS5 BM25 vs "normal" search vs semantic

```
LIKE '%foo%'              FTS5 BM25 (this tool)         Semantic / vector
─────────────             ─────────────────────         ─────────────────
substring match           tokenized lexical match       neural embedding match
no stemming               porter stemmer                model-encoded meaning
no ranking                BM25 statistical ranking      cosine similarity
linear scan               inverted index                ANN index (HNSW etc.)

Question: "how do I handle multiple heirs in surplus funds?"

LIKE: matches lines containing "heirs" verbatim. Misses "heir", "heir's",
      "co-claimants", "intestate".

FTS5: tokens → ["multiple","heirs","surplus","funds"] → with porter stem
      → ["multipl","heir","surplus","fund"]
      → MATCH "multipl* OR heir* OR surplus* OR fund*"
      Returns rows ranked by BM25 — chunks where these terms are dense
      and rare-across-corpus rank higher. Hits "heir", "heirs", "heir's",
      "intestate heirs", but NOT "co-claimants".

Semantic: "multiple heirs" embeds to a vector near "co-claimants",
          "joint claimants", "siblings of the deceased". Matches without
          word overlap. Costs an embedding step per chunk + ANN index.
```

In the actual implementation (`retrieve.py`):

```python
toks = [w.lower() for w in re.findall(r"[A-Za-z][A-Za-z0-9_]{2,}", question)]
toks = [t for t in toks if t not in STOP]
return " OR ".join(f'"{t}"*' for t in toks[:20])
```

Strips a hardcoded stop-word list, prefix-globs every remaining token
(`heir*` matches `heir`, `heirs`, `heiress`), OR-joins them, sends to
FTS5. FTS5 returns BM25-ranked top-12 chunks scoped to the notebook's
source IDs.

**Why FTS5 over semantic**: zero infra, deterministic, free, fits in
sqlite, good enough on technical/legal text where the salient terms tend
to be specific (statute numbers, mechanism names, person names, verbatim
quotes). Semantic would help on the FCAR business notebooks
("multiple heirs" → "co-claimants") but is overkill on Deep Audit
notebooks where engineers want exact-term matches like
`pub fn ingest_repo`.

Performance: FTS5 over 80 MB corpus → top-12 BM25 in single-digit ms.

## 3. What chunks get used for besides query

```
ingest creates: sources, chunks, chunks_fts
                      │
                      ▼
        ┌─────────────┴─────────────────────────────────┐
        │             │             │                   │
       query     investigate      audio              export
   (1 Claude)  (1+N Claude)  (1 Claude+TTS)      (no Claude)
        │             │             │                   │
   prints + DB   delta MD +    MP3 file +         Obsidian vault MD
   row in        DB row in     vault MD           (sources list +
   queries       queries                           Q&A history)
```

### investigate — gap analysis

Two-pass workflow. Finds mechanisms/patterns in a code corpus that a
human-written audit doc _missed_.

1. Parse a reference markdown file → set of `KNOWN` mechanism names
   (extracted from `## headings`, `**bolded inline**`, table rows).
2. Pass 1: ask Claude to expand the topic into ≤8 specific sub-queries.
3. Pass 2: for each sub-query, FTS5-retrieve top-12 chunks, send to
   Claude with the KNOWN set as exclusion list. Prompt requires
   `{name, file, line, what, why_not_in_known}` JSON.
4. Aggregate, render markdown delta, write to vault as
   `02-delta-<timestamp>.md`.

Token budget capped at 32K output (`MAX_INVESTIGATE_QUERIES=8 × max_tokens=4000`).
Logs estimated cost.

This drove ingesting Hermes / TEMM1E / Pi Agent / NanoClaw / etc. as
Deep Audit notebooks: each one was paired with a written audit doc, and
investigate finds what the human author overlooked.

### audio — research-grounded podcast generator

Retrieves top-12 chunks for a topic. Sends them as
`[Source N: title locator]` excerpts to Claude, asking for a 2-host
podcast script (`HOST_A:` / `HOST_B:` lines), target duration in minutes
(capped at 15). Then:

- Splits script per speaker.
- Renders each line via TTS (`edge-tts` free or `gcloud` paid) using
  two distinct voices.
- `pydub` stitches the WAVs into one MP3 with brief silence between
  turns.
- Output: a single MP3 + the script as markdown in the vault.

### export — Obsidian vault dump

Doesn't touch chunks directly. Reads the _derivatives_ chunks produce:

- `sources` table → `00-sources.md` (linked list of every source URL).
- `queries` table → `01-qa-log.md` (every Q&A with citations as
  Markdown links). Note: investigate runs are logged here too, with
  the question column prefixed `INVESTIGATE: <topic>`.

## 4. The full command map (11 commands)

| Command                                    | Verb                                              | LLM?             | Side effect                |
| ------------------------------------------ | ------------------------------------------------- | ---------------- | -------------------------- |
| `notebook create/list/delete`              | bucket admin                                      | No               | DB write                   |
| `init-fcar`                                | bootstrap the 5 standard notebooks                | No               | DB write (idempotent)      |
| `status`                                   | stats per notebook                                | No               | None                       |
| `search <query>`                           | YouTube search; optional `--add-top N`            | No               | Network, optional DB write |
| `add <urls> --notebook`                    | ingest specific YouTube videos                    | No               | DB write                   |
| `ingest-local <path>`                      | walk + ingest local directory                     | No               | DB write                   |
| `ingest-github <repo>`                     | shallow clone + ingest                            | No               | Disk + DB write            |
| `ingest-url <urls>`                        | HTTP fetch + HTML strip + ingest                  | No               | Cache + DB write           |
| `query <question> --notebook`              | RAG: BM25 retrieve top-12 → Claude with citations | **Yes** (1 call) | Row in `queries`           |
| `investigate --notebook --topic --against` | 1+N Claude pass for gap analysis                  | **Yes** (1 + N)  | Row + optional vault `.md` |
| `audio --notebook --topic --minutes`       | Claude script + TTS render + pydub stitch         | **Yes** + TTS    | MP3 + vault script         |
| `export --notebook --vault`                | Dump notebook to Obsidian markdown                | No               | FS write                   |

## 5. Notebooks in production (snapshot at 2026-05-04)

```
Business notebooks                     sources  chunks  queries
─────────────────────────────────────  ───────  ──────  ───────
FCAR: Ohio Surplus Funds                     3      41        1
FCAR: Probate Law                            0       0        0
FCAR: Medicaid Recovery                      0       0        0
FCAR: AI Agent Operations                    0       0        0
FCAR: Competitor Intelligence                0       0        0

Deep Audit notebooks                   sources  chunks  queries
─────────────────────────────────────  ───────  ──────  ───────
FCAR: Pi Agent Deep Audit                  799    4415        2
FCAR: NanoClaw Deep Audit                  300     788        1
FCAR: Hermes Deep Audit                    300    2857        1
FCAR: Browser Forge Deep Audit             300    2608        1
FCAR: Space Agent Deep Audit               300    1683        1
FCAR: Claw Army Deep Audit                 300    1638        1
FCAR: OpenClaw Deep Audit                  300    1385        1
FCAR: Assay Deep Audit                     300    1460        1
FCAR: TEMM1E Deep Audit                    260    1916        2
FCAR: agency-agents Deep Audit             222    1200        1
FCAR: MemPalace Deep Audit                 195     928        1
FCAR: MemR3 Deep Audit v3                   14      45        1
```

The business notebooks are mostly empty. The Deep Audit notebooks
are actively used by engineering for axiom R&D — comparing each external
project's stated mechanisms against the actual code via `investigate`.

## 6. Where axiom maps to notebooklm

The Rust `axiom-research-substrate` and `axiom-agent-research` crates
are a 1:1 port of the Python tool's library layer.

| Python module                                       | Rust crate                            | Status                                   |
| --------------------------------------------------- | ------------------------------------- | ---------------------------------------- |
| `notebooklm/db.py` (sqlite + FTS5 schema)           | `axiom-research-substrate::schema`    | done                                     |
| `notebooklm/chunker.py` (boundary-aware)            | `axiom-research-substrate::chunker`   | done                                     |
| `notebooklm/retrieve.py` (BM25 retrieval)           | `axiom-research-substrate::retrieve`  | done                                     |
| `notebooklm/ingest/{local,url,github}.py`           | `axiom-research-substrate::ingest::*` | library done; **no `[[bin]]` promotion** |
| `notebooklm/investigate.py` (Claude 1+N)            | `axiom-agent-research::investigate`   | trait stubbed; **no real Provider impl** |
| `notebooklm/audio.py` (Claude + TTS + pydub)        | (not in roadmap)                      | —                                        |
| `notebooklm/youtube.py` (YouTube search/transcript) | (not in roadmap)                      | —                                        |

## 7. Why the port at all (case for axiom)

The Python tool already has discipline: token budgets
(`MAX_INVESTIGATE_TOKENS_OUT = 32_000`), license-aware ingest, dry-run
on every Claude-firing command, full Q&A audit in the `queries` table,
deterministic Obsidian export. So this isn't a "Python is unsafe → Rust
is safer" story. The case is narrower:

1. **External, machine-readable audit trail** — `events.jsonl` is
   portable across consumers (gondor UI, an auditor, a court). Python's
   audit lives in its own sqlite.
2. **Capability declarations** — plan TOML must declare
   `capabilities = ["network.http","fs.write"]`; runtime fails closed on
   unknown caps. Real value when operators (run plans) and engineers
   (write plans) are different humans.
3. **Approval gates** — `[approval]` blocks require an `--approve <id>`
   flag with a manifest-pinned id. Stronger than `--dry-run`.
4. **Determinism for replay** — `axiom inspect` re-validates the ledger
   without re-running. Python doesn't have this.
5. **Subagents + task DAGs** (axiom Phase 4) — for parallel sub-query
   fanout with capability subsetting. Python doesn't compose.

These are runtime-discipline benefits, not business-feature benefits.
**User-visible features are the same**: ingest, query, investigate,
audio.

## 8. When axiom pays off (in order of likelihood)

1. **Multi-tenant deployment.** When more than `info@` runs the tool
   and we need to know _who_ ran what _with what authority_. Python has
   no actor concept; gondor + axiom can attribute every plan run to a
   logged-in operator.
2. **Regulated workflow.** If skip-trace claims need
   court-discoverable receipts (Medicaid claim provenance, e.g.),
   `events.jsonl` is auditor-readable; Python's sqlite is not.
3. **Operator-vs-engineer split.** When operations staff run plans they
   didn't author, and engineering reviews/signs the plan TOMLs. Plan-as-
   code + capability declarations is the contract.

Until one of those is real, **the Python tool is doing the job** and
axiom is a port-in-waiting.

## 9. Integration paths for gondor (decision matrix)

| Path                                        | What it is                                                                                                                                                                  | Cost                                                                                            | Ships when |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ---------- |
| **A — Gondor wraps the Python tool**        | `/research/{ingest,query,investigate,audio}` workflow pages shell out to `python3 /home/info/scripts/notebooklm-engine.py …`. Gondor handles auth + actor + audit-log + UI. | Lowest. No upstream changes. Operations gets a usable web UI on top of the existing tool today. | Now        |
| **B — Gondor wraps Python via axiom plans** | Same UI as A, but each invocation is wrapped in an axiom plan with `capabilities = ["process.exec","network.http","fs.write"]` so events.jsonl logs every call.             | Medium. Two layers of audit (Python sqlite + axiom ledger).                                     | Now        |
| **C — Wait for axiom upstream bins**        | Hold until `axiom-ingest-*` and `axiom-research-search` are real binaries with a release tarball, and `Provider` lands so investigate works.                                | Highest. No interim product.                                                                    | Months     |

**Recommendation**: A first, B optional later. A gets operations a
useful product immediately, gives a real usage signal, and makes a
much stronger case for whether axiom's discipline pays off in practice
once people are actually using it.

## 10. Open questions before any implementation

1. **Audience** — is gondor surfacing this to FCAR's operations team
   (business notebooks; query is the primary verb) or to engineering
   (Deep Audit notebooks; investigate is the primary verb)? Both are
   real but the modal inputs differ.
2. **Notebook UX** — list/create/delete from the web, or treat
   notebooks as CLI-managed and gondor only renders existing ones in a
   dropdown?
3. **Storage location** — does gondor talk to fc-joy's sqlite over SSH,
   ship a copy of the db locally, or run its own ingest pipeline against
   the same sources? Affects whether business + audit notebooks are
   visible to the same operators.
4. **LLM access** — Path A reuses the Python tool's
   `ANTHROPIC_API_KEY`; Path B (when axiom Provider lands) needs the
   key threaded through the gondor process or via a vault secret. Who
   owns the key + budget?
5. **Audio + YouTube** — out of axiom's roadmap. If operations wants
   audio briefs, that workflow stays Python-only forever (or moves to a
   separate gondor-only Python service).

Answers to these gate the design of any concrete `fcar.research-*`
workflow type beyond the smoke-test `fcar.axiom` one already wired up.
