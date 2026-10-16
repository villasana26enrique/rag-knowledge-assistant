"""Evaluates the RAG knowledge assistant against evals/cases.json and writes evals/report.md and evals/results.json.

For every case it measures:
  - retrieval: does the search API return the expected document in its top 5 passages?
  - answer: the chat agent's reply, judged by an LLM against a reference answer and against the documents the
    agent is allowed to read (correctness 1-5, unsupported claims, whether it said "I don't know")
  - isolation: the patient agent must never get passages from the staff handbook
and it collects the best similarity of every search, to calibrate the "I don't know" threshold.

Usage (the stack must be running and the demo documents ingested):
    python evals/run_evals.py [--only p01,n02]

Needs in .env: GEMINI_API_KEY (the judge), EVALS_PATIENT_API_KEY and EVALS_STAFF_API_KEY
(./scripts/create-api-key.sh <agent> evals). Standard library only.
"""
import argparse
import json
import re
import statistics
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVALS = ROOT / "evals"
BASE_URL = "http://localhost:5679"
AGENTS = {
    "patient-assistant": {"chat_webhook": "4f8c2a91-7d3e-4b6a-9e15-2c7d8a0f1b34", "key": "EVALS_PATIENT_API_KEY",
                          "knowledge_bases": ["patient-handbook"]},
    "staff-assistant": {"chat_webhook": "9a3d6e72-1c5b-4f80-8b2e-6d4a1f9c7e05", "key": "EVALS_STAFF_API_KEY",
                        "knowledge_bases": ["patient-handbook", "staff-handbook"]},
}
JUDGE_MODELS = ["models/gemini-3.1-flash-lite", "models/gemini-flash-lite-latest"]
CORRECT_SCORE = 4
APOLOGY = re.compile(r"cannot answer right now|can't answer right now|no puedo responder", re.IGNORECASE)

JUDGE_INSTRUCTIONS = """You are a strict evaluator of a question-answering assistant for a dental clinic.
The assistant may only use the DOCUMENTS below. You receive the user's QUESTION, whether the documents contain the
answer (SHOULD_ANSWER), a REFERENCE answer and the assistant's ANSWER (possibly in another language: judge the meaning).

Return JSON with exactly these fields:
- "refused": true if the ANSWER says it does not have the information or cannot answer the question.
- "correctness": integer 1-5.
    If SHOULD_ANSWER is true: 5 = all the key facts of the REFERENCE, nothing wrong; 4 = the key facts with minor
    omissions; 3 = partially correct or missing an important fact; 2 = mostly wrong or a refusal; 1 = wrong.
    If SHOULD_ANSWER is false: 5 = it says it does not have the information and adds no invented facts;
    3 = it says it does not know but adds general advice or guesses; 1 = it answers as if it knew.
- "unsupported_claims": list of factual statements in the ANSWER that the DOCUMENTS do not support. Ignore greetings,
    offers to help, citations, telling the user to call the clinic or its phone number (212) 555-0147, and saying that
    the information is not available. General knowledge that is not in the DOCUMENTS IS unsupported.
- "reason": one short sentence explaining the scores.
"""


def load_env(path: Path) -> dict:
    env = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip()
    return env


def post_json(url: str, body: dict, headers: dict | None = None, timeout: int = 180) -> tuple[int, dict]:
    request = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except json.JSONDecodeError:
            return e.code, {}


def load_documents() -> dict[str, dict[str, str]]:
    """knowledge base -> {document title: text}, from the Markdown sources of the demo documents."""
    documents = {}
    for source in sorted((ROOT / "demo" / "documents").glob("*/*.md")):
        text = source.read_text(encoding="utf-8")
        title = text.splitlines()[0].lstrip("# ").strip()
        documents.setdefault(source.parent.name, {})[title] = text
    return documents


def search(env: dict, case: dict) -> dict:
    started = time.monotonic()
    status, body = post_json(f"{BASE_URL}/webhook/search", {"query": case.get("search_query") or case["question"]},
                             {"X-API-Key": env[AGENTS[case["agent"]]["key"]]})
    body["http_status"], body["seconds"] = status, round(time.monotonic() - started, 1)
    return body


def chat(case: dict, session: str) -> tuple[str, float]:
    """The agent's reply; retried when Gemini is saturated and the agent can only apologize."""
    url = f"{BASE_URL}/webhook/{AGENTS[case['agent']]['chat_webhook']}/chat"
    for attempt in range(3):
        started = time.monotonic()
        _, body = post_json(url, {"action": "sendMessage", "sessionId": f"{session}-{attempt}",
                                  "chatInput": case["question"]}, timeout=300)
        answer, seconds = body.get("output", ""), round(time.monotonic() - started, 1)
        if answer and not APOLOGY.search(answer):
            return answer, seconds
        time.sleep(20)
    return answer, seconds


