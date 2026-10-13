\set first_term random(1, :term_count)
SELECT local_timed.run_batch(
    :run_id,
    :first_term,
    :batch_size,
    :record_samples
);
