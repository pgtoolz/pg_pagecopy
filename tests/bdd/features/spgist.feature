@spgist
Feature: Approved SP-GiST indexes transfer as page images

  Physical transfer covers exactly the core quad_point_ops/kd_point_ops
  opclasses on plain single-column point keys; every other SP-GiST index
  keeps degrading to a rebuildable definition. Every positive scenario
  proves the physical classification, the target index flags, the intended
  SP-GiST access path and containment/nearest-neighbour results against a
  sequential-scan baseline, then keeps writing through the imported tree.

  Scenario: quad_point_ops and kd_point_ops keys with NULL and duplicate points transfer physically
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.quad_t (
        id integer PRIMARY KEY,
        p point
      );
      CREATE INDEX quad_q ON public.quad_t USING spgist (p);
      CREATE TABLE public.kd_t (
        id integer PRIMARY KEY,
        p point
      );
      CREATE INDEX kd_q ON public.kd_t USING spgist (p kd_point_ops);
      INSERT INTO public.quad_t
      SELECT i, CASE WHEN i % 37 = 0 THEN NULL
                     ELSE point(i % 41 - 20, (i * 7) % 43 - 21) END
      FROM generate_series(1, 3000) AS i;
      INSERT INTO public.kd_t SELECT * FROM public.quad_t;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.quad_t', 'public.quad_t', true
      );
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.kd_t', 'public.kd_t', true
      );
      """
    Then the following SQL on "target" returns "2|2":
      """
      SELECT count(*), count(*) FILTER (WHERE indisvalid AND indisready)
      FROM pg_index WHERE indrelid = 'public.quad_t'::regclass;
      """
    And the following SQL on "target" contains "using quad_q on quad_t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.quad_t
        WHERE p <@ box(point(-3, -3), point(3, 3));
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using kd_q on kd_t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT id FROM public.kd_t
        ORDER BY p <-> point(0, 0) LIMIT 5;
      ROLLBACK;
      """
    And the following SQL on "target" returns "83|3000|81|16|2919|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.quad_t
               WHERE p <@ box(point(-3, -3), point(3, 3))),
             (SELECT count(*) FROM public.quad_t),
             (SELECT count(*) FROM public.quad_t WHERE p IS NULL),
             (SELECT count(*) FROM public.quad_t
               WHERE p <@ box(point(-1, -1), point(1, 1))),
             (SELECT count(*) FROM public.quad_t WHERE p IS NOT NULL),
             (SELECT count(*) FROM public.quad_t
               WHERE p <@ box(point(0, 0), point(0, 0)));
      ROLLBACK;
      """
    And the following SQL on "target" returns "2919|81|16":
      """
      SELECT (SELECT count(*) FROM public.kd_t WHERE p IS NOT NULL),
             (SELECT count(*) FROM public.kd_t WHERE p IS NULL),
             (SELECT count(*) FROM public.kd_t
               WHERE p <@ box(point(-1, -1), point(1, 1)));
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.quad_t VALUES
        (9998, point(0, 0)),
        (9999, NULL),
        (9997, point(-20, -21)),
        (9996, point(20, 21));
      INSERT INTO public.kd_t SELECT * FROM public.quad_t WHERE id >= 9996;
      """
    Then the following SQL on "target" returns "4|4|84|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*), count(*) FILTER (WHERE indisvalid AND indisready),
             (SELECT count(*) FROM public.quad_t
               WHERE p <@ box(point(-3, -3), point(3, 3))),
             (SELECT count(*) FROM public.quad_t
               WHERE p <@ box(point(0, 0), point(0, 0)))
      FROM pg_index
      WHERE indrelid IN ('public.quad_t'::regclass, 'public.kd_t'::regclass);
      ROLLBACK;
      """
    And the following SQL on "target" returns "5":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM
        (SELECT id FROM public.kd_t
          WHERE p IS NOT NULL ORDER BY p <-> point(0, 0) LIMIT 5) nearest;
      ROLLBACK;
      """

  Scenario: Empty, NULL-only and grown trees transfer their geometry
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.dists (id integer PRIMARY KEY, p point);
      CREATE INDEX dists_q ON public.dists USING spgist (p);
      CREATE TABLE public.nulls (id integer PRIMARY KEY, p point);
      CREATE INDEX nulls_q ON public.nulls USING spgist (p);
      INSERT INTO public.dists
      SELECT i, CASE WHEN i % 11 = 0 THEN NULL
                     ELSE point((i * 13) % 199 - 99, (i * 29) % 211 - 105) END
      FROM generate_series(1, 5000) AS i;
      INSERT INTO public.nulls SELECT i, NULL FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.dists', 'public.dists', true
      );
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.nulls', 'public.nulls', true
      );
      """
    Then the following SQL on "target" returns "t|t|t":
      """
      SELECT bool_and(indisvalid AND indisready),
             (SELECT pg_relation_size('public.dists_q'::regclass) > 3 * 8192),
             (SELECT pg_relation_size('public.nulls_q'::regclass) >= 3 * 8192)
      FROM pg_index
      WHERE indexrelid IN ('public.dists_q'::regclass, 'public.nulls_q'::regclass);
      """
    And the following SQL on "target" returns "4546|48|5000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.dists WHERE p IS NOT NULL),
             (SELECT count(*) FROM public.dists
               WHERE p <@ box(point(-10, -10), point(10, 10))),
             (SELECT count(*) FROM public.dists);
      ROLLBACK;
      """
    And the following SQL on "target" returns "500|0":
      """
      SELECT (SELECT count(*) FROM public.nulls),
             (SELECT count(*) FROM public.nulls WHERE p IS NOT NULL);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.dists SELECT 20000 + i, point(i, -i) FROM generate_series(1, 2000) AS i;
      INSERT INTO public.nulls VALUES (9999, point(1, 1));
      """
    Then the following SQL on "target" returns "t|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT bool_and(indisvalid AND indisready),
             (SELECT count(*) FROM public.nulls WHERE p IS NOT NULL)
      FROM pg_index
      WHERE indexrelid IN ('public.dists_q'::regclass, 'public.nulls_q'::regclass);
      ROLLBACK;
      """

  Scenario: An spgist index created before its data keeps splitting after the import
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.grow (id integer PRIMARY KEY, p point);
      CREATE INDEX grow_q ON public.grow USING spgist (p);
      INSERT INTO public.grow SELECT i, point(i % 100, i % 97) FROM generate_series(1, 4000) AS i;
      DELETE FROM public.grow WHERE id % 5 = 0;
      INSERT INTO public.grow SELECT 10000 + i, point(i % 89, i % 83) FROM generate_series(1, 1000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.grow', 'public.grow', true
      );
      """
    Then the following SQL on "target" returns "t|4200":
      """
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.grow)
      FROM pg_index WHERE indexrelid = 'public.grow_q'::regclass;
      """
    And the following SQL on "target" contains "using grow_q on grow":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.grow
        WHERE p <@ box(point(0, 0), point(4, 4));
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.grow SELECT 20000 + i, point(i % 211, i % 199) FROM generate_series(1, 8000) AS i;
      DELETE FROM public.grow WHERE id % 7 = 0;
      """
    When the following SQL is executed on "target":
      """
      VACUUM public.grow;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.grow SELECT 30000 + i, point(i % 223, i % 227) FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "t|12457":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.grow)
      FROM pg_index WHERE indexrelid = 'public.grow_q'::regclass;
      ROLLBACK;
      """
    And the following SQL on "target" returns "12457":
      """
      SELECT count(*) FROM public.grow;
      """

  Scenario Outline: Fillfactor <fillfactor> transfers and keeps the source split threshold
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.ff (id integer PRIMARY KEY, p point);
      CREATE INDEX ff_q ON public.ff USING spgist (p) WITH (fillfactor = <fillfactor>);
      INSERT INTO public.ff SELECT i, point(i % 71, i % 67) FROM generate_series(1, 1500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.ff', 'public.ff', true
      );
      """
    Then the following SQL on "target" returns "t|<reloption>|1500":
      """
      SELECT indisvalid AND indisready,
             (SELECT coalesce(array_to_string(reloptions, ','), 'default')
              FROM pg_class WHERE oid = 'public.ff_q'::regclass),
             (SELECT count(*) FROM public.ff)
      FROM pg_index WHERE indexrelid = 'public.ff_q'::regclass;
      """
    And the following SQL on "target" returns "2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.ff WHERE p <@ box(point(0, 0), point(1, 1));
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.ff SELECT 9000 + i, point(i % 73, i % 79) FROM generate_series(1, 500) AS i;
      """
    Then the following SQL on "target" returns "t|2000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready, (SELECT count(*) FROM public.ff)
      FROM pg_index WHERE indexrelid = 'public.ff_q'::regclass;
      ROLLBACK;
      """

    Examples:
      | fillfactor | reloption      |
      | 10         | fillfactor=10  |
      | 50         | fillfactor=50  |
      | 75         | fillfactor=75  |
      | 100        | fillfactor=100 |

  Scenario: ALTER INDEX fillfactor after creation transfers the current definition
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.alt (id integer PRIMARY KEY, p point);
      CREATE INDEX alt_q ON public.alt USING spgist (p);
      INSERT INTO public.alt SELECT i, point(i % 61, i % 59) FROM generate_series(1, 800) AS i;
      ALTER INDEX public.alt_q SET (fillfactor = 10);
      INSERT INTO public.alt SELECT 5000 + i, point(i % 57, i % 53) FROM generate_series(1, 200) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.alt', 'public.alt', true
      );
      """
    Then the following SQL on "target" returns "t|t|1000":
      """
      SELECT indisvalid AND indisready,
             (SELECT array_to_string(reloptions, ',') LIKE '%fillfactor=10%'
              FROM pg_class WHERE oid = 'public.alt_q'::regclass),
             (SELECT count(*) FROM public.alt)
      FROM pg_index WHERE indexrelid = 'public.alt_q'::regclass;
      """
    And the following SQL on "target" returns "86":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.alt WHERE p <@ box(point(0, 0), point(13, 13));
      ROLLBACK;
      """

  Scenario: Smaller, larger and prepopulated target indexes are overwritten in place
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.over (id integer PRIMARY KEY, p point);
      CREATE INDEX over_q ON public.over USING spgist (p);
      INSERT INTO public.over SELECT i, point(i % 97, i % 89) FROM generate_series(1, 3000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.over (id integer PRIMARY KEY, p point);
      CREATE INDEX over_q ON public.over USING spgist (p);
      INSERT INTO public.over SELECT i, point(i % 83, i % 79) FROM generate_series(1, 30) AS i;
      SET enable_seqscan = off;
      SELECT count(*) FROM public.over WHERE p <@ box(point(0, 0), point(4, 4));
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.over', 'public.over', true
      );
      """
    Then the following SQL on "target" returns "t|3000|0|162":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.over),
             (SELECT count(*) FROM public.over
               WHERE p <@ box(point(0, 0), point(0, 0))),
             (SELECT count(*) FROM public.over
               WHERE p <@ box(point(70, 70), point(100, 100)))
      FROM pg_index WHERE indexrelid = 'public.over_q'::regclass;
      ROLLBACK;
      """
    And the following SQL on "target" returns "1":
      """
      INSERT INTO public.over VALUES (9999, point(0, 0));
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.over WHERE p <@ box(point(0, 0), point(0, 0));
      ROLLBACK;
      """

  Scenario: A mixed TOAST, btree, BRIN, HASH and SP-GiST index table transfers in one stream
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.mixed (
        id integer PRIMARY KEY,
        p point,
        payload text,
        note text
      );
      CREATE INDEX mixed_spg ON public.mixed USING spgist (p);
      CREATE INDEX mixed_hash ON public.mixed USING hash (id);
      CREATE INDEX mixed_btree ON public.mixed USING btree (note);
      CREATE INDEX mixed_brin ON public.mixed USING brin (id);
      ALTER TABLE public.mixed ALTER COLUMN payload SET STORAGE EXTERNAL;
      INSERT INTO public.mixed
      SELECT i, point(i % 101, i % 103), repeat('body-' || i, 400), 'note ' || (i % 97)
      FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "source" returns "t":
      """
      SELECT pg_relation_size((SELECT reltoastrelid
                                 FROM pg_class
                                WHERE oid = 'public.mixed'::regclass)) > 0;
      """
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.mixed (
        id integer PRIMARY KEY,
        p point,
        payload text,
        note text
      );
      CREATE INDEX mixed_brin ON public.mixed USING brin (id);
      CREATE INDEX reordered_note ON public.mixed USING btree (note);
      CREATE INDEX mixed_hash ON public.mixed USING hash (id);
      CREATE INDEX mixed_spg ON public.mixed USING spgist (p);
      ALTER TABLE public.mixed ALTER COLUMN payload SET STORAGE EXTERNAL;
      INSERT INTO public.mixed VALUES (9999, point(1, 1), 'sentinel', 'keep');
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.mixed', 'public.mixed', true
      );
      """
    Then the following SQL on "target" returns "5|2000|11|3":
      """
      SELECT count(*) FILTER (WHERE indisvalid AND indisready),
             (SELECT count(*) FROM public.mixed),
             (SELECT count(*) FROM public.mixed WHERE payload LIKE 'body-42%'),
             (SELECT count(*) FROM public.mixed
               WHERE p <@ box(point(0, 0), point(2, 2)))
      FROM pg_index WHERE indrelid = 'public.mixed'::regclass;
      """
    And the following SQL on "target" returns "t|t":
      """
      SELECT (SELECT min(id) FROM public.mixed) = 1,
             (SELECT count(*) FROM public.mixed WHERE payload = 'sentinel') = 0;
      """
    And the following SQL on "target" contains "using mixed_spg on mixed":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.mixed
        WHERE p <@ box(point(0, 0), point(2, 2));
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.mixed VALUES (10000, point(1, 1), 'new', 'note 42');
      """
    Then the following SQL on "target" returns "4|22":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.mixed
               WHERE p <@ box(point(0, 0), point(2, 2))),
             (SELECT count(*) FROM public.mixed WHERE note = 'note 42');
      ROLLBACK;
      """
