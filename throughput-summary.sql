\set ON_ERROR_STOP on
COPY (
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
        count(w.backend_pid) AS workers,
        coalesce(sum(w.query_count), 0) AS successful_queries,
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
        )::numeric, 3) AS deadline_overrun_ms,
        min(w.query_count) AS min_worker_queries,
        max(w.query_count) AS max_worker_queries
    FROM local_timed.runs AS r
    JOIN local_timed.throughput_windows AS tw ON tw.run_id = r.id
    LEFT JOIN local_timed.throughput_workers AS w ON w.run_id = r.id
    WHERE r.id = :run_id
    GROUP BY r.id, tw.scheduled_start, tw.scheduled_end
) TO STDOUT WITH (FORMAT csv, HEADER true);
