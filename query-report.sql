\set ON_ERROR_STOP on
COPY (
    SELECT
        sample.source_id,
        sample.style,
        term.query_text,
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
            AS max_ms,
        min(hit_count) FILTER (WHERE ok) AS min_hits,
        max(hit_count) FILTER (WHERE ok) AS max_hits
    FROM local_timed.samples AS sample
    JOIN local_timed.terms AS term
      ON term.run_id = sample.run_id
     AND term.source_id = sample.source_id
     AND term.style = sample.style
    WHERE sample.run_id = :run_id
    GROUP BY sample.source_id, sample.style, term.query_text
    ORDER BY p50_ms DESC NULLS LAST, sample.source_id, sample.style
) TO STDOUT WITH (FORMAT csv, HEADER true);
