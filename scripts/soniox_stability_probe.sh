#!/bin/zsh
set -u

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
RUNS=${1:-10}

if ! [[ "$RUNS" =~ '^[1-9][0-9]*$' ]]; then
    echo "usage: $0 [positive-run-count]" >&2
    exit 2
fi

"$SCRIPT_DIR/cloud_live_probe.sh" soniox >/dev/null
PROBE="$PROJECT_DIR/.build/cloud-live-probe/cloud-live-probe"
FAILURES=0

for RUN in $(seq 1 "$RUNS"); do
    OUTPUT=$("$PROBE" soniox 2>&1)
    PROBE_RC=$?
    RESULT=$(printf '%s\n' "$OUTPUT" | rg '^result provider=soniox ' || true)
    if [[ "$PROBE_RC" -ne 0 || -z "$RESULT" ]]; then
        FAILURES=$((FAILURES + 1))
        printf 'run=%s rc=%s failure=%s\n' "$RUN" "$PROBE_RC" "$OUTPUT"
    else
        printf 'run=%s %s\n' "$RUN" "$RESULT"
    fi
done

printf 'soniox_probe_runs=%s failures=%s\n' "$RUNS" "$FAILURES"
exit "$FAILURES"
