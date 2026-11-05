@cross-major @gist
Feature: Approved GIST indexes transfer across major upgrades

  The core point_ops key format (the 16-byte point and its box unions)
  has been stable across PostgreSQL 13-18, and every source support
  procedure must resolve to the same function OID on the target, so the
  approved pairs cross every upward combination as page images.

  Scenario Outline: PostgreSQL <source_major> to <target_major> transfers a point GIST index with checksums <checksums> and WAL <wal>
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "<checksums>"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        loc point
      );
      CREATE INDEX events_gist ON public.events USING gist (loc);
      INSERT INTO public.events
      SELECT i, point((i % 199) - 99, ((i * 13) % 197) - 98)
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
        'public.events', 'public.events', <wal>
      );
      """
    Then the following SQL on "target" returns "t|t|5000|5000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             pg_relation_size(indexrelid) > 8192,
             (SELECT count(*) FROM public.events),
             (SELECT count(*) FROM public.events
                WHERE loc <@ box(point(-99, -98), point(99, 98)))
      FROM pg_index WHERE indexrelid = 'public.events_gist'::regclass;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using events_gist":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(id) FROM public.events
        WHERE loc <@ box(point(-99, -98), point(99, 98));
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.events
      SELECT 90000 + i, point((i % 199) - 99, ((i * 13) % 197) - 98)
      FROM generate_series(1, 3000) AS i;
      """
    Then the following SQL on "target" returns "8000|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.events
                WHERE loc <@ box(point(-99, -98), point(99, 98))),
             (SELECT indisvalid AND indisready FROM pg_index
                WHERE indexrelid = 'public.events_gist'::regclass);
      ROLLBACK;
      """

    Examples:
      | source_major | target_major | checksums | wal  |
      | 13           | 14           | enabled   | true |
      | 13           | 18           | enabled   | true |
      | 17           | 18           | enabled   | true |
      | 13           | 14           | disabled  | false |
      | 13           | 18           | disabled  | false |
      | 17           | 18           | disabled  | false |

  Scenario Outline: PostgreSQL <source_major> to <target_major> keeps degrading unapproved GIST opclasses
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        loc point,
        area box
      );
      CREATE INDEX events_gist ON public.events USING gist (loc);
      CREATE INDEX events_box ON public.events USING gist (area);
      INSERT INTO public.events
      SELECT i, point(i, i), box(point(i, i), point(i + 5, i + 5))
      FROM generate_series(1, 500) AS i;
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
    Then the following SQL on "target" returns "2|1|500":
      """
      SELECT count(*) FILTER (WHERE indisvalid AND indisready),
             count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM public.events)
      FROM pg_index WHERE indrelid = 'public.events'::regclass;
      """
    When the following SQL is executed on "target":
      """
      REINDEX TABLE public.events;
      """
    Then the following SQL on "target" returns "0":
      """
      SELECT count(*) FROM pg_index
      WHERE indrelid = 'public.events'::regclass AND NOT indisvalid;
      """

    Examples:
      | source_major | target_major |
      | 13           | 14           |
      | 13           | 18           |
      | 17           | 18           |