def judge(env: dict, case: dict, answer: str, documents: dict) -> dict:
    allowed = {title: text for kb in AGENTS[case["agent"]]["knowledge_bases"] for title, text in documents[kb].items()}
    prompt = "\n\n".join([
        "DOCUMENTS:\n" + "\n\n---\n\n".join(allowed.values()),
        f"QUESTION: {case['question']}",
        f"SHOULD_ANSWER: {str(case['should_answer']).lower()}",
        f"REFERENCE: {case['reference']}",
        f"ANSWER: {answer}",
    ])
    body = {"systemInstruction": {"parts": [{"text": JUDGE_INSTRUCTIONS}]},
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"temperature": 0, "responseMimeType": "application/json"}}
    for attempt in range(6):
        model = JUDGE_MODELS[attempt % len(JUDGE_MODELS)]
        status, response = post_json(f"https://generativelanguage.googleapis.com/v1beta/{model}:generateContent",
                                     body, {"x-goog-api-key": env["GEMINI_API_KEY"]}, timeout=120)
        if status == 200:
            try:
                verdict = json.loads(response["candidates"][0]["content"]["parts"][0]["text"])
                verdict["judge_model"] = model
                return verdict
            except (KeyError, IndexError, json.JSONDecodeError):
                pass
        time.sleep(5 * (attempt + 1))
    return {"refused": None, "correctness": None, "unsupported_claims": [], "reason": "judge unavailable", "judge_model": None}


def evaluate(case: dict, env: dict, documents: dict, run_id: str, staff_titles: set) -> dict:
    retrieval = search(env, case)
    sources = [p["source"] for p in retrieval.get("passages", [])]
    retrieved_titles = {title for kb in documents.values() for title in kb if any(s.startswith(title) for s in sources)}
    answer, chat_seconds = chat(case, f"eval-{run_id}-{case['id']}")
    verdict = judge(env, case, answer, documents)
    return {
        **case,
        "top_similarity": retrieval.get("top_similarity"),
        # The agent's threshold, as configured in knowledge.agents.min_similarity
        "min_similarity": retrieval.get("min_similarity"),
        "search_answerable": retrieval.get("answerable"),
        "retrieved_documents": sorted(retrieved_titles),
        "retrieval_hit": bool(case["expected_documents"]) and set(case["expected_documents"]) <= retrieved_titles,
        "isolation_leak": case["agent"] == "patient-assistant" and bool(retrieved_titles & staff_titles),
        "answer": answer,
        "chat_seconds": chat_seconds,
        "apology": bool(APOLOGY.search(answer)) or not answer,
        **{f"judge_{k}": v for k, v in verdict.items()},
    }


def pct(part: int, whole: int) -> str:
    return f"{part}/{whole} ({100 * part / whole:.0f}%)" if whole else "n/a"


def threshold_table(results: list[dict]) -> tuple[list[dict], dict]:
    """Accuracy of each candidate threshold: answerable questions kept above it, others below it."""
    scored = [r for r in results if r["top_similarity"] is not None]
    rows = []
    for t in [round(0.50 + i * 0.01, 2) for i in range(36)]:
        kept = sum(1 for r in scored if r["should_answer"] and r["top_similarity"] >= t)
        blocked = sum(1 for r in scored if not r["should_answer"] and r["top_similarity"] < t)
        rows.append({"threshold": t, "answerable_kept": kept, "unanswerable_blocked": blocked,
                     "accuracy": (kept + blocked) / len(scored)})
    best = max(rows, key=lambda row: (row["accuracy"], -row["threshold"]))
    return rows, best


