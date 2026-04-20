#!/usr/bin/env python3
"""Phase 1 ベンチマーク結果を統計分析する。

入力: /fsx/logs/phase1/results/{A,B,C}_{sharegpt,prefix_repetition,random}_s{1,2,3}.json
出力: 系列 × workload の TTFT/ITL/E2E P50/P99、Welch's t-test、bootstrap 95% CI
"""

import json
import math
import statistics
from pathlib import Path
from itertools import combinations

RESULT_DIR = Path("/fsx/logs/phase1/results")
SERIES = ["A", "B", "C"]
WORKLOADS = ["sharegpt", "prefix_repetition", "random"]
SEEDS = [1, 2, 3]


def load(series: str, workload: str, seed: int) -> dict | None:
    path = RESULT_DIR / f"{series}_{workload}_s{seed}.json"
    if not path.exists():
        return None
    with path.open() as f:
        return json.load(f)


def bootstrap_ci(values: list[float], stat=statistics.mean, n_boot: int = 2000, alpha: float = 0.05):
    import random
    if not values:
        return (float("nan"), float("nan"))
    boots = []
    n = len(values)
    rng = random.Random(42)
    for _ in range(n_boot):
        sample = [values[rng.randrange(n)] for _ in range(n)]
        boots.append(stat(sample))
    boots.sort()
    lo = boots[int(n_boot * alpha / 2)]
    hi = boots[int(n_boot * (1 - alpha / 2))]
    return (lo, hi)


def welch_t(a: list[float], b: list[float]) -> tuple[float, float]:
    if len(a) < 2 or len(b) < 2:
        return (float("nan"), float("nan"))
    ma, mb = statistics.mean(a), statistics.mean(b)
    va, vb = statistics.variance(a), statistics.variance(b)
    na, nb = len(a), len(b)
    se = math.sqrt(va / na + vb / nb)
    if se == 0:
        return (float("inf") if ma != mb else 0.0, 0.0)
    t = (ma - mb) / se
    # Welch-Satterthwaite df
    num = (va / na + vb / nb) ** 2
    den = (va ** 2) / (na ** 2 * (na - 1)) + (vb ** 2) / (nb ** 2 * (nb - 1))
    df = num / den if den else (na + nb - 2)
    # normal approximation for p-value (small n=3 なので参考値)
    # 正確な p 値は scipy 必要。代わりに |t| を報告
    return (t, df)


def summarize():
    rows = []
    for series in SERIES:
        for workload in WORKLOADS:
            for metric_key, metric_name in [
                ("mean_ttft_ms", "TTFT mean"),
                ("median_ttft_ms", "TTFT P50"),
                ("p99_ttft_ms", "TTFT P99"),
                ("mean_itl_ms", "ITL mean"),
                ("median_itl_ms", "ITL P50"),
                ("p99_itl_ms", "ITL P99"),
                ("mean_e2el_ms", "E2E mean"),
                ("p99_e2el_ms", "E2E P99"),
                ("request_throughput", "Throughput req/s"),
                ("output_throughput", "Throughput tok/s"),
            ]:
                vals = []
                for seed in SEEDS:
                    data = load(series, workload, seed)
                    if data and metric_key in data:
                        vals.append(data[metric_key])
                if not vals:
                    continue
                mean = statistics.mean(vals)
                stdev = statistics.stdev(vals) if len(vals) > 1 else 0.0
                ci_lo, ci_hi = bootstrap_ci(vals)
                rows.append({
                    "series": series,
                    "workload": workload,
                    "metric": metric_name,
                    "n": len(vals),
                    "mean": mean,
                    "stdev": stdev,
                    "ci95_lo": ci_lo,
                    "ci95_hi": ci_hi,
                    "values": vals,
                })
    return rows


def print_table(rows):
    # series × workload × metric の簡潔テーブル
    print("\n" + "=" * 110)
    print("Phase 1 Summary Statistics (n=3 seeds each)")
    print("=" * 110)
    print(f"{'Series':<6} {'Workload':<20} {'Metric':<22} {'Mean':>10} {'StDev':>8} {'CI95 Lo':>10} {'CI95 Hi':>10}")
    print("-" * 110)
    current = None
    for r in rows:
        key = (r["series"], r["workload"])
        if key != current:
            if current is not None:
                print()
            current = key
        print(f"{r['series']:<6} {r['workload']:<20} {r['metric']:<22} "
              f"{r['mean']:>10.2f} {r['stdev']:>8.2f} {r['ci95_lo']:>10.2f} {r['ci95_hi']:>10.2f}")


def compare_series(rows):
    # 各 (workload, metric) で A vs B, A vs C, B vs C の Welch t を計算
    print("\n" + "=" * 110)
    print("Welch's t-test (pairwise series comparison, df by Welch-Satterthwaite)")
    print("=" * 110)
    print(f"{'Workload':<20} {'Metric':<22} {'Pair':<8} {'Δmean':>10} {'t':>8} {'df':>6}")
    print("-" * 110)

    by_key = {}
    for r in rows:
        by_key.setdefault((r["workload"], r["metric"]), {})[r["series"]] = r["values"]

    for (workload, metric), series_vals in sorted(by_key.items()):
        for s1, s2 in combinations(SERIES, 2):
            a = series_vals.get(s1)
            b = series_vals.get(s2)
            if not a or not b:
                continue
            t, df = welch_t(a, b)
            diff = statistics.mean(a) - statistics.mean(b)
            print(f"{workload:<20} {metric:<22} {s1}vs{s2:<4} {diff:>10.2f} {t:>8.2f} {df:>6.1f}")


def key_findings(rows):
    print("\n" + "=" * 110)
    print("Key Findings (TTFT P50 / ITL P50 / Throughput)")
    print("=" * 110)
    by_key = {}
    for r in rows:
        by_key.setdefault((r["workload"], r["metric"]), {})[r["series"]] = r["mean"]
    for workload in WORKLOADS:
        print(f"\n[{workload}]")
        for metric in ["TTFT P50", "ITL P50", "Throughput tok/s"]:
            values = by_key.get((workload, metric), {})
            if not values:
                continue
            best = min(values, key=values.get) if "Throughput" not in metric else max(values, key=values.get)
            parts = [f"{s}={values[s]:.1f}" for s in SERIES if s in values]
            print(f"  {metric:<20}: {' | '.join(parts)}  -> best={best}")


if __name__ == "__main__":
    rows = summarize()
    if not rows:
        print("No results found in", RESULT_DIR)
        raise SystemExit(1)
    print_table(rows)
    compare_series(rows)
    key_findings(rows)
