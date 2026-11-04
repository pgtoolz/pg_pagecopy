@brin
Feature: Approved BRIN indexes transfer as page images

  Physical transfer covers exactly the core ordinary minmax opclasses on
  int2/int4/int8/date/timestamp/timestamptz; every other BRIN index keeps
  degrading to a rebuildable definition.

  Scenario: A multi-range BRIN index with a nondefault pages_per_range stays valid and correct
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (
        id bigint,
        ts timestamptz,
        note text
      );
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = 4);
      INSERT INTO public.events
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i * 30),
             repeat('payload-' || i, 20)
      FROM generate_series(1, 5000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "t|t|1":
      """
      SELECT bool_and(indisvalid), bool_and(indisready), count(*)
      FROM pg_index WHERE indexrelid = 'public.events_brin'::regclass;
      """
    And the following SQL on "source" returns "49|5000":
      """
      SELECT count(*) FILTER (WHERE ts < timestamptz '2024-01-01 00:25:00'),
             count(*)
      FROM public.events;
      """
    And the following SQL on "target" returns "49|5000":
      """
      SELECT count(*) FILTER (WHERE ts < timestamptz '2024-01-01 00:25:00'),
             count(*)
      FROM public.events;
      """
    And the following SQL on "target" returns "50":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.events
      WHERE ts BETWEEN timestamptz '2024-01-01' AND timestamptz '2024-01-01 00:25:00';
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.events
      SELECT i, timestamptz '2024-01-02' + make_interval(secs => i), 'new'
      FROM generate_series(1, 500) AS i;
      DELETE FROM public.events WHERE id % 7 = 0;
      """
    And the following SQL is executed on "target":
      """
      VACUUM public.events;
      """
    Then the following SQL on "target" returns "4715":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.events
      WHERE ts >= timestamptz '2024-01-01' AND ts < timestamptz '2024-01-03';
      ROLLBACK;
      """
    And the following SQL on "target" returns "t":
      """
      SELECT indisvalid AND indisready
      FROM pg_index WHERE indexrelid = 'public.events_brin'::regclass;
      """

  Scenario: An empty BRIN index transfers its metapage-only geometry and stays maintained
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.empty_events (id integer, d date);
      CREATE INDEX empty_events_brin ON public.empty_events USING brin (d);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.empty_events', 'public.empty_events', true
      );
      """
    Then the following SQL on "target" returns "t|24576":
      """
      SELECT indisvalid AND indisready,
             pg_relation_size('public.empty_events_brin'::regclass)
      FROM pg_index WHERE indexrelid = 'public.empty_events_brin'::regclass;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.empty_events
      SELECT i, date '2024-01-01' + i FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "151|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*), (SELECT indisvalid AND indisready FROM pg_index
                        WHERE indexrelid = 'public.empty_events_brin'::regclass)
      FROM public.empty_events WHERE d < date '2024-06-01';
      ROLLBACK;
      """

  Scenario: Multi-column approved BRIN keys transfer physically
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.metrics (device bigint, recorded_at timestamp, small smallint);
      CREATE INDEX metrics_brin ON public.metrics
        USING brin (device int8_minmax_ops, recorded_at timestamp_minmax_ops, small int2_minmax_ops);
      INSERT INTO public.metrics
      SELECT device, timestamp '2024-01-01' + make_interval(secs => i * 7), (i % 100)::smallint
      FROM generate_series(1, 4000) AS i, generate_series(1, 3) AS device;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.metrics', 'public.metrics', true
      );
      """
    Then the following SQL on "target" returns "t|12000|1028":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.metrics_brin'::regclass),
             count(*),
             count(*) FILTER (WHERE device = 2
                              AND recorded_at < timestamp '2024-01-01 02:00:00')
      FROM public.metrics;
      """
    And the following SQL on "target" contains "metrics_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.metrics
      WHERE device = 2
        AND recorded_at < timestamp '2024-01-01 01:00:00'
        AND small = 3;
      ROLLBACK;
      """
    And the following SQL on "target" returns "6":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.metrics
      WHERE device = 2
        AND recorded_at < timestamp '2024-01-01 01:00:00'
        AND small = 3;
      ROLLBACK;
      """
    And the following SQL on "target" returns "6":
      """
      BEGIN;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.metrics
      WHERE device = 2
        AND recorded_at < timestamp '2024-01-01 01:00:00'
        AND small = 3;
      ROLLBACK;
      """

  Scenario: Mixed btree and approved BRIN indexes on one table all transfer physically
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.mixed (id integer PRIMARY KEY, ts timestamptz, note text);
      CREATE INDEX mixed_brin ON public.mixed USING brin (ts);
      CREATE INDEX mixed_note ON public.mixed USING btree (note);
      INSERT INTO public.mixed
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i * 60), 'note' || i
      FROM generate_series(1, 3000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.mixed', 'public.mixed', true
      );
      """
    Then the following SQL on "target" returns "3|3|0|1":
      """
      SELECT count(*),
             count(*) FILTER (WHERE indisvalid AND indisready),
             count(*) FILTER (WHERE NOT indisvalid OR NOT indisready),
             (SELECT count(*) FROM public.mixed WHERE note = 'note42')
      FROM pg_index WHERE indrelid = 'public.mixed'::regclass;
      """
    Then the following SQL on "target" returns "45":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.mixed
      WHERE ts BETWEEN timestamptz '2024-01-01 00:00:00'
               AND timestamptz '2024-01-01 00:45:00';
      ROLLBACK;
      """

  Scenario: Unsupported, expression and partial BRIN indexes still degrade to rebuildable definitions
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.degraded (id integer, body text, owner inet);
      CREATE INDEX degraded_text ON public.degraded USING brin (body);
      CREATE INDEX degraded_inet ON public.degraded USING brin (owner inet_inclusion_ops);
      CREATE INDEX degraded_expr ON public.degraded USING brin ((id + 1));
      CREATE INDEX degraded_partial ON public.degraded USING brin (id) WHERE id > 500;
      INSERT INTO public.degraded
      SELECT i, repeat('x', 100), ('10.0.' || i % 250 || '.1')::inet
      FROM generate_series(1, 1000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.degraded', 'public.degraded', true
      );
      """
    Then the following SQL on "target" returns "4|4|1000":
      """
      SELECT count(*),
             count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM public.degraded)
      FROM pg_index WHERE indrelid = 'public.degraded'::regclass;
      """
    And the following SQL on "source" returns "definition|definition":
      """
      SELECT (SELECT method FROM pagecopy.check('public.degraded')
              WHERE name LIKE 'degraded_text%'),
             (SELECT method FROM pagecopy.check('public.degraded')
              WHERE name LIKE 'degraded_inet%');
      """
    And the following SQL on "source" contains "brin opclass":
      """
      SELECT detail FROM pagecopy.check('public.degraded')
      WHERE name LIKE 'degraded_text%' AND type = 'index';
      """
    And the following SQL on "source" returns "brin expression or partial indexes are not transferred|brin expression or partial indexes are not transferred":
      """
      SELECT (SELECT detail FROM pagecopy.check('public.degraded')
              WHERE name LIKE 'degraded_expr%' AND type = 'index'),
             (SELECT detail FROM pagecopy.check('public.degraded')
              WHERE name LIKE 'degraded_partial%' AND type = 'index');
      """
    When the following SQL is executed on "target":
      """
      REINDEX TABLE public.degraded;
      """
    Then the following SQL on "target" returns "4|4":
      """
      SELECT count(*) FILTER (WHERE indisvalid AND indisready),
             (SELECT count(*) FROM public.degraded WHERE owner = '10.0.1.1')
      FROM pg_index WHERE indrelid = 'public.degraded'::regclass;
      """

  Scenario: A target BRIN index with different pages_per_range fails the transfer without touching the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id bigint, ts timestamptz);
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = 4);
      INSERT INTO public.events
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i)
      FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id bigint, ts timestamptz);
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = 8);
      INSERT INTO public.events VALUES (9999, timestamptz '2030-01-01');
      """
    Then the following SQL on "target" fails with "target lacks source index":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|9999|t|t|t":
      """
      SELECT (SELECT count(*) FROM public.events),
             (SELECT max(id) FROM public.events),
             (SELECT indisvalid FROM pg_index
              WHERE indexrelid = 'public.events_brin'::regclass),
             (SELECT indisready FROM pg_index
              WHERE indexrelid = 'public.events_brin'::regclass),
             (SELECT reloptions = ARRAY['pages_per_range=8'] FROM pg_class
              WHERE oid = 'public.events_brin'::regclass);
      """

  Scenario: A source catalog pages_per_range drift after ALTER INDEX is rejected
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id bigint, ts timestamptz);
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = 4);
      INSERT INTO public.events
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i)
      FROM generate_series(1, 500) AS i;
      ALTER INDEX public.events_brin SET (pages_per_range = 32);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id bigint, ts timestamptz);
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = 4);
      INSERT INTO public.events VALUES (9999, timestamptz '2030-01-01');
      """
    Then the following SQL on "target" fails with "brin catalog pages_per_range differs from the metapage":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|9999|t":
      """
      SELECT (SELECT count(*) FROM public.events),
             (SELECT max(id) FROM public.events),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.events_brin'::regclass);
      """

  Scenario Outline: A corrupted source BRIN metapage is rejected with "<detail>"
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id bigint, ts timestamptz);
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = 4);
      INSERT INTO public.events
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i)
      FROM generate_series(1, 500) AS i;
      CREATE FUNCTION pc_test_corrupt_index_byte(regclass, integer, integer)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_corrupt_index_byte'
        LANGUAGE C STRICT;
      SELECT pc_test_corrupt_index_byte('public.events_brin', 0, <offset>);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id bigint, ts timestamptz);
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = 4);
      INSERT INTO public.events VALUES (9999, timestamptz '2030-01-01');
      """
    Then the following SQL on "target" fails with "<detail>":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|9999|t":
      """
      SELECT (SELECT count(*) FROM public.events),
             (SELECT max(id) FROM public.events),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.events_brin'::regclass);
      """

    Examples:
      | offset | detail                                          |
      | 16     | brin page has an unexpected special area       |
      | 8190   | brin page has an unexpected type                |
      | 24     | brin metapage magic mismatch                    |
      | 32     | brin catalog pages_per_range differs from the metapage |
      | 37     | brin revmap exceeds the index size              |

  Scenario Outline: A corrupted incoming BRIN metapage fails verification on the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id bigint, ts timestamptz);
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = 4);
      INSERT INTO public.events
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i)
      FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id bigint, ts timestamptz);
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = 4);
      INSERT INTO public.events VALUES (9999, timestamptz '2030-01-01');
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = <offset>;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|9999|t":
      """
      SELECT (SELECT count(*) FROM public.events),
             (SELECT max(id) FROM public.events),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.events_brin'::regclass);
      """

    Examples:
      | offset |
      | 16     |
      | 8190   |
      | 24     |
      | 32     |
      | 37     |

  @wal
  Scenario: WAL full-page images restore BRIN revmap contents byte for byte
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (
        id bigint,
        ts timestamptz,
        note text
      );
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = 4);
      INSERT INTO public.events
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i * 30),
             repeat('payload-' || i, 40)
      FROM generate_series(1, 4000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CHECKPOINT;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And target relation "public.events_brin" block 1 is recorded
    And target postmaster is crashed
    And the recorded target data file is removed
    And target postmaster is started
    Then the recorded target block is unchanged after crash recovery
    And the following SQL on "target" returns "t|39":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.events_brin'::regclass),
             (SELECT count(*) FROM public.events
              WHERE ts < timestamptz '2024-01-01 00:20:00');
      """
