#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/docs/fit_reports"
mkdir -p "${OUT_DIR}"

TIMESTAMP="$(date -u +"%Y%m%d_%H%M%SZ")"
OUT_FILE="${1:-${OUT_DIR}/fit_evidence_${TIMESTAMP}.md}"

GIT_COMMIT="$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
GIT_BRANCH="$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"

RUN_SIM_GATE="${RUN_SIM_GATE:-0}"
SIM_GATE_STATUS="${SIM_GATE_STATUS:-TBD}"
CFG_MIN_CONTROL_STATUS="${CFG_MIN_CONTROL_STATUS:-TBD}"
CFG_MID_STREAM_STATUS="${CFG_MID_STREAM_STATUS:-TBD}"
CFG_FULL_TARGET_STATUS="${CFG_FULL_TARGET_STATUS:-TBD}"
GOWIN_REPORT_ROOT="${GOWIN_REPORT_ROOT:-}"

# Gowin P&R report paths (point to impl/pnr/*.rpt.txt and impl/pnr/*.timing_paths)
CFG_MIN_CONTROL_PNR_RPT="${CFG_MIN_CONTROL_PNR_RPT:-}"
CFG_MIN_CONTROL_TIMING="${CFG_MIN_CONTROL_TIMING:-}"
CFG_MIN_CONTROL_REPORT_DIR="${CFG_MIN_CONTROL_REPORT_DIR:-}"
CFG_MID_STREAM_PNR_RPT="${CFG_MID_STREAM_PNR_RPT:-}"
CFG_MID_STREAM_TIMING="${CFG_MID_STREAM_TIMING:-}"
CFG_MID_STREAM_REPORT_DIR="${CFG_MID_STREAM_REPORT_DIR:-}"
CFG_FULL_TARGET_PNR_RPT="${CFG_FULL_TARGET_PNR_RPT:-}"
CFG_FULL_TARGET_TIMING="${CFG_FULL_TARGET_TIMING:-}"
CFG_FULL_TARGET_REPORT_DIR="${CFG_FULL_TARGET_REPORT_DIR:-}"

parser_note="TBD"
top_note="TBD"
wb_note="TBD"
axis_note="TBD"
parser_log_ref="TBD"
top_log_ref="TBD"
wb_log_ref="TBD"
axis_log_ref="TBD"
critical_path_1="TBD"
critical_path_2="TBD"
critical_path_3="TBD"
fit_gate_result="TBD"
high_impact_modules_text="- TBD"
follow_up_actions_text="- TBD"

parse_tests_line() {
	local line="$1"
	local tests pass fail
	tests="$(echo "$line" | sed -n 's/.*TESTS=\([0-9][0-9]*\).*/\1/p')"
	pass="$(echo "$line" | sed -n 's/.*PASS=\([0-9][0-9]*\).*/\1/p')"
	fail="$(echo "$line" | sed -n 's/.*FAIL=\([0-9][0-9]*\).*/\1/p')"
	if [[ -n "$tests" && -n "$pass" && -n "$fail" ]]; then
		echo "${pass}/${tests} pass (fail=${fail})"
	else
		echo "unknown"
	fi
}

resolve_report_path() {
	local current_path="$1"
	local report_dir="$2"
	local pattern="$3"
	local resolved="$current_path"

	if [[ -n "$resolved" && -f "$resolved" ]]; then
		echo "$resolved"
		return
	fi

	if [[ -n "$report_dir" && -d "$report_dir" ]]; then
		resolved="$(find "$report_dir" -maxdepth 2 -type f -name "$pattern" | sort | head -n 1)"
	fi

	echo "$resolved"
}

dir_has_gowin_reports() {
	local dir="$1"
	[[ -d "$dir" ]] || return 1
	find "$dir" -maxdepth 1 -type f \( -name '*.rpt.txt' -o -name '*.timing_paths' \) | grep -q .
}

