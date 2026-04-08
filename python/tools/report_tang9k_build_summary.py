#!/usr/bin/env python3
"""Generate a concise Tang9K build summary from nextpnr logs.

Writes:
- <out_dir>/compile_summary_latest.md
- <out_dir>/compile_summary_<UTC_TIMESTAMP>.md

Also updates docs/TIMING_REPORT.md with an auto-generated compile section.
"""

from __future__ import annotations

import datetime as _dt
import os
import pathlib
import re
import subprocess
import sys


AUTO_START = "<!-- AUTO_COMPILE_SUMMARY_START -->"
AUTO_END = "<!-- AUTO_COMPILE_SUMMARY_END -->"


def _parse_resource_usage(text: str) -> dict[str, tuple[str, str, str]]:
    m = re.search(
        r"Info:\s*Device utilisation:\n(?P<body>.*?)(?:\n\s*Info:\s*Running custom HCLK placer)",
        text,
        flags=re.S,
    )
    if not m:
        return {}

    usage: dict[str, tuple[str, str, str]] = {}
    line_re = re.compile(r"Info:\s*([A-Za-z0-9_]+):\s*([0-9]+)/\s*([0-9]+)\s*([0-9]+)%")

    for line in m.group("body").splitlines():
        lm = line_re.search(line)
        if not lm:
            continue
        name = lm.group(1)
        used, avail, pct = lm.group(2), lm.group(3), lm.group(4)
        usage[name] = (used, avail, pct)

    return usage


def _safe_cmd(args: list[str], cwd: pathlib.Path) -> str:
    try:
        out = subprocess.check_output(args, cwd=str(cwd), stderr=subprocess.DEVNULL)
        return out.decode("utf-8", errors="replace").strip()
    except Exception:
        return "unknown"


def _parse_fmax(text: str) -> tuple[tuple[str, str] | None, tuple[str, str] | None]:
    matches = re.findall(
        r"Info:\s*Max frequency for clock 'sys_clk':\s*([0-9.]+) MHz \(PASS at ([0-9.]+) MHz\)",
        text,
    )
    if not matches:
        return None, None
    return matches[0], matches[-1]


def _parse_critical_path(text: str) -> tuple[str, str, str, str]:
    crit_idx = text.find("Critical path report for clock 'sys_clk'")
    if crit_idx < 0:
        return ("TBD", "TBD", "TBD", "TBD")

    tail = text[crit_idx:]

    src_m = re.search(r"Source\s+(.+)", tail)
    sink_m = re.search(r"Sink\s+(.+)", tail)
    lr_m = re.search(r"Info:\s*([0-9.]+) ns logic,\s*([0-9.]+) ns routing", tail)

    src = src_m.group(1).strip() if src_m else "TBD"
    sink = sink_m.group(1).strip() if sink_m else "TBD"
    logic_ns = lr_m.group(1) if lr_m else "TBD"
    routing_ns = lr_m.group(2) if lr_m else "TBD"

    return src, sink, logic_ns, routing_ns


def _fmt_resource_row(name: str, usage: dict[str, tuple[str, str, str]]) -> str:
    if name not in usage:
        return f"| {name} | TBD | TBD |"
    used, avail, pct = usage[name]
    return f"| {name} | {used} / {avail} | {pct}% |"


def _build_auto_section(
    *,
    timestamp: str,
    log_path: pathlib.Path,
    target: str,
    post_fmax: str,
    margin: str,
    initial_fmax: str,
    usage: dict[str, tuple[str, str, str]],
    src: str,
    sink: str,
    logic_ns: str,
    routing_ns: str,
) -> str:
    return f"""{AUTO_START}
## Auto-updated Compile Snapshot

Generated: {timestamp}

Source log: `{log_path}`

### Timing

- Constraint (`sys_clk`): **{target} MHz**
- Post-route FMAX (`sys_clk`): **{post_fmax} MHz**
- Margin vs target: **{margin} MHz**
- Early analytical estimate (pre-route): **{initial_fmax} MHz**

### Utilization

| Resource | Used / Avail | Utilization |
|---|---:|---:|
{_fmt_resource_row('IOB', usage)}
{_fmt_resource_row('LUT4', usage)}
{_fmt_resource_row('DFF', usage)}
{_fmt_resource_row('RAM16SDP4', usage)}
{_fmt_resource_row('BSRAM', usage)}
{_fmt_resource_row('rPLL', usage)}

### Current Worst Path Snapshot (`sys_clk`)

- Source: `{src}`
- Sink: `{sink}`
- Logic delay: **{logic_ns} ns**
- Routing delay: **{routing_ns} ns**
{AUTO_END}
"""


