#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-CSSL-1.0
#
# sweep_locations.sh
# -------------------
# Drives the ray-tracer UE through a list of positions and, at each stop,
# compares the ground-truth position (from the emulator REST API) against
# the LMF's calculated location. Results are printed as a table and logged
# to a CSV file for later analysis (e.g. for plotting error vs. position).
#
# This combines:
#   - move_ue.sh            (sets the UE position via POST /position/<id>)
#   - compare_location_live.sh (reads ground truth + queries the LMF)
#
# Frames: LMF point.{x,y,z} is in METRES (since MR !57). Emulator position is in METRES.
#
# Requires: curl, jq, python3
#
# Locations file format (one target per line, whitespace or comma separated):
#   # comment lines and blank lines are ignored
#   0, 0, 1.5
#   5 -3 1.5
#   10, 10, 1.5
#
# Usage:
#   ./sweep_locations.sh \
#       --locations locations.txt \
#       [--url     http://192.168.89.141:8080/nlmf-loc/v1/determine-location] \
#       [--gt-url  http://127.0.0.1:5002/ue/] \
#       [--input   InputData.json] \
#       [--ue-id   0] \
#       [--wait    30] \
#       [--out     results.csv] \
#       [--debug]
#
# NOTE on robustness: this script deliberately does NOT use `set -e`/
# `pipefail`. Combined with process substitution (`< <(...)`) those can
# cause bash to abort the whole script silently on a single failed curl/
# python call, with no error message -- which is almost certainly what
# happened if the script "just closed itself". Every network/parse step
# below checks its own exit code explicitly and `continue`s the loop
# instead, and every curl call has an explicit timeout so a dead/unreachable
# server can't hang the script forever.
set -u

URL="http://192.168.89.141:8080/nlmf-loc/v1/determine-location"
GT_URL="http://127.0.0.1:5002/ue/"
INPUT="InputData.json"
UE_ID=0
WAIT=30
LOCATIONS=""
OUT="sweep_results.csv"
DEBUG=0
CURL_TIMEOUT=10   # seconds, per HTTP request -- prevents indefinite hangs

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)        URL="$2";        shift 2 ;;
    --gt-url)     GT_URL="$2";     shift 2 ;;
    --input)      INPUT="$2";      shift 2 ;;
    --ue-id)      UE_ID="$2";      shift 2 ;;
    --wait)       WAIT="$2";       shift 2 ;;
    --locations)  LOCATIONS="$2";  shift 2 ;;
    --out)        OUT="$2";        shift 2 ;;
    --debug)      DEBUG=1;         shift 1 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

dbg() { [[ "$DEBUG" -eq 1 ]] && echo "[debug] $*" >&2; return 0; }

for tool in curl jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 3; }
done
[[ -f "$INPUT" ]] || { echo "Input file not found: $INPUT" >&2; exit 4; }
[[ -n "$LOCATIONS" ]] || { echo "You must pass --locations <file>" >&2; exit 4; }
[[ -f "$LOCATIONS" ]] || { echo "Locations file not found: $LOCATIONS" >&2; exit 4; }

# The /position/ endpoint lives on the same host:port as GT_URL's /ue/ endpoint
# (both served by the same Flask REST API in server.py). Derive it so you only
# have to pass one URL.
BASE_URL="$(echo "$GT_URL" | sed -E 's#(https?://[^/]+).*#\1#')"
MOVE_URL="${BASE_URL}/position"

# Extract UE position from /ue/ response (same logic as compare_location_live.sh)
read -r -d '' EXTRACT <<'PY' || true
import json, sys
def find_position(obj, tid):
    tid = str(tid)
    if isinstance(obj, dict):
        if tid in obj and isinstance(obj[tid], dict) and 'position' in obj[tid]:
            return obj[tid]['position']
        for v in obj.values():
            r = find_position(v, tid)
            if r is not None: return r
    elif isinstance(obj, list):
        for e in obj:
            if isinstance(e, dict) and str(e.get('id')) == tid and 'position' in e:
                return e['position']
        try:
            e = obj[int(tid)]
            if isinstance(e, dict) and 'position' in e: return e['position']
        except Exception: pass
        for e in obj:
            r = find_position(e, tid)
            if r is not None: return r
    return None
data = json.load(sys.stdin)
pos = find_position(data, sys.argv[1])
if pos is None:
    sys.stderr.write("Could not find UE position in /ue/ response.\n")
    sys.exit(5)