resolve_report_dir() {
	local current_dir="$1"
	local current_rpt="$2"
	local current_timing="$3"
	local report_root="$4"
	local alias_list="$5"
	local dir alias candidate found=""

	if [[ -n "$current_dir" && -d "$current_dir" ]]; then
		echo "$current_dir"
		return
	fi

	if [[ -n "$current_rpt" && -f "$current_rpt" ]]; then
		dir="$(dirname "$current_rpt")"
		echo "$dir"
		return
	fi

	if [[ -n "$current_timing" && -f "$current_timing" ]]; then
		dir="$(dirname "$current_timing")"
		echo "$dir"
		return
	fi

	if [[ -z "$report_root" || ! -d "$report_root" ]]; then
		echo ""
		return
	fi

	IFS='|' read -r -a aliases <<< "$alias_list"
	for alias in "${aliases[@]}"; do
		candidate="${report_root}/${alias}/impl/pnr"
		if dir_has_gowin_reports "$candidate"; then
			echo "$candidate"
			return
		fi

		candidate="${report_root}/${alias}"
		if dir_has_gowin_reports "$candidate"; then
			echo "$candidate"
			return
		fi
	done

	for alias in "${aliases[@]}"; do
		found="$(find "$report_root" -maxdepth 6 -type d \( -path "*/${alias}/impl/pnr" -o -path "*/${alias}" \) | sort | head -n 1)"
		if [[ -n "$found" ]]; then
			if dir_has_gowin_reports "$found"; then
				echo "$found"
				return
			fi
			candidate="${found}/impl/pnr"
			if dir_has_gowin_reports "$candidate"; then
				echo "$candidate"
				return
			fi
		fi
	done

	echo ""
}

# --- Gowin P&R report parser functions ---
# Parses Gowin impl/pnr/*.rpt.txt for resource counts
# and impl/pnr/*.timing_paths for WNS/Fmax.

parse_gowin_lut() {
	local rpt="${1:-}"
	[[ -f "$rpt" ]] || { echo "TBD"; return; }
	# Line: "  --LUT,ALU,ROM16  | XX(Y LUT, Z ALU, ...)"
	local val
	val=$(grep -E '^\s+--LUT,ALU,ROM16' "$rpt" | sed 's/.*|\s*\([0-9][0-9]*\)(.*/\1/' | head -1)
	echo "${val:-TBD}"
}

parse_gowin_ff() {
	local rpt="${1:-}"
	[[ -f "$rpt" ]] || { echo "TBD"; return; }
	# Line: "  --Logic Register as FF  | XX/TOTAL"
	local val
	val=$(grep -E '^\s+--Logic Register as FF' "$rpt" | sed 's/.*|\s*\([0-9][0-9]*\)\/.*/\1/' | head -1)
	echo "${val:-TBD}"
}

parse_gowin_bram() {
	local rpt="${1:-}"
	[[ -f "$rpt" ]] || { echo "TBD"; return; }
	# Line present only when BRAM is used; default 0 if absent
	local val
	val=$(grep -iE '^\s+(Block SRAM|B-SRAM|BSRAM)' "$rpt" | sed 's/.*|\s*\([0-9][0-9]*\)\/.*/\1/' | head -1)
	echo "${val:-0}"
}

parse_gowin_dsp() {
	local rpt="${1:-}"
	[[ -f "$rpt" ]] || { echo "TBD"; return; }
	# Line present only when DSP/Multiplier is used; default 0 if absent
	local val
	val=$(grep -iE '^\s+Multiplier' "$rpt" | sed 's/.*|\s*\([0-9][0-9]*\)\/.*/\1/' | head -1)
	echo "${val:-0}"
}

parse_gowin_wns() {
	local timing="${1:-}"
	[[ -f "$timing" ]] || { echo "TBD"; return; }
	# Format: =====\nSETUP\nWNS_ns\narrival_ns\nrequired_ns\n...
	local val
	val=$(sed -n '3p' "$timing")
	echo "${val:-TBD}"
}

parse_gowin_fmax() {
	local timing="${1:-}"
	[[ -f "$timing" ]] || { echo "TBD"; return; }
	# Fmax (MHz) = 1000 / arrival_delay_ns (critical path, line 4)
	local arrival
	arrival=$(sed -n '4p' "$timing")
	if [[ -n "$arrival" ]] && awk "BEGIN { exit !($arrival > 0) }" 2>/dev/null; then
		awk -v a="$arrival" 'BEGIN { printf "%.1f", 1000.0/a }'
	else
		echo "TBD"
	fi
}

