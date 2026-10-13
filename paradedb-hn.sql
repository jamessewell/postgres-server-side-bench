\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION local_timed.execute_one(
    p_workload text,
    p_query_shape text,
    p_style text,
    p_query text,
    p_top_k integer,
    p_dense_ratio real
) RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, public, local_timed
AS $$
DECLARE
    v_count bigint := 0;
    v_hit record;
BEGIN
    IF p_style <> 'disjunction' THEN
        RAISE EXCEPTION 'Hacker News only supports disjunction query style';
    END IF;

    IF p_query_shape = 'text' THEN
        IF p_workload = 'count' THEN
            SELECT count(*) INTO v_count
              FROM public.hn_items
             WHERE text ||| p_query;
        ELSIF p_workload = 'topk' THEN
            FOR v_hit IN
                SELECT id, text, "by", score, pdb.score(id) AS relevance
                  FROM public.hn_items
                 WHERE text ||| p_query
                 ORDER BY relevance DESC
                 LIMIT p_top_k
            LOOP
                v_count := v_count + 1;
            END LOOP;
        ELSE
            RAISE EXCEPTION 'unsupported workload: %', p_workload;
        END IF;
    ELSIF p_query_shape = 'score_filter' THEN
        IF p_workload = 'count' THEN
            SELECT count(*) INTO v_count
              FROM public.hn_items
             WHERE text ||| p_query
               AND score > 10;
        ELSIF p_workload = 'topk' THEN
            FOR v_hit IN
                SELECT id, text, "by", score, pdb.score(id) AS relevance
                  FROM public.hn_items
                 WHERE text ||| p_query
                   AND score > 10
                 ORDER BY relevance DESC
                 LIMIT p_top_k
            LOOP
                v_count := v_count + 1;
            END LOOP;
        ELSE
            RAISE EXCEPTION 'unsupported workload: %', p_workload;
        END IF;
    ELSIF p_query_shape = 'time_sort' THEN
        IF p_workload <> 'topk' THEN
            RAISE EXCEPTION 'time_sort only supports topk workload';
        END IF;

        FOR v_hit IN
            SELECT id, text, "by", score, "time"
              FROM public.hn_items
             WHERE text ||| p_query
             ORDER BY "time" DESC NULLS LAST
             LIMIT p_top_k
        LOOP
            v_count := v_count + 1;
        END LOOP;
    ELSE
        RAISE EXCEPTION 'unsupported Hacker News query shape: %', p_query_shape;
    END IF;

    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION local_timed.execute_one(text, text, text, text, integer, real) IS
    'ParadeDB Hacker News executor. Fully consumes top-k rows inside PostgreSQL.';
