# task_eval — 3-step trajectory rubric judge

Pipeline that evaluates GUI/web agent **trajectories** with a vision-language judge.  
Default entry point: **`main_eval.py`** (local vLLM + **Qwen3-VL**).

## Pipeline (3 steps)

| Step | Module | Input | Role |
|------|--------|-------|------|
| **1** | `step1_eval.py` | Screenshot chunks | Extract **observed evidence only** (`screenshot_ocr`, `visual_elements`, …) |
| **2** | `step2_eval.py` | Step 1 + `final_answer` | Map and review **claims** in the final answer vs evidence (text only, no images) |
| **3** | `step3_eval.py` | Steps 1–2 + task metadata | **Global rubric** judgement (`answer_success`, per-dimension pass/fail, …) |

Steps 2 and 3 are text-only API calls. On vLLM, VL models can return empty JSON for multimodal payloads with no images; `main_eval.py` sends user content as a **plain string** when there are no images.

## Layout

```
task_eval/
  main_eval.py          # Qwen / local vLLM (default)
  main_eval_gpt.py      # OpenAI GPT judge
  main_eval_gemini.py   # Google Gemini judge
  main_eval_internvl.py # InternVL on local vLLM
  step1_eval.py
  step2_eval.py
  step3_eval.py
  html_statistic.py     # batch HTML reports and aggregates
  run.sh                # example batch run
  legacy/               # older batch scripts and utilities
```

## Prerequisites

- Python 3.10+ (`openai`, `tqdm`, … — project venv recommended)
- **Qwen judge (`main_eval.py`)**: OpenAI-compatible **vLLM** server must be running  
  - Default API: `http://127.0.0.1:8005/v1`  
  - Default model: `Qwen/Qwen3-VL-235B-A22B-Instruct-FP8`
- Other judges use the matching `main_eval_*.py` script plus the right API key and endpoint (see below)

Environment variables (Qwen):

| Variable | Description |
|----------|-------------|
| `QWEN_PORT` | vLLM port (default `8005`) |
| `QWEN_API_BASE` | Override API base URL |
| `QWEN_MODEL` | Override model ID |
| `QWEN_API_KEY` | For local vLLM (defaults to `dummy` if unset) |

## Input (per episode / `--run-dir`)

Each episode directory is expected to contain:

| Path | Required | Description |
|------|----------|-------------|
| `trajectory.json` | yes | Steps, screenshots, actions |
| `images/*.png` (or jpg) | yes | Screenshots referenced by the trajectory |
| `metadata.json` | optional | e.g. `start_url` |
| `user_message/user_message_001.txt` | optional | Auxiliary instruction text |

**`final_answer`** resolution order:

1. `--final-answer`
2. `--final-answer-file`
3. `final_answer.txt` / `answer.txt` / `assistant_final_answer.txt` in the run dir
4. Last `send_msg_to_user` message in the trajectory (`[ANSWER]` prefix stripped)

**Batch** (`--tasks-json` + `--results-root`): match each task `id` to `results_root/<id>/`.  
JSON format: array of `{id, prompt, start_url, …}`, or a bundle `{ "tasks": [...], "meta": ... }`.

Default tasks JSON (in code): `../task_gen/outputs/final/possible_translate_ko_metadata.json`

## Usage

Run from the `task_eval` directory when possible.

```bash
cd task_eval
source .venv/bin/activate   # optional
```

### Single episode

```bash
python3 main_eval.py \
  --run-dir /path/to/results/<episode_id> \
  --tasks-json /path/to/tasks.json \
  --final-answer-file /path/to/final_answer.txt \
  --constraints "optional constraint text" \
  --out ./output/<episode_id>.json
```

If a cache file exists in the run dir, it is loaded without calling the judge again (use `--force` to ignore).

### Batch

```bash
python3 main_eval.py \
  --tasks-json /path/to/tasks.json \
  --results-root /path/to/agent_results \
  --workers 8 \
  --llm-max-inflight 12 \
  --max-images 0 \
  --image-chunk-size 8 \
  --port 8005
```

