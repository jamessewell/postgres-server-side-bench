\set first_term random(1, :term_count)
INSERT INTO local_timed.samples (
    run_id,
    source_id,
    style,
    recorded_at,
    backend_pid,
    elapsed_us,
    hit_count,
    ok,
    error_state,
    error_message
)
SELECT
    :run_id,
    term.source_id,
    term.style,
    clock_timestamp(),
    pg_backend_pid(),
    sample.sample_elapsed_us,
    sample.sample_hit_count,
    true,
    NULL,
    NULL
FROM local_timed.run_latency_window(
    :run_id,
    :first_term,
    :chunk_size
) AS sample
JOIN local_timed.terms AS term
  ON term.run_id = :run_id
 AND term.term_no = sample.sample_term_no;
