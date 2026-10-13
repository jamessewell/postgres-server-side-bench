\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS local_timed;

CREATE TABLE IF NOT EXISTS local_timed.runs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    started_at timestamptz,
    finished_at timestamptz,
    backend text NOT NULL CHECK (backend IN ('tin', 'paradedb')),
    dataset text NOT NULL DEFAULT 'documents'
        CONSTRAINT local_timed_runs_dataset_check
        CHECK (dataset IN ('documents', 'hn')),
    workload text NOT NULL CHECK (workload IN ('topk', 'count')),
    query_shape text NOT NULL DEFAULT 'text'
        CONSTRAINT local_timed_runs_query_shape_check
        CHECK (query_shape IN ('text', 'score_filter', 'time_sort')),
    query_style text NOT NULL CHECK (
        query_style IN ('conjunction', 'disjunction', 'phrase', 'mixed')
    ),
    clients integer NOT NULL CHECK (clients > 0),
    jobs integer NOT NULL CHECK (jobs > 0),
    duration_s integer NOT NULL CHECK (duration_s > 0),
    prewarm_s integer NOT NULL CHECK (prewarm_s >= 0),
    batch_size integer NOT NULL CHECK (batch_size > 0),
    top_k integer NOT NULL CHECK (top_k > 0),
    dense_ratio real NOT NULL CHECK (dense_ratio >= 0 AND dense_ratio <= 1),
    seed bigint NOT NULL CHECK (seed >= 0 AND seed <= 4294967295),
    term_count integer NOT NULL DEFAULT 0 CHECK (term_count >= 0),
    status text NOT NULL DEFAULT 'loading' CHECK (
        status IN (
            'loading',
            'ready',
            'running',
            'completed',
            'completed_with_errors',
            'failed'
        )
    ),
    postgres_version text NOT NULL DEFAULT current_setting('server_version'),
    extension_version text,
    termset_sha256 text
        CONSTRAINT local_timed_runs_termset_sha256_check
        CHECK (termset_sha256 IS NULL OR termset_sha256 ~ '^[0-9a-f]{64}$')
);

-- Keep installation idempotent for databases that already have run history
-- from the original documents-only harness.
ALTER TABLE local_timed.runs
    ADD COLUMN IF NOT EXISTS dataset text NOT NULL DEFAULT 'documents';
ALTER TABLE local_timed.runs
    ADD COLUMN IF NOT EXISTS query_shape text NOT NULL DEFAULT 'text';
ALTER TABLE local_timed.runs
    ADD COLUMN IF NOT EXISTS termset_sha256 text;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM pg_catalog.pg_constraint
         WHERE conname = 'local_timed_runs_dataset_check'
           AND conrelid = 'local_timed.runs'::regclass
    ) THEN
        ALTER TABLE local_timed.runs
            ADD CONSTRAINT local_timed_runs_dataset_check
            CHECK (dataset IN ('documents', 'hn'));
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM pg_catalog.pg_constraint
         WHERE conname = 'local_timed_runs_query_shape_check'
           AND conrelid = 'local_timed.runs'::regclass
    ) THEN
        ALTER TABLE local_timed.runs
            ADD CONSTRAINT local_timed_runs_query_shape_check
            CHECK (query_shape IN ('text', 'score_filter', 'time_sort'));
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM pg_catalog.pg_constraint
         WHERE conname = 'local_timed_runs_termset_sha256_check'
           AND conrelid = 'local_timed.runs'::regclass
    ) THEN
        ALTER TABLE local_timed.runs
            ADD CONSTRAINT local_timed_runs_termset_sha256_check
            CHECK (
                termset_sha256 IS NULL
                OR termset_sha256 ~ '^[0-9a-f]{64}$'
            );
    END IF;
END;
$$;

