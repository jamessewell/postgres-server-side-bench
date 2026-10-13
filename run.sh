#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

BACKEND=${BACKEND:-}
DATABASE_URL=${DATABASE_URL:-}
TERMSET=${TERMSET:-}
DATASET=${DATASET:-documents}
WORKLOAD=${WORKLOAD:-topk}
QUERY_SHAPE=${QUERY_SHAPE:-text}
QUERY_STYLE=${QUERY_STYLE:-disjunction}
QUERY_IDS=${QUERY_IDS:-}
MODE=${MODE:-both}
CLIENTS=${CLIENTS:-8}
JOBS=${JOBS:-$CLIENTS}
DURATION=${DURATION:-60}
PREWARM=${PREWARM:-10}
BATCH_SIZE=${BATCH_SIZE:-100}
THROUGHPUT_START_DELAY=${THROUGHPUT_START_DELAY:-5}
TOP_K=${TOP_K:-10}
DENSE_RATIO=${DENSE_RATIO:-0.1}
SEED=${SEED:-1592614637}
PROGRESS=${PROGRESS:-5}
OUTPUT_DIR=${OUTPUT_DIR:-$SCRIPT_DIR/out}

usage() {
    cat <<'EOF'
Usage: local-timed/run.sh --backend tin|paradedb --url URL --termset FILE [options]

Options:
  --dataset documents|hn
  --workload topk|count
  --query-shape text|score_filter|time_sort
  --query-style conjunction|disjunction|phrase|mixed
  --query-ids 1,2,3
  --mode both|throughput|latency
                        measurement phase(s) to run (default: both)
  --clients N           pgbench connections (default: 8)
  --jobs N              pgbench worker threads (default: CLIENTS)
  --duration SECONDS    measured phase (default: 60)
  --prewarm SECONDS     unrecorded phase (default: 10)
  --batch-size N        measurement deadline-check interval (default: 100)
  --throughput-start-delay SECONDS
                        synchronization lead time (default: 5)
  --top-k N             top-k result size (default: 10)
  --dense-ratio NUMBER  TIN score dense ratio (default: 0.1)
  --seed N              term shuffle and pgbench random seed
  --progress SECONDS    pgbench progress interval (default: 5)
  --output-dir DIR      report directory (default: local-timed/out)

Every option also has an uppercase environment-variable equivalent. The URL
variable is DATABASE_URL and the termset variable is TERMSET.
EOF
}

while (($#)); do
    case "$1" in
        --backend) BACKEND=${2:?missing value}; shift 2 ;;
        --url) DATABASE_URL=${2:?missing value}; shift 2 ;;
        --termset) TERMSET=${2:?missing value}; shift 2 ;;
        --dataset) DATASET=${2:?missing value}; shift 2 ;;
        --workload) WORKLOAD=${2:?missing value}; shift 2 ;;
        --query-shape) QUERY_SHAPE=${2:?missing value}; shift 2 ;;
        --query-style) QUERY_STYLE=${2:?missing value}; shift 2 ;;
        --query-ids) QUERY_IDS=${2:?missing value}; shift 2 ;;
        --mode) MODE=${2:?missing value}; shift 2 ;;
        --clients) CLIENTS=${2:?missing value}; shift 2 ;;
        --jobs) JOBS=${2:?missing value}; shift 2 ;;
        --duration) DURATION=${2:?missing value}; shift 2 ;;
        --prewarm) PREWARM=${2:?missing value}; shift 2 ;;
        --batch-size) BATCH_SIZE=${2:?missing value}; shift 2 ;;
        --throughput-start-delay) THROUGHPUT_START_DELAY=${2:?missing value}; shift 2 ;;
        --top-k) TOP_K=${2:?missing value}; shift 2 ;;
        --dense-ratio) DENSE_RATIO=${2:?missing value}; shift 2 ;;
        --seed) SEED=${2:?missing value}; shift 2 ;;
        --progress) PROGRESS=${2:?missing value}; shift 2 ;;
        --output-dir) OUTPUT_DIR=${2:?missing value}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$BACKEND" == tin || "$BACKEND" == paradedb ]] || {
    echo 'BACKEND must be tin or paradedb' >&2; exit 2;
}
if [[ -z "$DATABASE_URL" ]]; then
    if [[ "$BACKEND" == tin ]]; then
        DATABASE_URL=${TIN_URL:-}
    else
        DATABASE_URL=${PARADEDB_URL:-}
    fi