parse_gowin_top_paths() {
	local timing="${1:-}"
	local count="${2:-3}"
	[[ -f "$timing" ]] || return 0
	awk -v max_paths="$count" '
		function isnum(s) { return s ~ /^-?[0-9]+(\.[0-9]+)?$/ }
		function flush_block(    i,start_name,end_name,summary) {
			if (!in_block || path_count >= max_paths) {
				delete block
				block_len = 0
				return
			}
			if (block_len >= 7) {
				start_name = block[6]
				end_name = "unknown"
				for (i = block_len; i >= 1; i--) {
					if (!isnum(block[i]) && block[i] != "SETUP" && block[i] != "HOLD" && block[i] != "=====") {
						end_name = block[i]
						break
					}
				}
				summary = start_name " -> " end_name " (delay=" block[4] " ns, slack=" block[3] " ns)"
				print summary
				path_count++
			}
			delete block
			block_len = 0
		}
		/^=====$/ {
			flush_block()
			in_block = 1
			block[++block_len] = $0
			next
		}
		{
			if (in_block) {
				block[++block_len] = $0
			}
		}
		END { flush_block() }
	' "$timing"
}

compute_row_result() {
	local sim_gate="$1"
	local wns="$2"
	if [[ "$wns" == "TBD" ]]; then
		echo "TBD"
	elif awk "BEGIN { exit !($wns >= 0) }" 2>/dev/null; then
		# Timing met: result depends on sim gate
		case "$sim_gate" in
			PASS) echo "PASS" ;;
			FAIL) echo "FAIL" ;;
			*)    echo "TBD"  ;;   # sim gate not yet run
		esac
	else
		echo "FAIL"  # timing violated regardless of sim gate
	fi
}

compute_fit_gate_result() {
	local min_result="$1"
	local mid_result="$2"
	local full_result="$3"

	if [[ "$min_result" == "FAIL" || "$mid_result" == "FAIL" || "$full_result" == "FAIL" ]]; then
		echo "FAIL"
	elif [[ "$min_result" == "PASS" && "$mid_result" == "PASS" && "$full_result" == "PASS" ]]; then
		echo "PASS"
	else
		echo "TBD"
	fi
}

normalize_signal_name() {
	local signal="$1"
	signal="${signal%%[*}"
	signal="$(echo "$signal" | sed -E 's/_[sdq][0-9]*$//; s/_[0-9]+$//')"
	echo "$signal"
}

derive_high_impact_modules() {
	local path_lines=("$@")
	local tokens=""
	local line start_sig end_sig norm
	for line in "${path_lines[@]}"; do
		[[ -n "$line" && "$line" != "TBD" ]] || continue
		start_sig="$(echo "$line" | sed -n 's/^\(.*\) -> .* (delay=.*/\1/p')"
		end_sig="$(echo "$line" | sed -n 's/^.* -> \(.*\) (delay=.*/\1/p')"
		for norm in "$(normalize_signal_name "$start_sig")" "$(normalize_signal_name "$end_sig")"; do
			[[ -n "$norm" && "$norm" != "unknown" ]] || continue
			tokens+="$norm\n"
		done
	done

	if [[ -z "$tokens" ]]; then
		echo "- TBD"
		return
	fi

	echo -e "$tokens" | awk 'NF { count[$0]++ } END {
		printed = 0
		for (name in count) {
			items[name] = count[name]
		}
		# simple frequency sort by piping through shell sort in caller would be awkward; use manual selection
		while (printed < 3) {
			best_name = ""
			best_count = -1
			for (name in items) {
				if (items[name] > best_count || (items[name] == best_count && name < best_name)) {
					best_name = name
					best_count = items[name]
				}
			}
			if (best_count < 0) break
			printf "- %s (appears in %d critical path%s)\n", best_name, best_count, (best_count == 1 ? "" : "s")
			delete items[best_name]
			printed++
		}
	}'
}