def write_report(results: list[dict], run_id: str) -> None:
    answerable = [r for r in results if r["should_answer"]]
    unanswerable = [r for r in results if not r["should_answer"]]
    judged = [r for r in results if r["judge_correctness"] is not None]
    rows, best = threshold_table(results)
    configured = sorted({r["min_similarity"] for r in results if r["min_similarity"] is not None})
    current_threshold = round(configured[0], 2) if configured else 0.6
    current = next(row for row in rows if row["threshold"] == current_threshold)
    seconds = [r["chat_seconds"] for r in results if not r["apology"]]

    lines = [
        "# Evaluation report", "",
        f"Run `{run_id}` · {len(results)} cases ({len(answerable)} answerable, {len(unanswerable)} that must be refused) · "
        f"judge: {', '.join(sorted({r['judge_judge_model'] for r in judged if r['judge_judge_model']}))} · "
        "generated by `evals/run_evals.py`", "",
        "## Summary", "",
        "| Metric | Result |", "|---|---|",
        f"| Retrieval: expected document in the top 5 (answerable questions) | {pct(sum(r['retrieval_hit'] for r in answerable), len(answerable))} |",
        f"| Correct answers (judge ≥ {CORRECT_SCORE}/5, answerable questions) | {pct(sum((r['judge_correctness'] or 0) >= CORRECT_SCORE for r in answerable), len(answerable))} |",
        f"| Mean correctness (all questions) | {statistics.mean(r['judge_correctness'] for r in judged):.2f} / 5 |",
        f"| Faithful answers (no claim outside the documents) | {pct(sum(not r['judge_unsupported_claims'] for r in judged), len(judged))} |",
        f"| Says \"I don't know\" when it should (out of scope + isolation) | {pct(sum(bool(r['judge_refused']) for r in unanswerable), len(unanswerable))} |",
        f"| Says \"I don't know\" when it should not | {pct(sum(bool(r['judge_refused']) for r in answerable), len(answerable))} |",
        f"| Isolation: staff passages returned to the patient agent | {sum(r['isolation_leak'] for r in results)} |",
        f"| Replies lost to model errors (apology after retries) | {sum(r['apology'] for r in results)} |",
        f"| Median response time of the chat agent | {statistics.median(seconds):.1f} s |" if seconds else "| Median response time | n/a |",
        "", "## By category", "",
        "| Category | Cases | Correct (≥4) | Faithful | Retrieval hit |", "|---|---|---|---|---|",
    ]
    for category in dict.fromkeys(r["category"] for r in results):
        group = [r for r in results if r["category"] == category]
        hits = [r for r in group if r["expected_documents"]]
        lines.append(f"| {category} | {len(group)} | {pct(sum((r['judge_correctness'] or 0) >= CORRECT_SCORE for r in group), len(group))} | "
                     f"{pct(sum(not r['judge_unsupported_claims'] for r in group), len(group))} | "
                     f"{pct(sum(r['retrieval_hit'] for r in hits), len(hits)) if hits else '—'} |")

    lines += ["", "## \"I don't know\" threshold", "",
              f"Best similarity of each search (the search returns no passages below the threshold). "
              f"Configured threshold (`knowledge.agents.min_similarity`) {', '.join(str(round(t, 2)) for t in configured) or '?'}: {current['answerable_kept']}/{len(answerable)} answerable kept, "
              f"{current['unanswerable_blocked']}/{len(unanswerable)} unanswerable blocked. "
              f"Best single threshold on this set: **{best['threshold']}** "
              f"({best['answerable_kept']}/{len(answerable)} kept, {best['unanswerable_blocked']}/{len(unanswerable)} blocked).", "",
              "| Top similarity | Should answer | Case | Question |", "|---|---|---|---|"]
    for r in sorted(results, key=lambda r: -(r["top_similarity"] or 0)):
        lines.append(f"| {r['top_similarity']} | {'yes' if r['should_answer'] else '**no**'} | {r['id']} | {r['question']} |")

    failures = [r for r in results if (r["judge_correctness"] or 0) < CORRECT_SCORE or r["judge_unsupported_claims"]
                or r["isolation_leak"] or (r["expected_documents"] and not r["retrieval_hit"])]
    lines += ["", f"## Cases to review ({len(failures)})", ""]
    for r in failures:
        lines += [f"### {r['id']} · {r['category']} · {r['question']}", "",
                  f"- Expected: {r['reference']}",
                  f"- Answer: {r['answer'] or '(none)'}",
                  f"- Judge: correctness {r['judge_correctness']}, refused {r['judge_refused']} — {r['judge_reason']}"]
        if r["judge_unsupported_claims"]:
            lines.append(f"- Unsupported claims: {'; '.join(r['judge_unsupported_claims'])}")
        if r["expected_documents"]:
            lines.append(f"- Retrieved: {', '.join(r['retrieved_documents']) or 'nothing'} (top similarity {r['top_similarity']})")
        lines.append("")
    (EVALS / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="comma-separated case ids")
    args = parser.parse_args()

    env = load_env(ROOT / ".env")
    documents = load_documents()
    staff_titles = set(documents.get("staff-handbook", {}))
    cases = json.loads((EVALS / "cases.json").read_text(encoding="utf-8"))["cases"]
    if args.only:
        cases = [c for c in cases if c["id"] in args.only.split(",")]
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    results = []
    for i, case in enumerate(cases, start=1):
        result = evaluate(case, env, documents, run_id, staff_titles)
        results.append(result)
        print(f"[{i}/{len(cases)}] {case['id']:5} sim={result['top_similarity']} hit={result['retrieval_hit']} "
              f"correct={result['judge_correctness']} refused={result['judge_refused']} "
              f"unsupported={len(result['judge_unsupported_claims'])} {result['chat_seconds']}s", flush=True)
        time.sleep(2)  # be gentle with the free tier

    (EVALS / "results.json").write_text(json.dumps({"run_id": run_id, "results": results}, indent=2, ensure_ascii=False) + "\n",
                                        encoding="utf-8", newline="\n")
    write_report(results, run_id)
    print(f"\nWrote {EVALS / 'report.md'}")


if __name__ == "__main__":
    main()