Single episode filter:

```bash
python3 main_eval.py \
  --tasks-json /path/to/tasks.json \
  --results-root /path/to/agent_results \
  --episode-id <episode_id>
```

`run.sh` uses relative paths (`./task/...`, `./results`). Adjust paths for your environment.

## Cache & reports

- Per-episode cache: `<run_dir>/<cache-filename>` (default `two_pass_judge.json`)
- On rerun, cache hit skips judge LLM calls (`meta.cache_hit`)
- Force re-evaluation: `--force`
- After batch: HTML at `results_root/<report-filename>` (default `!__two_pass_verdicts.html`)
- Per–task-type HTML may also be written under `results_root` via `html_statistic.py`

## Important CLI flags

| Flag | Default | Description |
|------|---------|-------------|
| `--max-images` | `16` | Cap screenshots for Steps 1–2; `≤0` = all images in the trajectory |
| `--image-chunk-size` | `8` | Screenshots per Step 1 call (`0` = all at once) |
| `--step1-chunk-workers` | `2` | Parallel Step 1 chunks within an episode |
| `--llm-max-inflight` | `12` | Max concurrent LLM HTTP requests (keep ≤ vLLM `max-num-seqs`) |
| `--max-output-tokens` | `16000` | Response token cap (`0` = unlimited) |
| `--request-timeout` | `180` | Per-request timeout (seconds) |
| `--llm-retries` | `2` | Retries on timeout / 5xx / empty response / JSON parse failure |
| `--step1-retry-on-empty` | off | Re-run Step 1 once if OCR is empty |
| `--step2-retry-on-empty` | off | Re-run Step 2 once if claims and reviews are both empty |
| `--print-llm-raw` | off | Print request/response for debugging |

## Output JSON (single episode)

```json
{
  "meta": { "...": "model, paths, counts, cache_hit, metric notes ..." },
  "step1_window_evidence": { "screenshot_ocr": [], "visual_elements": [] },
  "step2_claim_evidence": { "final_answer_claims": [], "evidence_check_reviews": [] },
  "step3_final_judgement": { "answer_success": true, "dimensions": {}, "...": "..." },
  "derived_metrics": { "tsr": true, "egsr": true, "etsr": false, "sr_rate": 0.85 }
}
```

**Batch** output adds a top-level `meta` (aggregates, `tsr_rate`, `egsr_rate`, …) and an `episodes` array.

### Metrics (summary)

- **TSR**: `answer_success` (Step 3)
- **EGSR**: `answer_success` ∧ `metadata_requirement_verified`
- **ETSR**: EGSR ∧ `key_claims_all_supported`
- **SR**: Fraction of trajectory steps in the longest error-free prefix
- **DDR / ASS**: Dead-end and successful-trajectory step stats in batch `meta`

Rubrics merge a **common three dimensions** with task-type profiles (`semantic_grounding`, `contextual_inference`, `visual_grounding`, …) for Step 3 scoring (`_RUBRIC_DIMENSIONS` in `main_eval.py`).

## Other judge entrypoints

Same pipeline; different judge model and API:

| Script | Backend | API key env |
|--------|---------|-------------|
| `main_eval_gpt.py` | OpenAI | `OPENAI_API_KEY` |
| `main_eval_gemini.py` | Gemini (OpenAI-compatible) | `GEMINI_API_KEY` / `GOOGLE_API_KEY` |
| `main_eval_internvl.py` | local vLLM | `INTERNVL_API_KEY` (or `dummy`) |

Batch examples for GPT/Gemini: `legacy/run_eval_300_gpt.sh`, `legacy/run_eval_300_gemini.sh`.  
Set API keys **only via environment variables** — do not put them in the README, logs, or commits.

## Notes

- The old name `two_pass_judge.py` is now **`main_eval.py`**.
- Scripts under `legacy/` may hard-code absolute paths or internal batch names; use **placeholder paths** in shared docs.
- Outputs and HTML may include trajectory text; check for sensitive URLs, accounts, or PII before sharing externally.
