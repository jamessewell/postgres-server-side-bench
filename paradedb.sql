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
    IF p_query_shape <> 'text' THEN
        RAISE EXCEPTION 'unsupported documents query shape: %', p_query_shape;
    END IF;

    IF p_workload = 'count' THEN
        CASE p_style
            WHEN 'conjunction' THEN
                SELECT count(*) INTO v_count
                  FROM public.documents
                 WHERE body &&& p_query;
            WHEN 'disjunction' THEN
                SELECT count(*) INTO v_count
                  FROM public.documents
                 WHERE body ||| p_query;
            WHEN 'phrase' THEN
                SELECT count(*) INTO v_count
                  FROM public.documents
                 WHERE body ### p_query;
            ELSE
                RAISE EXCEPTION 'unsupported query style: %', p_style;
        END CASE;
    ELSIF p_workload = 'topk' THEN
        CASE p_style
            WHEN 'conjunction' THEN
                FOR v_hit IN
                    SELECT id, body, pdb.score(id) AS score
                      FROM public.documents
                     WHERE body &&& p_query
                     ORDER BY score DESC
                     LIMIT p_top_k
                LOOP
                    v_count := v_count + 1;
                END LOOP;
            WHEN 'disjunction' THEN
                FOR v_hit IN
                    SELECT id, body, pdb.score(id) AS score
                      FROM public.documents
                     WHERE body ||| p_query
                     ORDER BY score DESC
                     LIMIT p_top_k
                LOOP
                    v_count := v_count + 1;
                END LOOP;
            WHEN 'phrase' THEN
                FOR v_hit IN
                    SELECT id, body, pdb.score(id) AS score
                      FROM public.documents
                     WHERE body ### p_query
                     ORDER BY score DESC
                     LIMIT p_top_k
                LOOP
                    v_count := v_count + 1;
                END LOOP;
            ELSE
                RAISE EXCEPTION 'unsupported query style: %', p_style;
        END CASE;
    ELSE
        RAISE EXCEPTION 'unsupported workload: %', p_workload;
    END IF;

    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION local_timed.execute_one(text, text, text, text, integer, real) IS
    'ParadeDB executor. Fully consumes top-k rows inside PostgreSQL.';