def _update_timing_report(repo_root: pathlib.Path, auto_section: str) -> pathlib.Path:
    report_path = repo_root / "docs" / "TIMING_REPORT.md"
    if not report_path.exists():
        raise FileNotFoundError(f"TIMING_REPORT not found: {report_path}")

    content = report_path.read_text(encoding="utf-8", errors="replace")
    pattern = re.compile(rf"{re.escape(AUTO_START)}.*?{re.escape(AUTO_END)}", flags=re.S)

    if pattern.search(content):
        updated = pattern.sub(auto_section.strip(), content)
    else:
        updated = content.rstrip() + "\n\n" + auto_section.strip() + "\n"

    report_path.write_text(updated, encoding="utf-8")
    return report_path


def _env_truthy(name: str, default: str = "1") -> bool:
    v = os.environ.get(name, default).strip().lower()
    return v in {"1", "true", "yes", "on"}


def main() -> int:
    out_dir = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path("build/tang9k_oss").resolve()
    repo_root = pathlib.Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else pathlib.Path(__file__).resolve().parents[2]
    log_path = out_dir / "nextpnr.log"

    if not log_path.exists():
        print(f"[compile-summary] WARNING: nextpnr log not found: {log_path}")
        print("[compile-summary] Skipping summary generation (non-fatal).")
        return 0

    text = log_path.read_text(encoding="utf-8", errors="replace")

    usage = _parse_resource_usage(text)
    fmax_initial, fmax_post = _parse_fmax(text)
    src, sink, logic_ns, routing_ns = _parse_critical_path(text)

    timestamp = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    ts_file = _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%d_%H%M%SZ")
    git_commit = _safe_cmd(["git", "rev-parse", "--short", "HEAD"], repo_root)
    git_branch = _safe_cmd(["git", "rev-parse", "--abbrev-ref", "HEAD"], repo_root)
    yosys_ver = _safe_cmd(["yosys", "-V"], repo_root)
    nextpnr_ver = _safe_cmd(["nextpnr-himbaechel", "--version"], repo_root)

    if fmax_post:
        post_fmax, target = fmax_post
        try:
            margin = f"{float(post_fmax) - float(target):.2f}"
        except Exception:
            margin = "TBD"
    else:
        post_fmax, target, margin = "TBD", "TBD", "TBD"

    initial_fmax = fmax_initial[0] if fmax_initial else "TBD"

    report = f"""# Tang9K Compile Summary\n\nGenerated: {timestamp}\n\n## Build Metadata\n\n- Git branch: `{git_branch}`\n- Git commit: `{git_commit}`\n- Yosys: `{yosys_ver}`\n- nextpnr-himbaechel: `{nextpnr_ver}`\n\n## Timing\n\n- Constraint (`sys_clk`): **{target} MHz**\n- Post-route FMAX (`sys_clk`): **{post_fmax} MHz**\n- Margin vs target: **{margin} MHz**\n- Early analytical estimate (pre-route): **{initial_fmax} MHz**\n\n## Device Utilization\n\n| Resource | Used / Avail | Utilization |\n|---|---:|---:|\n{_fmt_resource_row('IOB', usage)}\n{_fmt_resource_row('LUT4', usage)}\n{_fmt_resource_row('DFF', usage)}\n{_fmt_resource_row('RAM16SDP4', usage)}\n{_fmt_resource_row('BSRAM', usage)}\n{_fmt_resource_row('rPLL', usage)}\n\n## Worst Path Snapshot (`sys_clk`)\n\n- Source: `{src}`\n- Sink: `{sink}`\n- Logic delay: **{logic_ns} ns**\n- Routing delay: **{routing_ns} ns**\n\n## Inputs\n\n- Parsed log: `{log_path}`\n"""

    latest_path = out_dir / "compile_summary_latest.md"
    archive_path = out_dir / f"compile_summary_{ts_file}.md"

    latest_path.write_text(report, encoding="utf-8")
    archive_path.write_text(report, encoding="utf-8")

    should_update_timing_report = _env_truthy("UPDATE_TIMING_REPORT", "1")
    report_path = repo_root / "docs" / "TIMING_REPORT.md"
    if should_update_timing_report:
        try:
            auto_section = _build_auto_section(
                timestamp=timestamp,
                log_path=log_path,
                target=target,
                post_fmax=post_fmax,
                margin=margin,
                initial_fmax=initial_fmax,
                usage=usage,
                src=src,
                sink=sink,
                logic_ns=logic_ns,
                routing_ns=routing_ns,
            )
            report_path = _update_timing_report(repo_root, auto_section)
        except Exception as exc:
            print(f"[compile-summary] WARNING: failed to auto-update TIMING_REPORT.md: {exc}")
            print("[compile-summary] Continuing without docs update.")

    print(f"[compile-summary] Wrote: {latest_path}")
    print(f"[compile-summary] Archived: {archive_path}")
    print(f"[compile-summary] sys_clk post-route FMAX: {post_fmax} MHz (target {target} MHz)")
    if should_update_timing_report:
        print(f"[compile-summary] Auto-updated timing report: {report_path}")
    else:
        print("[compile-summary] TIMING_REPORT auto-update skipped (UPDATE_TIMING_REPORT=0)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
