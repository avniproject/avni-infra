#!/usr/bin/env python3
"""Check OPENTOFU_LOADTEST_ENV_PLAN.md against its GitHub issues and its upstream.

Three classes of drift, each of which has actually occurred:

  1. Task-ID drift      — a task added to the plan but not the issue, or vice versa.
  2. Superseded strings — a figure or decision that was revised, but survives somewhere.
  3. Missing facts      — a current decision that never reached the issue that owns it.

Plus a reminder when the upstream harness plan has moved since the plan header's
reconciliation point.

Usage:  python3 provision/scripts/check_plan_sync.py [--perf-repo ../avni-perf]
Needs:  gh, authenticated.  Exit code 1 if anything is out of sync.
"""
import argparse, re, subprocess, sys, pathlib

REPO = "avniproject/avni-infra"
PLAN = pathlib.Path(__file__).resolve().parents[1] / "OPENTOFU_LOADTEST_ENV_PLAN.md"

# issue -> plan phase whose task IDs it must mirror
PHASES = {104: "1", 105: "2", 106: "3", 109: "4", 110: "5", 111: "6", 108: "9"}

# Phase 0's tasks are unnumbered bullets in #103; compare counts instead.
UNNUMBERED = {103: "0"}

# Decisions that were revised. If these reappear, something stale survived an edit.
SUPERSEDED = {
    104: ["150–200 GiB", "300–350 GiB", "300 GiB to match production",
          "time all three candidates", "two copies plus load headroom"],
    105: ["300 GiB to match production", "below 400 GiB to hold", "enable_etl` (default off"],
    109: ["all three candidates"],
}

# Current decisions that must be present in the issue that owns them.
CURRENT = {
    104: ["~250 GiB", "20–399 GiB", "70 GB", "1.10", "by timing"],
    105: ["~250 GiB", "default on", "16.8", "single-AZ", "max_allocated_storage",
          "run-artefacts", "FreeStorageSpace"],
    106: ["3.4", "enable_cognito"],
    108: ["instance ID", "java_apt_package", "max-active"],
    109: ["Time both", "FILE_COPY"],
    110: ["B2"],
    111: ["OIDC", "aws_setup.sh"],
}


def body(num):
    r = subprocess.run(["gh", "issue", "view", str(num), "--repo", REPO,
                        "--json", "body", "-q", ".body"],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"gh failed for #{num}: {r.stderr.strip()}")
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--perf-repo", default="../avni-perf")
    args = ap.parse_args()

    plan = PLAN.read_text()
    bodies = {n: body(n) for n in sorted(set(PHASES) | set(UNNUMBERED) | set(CURRENT))}
    ok = True

    print("task-ID parity")
    for iss, ph in PHASES.items():
        want = set(re.findall(r"\*\*(" + ph + r"\.\d+)\*\*", plan))
        got = set(re.findall(r"\*\*(" + ph + r"\.\d+)\*\*", bodies[iss]))
        good = want == got
        ok &= good
        note = "" if good else "  diff=" + str(sorted(want ^ got))
        print(f"  #{iss} phase {ph}: {len(want)} tasks {'ok' if good else 'DRIFT'}{note}")
    for iss, ph in UNNUMBERED.items():
        want = len(re.findall(r"\*\*" + ph + r"\.[1-9]\*\*", plan))
        got = len([l for l in bodies[iss].splitlines() if l.startswith("- [ ]")])
        good = want == got
        ok &= good
        print(f"  #{iss} phase {ph}: {want} plan / {got} issue bullets {'ok' if good else 'DRIFT'}")

    print("\nsuperseded strings absent")
    for iss, needles in SUPERSEDED.items():
        found = [n for n in needles if n in bodies[iss]]
        ok &= not found
        print(f"  #{iss}: {'ok' if not found else 'STALE ' + str(found)}")
    stale_plan = [n for ns in SUPERSEDED.values() for n in ns if n in plan]
    ok &= not stale_plan
    print(f"  plan: {'ok' if not stale_plan else 'STALE ' + str(stale_plan)}")

    print("\ncurrent facts present")
    for iss, needles in CURRENT.items():
        missing = [n for n in needles if n not in bodies[iss]]
        ok &= not missing
        print(f"  #{iss}: {'ok' if not missing else 'MISSING ' + str(missing)}")

    print("\nupstream")
    m = re.search(r"sync-simulation-plan\.md` @ `([0-9a-f]{7,40})`", plan)
    if not m:
        print("  no reconciliation point in the plan header"); ok = False
    else:
        sha = m.group(1)
        r = subprocess.run(["git", "-C", args.perf_repo, "log", "--oneline",
                            f"{sha}..HEAD", "--", "docs/sync-simulation-plan.md"],
                           capture_output=True, text=True)
        if r.returncode:
            print(f"  could not read {args.perf_repo} (pass --perf-repo): {r.stderr.strip()}")
        elif r.stdout.strip():
            n = len(r.stdout.strip().splitlines())
            print(f"  {n} upstream commit(s) since {sha} — reconcile and update the header:")
            for line in r.stdout.strip().splitlines():
                print(f"    {line}")
            ok = False
        else:
            print(f"  up to date with {sha}")

    print("\n" + ("IN SYNC" if ok else "OUT OF SYNC"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