print(pos[0], pos[1], pos[2] if len(pos) > 2 else 0)
PY

# Parse a "x,y,z" / "x y z" line into three floats, tolerant of commas.
read_line() {
  echo "$1" | tr ',' ' ' | tr -s ' '
}

# Prepare CSV with header if it doesn't already exist
if [[ ! -f "$OUT" ]]; then
  echo "index,timestamp,target_x,target_y,target_z,gt_x,gt_y,gt_z,est_x,est_y,est_z,error_2d_m,error_3d_m" > "$OUT"
fi

idx=0
total=$(grep -Ecv '^[[:space:]]*(#|$)' "$LOCATIONS")
echo "Loaded $total target location(s) from $LOCATIONS"
echo "Moving UE $UE_ID, waiting ${WAIT}s to settle at each stop, logging to $OUT"
echo

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  # skip blank lines and comments
  [[ "$raw_line" =~ ^[[:space:]]*(#.*)?$ ]] && continue

  line="$(read_line "$raw_line")"
  TX=$(echo "$line" | cut -d' ' -f1)
  TY=$(echo "$line" | cut -d' ' -f2)
  TZ=$(echo "$line" | cut -d' ' -f3)
  [[ -z "$TX" || -z "$TY" || -z "$TZ" ]] && { echo "Skipping malformed line: $raw_line" >&2; continue; }

  idx=$((idx + 1))
  echo "=================================================================="
  echo "[$idx/$total] Target position: ($TX, $TY, $TZ)"

  # ---- 1. Move the UE ----------------------------------------------------
  MOVE_HTTP_CODE=$(curl -s -o /tmp/move_resp.$$ -w '%{http_code}' --max-time "$CURL_TIMEOUT" \
                    -X POST -H "Content-Type: application/json" \
                    -d "{\"position\": [$TX,$TY,$TZ]}" \
                    "${MOVE_URL}/${UE_ID}")
  MOVE_CURL_STATUS=$?
  MOVE_RESP="$(cat /tmp/move_resp.$$ 2>/dev/null)"; rm -f /tmp/move_resp.$$
  dbg "move curl exit=$MOVE_CURL_STATUS http_code=$MOVE_HTTP_CODE"
  if [[ "$MOVE_CURL_STATUS" -ne 0 ]]; then
    echo "ERROR: curl failed to reach $MOVE_URL/$UE_ID (curl exit $MOVE_CURL_STATUS). Skipping this point." >&2
    continue
  fi
  echo "Move request -> [$MOVE_HTTP_CODE] $MOVE_RESP"
  if [[ "$MOVE_HTTP_CODE" != "200" ]]; then
    echo "WARNING: move request did not return HTTP 200 -- position likely did NOT change." >&2
  fi

  # ---- 2. Wait for the ray-tracer to settle -------------------------------
  echo "Waiting ${WAIT}s for ray-tracing to settle..."
  sleep "$WAIT"

  # ---- 3. Read ground truth ------------------------------------------------
  # Do curl and python as two explicit, checked steps (no process substitution)
  # so a failure is visible and doesn't take the whole script down with it.
  GT_JSON="$(curl -s --max-time "$CURL_TIMEOUT" "$GT_URL")"
  GT_CURL_STATUS=$?
  dbg "gt curl exit=$GT_CURL_STATUS bytes=${#GT_JSON}"
  if [[ "$GT_CURL_STATUS" -ne 0 || -z "$GT_JSON" ]]; then
    echo "ERROR: failed to reach $GT_URL (curl exit $GT_CURL_STATUS, empty=${GT_JSON:+no}${GT_JSON:-yes}). Skipping this point." >&2
    continue
  fi

  GT_LINE="$(printf '%s' "$GT_JSON" | python3 -c "$EXTRACT" "$UE_ID" 2>/tmp/gt_err.$$)"
  GT_PY_STATUS=$?
  if [[ "$GT_PY_STATUS" -ne 0 ]]; then
    echo "ERROR: could not parse UE $UE_ID position from $GT_URL response. Skipping this point." >&2
    echo "  python error: $(cat /tmp/gt_err.$$ 2>/dev/null)" >&2
    dbg "raw /ue/ response: $GT_JSON"
    rm -f /tmp/gt_err.$$
    continue
  fi
  rm -f /tmp/gt_err.$$
  read -r GT_X GT_Y GT_Z <<< "$GT_LINE"

  if [[ "$(printf '%.0f' "$GT_X" 2>/dev/null)" == "$(printf '%.0f' "$TX" 2>/dev/null)" ]] \
     && [[ "$(printf '%.0f' "$GT_Y" 2>/dev/null)" == "$(printf '%.0f' "$TY" 2>/dev/null)" ]]; then
    dbg "ground truth matches target (rounded) -- move confirmed"
  else
    echo "NOTE: ground truth ($GT_X, $GT_Y) still differs from target ($TX, $TY)." >&2
    echo "      Either the move hasn't propagated yet, or the UE didn't move -- consider a longer --wait." >&2
  fi

  # ---- 4. Query the LMF ------------------------------------------------
  RESP="$(curl -s --max-time "$CURL_TIMEOUT" --http2-prior-knowledge \
                -H "Content-Type: application/json" \
                -d "@$INPUT" -X POST "$URL")"
  LMF_CURL_STATUS=$?
  dbg "lmf curl exit=$LMF_CURL_STATUS"
  if [[ "$LMF_CURL_STATUS" -ne 0 ]]; then
    echo "ERROR: curl failed to reach LMF at $URL (curl exit $LMF_CURL_STATUS). Skipping this point." >&2
    continue
  fi

  if [[ -z "$RESP" ]]; then
    echo "ERROR: empty response from LMF, skipping this point." >&2
    continue
  fi
  if echo "$RESP" | jq -e 'has("error") or has("title")' >/dev/null 2>&1; then
    echo "LMF returned an error, skipping this point:"; echo "$RESP" | jq .
    continue
  fi

  EST_X="$(echo "$RESP" | jq -r '.localLocationEstimate.point.x // empty')"
  EST_Y="$(echo "$RESP" | jq -r '.localLocationEstimate.point.y // empty')"
  EST_Z="$(echo "$RESP" | jq -r '.localLocationEstimate.point.z // empty')"
  if [[ -z "$EST_X" || -z "$EST_Y" ]]; then
    echo "No point in LMF response, skipping this point:"; echo "$RESP" | jq .
    continue
  fi
  [[ -z "$EST_Z" ]] && EST_Z=0

  # ---- 5. Print comparison + append to CSV --------------------------------
  python3 - "$idx" "$TX" "$TY" "$TZ" "$GT_X" "$GT_Y" "$GT_Z" "$EST_X" "$EST_Y" "$EST_Z" "$OUT" <<'PY'
import sys, math, csv, datetime
idx = sys.argv[1]
target = [float(sys.argv[i]) for i in (2, 3, 4)]
gt  = [float(sys.argv[i]) for i in (5, 6, 7)]
est = [float(sys.argv[8]), float(sys.argv[9]), float(sys.argv[10])]
out_path = sys.argv[11]

err2d = math.hypot(est[0]-gt[0], est[1]-gt[1])
err3d = math.sqrt((est[0]-gt[0])**2 + (est[1]-gt[1])**2 + (est[2]-gt[2])**2)

w = 22
print("-"*52)
print(f"{'':<{w}}{'x (m)':>10}{'y (m)':>10}{'z (m)':>10}")
print(f"{'Target (m)':<{w}}{target[0]:>10.3f}{target[1]:>10.3f}{target[2]:>10.3f}")
print(f"{'Ground truth (m)':<{w}}{gt[0]:>10.3f}{gt[1]:>10.3f}{gt[2]:>10.3f}")
print(f"{'LMF estimate (m)':<{w}}{est[0]:>10.3f}{est[1]:>10.3f}{est[2]:>10.3f}")
print("-"*52)
print(f"2D error : {err2d:.3f} m   (dx={est[0]-gt[0]:+.2f}, dy={est[1]-gt[1]:+.2f})")
print(f"3D error : {err3d:.3f} m")
print("-"*52)

with open(out_path, "a", newline="") as f:
    w_csv = csv.writer(f)
    w_csv.writerow([idx, datetime.datetime.now().isoformat(timespec="seconds"),
                     *target, *gt, *est, f"{err2d:.4f}", f"{err3d:.4f}"])
PY

  echo
done < "$LOCATIONS"

echo "=================================================================="
echo "Sweep complete. Results appended to $OUT"
