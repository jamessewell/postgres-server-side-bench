\set first_term random(1, :term_count)
SELECT local_timed.run_throughput_window(
    :run_id,
    :first_term,
    :chunk_size
);
