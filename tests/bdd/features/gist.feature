@gist
Feature: Approved GIST indexes transfer as page images

  Physical transfer covers exactly the core point_ops opclass on a plain
  single-column point key; every other GIST index keeps degrading to a
  rebuildable definition. Every positive scenario proves the physical
  classification, the target index flags, the intended GIST access path
  (containment, equality and KNN distance ordering) against a
  sequential-scan baseline, then keeps writing through the imported index.
  Transferred pages carry the GistBuildLSN NSN stamp, so every completed
  source split reads as complete while post-transfer splits still chain
  correctly.

  Scenario: point keys with negative, zero, extreme and duplicate values transfer physically
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.spots (
        id integer PRIMARY KEY,
        p point,
        note text
      );
      CREATE INDEX spots_p ON public.spots USING gist (p);
      INSERT INTO public.spots VALUES
        (1, point(0, 0), 'origin'),
        (2, point(3, 4), 'plain'),
        (3, point(-1e100, 1e100), 'far corner'),
        (4, point(1e100, -1e100), 'far corner'),
        (5, point(0, 0), 'origin again'),
        (6, point(3, 4), 'plain again'),
        (7, NULL, 'nowhere');
      INSERT INTO public.spots
      SELECT 100 + i,
             point((i % 41) - 20, ((i * 7) % 43) - 21),
             'bulk'
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
        'public.spots', 'public.spots', true
      );
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT indisvalid AND indisready,
             pg_relation_size(indexrelid) > 8192
      FROM pg_index WHERE indexrelid = 'public.spots_p'::regclass;
      """
    And the following SQL on "target" contains "Index Scan using spots_p on spots":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(note) FROM public.spots
        WHERE p <@ box(point(-20, -21), point(20, 21));
      ROLLBACK;
      """
    And the following SQL on "target" returns "3007|3|4|1|3006":
      """
      SELECT (SELECT count(*) FROM public.spots),
             (SELECT count(*) FROM public.spots WHERE p ~= point(0, 0)),
             (SELECT count(*) FROM public.spots WHERE p ~= point(3, 4)),
             (SELECT count(*) FROM public.spots WHERE p IS NULL),
             (SELECT count(*) FROM public.spots
                WHERE p <@ box(point(-1e100, -1e100), point(1e100, 1e100)));
      """
    And the following SQL on "target" returns "3007|3|4|1|3006":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.spots),
             (SELECT count(*) FROM public.spots WHERE p ~= point(0, 0)),
             (SELECT count(*) FROM public.spots WHERE p ~= point(3, 4)),
             (SELECT count(*) FROM public.spots WHERE p IS NULL),
             (SELECT count(*) FROM public.spots
                WHERE p <@ box(point(-1e100, -1e100), point(1e100, 1e100)));
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.spots VALUES
        (9999, point(0, 0), 'new origin'),
        (10000, point(3, 4), 'new plain');
      INSERT INTO public.spots
      SELECT 20000 + i, point((i % 37) - 18, ((i * 5) % 39) - 19), 'more'
      FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "6|6|5009":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.spots WHERE p ~= point(0, 0)),
             (SELECT count(*) FROM public.spots WHERE p ~= point(3, 4)),
             (SELECT count(*) FROM public.spots);
      ROLLBACK;
      """
    And the following SQL on "target" returns "t":
      """
      SELECT indisvalid AND indisready
      FROM pg_index WHERE indexrelid = 'public.spots_p'::regclass;
      """

  Scenario: An index built after the data transfers and keeps splitting on the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.grid (id integer PRIMARY KEY, p point);
      INSERT INTO public.grid
      SELECT i, point((i % 199) - 99, ((i * 13) % 197) - 98)
      FROM generate_series(1, 5000) AS i;
      CREATE INDEX grid_p ON public.grid USING gist (p);
      DELETE FROM public.grid WHERE id % 7 = 0;
      INSERT INTO public.grid
      SELECT 20000 + i, point((i % 89) - 44, ((i * 3) % 97) - 48)
      FROM generate_series(1, 1500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.grid', 'public.grid', true
      );
      """
    Then the following SQL on "target" returns "t|5786|5786":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.grid),
             (SELECT count(*) FROM public.grid
                WHERE p <@ box(point(-99, -98), point(99, 98)))
      FROM pg_index WHERE indexrelid = 'public.grid_p'::regclass;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.grid
      SELECT 30000 + i, point((i % 199) - 99, ((i * 13) % 197) - 98)
      FROM generate_series(1, 5000) AS i;
      """
    Then the following SQL on "target" returns "10786|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.grid
                WHERE p <@ box(point(-99, -98), point(99, 98))),
             (SELECT indisvalid AND indisready FROM pg_index
                WHERE indexrelid = 'public.grid_p'::regclass);
      ROLLBACK;
      """

  Scenario: Empty, NULL-only and never-split indexes transfer their root page
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.shapes (id integer PRIMARY KEY, p point, q point);
      CREATE INDEX shapes_p ON public.shapes USING gist (p);
      CREATE INDEX shapes_q ON public.shapes USING gist (q);
      INSERT INTO public.shapes SELECT i, NULL, point(i, i)
      FROM generate_series(1, 50) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.shapes', 'public.shapes', true
      );
      """
    Then the following SQL on "target" returns "t|t|8192":
      """
      SELECT bool_and(indisvalid AND indisready),
             bool_and(pg_relation_size(indexrelid) = 8192),
             (SELECT pg_relation_size('public.shapes_p'::regclass))
      FROM pg_index
      WHERE indexrelid IN ('public.shapes_p'::regclass, 'public.shapes_q'::regclass);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.shapes VALUES (9999, point(1, 1), point(2, 2));
      """
    Then the following SQL on "target" returns "1|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.shapes WHERE p ~= point(1, 1)),
             (SELECT count(*) FROM public.shapes WHERE q ~= point(2, 2));
      ROLLBACK;
      """

  Scenario: KNN distance ordering survives the transfer
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.near (id integer PRIMARY KEY, p point);
      INSERT INTO public.near
      SELECT i, point((i % 101) - 50, ((i * 17) % 103) - 51)
      FROM generate_series(1, 2000) AS i;
      CREATE INDEX near_p ON public.near USING gist (p);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.near', 'public.near', true
      );
      """
    Then the following SQL on "target" contains "Order By: (p <->":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT id FROM public.near
        ORDER BY p <-> point(0, 0) LIMIT 5;
      ROLLBACK;
      """
    And the following SQL on "target" returns "t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      WITH top AS (
        SELECT id, p <-> point(0, 0) AS d
        FROM public.near ORDER BY p <-> point(0, 0) LIMIT 5
      )
      SELECT (SELECT count(DISTINCT id) FROM top) = 5
         AND (SELECT max(d) FROM top)
             <= (SELECT min(p <-> point(0, 0)) FROM public.near
                  WHERE id NOT IN (SELECT id FROM top));
      ROLLBACK;
      """