fi
[[ -n "$DATABASE_URL" ]] || { echo 'DATABASE_URL/--url is required' >&2; exit 2; }
[[ -f "$TERMSET" ]] || { echo "Termset does not exist: $TERMSET" >&2; exit 2; }
case "$DATASET" in
    documents|hn) ;;
    *) echo 'DATASET must be documents or hn' >&2; exit 2 ;;
esac
[[ "$WORKLOAD" == topk || "$WORKLOAD" == count ]] || {
    echo 'WORKLOAD must be topk or count' >&2; exit 2;
}
case "$QUERY_SHAPE" in
    text|score_filter|time_sort) ;;
    *) echo 'QUERY_SHAPE must be text, score_filter, or time_sort' >&2; exit 2 ;;
esac
case "$QUERY_STYLE" in
    conjunction|disjunction|phrase|mixed) ;;
    *) echo 'QUERY_STYLE is invalid' >&2; exit 2 ;;
esac
case "$MODE" in
    both|throughput|latency) ;;
    *) echo 'MODE must be both, throughput, or latency' >&2; exit 2 ;;
esac
if [[ "$DATASET" == documents && "$QUERY_SHAPE" != text ]]; then
    echo 'DATASET=documents only supports QUERY_SHAPE=text' >&2
    exit 2
fi
if [[ "$DATASET" == hn ]]; then
    [[ "$QUERY_STYLE" == disjunction ]] || {
        echo 'DATASET=hn only supports QUERY_STYLE=disjunction' >&2; exit 2;
    }
    if [[ "$QUERY_SHAPE" == time_sort && "$WORKLOAD" != topk ]]; then
        echo 'QUERY_SHAPE=time_sort only supports WORKLOAD=topk' >&2
        exit 2
    fi
fi
for value_name in CLIENTS JOBS DURATION BATCH_SIZE THROUGHPUT_START_DELAY TOP_K PROGRESS; do
    value=${!value_name}
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "$value_name must be a positive integer" >&2; exit 2;
    }
done
[[ "$PREWARM" =~ ^[0-9]+$ ]] || {
    echo 'PREWARM must be a nonnegative integer' >&2; exit 2;
}
((JOBS <= CLIENTS)) || { echo 'JOBS cannot exceed CLIENTS' >&2; exit 2; }
if [[ ! "$SEED" =~ ^[0-9]+$ ]] || ((SEED > 4294967295)); then
    echo 'SEED must be an integer between 0 and 4294967295' >&2
    exit 2
fi
[[ "$DENSE_RATIO" =~ ^(0([.][0-9]+)?|[.][0-9]+|1([.]0+)?)$ ]] || {
    echo 'DENSE_RATIO must be between 0 and 1' >&2; exit 2;
}

for dependency in psql pgbench python3 tee; do
    command -v "$dependency" >/dev/null || {
        echo "Missing dependency: $dependency" >&2; exit 2;
    }
done

mkdir -p "$OUTPUT_DIR"
PSQL=(psql -X --no-psqlrc --set=ON_ERROR_STOP=1 --dbname="$DATABASE_URL")
termset_sha256=$(python3 -c \
    'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' \
    "$TERMSET")

