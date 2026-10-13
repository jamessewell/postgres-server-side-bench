\set ON_ERROR_STOP on
COPY (
    WITH sample_stats AS (
        SELECT
            run_id,
            count(*) FILTER (WHERE ok) AS successful_queries,
            count(*) FILTER (WHERE NOT ok) AS failed_queries,
            round((avg(elapsed_us) FILTER (WHERE ok) / 1000.0)::numeric, 3)
                AS mean_ms,
            round((min(elapsed_us) FILTER (WHERE ok) / 1000.0)::numeric, 3)
                AS min_ms,
            round((percentile_cont(0.50) WITHIN GROUP (ORDER BY elapsed_us)
                FILTER (WHERE ok) / 1000.0)::numeric, 3) AS p50_ms,
            round((percentile_cont(0.90) WITHIN GROUP (ORDER BY elapsed_us)
                FILTER (WHERE ok) / 1000.0)::numeric, 3) AS p90_ms,
            round((percentile_cont(0.95) WITHIN GROUP (ORDER BY elapsed_us)
                FILTER (WHERE ok) / 1000.0)::numeric, 3) AS p95_ms,
            round((percentile_cont(0.99) WITHIN GROUP (ORDER BY elapsed_us)
                FILTER (WHERE ok) / 1000.0)::numeric, 3) AS p99_ms,
            round((max(elapsed_us) FILTER (WHERE ok) / 1000.0)::numeric, 3)
                AS max_ms
        FROM local_timed.samples
        WHERE run_id = :run_id
        GROUP BY run_id
    ),
    worker_stats AS (
        SELECT
            tw.run_id,
            count(w.backend_pid) AS workers,
            round(extract(epoch FROM max(w.finished_at) - tw.scheduled_start)::numeric, 6)
                AS measurement_seconds,
            round((
                coalesce(sum(w.query_count), 0) /
                NULLIF(extract(epoch FROM max(w.finished_at) - tw.scheduled_start), 0)
            )::numeric, 3) AS query_throughput_per_s,
            round((
                extract(epoch FROM max(w.started_at) - min(w.started_at)) * 1000
            )::numeric, 3) AS worker_start_spread_ms,
            round(greatest(
                extract(epoch FROM max(w.finished_at) - tw.scheduled_end) * 1000,
                0
            )::numeric, 3) AS deadline_overrun_ms
        FROM local_timed.throughput_windows AS tw
        LEFT JOIN local_timed.throughput_workers AS w ON w.run_id = tw.run_id
        WHERE tw.run_id = :run_id
        GROUP BY tw.run_id, tw.scheduled_start, tw.scheduled_end
    )
    SELECT
        r.id AS run_id,
        r.backend,
        r.dataset,
        r.extension_version,
        r.workload,
        r.query_shape,
        r.query_style,
        r.termset_sha256,
        r.clients,
        r.jobs,
        r.batch_size AS clock_check_chunk,
        r.term_count,
        r.status,
        coalesce(s.successful_queries, 0) AS successful_queries,
        coalesce(s.failed_queries, 0) AS failed_queries,
        w.workers,
        w.measurement_seconds,
        w.query_throughput_per_s,
        w.worker_start_spread_ms,
        w.deadline_overrun_ms,
        s.mean_ms,
        s.min_ms,
        s.p50_ms,
        s.p90_ms,
        s.p95_ms,
        s.p99_ms,
        s.max_ms
    FROM local_timed.runs AS r
    LEFT JOIN sample_stats AS s ON s.run_id = r.id
    LEFT JOIN worker_stats AS w ON w.run_id = r.id
    WHERE r.id = :run_id
) TO STDOUT WITH (FORMAT csv, HEADER true);