generate_follow_up_actions() {
	local sim_gate_status="$1"
	local fit_result="$2"
	local min_result="$3"
	local mid_result="$4"
	local full_result="$5"
	local min_wns="$6"
	local mid_wns="$7"
	local full_wns="$8"
	local actions=()
	local has_timing_fail=0

	if [[ "$sim_gate_status" != "PASS" ]]; then
		actions+=("- Run \`make -C sim fit-evidence-snapshot-live\` to refresh the simulation evidence gate before signoff.")
		actions+=("- Inspect the per-suite raw logs above and fix failing cocotb targets before treating any fit result as trustworthy.")
	fi

	if [[ "$min_result" == "TBD" && ( "$min_wns" == "TBD" || "$CFG_MIN_CONTROL_PNR_RPT" == "" || "$CFG_MIN_CONTROL_TIMING" == "" ) ]]; then
		actions+=("- Generate or point to Gowin P&R outputs for \`cfg_min_control\` via \`CFG_MIN_CONTROL_REPORT_DIR\`, \`GOWIN_REPORT_ROOT\`, or explicit \`CFG_MIN_CONTROL_PNR_RPT\` / \`CFG_MIN_CONTROL_TIMING\`.")
	fi
	if [[ "$mid_result" == "TBD" && ( "$mid_wns" == "TBD" || "$CFG_MID_STREAM_PNR_RPT" == "" || "$CFG_MID_STREAM_TIMING" == "" ) ]]; then
		actions+=("- Generate or point to Gowin P&R outputs for \`cfg_mid_stream\` via \`CFG_MID_STREAM_REPORT_DIR\`, \`GOWIN_REPORT_ROOT\`, or explicit file vars.")
	fi
	if [[ "$full_result" == "TBD" && ( "$full_wns" == "TBD" || "$CFG_FULL_TARGET_PNR_RPT" == "" || "$CFG_FULL_TARGET_TIMING" == "" ) ]]; then
		actions+=("- Generate or point to Gowin P&R outputs for \`cfg_full_target\` via \`CFG_FULL_TARGET_REPORT_DIR\`, \`GOWIN_REPORT_ROOT\`, or explicit file vars.")
	fi

	if [[ "$min_wns" != "TBD" ]] && awk "BEGIN { exit !($min_wns < 0) }" 2>/dev/null; then has_timing_fail=1; fi
	if [[ "$mid_wns" != "TBD" ]] && awk "BEGIN { exit !($mid_wns < 0) }" 2>/dev/null; then has_timing_fail=1; fi
	if [[ "$full_wns" != "TBD" ]] && awk "BEGIN { exit !($full_wns < 0) }" 2>/dev/null; then has_timing_fail=1; fi

	if [[ $has_timing_fail -eq 1 ]]; then
		actions+=("- Investigate negative-WNS paths first; use the critical-path summaries above to target the longest combinational chain before the next milestone snapshot.")
	fi

	if [[ "$fit_result" == "PASS" ]]; then
		actions+=("- Archive this snapshot with the milestone PR/log entry as the current Tang9K fit evidence reference.")
	fi

	if [[ ${#actions[@]} -eq 0 ]]; then
		actions+=("- No blocking actions inferred from the current evidence set.")
	fi

	printf '%s\n' "${actions[@]}"
}

if [[ "$RUN_SIM_GATE" == "1" ]]; then
	export PATH="${ROOT_DIR}/.venv/bin:${PATH}"
	LOG_DIR="${OUT_DIR}/logs"
	mkdir -p "${LOG_DIR}"

	parser_log="${LOG_DIR}/parser_${TIMESTAMP}.log"
	top_log="${LOG_DIR}/top_${TIMESTAMP}.log"
	wb_log="${LOG_DIR}/wb_${TIMESTAMP}.log"
	axis_log="${LOG_DIR}/axis_${TIMESTAMP}.log"

	parser_log_ref="${parser_log#${ROOT_DIR}/}"
	top_log_ref="${top_log#${ROOT_DIR}/}"
	wb_log_ref="${wb_log#${ROOT_DIR}/}"
	axis_log_ref="${axis_log#${ROOT_DIR}/}"

	parser_rc=0
	top_rc=0
	wb_rc=0
	axis_rc=0

	set +e
	make -C "${ROOT_DIR}/sim" test-cocotb >"${parser_log}" 2>&1
	parser_rc=$?
	make -C "${ROOT_DIR}/sim" test-top-cocotb >"${top_log}" 2>&1
	top_rc=$?
	make -C "${ROOT_DIR}/sim" test-wb-example-cocotb >"${wb_log}" 2>&1
	wb_rc=$?
	make -C "${ROOT_DIR}/sim" test-axis-example-cocotb >"${axis_log}" 2>&1
	axis_rc=$?
	set -e

	parser_line="$(grep -E 'TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+' "${parser_log}" | tail -n 1 || true)"
	top_line="$(grep -E 'TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+' "${top_log}" | tail -n 1 || true)"
	wb_line="$(grep -E 'TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+' "${wb_log}" | tail -n 1 || true)"
	axis_line="$(grep -E 'TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+' "${axis_log}" | tail -n 1 || true)"

	parser_note="$(parse_tests_line "$parser_line")"
	top_note="$(parse_tests_line "$top_line")"
	wb_note="$(parse_tests_line "$wb_line")"
	axis_note="$(parse_tests_line "$axis_line")"

	if [[ $parser_rc -eq 0 && $top_rc -eq 0 && $wb_rc -eq 0 && $axis_rc -eq 0 ]]; then
		SIM_GATE_STATUS="PASS"
		CFG_MIN_CONTROL_STATUS="PASS"
	else
		SIM_GATE_STATUS="FAIL"
		CFG_MIN_CONTROL_STATUS="FAIL"
	fi
fi

CFG_MIN_CONTROL_REPORT_DIR="$(resolve_report_dir "${CFG_MIN_CONTROL_REPORT_DIR}" "${CFG_MIN_CONTROL_PNR_RPT}" "${CFG_MIN_CONTROL_TIMING}" "${GOWIN_REPORT_ROOT}" 'cfg_min_control|min_control|control_only|control-only')"
CFG_MID_STREAM_REPORT_DIR="$(resolve_report_dir "${CFG_MID_STREAM_REPORT_DIR}" "${CFG_MID_STREAM_PNR_RPT}" "${CFG_MID_STREAM_TIMING}" "${GOWIN_REPORT_ROOT}" 'cfg_mid_stream|mid_stream|telemetry|control_telemetry|control-telemetry')"
CFG_FULL_TARGET_REPORT_DIR="$(resolve_report_dir "${CFG_FULL_TARGET_REPORT_DIR}" "${CFG_FULL_TARGET_PNR_RPT}" "${CFG_FULL_TARGET_TIMING}" "${GOWIN_REPORT_ROOT}" 'cfg_full_target|full_target|full_path|full-path')"

CFG_MIN_CONTROL_PNR_RPT="$(resolve_report_path "${CFG_MIN_CONTROL_PNR_RPT}" "${CFG_MIN_CONTROL_REPORT_DIR}" '*.rpt.txt')"
CFG_MIN_CONTROL_TIMING="$(resolve_report_path "${CFG_MIN_CONTROL_TIMING}" "${CFG_MIN_CONTROL_REPORT_DIR}" '*.timing_paths')"
CFG_MID_STREAM_PNR_RPT="$(resolve_report_path "${CFG_MID_STREAM_PNR_RPT}" "${CFG_MID_STREAM_REPORT_DIR}" '*.rpt.txt')"
CFG_MID_STREAM_TIMING="$(resolve_report_path "${CFG_MID_STREAM_TIMING}" "${CFG_MID_STREAM_REPORT_DIR}" '*.timing_paths')"
CFG_FULL_TARGET_PNR_RPT="$(resolve_report_path "${CFG_FULL_TARGET_PNR_RPT}" "${CFG_FULL_TARGET_REPORT_DIR}" '*.rpt.txt')"
CFG_FULL_TARGET_TIMING="$(resolve_report_path "${CFG_FULL_TARGET_TIMING}" "${CFG_FULL_TARGET_REPORT_DIR}" '*.timing_paths')"

# --- Parse Gowin synth/P&R reports (when env vars point to real files) ---
min_lut=$(parse_gowin_lut "${CFG_MIN_CONTROL_PNR_RPT}")
min_ff=$(parse_gowin_ff  "${CFG_MIN_CONTROL_PNR_RPT}")
min_bram=$(parse_gowin_bram "${CFG_MIN_CONTROL_PNR_RPT}")
min_dsp=$(parse_gowin_dsp  "${CFG_MIN_CONTROL_PNR_RPT}")
min_wns=$(parse_gowin_wns  "${CFG_MIN_CONTROL_TIMING}")
min_fmax=$(parse_gowin_fmax "${CFG_MIN_CONTROL_TIMING}")
min_result=$(compute_row_result "${CFG_MIN_CONTROL_STATUS}" "${min_wns}")

mid_lut=$(parse_gowin_lut  "${CFG_MID_STREAM_PNR_RPT}")
mid_ff=$(parse_gowin_ff   "${CFG_MID_STREAM_PNR_RPT}")
mid_bram=$(parse_gowin_bram "${CFG_MID_STREAM_PNR_RPT}")
mid_dsp=$(parse_gowin_dsp  "${CFG_MID_STREAM_PNR_RPT}")
mid_wns=$(parse_gowin_wns  "${CFG_MID_STREAM_TIMING}")
mid_fmax=$(parse_gowin_fmax "${CFG_MID_STREAM_TIMING}")
mid_result=$(compute_row_result "${CFG_MID_STREAM_STATUS}" "${mid_wns}")

full_lut=$(parse_gowin_lut  "${CFG_FULL_TARGET_PNR_RPT}")
full_ff=$(parse_gowin_ff   "${CFG_FULL_TARGET_PNR_RPT}")
full_bram=$(parse_gowin_bram "${CFG_FULL_TARGET_PNR_RPT}")
full_dsp=$(parse_gowin_dsp  "${CFG_FULL_TARGET_PNR_RPT}")
full_wns=$(parse_gowin_wns  "${CFG_FULL_TARGET_TIMING}")
full_fmax=$(parse_gowin_fmax "${CFG_FULL_TARGET_TIMING}")
full_result=$(compute_row_result "${CFG_FULL_TARGET_STATUS}" "${full_wns}")
fit_gate_result=$(compute_fit_gate_result "${min_result}" "${mid_result}" "${full_result}")

mapfile -t critical_paths < <(parse_gowin_top_paths "${CFG_MIN_CONTROL_TIMING}" 3)
if [[ ${#critical_paths[@]} -ge 1 ]]; then critical_path_1="${critical_paths[0]}"; fi
if [[ ${#critical_paths[@]} -ge 2 ]]; then critical_path_2="${critical_paths[1]}"; fi
if [[ ${#critical_paths[@]} -ge 3 ]]; then critical_path_3="${critical_paths[2]}"; fi
high_impact_modules_text="$(derive_high_impact_modules "${critical_paths[@]}")"
follow_up_actions_text="$(generate_follow_up_actions "${SIM_GATE_STATUS}" "${fit_gate_result}" "${min_result}" "${mid_result}" "${full_result}" "${min_wns}" "${mid_wns}" "${full_wns}")"

cat > "${OUT_FILE}" <<EOF
# Tang9K Fit Evidence Snapshot

- Generated (UTC): $(date -u +"%Y-%m-%d %H:%M:%S")
- Git branch: ${GIT_BRANCH}
- Git commit: ${GIT_COMMIT}
- Simulation evidence gate: ${SIM_GATE_STATUS}

## Simulation evidence

Expected command set:

- \`make -C sim test-fcsp-smoke-cocotb\`
- \`make -C sim test-teaching-examples-cocotb\`

Observed notes:

- parser cocotb: ${parser_note}
- top-level cocotb: ${top_note}
- Wishbone example cocotb: ${wb_note}
- AXIS example cocotb: ${axis_note}

Raw logs:

- parser cocotb log: ${parser_log_ref}
- top-level cocotb log: ${top_log_ref}
- Wishbone example log: ${wb_log_ref}
- AXIS example log: ${axis_log_ref}

## Synthesis / P&R evidence

| Config | Sim Gate | LUT | FF | BRAM | DSP | Fmax (MHz) | WNS | Result |
|---|---|---:|---:|---:|---:|---:|---:|---|
| cfg_min_control | ${CFG_MIN_CONTROL_STATUS} | ${min_lut} | ${min_ff} | ${min_bram} | ${min_dsp} | ${min_fmax} | ${min_wns} | ${min_result} |
| cfg_mid_stream | ${CFG_MID_STREAM_STATUS} | ${mid_lut} | ${mid_ff} | ${mid_bram} | ${mid_dsp} | ${mid_fmax} | ${mid_wns} | ${mid_result} |
| cfg_full_target | ${CFG_FULL_TARGET_STATUS} | ${full_lut} | ${full_ff} | ${full_bram} | ${full_dsp} | ${full_fmax} | ${full_wns} | ${full_result} |

## Critical paths (top 3)

1. ${critical_path_1}
2. ${critical_path_2}
3. ${critical_path_3}

## High-impact modules

${high_impact_modules_text}

## Decision

- Fit gate result: ${fit_gate_result}
- Follow-up actions:
${follow_up_actions_text}
EOF

echo "Generated fit evidence snapshot: ${OUT_FILE}"