-- These tables deliberately avoid WAL. They are benchmark scratch data, and
-- WAL or synchronous-commit work for benchmark scratch data would throttle the
-- closed-loop driver even though it is outside the in-server timer.
CREATE UNLOGGED TABLE IF NOT EXISTS local_timed.terms (
    run_id bigint NOT NULL REFERENCES local_timed.runs(id) ON DELETE CASCADE,
    term_no integer NOT NULL CHECK (term_no > 0),
    source_id bigint NOT NULL CHECK (source_id > 0),
    style text NOT NULL CHECK (style IN ('conjunction', 'disjunction', 'phrase')),
    query_text text NOT NULL,
    PRIMARY KEY (run_id, term_no)
);

CREATE UNLOGGED TABLE IF NOT EXISTS local_timed.samples (
    run_id bigint NOT NULL,
    source_id bigint NOT NULL,
    style text NOT NULL,
    recorded_at timestamptz NOT NULL,
    backend_pid integer NOT NULL,
    elapsed_us bigint NOT NULL CHECK (elapsed_us >= 0),
    hit_count bigint,
    ok boolean NOT NULL,
    error_state text,
    error_message text
);

-- Throughput workers receive one synchronized server-side window. They load
-- the termset before the window opens, execute without client round trips, and
-- persist only one aggregate row after their window closes.
CREATE UNLOGGED TABLE IF NOT EXISTS local_timed.throughput_windows (
    run_id bigint PRIMARY KEY REFERENCES local_timed.runs(id) ON DELETE CASCADE,
    scheduled_start timestamptz NOT NULL,
    scheduled_end timestamptz NOT NULL,
    CHECK (scheduled_end > scheduled_start)
);

CREATE UNLOGGED TABLE IF NOT EXISTS local_timed.throughput_workers (
    run_id bigint NOT NULL REFERENCES local_timed.throughput_windows(run_id)
        ON DELETE CASCADE,
    backend_pid integer NOT NULL,
    arrived_at timestamptz NOT NULL,
    started_at timestamptz NOT NULL,
    finished_at timestamptz NOT NULL,
    first_term integer NOT NULL,
    chunk_size integer NOT NULL CHECK (chunk_size > 0),
    query_count bigint NOT NULL CHECK (query_count >= 0),
    PRIMARY KEY (run_id, backend_pid),
    CHECK (finished_at >= started_at)
);

-- BRIN keeps later reporting practical with much less write amplification than
-- a per-sample btree. Sample insertion itself is outside elapsed_us.
CREATE INDEX IF NOT EXISTS local_timed_samples_run_brin
    ON local_timed.samples USING brin (run_id) WITH (pages_per_range = 32);

CREATE OR REPLACE FUNCTION local_timed.create_run(
    p_backend text,
    p_dataset text,
    p_workload text,
    p_query_shape text,
    p_query_style text,
    p_clients integer,
    p_jobs integer,
    p_duration_s integer,
    p_prewarm_s integer,
    p_batch_size integer,
    p_top_k integer,
    p_dense_ratio real,
    p_seed bigint,
    p_termset_sha256 text
) RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, public, local_timed
AS $$
DECLARE
    v_id bigint;
    v_extension text;
