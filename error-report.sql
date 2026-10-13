\set ON_ERROR_STOP on
COPY (
    SELECT
        source_id,
        style,
        error_state,
        error_message,
        count(*) AS occurrences
    FROM local_timed.samples
    WHERE run_id = :run_id
      AND NOT ok
    GROUP BY source_id, style, error_state, error_message
    ORDER BY occurrences DESC, source_id, style
) TO STDOUT WITH (FORMAT csv, HEADER true);
