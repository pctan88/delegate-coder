#!/usr/bin/env python3
"""report.py — aggregate delegate-coder benchmark results into a summary table.
Usage: python3 report.py results/ [tasks.json]
"""
import json, sys, glob, os
from collections import defaultdict
from statistics import mean, stdev

def load(results_dir):
    runs = []
    for f in glob.glob(os.path.join(results_dir, "*.json")):
        if f.endswith(".transcript.json"):
            continue
        try:
            with open(f) as fh:
                content = fh.read().strip()
                import json
                decoder = json.JSONDecoder()
                idx = 0
                records = []
                while idx < len(content):
                    content = content[idx:].lstrip()
                    if not content: break
                    try:
                        obj, idx = decoder.raw_decode(content)
                        records.append(obj)
                    except json.JSONDecodeError:
                        break
                
                valid_records = [r for r in records if isinstance(r, dict) and r.get("task")]
                if valid_records:
                    rec = valid_records[-1]
                    # Fix broken num_turns (e.g. streaming anomalies reporting num_turns=1)
                    if rec.get("num_turns") == 1 and len(records) > 1:
                        rec["num_turns"] = len(records)
                    runs.append(rec)
        except Exception as e:
            print(f"warn: skipping {f}: {e}", file=sys.stderr)
    return runs

def categories(tasks_path):
    cat = {}
    if tasks_path and os.path.exists(tasks_path):
        with open(tasks_path) as fh:
            for t in json.load(fh).get("tasks", []):
                cat[t["id"]] = t.get("category", "uncategorized")
    return cat

def agg(runs):
    out = {}
    costs = [r["cost_usd"] for r in runs if r.get("cost_usd") is not None]
    out["n"] = len(runs)
    out["success_rate"] = mean(r["success"] for r in runs) if runs else 0
    out["cost_mean"] = mean(costs) if costs else None
    out["cost_sd"] = stdev(costs) if len(costs) > 1 else 0
    
    # Use the extracted num_turns directly, as it has been corrected in load()
    valid_turns = [r["num_turns"] for r in runs if r.get("num_turns")]
    out["turns_mean"] = mean(valid_turns) if valid_turns else None
    out["anomalies"] = 0  # Anomalies are now handled at load time
    
    out["wall_mean"] = mean(r["wall_seconds"] for r in runs if r.get("wall_seconds") is not None) if runs else None
    out["trigger_rate"] = mean(r.get("skill_triggered", 0) for r in runs) if runs else 0
    return out

def fmt_usd(v): return f"${v:.4f}" if v is not None else "n/a"
def fmt_pct(v): return f"{100*v:.0f}%" if v is not None else "n/a"

def main():
    results_dir = sys.argv[1] if len(sys.argv) > 1 else "results/"
    tasks_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(results_dir.rstrip("/")) or ".", "tasks.json")
    runs = load(results_dir)
    if not runs:
        print("No results found."); return
    cat = categories(tasks_path)

    groups = defaultdict(lambda: {"A": [], "B": []})
    for r in runs:
        key = cat.get(r["task"], "uncategorized")
        groups[key][r["condition"]].append(r)
    groups["OVERALL"] = {"A": [r for r in runs if r["condition"] == "A"],
                         "B": [r for r in runs if r["condition"] == "B"]}

    print(f"\n{'Category':<16}{'n(A/B)':<9}{'Cost A':<11}{'Cost B':<11}{'Savings':<9}"
          f"{'Succ A':<8}{'Succ B':<8}{'Trig B':<8}{'Turns A/B':<12}{'Wall A/B (s)':<14}")
    print("-" * 106)
    total_anomalies = 0
    for key in sorted(groups, key=lambda k: (k == "OVERALL", k)):
        a, b = agg(groups[key]["A"]), agg(groups[key]["B"])
        total_anomalies += a["anomalies"] + b["anomalies"]
        sav = None
        if a["cost_mean"] and b["cost_mean"] is not None:
            sav = (a["cost_mean"] - b["cost_mean"]) / a["cost_mean"]
        turns = f"{a['turns_mean']:.1f}/{b['turns_mean']:.1f}" if a["turns_mean"] is not None and b["turns_mean"] is not None else "n/a"
        wall = f"{a['wall_mean']:.0f}/{b['wall_mean']:.0f}" if a["wall_mean"] is not None and b["wall_mean"] is not None else "n/a"
        print(f"{key:<16}{str(a['n'])+'/'+str(b['n']):<9}{fmt_usd(a['cost_mean']):<11}{fmt_usd(b['cost_mean']):<11}"
              f"{fmt_pct(sav):<9}{fmt_pct(a['success_rate']):<8}{fmt_pct(b['success_rate']):<8}"
              f"{fmt_pct(b['trigger_rate']):<8}{turns:<12}{wall:<14}")

    if total_anomalies > 0:
        print(f"\n[!] Note: Filtered {total_anomalies} runs with num_turns=1 from the 'Turns' average (CLI streaming anomalies).")

    print("\nNotes:")
    print("- 'Savings' = Claude cost reduction in condition B. Worker-agent cost is assumed free tier;")
    print("  if your worker uses a paid API, add its cost manually before claiming net savings.")
    print("- A claim is only valid where 'Succ B' >= 'Succ A'. Cheaper-but-wrong is not savings.")
    print("- 'Trig B' < 100% means the skill sometimes didn't fire; those runs dilute condition B.")
    print("- With reps < 3 treat every number as anecdote, not evidence.")

if __name__ == "__main__":
    main()
