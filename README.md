# TIN vs. pg_search server-timed benchmark

This benchmark suite exists specifically to compare **TIN against ParadeDB's
`pg_search` PostgreSQL extension**. In the commands and output, the `tin`
backend selects TIN and the `paradedb` backend selects ParadeDB's `pg_search`.

For the background and analysis behind this comparison, read the two-part blog
series:

- [Opening a Closed TIN](https://paradedb.com/blog/opening-a-closed-tin)
- [Opening a Closed TIN, Part 2](https://paradedb.com/blog/opening-a-closed-tin-part-2)

## Why a separate harness?

Our main tool is the
[ParadeDB Benchmarker](https://github.com/paradedb/benchmarker), which is based
on k6. We did not use its normal client-timed k6 runner for this comparison
because PlanetScale makes TIN available only as a managed service. Comparing a
remote TIN service with a locally hosted ParadeDB container would otherwise
include two different network paths in the measurements. For the COUNT tests
in particular even the p99 measurements are under 4ms, so 1ms of lag makes a
difference.

This harness instead runs and times the search loop inside each PostgreSQL
server. That keeps the comparison focused on TIN versus `pg_search`, excluding
client/server round trips from the reported throughput and latency.

The standalone `pgbench` + PL/pgSQL harness uses the repository's existing
`queries.json` termsets or flat JSON string arrays and drives real PostgreSQL
connection concurrency. By default, it runs two independent measurements:

1. a synchronized server-side throughput phase with no client round trips,
   per-query clock, exception wrapper, or sample writes;
2. a synchronized all-query latency phase that preloads the termset, times
   every executor call, materializes compact samples in memory, and persists
   them only after the measured window closes.

The reported latency starts immediately before the search executor and stops
immediately after all result rows have been consumed. It excludes:

- the client/server network round trip;
- term selection and lookup;
- inserting the latency sample;
- transaction commit and `pgbench` bookkeeping.

For throughput, `pgbench` makes one call per worker. Each worker loads the
termset into a PostgreSQL array, waits for the same database-server timestamp,
and runs until the server-side deadline. The client/server network is therefore
outside the measurement. `CLIENTS` is the number of concurrent database
sessions. Each selected measurement gets its own unrecorded prewarm immediately
before it starts.

## Requirements

- PostgreSQL client tools (`psql` and `pgbench`);
- Python 3 (standard library only);
- a loaded `documents(id, body)` table and its existing TIN or `pg_search`
  index, or the Hacker News `hn_items` table and corresponding TIN or
  `pg_search` index;
- permission to create the `local_timed` schema in the benchmark database.

The harness does not start, stop, load, or alter the benchmark data table.
Start the desired database first. All harness files and local reports stay
under `local-timed`; database-side scratch objects stay in the `local_timed`
schema.

## Load the datasets

Load the same source data into both the TIN and `pg_search` databases before
running this harness. Use the benchmarker's loader to fetch the datasets and
prepare the database targets:

```bash
git clone https://github.com/paradedb/benchmarker.git
cd benchmarker && make

# POSTGRES_URL is the PlanetScale database with TIN
export PARADEDB_URL='postgres://USER:PASSWORD@PARADEDB_HOST:5432/benchmark'
export POSTGRES_URL='postgres://USER:PASSWORD@TIN_HOST:5432/benchmark'

# Stack Exchange
./bin/loader pull --dataset stackexchange --anonymous \
  --source s3://paradedb-benchmarker/datasets/stackexchange/
./bin/loader load --backend paradedb --pre-only ./datasets/stackexchange
./bin/loader load --backend postgres --pre-only ./datasets/stackexchange

psql "$PARADEDB_URL" -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE INDEX documents_body_bm25_idx ON documents
USING bm25 ((body::pdb.unicode_words('pnorms=true')))
WITH (target_segment_count=4, partition_by='ctid');
ANALYZE documents;
SQL

psql "$POSTGRES_URL" -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE INDEX documents_body_bm25_idx ON documents
USING tin (body) WITH (initial_segment_count=8);
CREATE INDEX documents_id_idx ON documents (id);
ANALYZE documents;
SQL

# Hacker News (28 million rows)
./bin/loader pull --dataset hn --anonymous \
  --source s3://paradedb-benchmarker/datasets/hn-benchmarker.tar.gz
./bin/loader load --backend paradedb --pre-only ./datasets/hn
./bin/loader load --backend postgres --pre-only ./datasets/hn

psql "$PARADEDB_URL" -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE INDEX hn_boolean_idx ON hn_items
USING bm25 (
  id, (title::pdb.unicode_words), (text::pdb.unicode_words),
  time, score, (type::pdb.literal), (by::pdb.literal),
  parent, descendants, dead, deleted
)
WITH (target_segment_count=4, partition_by='ctid');
ANALYZE hn_items;
SQL

psql "$POSTGRES_URL" -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE INDEX hn_items_text_bm25_idx ON hn_items
USING tin (text) WITH (initial_segment_count=4);
CREATE INDEX hn_items_by_idx ON hn_items (by);
CREATE INDEX hn_items_score ON hn_items (score);
CREATE INDEX hn_items_time ON hn_items (time);
ANALYZE hn_items;
SQL
```

`--pre-only` runs the dataset's pre-load setup and imports the rows without
running its post-load index script. The indexes above are created explicitly so
both databases use the configurations tested by this harness.

We aren't sure why PlanetScale sometimes use a `target_segment_count` of 4 and sometimes 8. We used 4 for ParadeDB because this is what the original benchmark did, but the setting will autotune.

See the benchmarker's [Data Loader guide](https://github.com/paradedb/benchmarker/blob/main/docs/loader.md)
for connection strings, supported data-source formats, and batch and worker
controls.

## Run it

`pg_search` (the `paradedb` backend) with the Stack Exchange termset:

```bash
./local-timed/run.sh \
  --backend paradedb \
  --url 'postgres://postgres:postgres@127.0.0.1:45432/benchmark' \
  --termset datasets/stackexchange/queries.json \
  --clients 32 \
  --jobs 8 \
  --duration 60 \
  --mode both \
  --query-style mixed
```

TIN:

```bash
./local-timed/run.sh \
  --backend tin \
  --url "$TIN_URL" \
  --termset datasets/stackexchange/queries.json \
  --clients 32 \
  --jobs 8 \
  --duration 60 \
  --query-style mixed \
  --dense-ratio 0.1
```

Hacker News filtered count (compare the `paradedb`/`pg_search` and `tin`
backends):

```bash
./local-timed/run.sh \
  --backend paradedb \
  --dataset hn \
  --url "$PARADEDB_URL" \
  --termset datasets/hn/k6/search_terms_1.json \
  --query-shape score_filter \
  --workload count \
  --query-style disjunction \
  --mode both
```

The Hacker News profile supports these combinations:

| Query shape | Workload | Query behavior |
| --- | --- | --- |
| `text` | `count`, `topk` | Unfiltered `text` search baseline |
| `score_filter` | `count`, `topk` | `text` search with `score > 10` |
| `time_sort` | `topk` | `text` search ordered by `time DESC NULLS LAST` |

Hacker News uses the flat term array without expanding it into query-style
variants. Its query style is therefore always `disjunction`, and the one-based
array position becomes the stable source ID in per-query reports. Both backends
search `hn_items.text`, so `pg_search` and TIN results cover the same field.

The equivalent Make interface is:

```bash
make -C local-timed run \
  BACKEND=paradedb \
  DATABASE_URL='postgres://postgres:postgres@127.0.0.1:45432/benchmark' \
  TERMSET=../datasets/stackexchange/queries.json \
  MODE=both CLIENTS=32 JOBS=8 DURATION=60 QUERY_STYLE=mixed
```

`DATABASE_URL` may be omitted when the matching existing `TIN_URL` or
`PARADEDB_URL` environment variable is set.

Durations are integer seconds. Important controls are:

| Variable | Default | Meaning |
| --- | ---: | --- |
| `MODE` | `both` | `both`, `throughput`, or `latency` |
| `DATASET` | `documents` | `documents` or `hn` |
| `CLIENTS` | `8` | Concurrent PostgreSQL sessions |
| `JOBS` | `CLIENTS` | Local pgbench worker threads |
| `DURATION` | `60` | Duration of each selected measurement phase |
| `PREWARM` | `10` | Unrecorded warm-up before each selected phase |
| `BATCH_SIZE` | `100` | Deadline-check interval for throughput and latency workers |
| `THROUGHPUT_START_DELAY` | `5` | Seconds allowed for every remote worker to reach the start barrier |
| `WORKLOAD` | `topk` | `topk` or `count` |
| `QUERY_SHAPE` | `text` | `text`, `score_filter`, or `time_sort` |
| `QUERY_STYLE` | `disjunction` | `conjunction`, `disjunction`, `phrase`, or `mixed` |
| `QUERY_IDS` | empty | Optional comma-separated source IDs |
| `TOP_K` | `10` | Rows fully consumed for a top-k search |
| `DENSE_RATIO` | `0.1` | TIN scoring dense ratio |
| `SEED` | `1592614637` | Existing deterministic term shuffle plus pgbench RNG seed |

The importer mirrors `benchmarks/queries.js`: it filters `QUERY_IDS`, expands
`mixed` into all three styles, and applies the same seeded shuffle. TIN receives
the termset's style-specific TINQL. `pg_search` (configured as the `paradedb`
backend) receives its `match` text while the PL/pgSQL executor chooses `&&&`,
`|||`, or `###` for the requested style.
Flat arrays, such as the Hacker News termset, preserve each string exactly,
support `QUERY_IDS`, and use the same seeded shuffle without style expansion.

## Results

With `MODE=both`, each run writes these reports to `local-timed/out/` (or
`OUTPUT_DIR`):

- `*-throughput-summary.csv`: server-timed query count, worker synchronization,
  deadline overrun, and throughput;
- `*-throughput-pgbench.log`: driver statistics for the throughput phase;
- `*-latency-summary.csv`: synchronized query throughput, server-timed mean,
  min, p50, p90, p95, p99, max, and sample counts;
- `*-queries.csv`: the same latency statistics and hit counts by source
  ID/style, including the query text;
- `*-errors.csv`: grouped SQLSTATE and error messages;
- `*-latency-pgbench.log`: driver statistics for the latency phase, whose
  transaction latency includes the synchronized window, post-window sample
  persistence, and network transfer and is therefore not the latency result.

The throughput result is the sum of the server-side worker counts divided by
the database-server wall time from the synchronized start until the last worker
finishes. Terms are loaded before that start. During the measured window there
are no client round trips, per-query clocks, exception blocks, sample writes,
or term-table lookups. A search error aborts its worker and fails the run.

The authoritative latency columns are the CSV values derived from
`local_timed.samples.elapsed_us`. Top-k executors iterate every returned row
inside PostgreSQL so the search is fully consumed without serializing those
rows over the network. Each worker materializes compact
sample rows in a server-side tuplestore and the outer statement inserts them
only after the measured window closes. The hot loop has no term-table lookups,
client round trips, commits, or sample-table writes. To avoid a subtransaction
around every query, a search error aborts its worker and fails the run, matching
throughput-mode semantics.

Run summaries include the dataset, query shape, and SHA-256 of the exact
termset file so results remain identifiable when an external termset changes.

For most comparisons, use `MODE=latency`. It reports synchronized query
throughput as well as the latency distribution and per-query breakdown, and in
practice its throughput is very close to the dedicated throughput mode. A
separate throughput run is therefore normally unnecessary.

Use `MODE=throughput` only when maximum clean throughput without per-query
timing and sample collection matters. `MODE=both` runs throughput first and
latency second so the small instrumentation difference can be inspected; the
two results must not be combined into a single throughput number.

`BATCH_SIZE` controls how often a throughput or latency worker checks the
server deadline. A worker finishes its current chunk, and
`measurement_seconds` includes that overrun. Reduce it for a sharper stop;
increase it to make the deadline check less frequent. Latency mode still reads
the clock around every executor call, independent of this setting.

Run the local tests with:

```bash
make -C local-timed test
```

To remove all database-side harness history and functions when no run is active:

```sql
DROP SCHEMA local_timed CASCADE;
```