run_id=''
finalized=0
finalize_failed_run() {
    status=$?
    trap - EXIT
    if [[ -n "$run_id" && "$finalized" == 0 ]]; then
        "${PSQL[@]}" -q -c \
            "SELECT local_timed.finish_run($run_id, 'failed');" \
            >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap finalize_failed_run EXIT

echo "Installing local timing harness for $BACKEND/$DATASET"
"${PSQL[@]}" -q -f "$SCRIPT_DIR/install.sql"
executor_file="$SCRIPT_DIR/$BACKEND.sql"
if [[ "$DATASET" != documents ]]; then
    executor_file="$SCRIPT_DIR/$BACKEND-$DATASET.sql"
fi
[[ -f "$executor_file" ]] || {
    echo "No executor for BACKEND=$BACKEND DATASET=$DATASET" >&2; exit 2;
}
"${PSQL[@]}" -q -f "$executor_file"

run_id=$("${PSQL[@]}" -Atq -c \
    "SELECT local_timed.create_run('$BACKEND', '$DATASET', '$WORKLOAD', '$QUERY_SHAPE', '$QUERY_STYLE', $CLIENTS, $JOBS, $DURATION, $PREWARM, $BATCH_SIZE, $TOP_K, $DENSE_RATIO, $SEED, '$termset_sha256');")
[[ "$run_id" =~ ^[1-9][0-9]*$ ]] || {
    echo "Could not create run; server returned: $run_id" >&2; exit 1;
}

echo "Loading termset for run $run_id"
python3 "$SCRIPT_DIR/prepare_terms.py" \
    --termset "$TERMSET" \
    --backend "$BACKEND" \
    --query-style "$QUERY_STYLE" \
    --query-ids "$QUERY_IDS" \
    --seed "$SEED" \
    --run-id "$run_id" |
    "${PSQL[@]}" -q -c \
        'COPY local_timed.terms (run_id, term_no, source_id, style, query_text) FROM STDIN WITH (FORMAT csv)'

term_count=$("${PSQL[@]}" -Atq -c "SELECT local_timed.seal_run($run_id);")
[[ "$term_count" =~ ^[1-9][0-9]*$ ]] || {
    echo "Could not seal termset; server returned: $term_count" >&2; exit 1;
}
echo "Loaded $term_count shuffled query/style entries"

run_batched_pgbench() {
    local benchmark_seconds=$1
    local benchmark_record_samples=$2
    local benchmark_log=${3:-}
    local -a benchmark_command=(pgbench
        --dbname="$DATABASE_URL" \
        --no-vacuum \
        --protocol=prepared \
        --client="$CLIENTS" \
        --jobs="$JOBS" \
        --time="$benchmark_seconds" \
        --progress="$PROGRESS" \
        --random-seed="$SEED" \
        --define="run_id=$run_id" \
        --define="term_count=$term_count" \
        --define="batch_size=$BATCH_SIZE" \
        --define="record_samples=$benchmark_record_samples" \
        --file="$SCRIPT_DIR/workload.sql")

    if [[ -n "$benchmark_log" ]]; then
        "${benchmark_command[@]}" 2>&1 | tee "$benchmark_log"
    else
        "${benchmark_command[@]}"
    fi
}

run_throughput_pgbench() {
    local benchmark_log=$1
    local -a benchmark_command=(pgbench
        --dbname="$DATABASE_URL" \
        --no-vacuum \
        --protocol=prepared \
        --client="$CLIENTS" \
        --jobs="$JOBS" \
        --transactions=1 \
        --progress="$PROGRESS" \
        --random-seed="$SEED" \
        --define="run_id=$run_id" \
        --define="term_count=$term_count" \
        --define="chunk_size=$BATCH_SIZE" \
        --file="$SCRIPT_DIR/throughput-workload.sql")

    "${benchmark_command[@]}" 2>&1 | tee "$benchmark_log"
}

run_latency_pgbench() {
    local benchmark_log=$1
    local -a benchmark_command=(pgbench
        --dbname="$DATABASE_URL" \
        --no-vacuum \
        --protocol=prepared \
        --client="$CLIENTS" \
        --jobs="$JOBS" \
        --transactions=1 \
        --progress="$PROGRESS" \
        --random-seed="$SEED" \
        --define="run_id=$run_id" \
        --define="term_count=$term_count" \
        --define="chunk_size=$BATCH_SIZE" \
        --file="$SCRIPT_DIR/latency-workload.sql")

    "${benchmark_command[@]}" 2>&1 | tee "$benchmark_log"
}

run_prewarm() {
    local benchmark_phase=$1
    if ((PREWARM > 0)); then
        echo "Prewarming before $benchmark_phase for ${PREWARM}s with $CLIENTS clients"
        run_batched_pgbench "$PREWARM" 0
    fi
}

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
prefix="$OUTPUT_DIR/$timestamp-$BACKEND-$DATASET-$QUERY_SHAPE-$WORKLOAD-$QUERY_STYLE-run-$run_id"
throughput_worker_mismatch=0
latency_worker_mismatch=0
latency_error_count=0

if [[ "$MODE" == both || "$MODE" == throughput ]]; then
    run_prewarm throughput
    "${PSQL[@]}" -q -c \
        "SELECT local_timed.schedule_throughput($run_id, $THROUGHPUT_START_DELAY);" \
        >/dev/null
    echo "Measuring server-side throughput for ${DURATION}s with $CLIENTS workers and clock checks every $BATCH_SIZE queries"
    run_throughput_pgbench "$prefix-throughput-pgbench.log"

    throughput_worker_count=$("${PSQL[@]}" -Atq -c \
        "SELECT count(*) FROM local_timed.throughput_workers WHERE run_id = $run_id;")
    if [[ "$throughput_worker_count" != "$CLIENTS" ]]; then
        throughput_worker_mismatch=1
    fi
    "${PSQL[@]}" -q -v run_id="$run_id" -f "$SCRIPT_DIR/throughput-summary.sql" \
        >"$prefix-throughput-summary.csv"

    echo
    echo 'Server-side throughput result (no client round trips during the window):'
    sed -n '1,2p' "$prefix-throughput-summary.csv"
fi

if [[ "$MODE" == both || "$MODE" == latency ]]; then
    run_prewarm latency
    # MODE=both already used the per-run window tables for throughput. Its
    # report is on disk now, so replace those scratch rows with the latency
    # window and worker aggregates.
    if [[ "$MODE" == both ]]; then
        "${PSQL[@]}" -q -c \
            "DELETE FROM local_timed.throughput_windows WHERE run_id = $run_id;" \
            >/dev/null
    fi
    "${PSQL[@]}" -q -c \
        "SELECT local_timed.schedule_throughput($run_id, $THROUGHPUT_START_DELAY);" \
        >/dev/null
    "${PSQL[@]}" -q -c "SELECT local_timed.start_run($run_id);" >/dev/null

    echo "Measuring all-query server latency for ${DURATION}s with $CLIENTS synchronized workers and clock checks every $BATCH_SIZE queries"
    run_latency_pgbench "$prefix-latency-pgbench.log"

    latency_worker_count=$("${PSQL[@]}" -Atq -c \
        "SELECT count(*) FROM local_timed.throughput_workers WHERE run_id = $run_id;")
    if [[ "$latency_worker_count" != "$CLIENTS" ]]; then
        latency_worker_mismatch=1
    fi
    latency_error_count=$("${PSQL[@]}" -Atq -c \
        "SELECT count(*) FROM local_timed.samples WHERE run_id = $run_id AND NOT ok;")
fi

if ((throughput_worker_mismatch > 0 || latency_worker_mismatch > 0 || latency_error_count > 0)); then
    final_status=completed_with_errors
else
    final_status=completed
fi
"${PSQL[@]}" -q -c \
    "SELECT local_timed.finish_run($run_id, '$final_status');" >/dev/null
finalized=1

if [[ "$MODE" == both || "$MODE" == latency ]]; then
    "${PSQL[@]}" -q -v run_id="$run_id" -f "$SCRIPT_DIR/summary.sql" \
        >"$prefix-latency-summary.csv"
    "${PSQL[@]}" -q -v run_id="$run_id" -f "$SCRIPT_DIR/query-report.sql" \
        >"$prefix-queries.csv"
    "${PSQL[@]}" -q -v run_id="$run_id" -f "$SCRIPT_DIR/error-report.sql" \
        >"$prefix-errors.csv"

    echo
    echo 'All-query server-timed latency and throughput result:'
    sed -n '1,2p' "$prefix-latency-summary.csv"
    echo "Per-query report:  $prefix-queries.csv"
    echo "Error report:      $prefix-errors.csv"
fi

if [[ "$MODE" == both || "$MODE" == throughput ]]; then
    echo "Throughput summary: $prefix-throughput-summary.csv"
    echo "Throughput log:     $prefix-throughput-pgbench.log"
fi
if [[ "$MODE" == both || "$MODE" == latency ]]; then
    echo "Latency summary:    $prefix-latency-summary.csv"
    echo "Latency log:        $prefix-latency-pgbench.log"
fi

if ((throughput_worker_mismatch > 0)); then
    echo "throughput recorded $throughput_worker_count workers; expected $CLIENTS" >&2
    exit 1
fi
if ((latency_worker_mismatch > 0)); then
    echo "latency recorded $latency_worker_count workers; expected $CLIENTS" >&2
    exit 1
fi
if ((latency_error_count > 0)); then
    echo "$latency_error_count server-timed queries failed; see the error report" >&2
    exit 1
fi