BEGIN
    IF p_backend NOT IN ('tin', 'paradedb') THEN
        RAISE EXCEPTION 'unsupported backend: %', p_backend;
    END IF;
    IF p_dataset NOT IN ('documents', 'hn') THEN
        RAISE EXCEPTION 'unsupported dataset: %', p_dataset;
    END IF;
    IF p_workload NOT IN ('topk', 'count') THEN
        RAISE EXCEPTION 'unsupported workload: %', p_workload;
    END IF;
    IF p_query_shape NOT IN ('text', 'score_filter', 'time_sort') THEN
        RAISE EXCEPTION 'unsupported query shape: %', p_query_shape;
    END IF;
    IF p_query_style NOT IN ('conjunction', 'disjunction', 'phrase', 'mixed') THEN
        RAISE EXCEPTION 'unsupported query style: %', p_query_style;
    END IF;
    IF p_termset_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'invalid termset SHA-256';
    END IF;
    IF p_dataset = 'documents' AND p_query_shape <> 'text' THEN
        RAISE EXCEPTION 'documents only supports text query shape';
    END IF;
    IF p_dataset = 'hn' THEN
        IF p_query_style <> 'disjunction' THEN
            RAISE EXCEPTION 'Hacker News only supports disjunction query style';
        END IF;
        IF p_query_shape = 'time_sort' AND p_workload <> 'topk' THEN
            RAISE EXCEPTION 'time_sort only supports topk workload';
        END IF;
    END IF;

    SELECT extversion
      INTO v_extension
      FROM pg_catalog.pg_extension
     WHERE extname = CASE p_backend WHEN 'tin' THEN 'tin' ELSE 'pg_search' END;

    IF v_extension IS NULL THEN
        RAISE EXCEPTION 'required extension is not installed for backend %', p_backend;
    END IF;

    INSERT INTO local_timed.runs (
        backend, dataset, workload, query_shape, query_style, clients, jobs,
        duration_s, prewarm_s, batch_size, top_k, dense_ratio, seed,
        extension_version, termset_sha256
    ) VALUES (
        p_backend, p_dataset, p_workload, p_query_shape, p_query_style,
        p_clients, p_jobs, p_duration_s, p_prewarm_s, p_batch_size, p_top_k,
        p_dense_ratio, p_seed, v_extension, p_termset_sha256
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION local_timed.seal_run(p_run_id bigint)
RETURNS integer
LANGUAGE plpgsql
SET search_path = pg_catalog, public, local_timed
AS $$
DECLARE
    v_count integer;
    v_min integer;
    v_max integer;
BEGIN
    SELECT count(*)::integer, min(term_no), max(term_no)
      INTO v_count, v_min, v_max
      FROM local_timed.terms
     WHERE run_id = p_run_id;

    IF v_count = 0 OR v_min <> 1 OR v_max <> v_count THEN
        RAISE EXCEPTION 'run % has an empty or non-contiguous termset', p_run_id;
    END IF;

    UPDATE local_timed.runs
       SET term_count = v_count,
           status = 'ready'
     WHERE id = p_run_id
       AND status = 'loading';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'run % is not in loading state', p_run_id;
    END IF;

    RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION local_timed.start_run(p_run_id bigint)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, public, local_timed
AS $$
BEGIN
    UPDATE local_timed.runs
       SET started_at = clock_timestamp(),
           finished_at = NULL,
           status = 'running'
     WHERE id = p_run_id
       AND status = 'ready';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'run % is not ready', p_run_id;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION local_timed.finish_run(
    p_run_id bigint,
    p_status text
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, public, local_timed
AS $$
BEGIN
    IF p_status NOT IN ('completed', 'completed_with_errors', 'failed') THEN
        RAISE EXCEPTION 'invalid final status: %', p_status;
    END IF;

    UPDATE local_timed.runs
       SET finished_at = clock_timestamp(),
           status = p_status
     WHERE id = p_run_id
       AND status IN ('loading', 'ready', 'running');

    IF NOT FOUND THEN
        RAISE EXCEPTION 'run % cannot be finalized', p_run_id;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION local_timed.schedule_throughput(
    p_run_id bigint,
    p_delay_s integer
) RETURNS timestamptz
LANGUAGE plpgsql
SET search_path = pg_catalog, public, local_timed
AS $$
DECLARE
    v_run local_timed.runs%ROWTYPE;
    v_start timestamptz;
BEGIN
    SELECT * INTO STRICT v_run
      FROM local_timed.runs
     WHERE id = p_run_id;

    IF v_run.status <> 'ready' THEN
        RAISE EXCEPTION 'run % is not ready for throughput', p_run_id;
    END IF;
    IF p_delay_s <= 0 THEN
        RAISE EXCEPTION 'throughput start delay must be positive';
    END IF;

    v_start := clock_timestamp() + p_delay_s * interval '1 second';
    INSERT INTO local_timed.throughput_windows (
        run_id, scheduled_start, scheduled_end
    ) VALUES (
        p_run_id,
        v_start,
        v_start + v_run.duration_s * interval '1 second'
    );

    RETURN v_start;
END;
$$;

-- Run a complete throughput phase inside one server call. The only clock read
-- in the hot loop is at a chunk boundary; individual queries have no timer,
-- exception subtransaction, sample write, term-table lookup, or network wait.
CREATE OR REPLACE FUNCTION local_timed.run_throughput_window(
    p_run_id bigint,
    p_first_term integer,
    p_chunk_size integer
) RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, public, local_timed
AS $$
DECLARE
    v_run local_timed.runs%ROWTYPE;
    v_window local_timed.throughput_windows%ROWTYPE;
    v_styles text[];
    v_queries text[];
    v_term_no integer := p_first_term;
    v_query_count bigint := 0;
    v_arrived_at timestamptz;
    v_started_at timestamptz;
    v_finished_at timestamptz;
BEGIN
    SELECT * INTO STRICT v_run
      FROM local_timed.runs
     WHERE id = p_run_id;
    SELECT * INTO STRICT v_window
      FROM local_timed.throughput_windows
     WHERE run_id = p_run_id;

    IF v_run.status <> 'ready' THEN
        RAISE EXCEPTION 'run % is not ready for throughput', p_run_id;
    END IF;
    IF p_first_term < 1 OR p_first_term > v_run.term_count THEN
        RAISE EXCEPTION 'first term % is outside 1..%', p_first_term, v_run.term_count;
    END IF;
    IF p_chunk_size <= 0 THEN
        RAISE EXCEPTION 'throughput chunk size must be positive';
    END IF;

    SELECT array_agg(style ORDER BY term_no),
           array_agg(query_text ORDER BY term_no)
      INTO v_styles, v_queries
      FROM local_timed.terms
     WHERE run_id = p_run_id;

    IF cardinality(v_queries) <> v_run.term_count THEN
        RAISE EXCEPTION 'run % termset changed after it was sealed', p_run_id;
    END IF;

    v_arrived_at := clock_timestamp();
    IF v_arrived_at >= v_window.scheduled_start THEN
        RAISE EXCEPTION 'throughput worker arrived after the synchronized start';
    END IF;

    PERFORM pg_sleep(extract(epoch FROM v_window.scheduled_start - v_arrived_at));
    v_started_at := clock_timestamp();

    WHILE clock_timestamp() < v_window.scheduled_end LOOP
        FOR v_offset IN 0..p_chunk_size - 1 LOOP
            PERFORM local_timed.execute_one(
                v_run.workload,
                v_run.query_shape,
                v_styles[v_term_no],
                v_queries[v_term_no],
                v_run.top_k,
                v_run.dense_ratio
            );
            v_query_count := v_query_count + 1;
            v_term_no := (v_term_no % v_run.term_count) + 1;
        END LOOP;
    END LOOP;

    v_finished_at := clock_timestamp();
    INSERT INTO local_timed.throughput_workers (
        run_id, backend_pid, arrived_at, started_at, finished_at,
        first_term, chunk_size, query_count
    ) VALUES (
        p_run_id, pg_backend_pid(), v_arrived_at, v_started_at, v_finished_at,
        p_first_term, p_chunk_size, v_query_count
    );

    RETURN v_query_count;
END;
$$;

-- Run a complete all-query latency phase inside one server call. Terms are
-- loaded before the synchronized window. Every executor call is timed, but
-- the compact result rows stay in PL/pgSQL's tuplestore until the function
-- finishes; the caller persists them only after the measured window closes.
-- Errors deliberately abort the worker, matching throughput-mode semantics
-- and avoiding an exception subtransaction around every query.
CREATE OR REPLACE FUNCTION local_timed.run_latency_window(
    p_run_id bigint,
    p_first_term integer,
    p_chunk_size integer
) RETURNS TABLE (
    sample_term_no integer,
    sample_elapsed_us bigint,
    sample_hit_count bigint
)
LANGUAGE plpgsql
SET search_path = pg_catalog, public, local_timed
AS $$
DECLARE
    v_run local_timed.runs%ROWTYPE;
    v_window local_timed.throughput_windows%ROWTYPE;
    v_styles text[];
    v_queries text[];
    v_term_no integer := p_first_term;
    v_query_count bigint := 0;
    v_query_started timestamptz;
    v_arrived_at timestamptz;
    v_started_at timestamptz;
    v_finished_at timestamptz;
BEGIN
    SELECT * INTO STRICT v_run
      FROM local_timed.runs
     WHERE id = p_run_id;
    SELECT * INTO STRICT v_window
      FROM local_timed.throughput_windows
     WHERE run_id = p_run_id;

    IF v_run.status <> 'running' THEN
        RAISE EXCEPTION 'run % is not running for latency', p_run_id;
    END IF;
    IF p_first_term < 1 OR p_first_term > v_run.term_count THEN
        RAISE EXCEPTION 'first term % is outside 1..%', p_first_term, v_run.term_count;
    END IF;
    IF p_chunk_size <= 0 THEN
        RAISE EXCEPTION 'latency clock-check chunk size must be positive';
    END IF;

    SELECT array_agg(style ORDER BY term_no),
           array_agg(query_text ORDER BY term_no)
      INTO v_styles, v_queries
      FROM local_timed.terms
     WHERE run_id = p_run_id;

    IF cardinality(v_queries) <> v_run.term_count THEN
        RAISE EXCEPTION 'run % termset changed after it was sealed', p_run_id;
    END IF;

    v_arrived_at := clock_timestamp();
    IF v_arrived_at >= v_window.scheduled_start THEN
        RAISE EXCEPTION 'latency worker arrived after the synchronized start';
    END IF;

    PERFORM pg_sleep(extract(epoch FROM v_window.scheduled_start - v_arrived_at));
    v_started_at := clock_timestamp();

    WHILE clock_timestamp() < v_window.scheduled_end LOOP
        FOR v_offset IN 0..p_chunk_size - 1 LOOP
            sample_term_no := v_term_no;
            v_query_started := clock_timestamp();
            sample_hit_count := local_timed.execute_one(
                v_run.workload,
                v_run.query_shape,
                v_styles[v_term_no],
                v_queries[v_term_no],
                v_run.top_k,
                v_run.dense_ratio
            );
            sample_elapsed_us := (
                extract(epoch FROM clock_timestamp() - v_query_started) * 1000000
            )::bigint;
            RETURN NEXT;

            v_query_count := v_query_count + 1;
            v_term_no := (v_term_no % v_run.term_count) + 1;
        END LOOP;
    END LOOP;

    v_finished_at := clock_timestamp();
    INSERT INTO local_timed.throughput_workers (
        run_id, backend_pid, arrived_at, started_at, finished_at,
        first_term, chunk_size, query_count
    ) VALUES (
        p_run_id, pg_backend_pid(), v_arrived_at, v_started_at, v_finished_at,
        p_first_term, p_chunk_size, v_query_count
    );

    RETURN;
END;
$$;

-- execute_one() is installed from a backend/dataset-specific SQL file. Keeping
-- its search statement static gives each server session a cached plan after
-- first use.
CREATE OR REPLACE FUNCTION local_timed.run_batch(
    p_run_id bigint,
    p_first_term integer,
    p_batch_size integer,
    p_record_samples integer
) RETURNS integer
LANGUAGE plpgsql
SET search_path = pg_catalog, public, local_timed
AS $$
DECLARE
    v_run local_timed.runs%ROWTYPE;
    v_term_no integer;
    v_source_id bigint;
    v_style text;
    v_query_text text;
    v_started timestamptz;
    v_elapsed_us bigint;
    v_hit_count bigint;
    v_ok boolean;
    v_error_state text;
    v_error_message text;
    v_source_ids bigint[] := ARRAY[]::bigint[];
    v_styles text[] := ARRAY[]::text[];
    v_recorded_ats timestamptz[] := ARRAY[]::timestamptz[];
    v_elapsed_uses bigint[] := ARRAY[]::bigint[];
    v_hit_counts bigint[] := ARRAY[]::bigint[];
    v_oks boolean[] := ARRAY[]::boolean[];
    v_error_states text[] := ARRAY[]::text[];
    v_error_messages text[] := ARRAY[]::text[];
BEGIN
    SELECT * INTO STRICT v_run
      FROM local_timed.runs
     WHERE id = p_run_id;

    IF v_run.term_count <= 0 THEN
        RAISE EXCEPTION 'run % has no sealed termset', p_run_id;
    END IF;
    IF p_first_term < 1 OR p_first_term > v_run.term_count THEN
        RAISE EXCEPTION 'first term % is outside 1..%', p_first_term, v_run.term_count;
    END IF;
    IF p_batch_size <= 0 THEN
        RAISE EXCEPTION 'batch size must be positive';
    END IF;
    IF p_record_samples NOT IN (0, 1) THEN
        RAISE EXCEPTION 'record_samples must be 0 or 1';
    END IF;
    IF p_record_samples <> 0 AND v_run.status <> 'running' THEN
        RAISE EXCEPTION 'run % is not in running state', p_run_id;
    END IF;

    FOR v_offset IN 0..p_batch_size - 1 LOOP
        v_term_no := ((p_first_term - 1 + v_offset) % v_run.term_count) + 1;

        SELECT source_id, style, query_text
          INTO STRICT v_source_id, v_style, v_query_text
          FROM local_timed.terms
         WHERE run_id = p_run_id
           AND term_no = v_term_no;

        -- The throughput/prewarm path deliberately does no per-query timing,
        -- exception handling, or sample writes. An executor error aborts the
        -- whole pgbench transaction and is counted as a failed batch.
        IF p_record_samples = 0 THEN
            PERFORM local_timed.execute_one(
                v_run.workload,
                v_run.query_shape,
                v_style,
                v_query_text,
                v_run.top_k,
                v_run.dense_ratio
            );
            CONTINUE;
        END IF;

        v_hit_count := NULL;
        v_ok := true;
        v_error_state := NULL;
        v_error_message := NULL;

        -- The timer intentionally surrounds only the backend executor. Term
        -- lookup, sample insertion, commits, pgbench, and the network are out.
        BEGIN
            v_started := clock_timestamp();
            v_hit_count := local_timed.execute_one(
                v_run.workload,
                v_run.query_shape,
                v_style,
                v_query_text,
                v_run.top_k,
                v_run.dense_ratio
            );
            v_elapsed_us := (
                extract(epoch FROM clock_timestamp() - v_started) * 1000000
            )::bigint;
        EXCEPTION WHEN OTHERS THEN
            v_elapsed_us := (
                extract(epoch FROM clock_timestamp() - v_started) * 1000000
            )::bigint;
            v_ok := false;
            GET STACKED DIAGNOSTICS
                v_error_state = RETURNED_SQLSTATE,
                v_error_message = MESSAGE_TEXT;
        END;

        v_source_ids := array_append(v_source_ids, v_source_id);
        v_styles := array_append(v_styles, v_style);
        v_recorded_ats := array_append(v_recorded_ats, clock_timestamp());
        v_elapsed_uses := array_append(v_elapsed_uses, v_elapsed_us);
        v_hit_counts := array_append(v_hit_counts, v_hit_count);
        v_oks := array_append(v_oks, v_ok);
        v_error_states := array_append(v_error_states, v_error_state);
        v_error_messages := array_append(v_error_messages, v_error_message);
    END LOOP;

    -- Keep sample persistence outside every individual query timer and pay
    -- the SQL/index maintenance overhead once per batch rather than once per
    -- query. All arrays have exactly p_batch_size elements.
    IF p_record_samples = 1 THEN
        INSERT INTO local_timed.samples (
            run_id, source_id, style, recorded_at, backend_pid,
            elapsed_us, hit_count, ok, error_state, error_message
        )
        SELECT
            p_run_id,
            sample.source_id,
            sample.style,
            sample.recorded_at,
            pg_backend_pid(),
            sample.elapsed_us,
            sample.hit_count,
            sample.ok,
            sample.error_state,
            sample.error_message
        FROM unnest(
            v_source_ids,
            v_styles,
            v_recorded_ats,
            v_elapsed_uses,
            v_hit_counts,
            v_oks,
            v_error_states,
            v_error_messages
        ) AS sample(
            source_id,
            style,
            recorded_at,
            elapsed_us,
            hit_count,
            ok,
            error_state,
            error_message
        );
    END IF;

    RETURN p_batch_size;
END;
$$;
