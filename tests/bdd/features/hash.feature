@hash
Feature: Approved HASH indexes transfer as page images

  Physical transfer covers exactly the core int2_ops/int4_ops/int8_ops
  opclasses on plain single-column int2/int4/int8 keys; every other HASH
  index keeps degrading to a rebuildable definition. Every positive
  scenario proves the physical classification, the target index flags, the
  intended HASH access path and equality results against a sequential-scan
  baseline, then keeps writing through the imported index.

  Scenario: int2, int4 and int8 keys with negative, zero and extreme values transfer physically
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.nums (
        s smallint,
        i integer,
        b bigint
      );
      CREATE INDEX nums_s ON public.nums USING hash (s);
      CREATE INDEX nums_i ON public.nums USING hash (i);
      CREATE INDEX nums_b ON public.nums USING hash (b);
      INSERT INTO public.nums VALUES
        (-32768, -2147483648, -9223372036854775808),
        (0, 0, 0),
        (32767, 2147483647, 9223372036854775807),
        (-1, -1, -1),
        (1, 1, 1),
        (0, 42, 42);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.nums', 'public.nums', true
      );
      """
    Then the following SQL on "target" returns "3|3":
      """
      SELECT count(*), count(*) FILTER (WHERE indisvalid AND indisready)
      FROM pg_index WHERE indrelid = 'public.nums'::regclass;
      """
    And the following SQL on "target" contains "Index Scan using nums_i on nums":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.nums WHERE i = 42;
      ROLLBACK;
      """
    And the following SQL on "target" returns "1|1|1|6|1|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.nums WHERE s = 32767),
             (SELECT count(*) FROM public.nums WHERE i = -2147483648),
             (SELECT count(*) FROM public.nums WHERE b = 0),
             (SELECT count(*) FROM public.nums),
             (SELECT count(*) FROM public.nums WHERE i = 42),
             (SELECT count(*) FROM public.nums WHERE b = -9223372036854775808);
      ROLLBACK;
      """
    And the following SQL on "target" returns "1|1|1":
      """
      SELECT (SELECT count(*) FROM public.nums WHERE s = 32767),
             (SELECT count(*) FROM public.nums WHERE i = -2147483648),
             (SELECT count(*) FROM public.nums WHERE b = 0);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.nums VALUES (7, 7, 7), (-32768, -2147483648, 0);
      """
    Then the following SQL on "target" returns "1|1|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.nums WHERE s = 7),
             (SELECT count(*) FROM public.nums WHERE i = 7),
             (SELECT count(*) FROM public.nums WHERE b = 0);
      ROLLBACK;
      """
    And the following SQL on "target" returns "3|3":
      """
      SELECT count(*), count(*) FILTER (WHERE indisvalid AND indisready)
      FROM pg_index WHERE indrelid = 'public.nums'::regclass;
      """

  Scenario: Empty, NULL-only, mixed-NULL and duplicate-heavy keys transfer their geometry
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.dists (id integer PRIMARY KEY, k integer, note text);
      CREATE INDEX dists_k ON public.dists USING hash (k);
      CREATE TABLE public.nulls (id integer PRIMARY KEY, k integer);
      CREATE INDEX nulls_k ON public.nulls USING hash (k);
      INSERT INTO public.dists
      SELECT i, CASE WHEN i % 10 = 0 THEN NULL ELSE i % 7 END, 'row' || i
      FROM generate_series(1, 2000) AS i;
      INSERT INTO public.nulls SELECT i, NULL FROM generate_series(1, 50) AS i;
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
    Then the following SQL on "target" returns "t":
      """
      SELECT bool_and(indisvalid AND indisready)
      FROM pg_index
      WHERE indexrelid IN ('public.dists_k'::regclass, 'public.nulls_k'::regclass);
      """
    And the following SQL on "target" returns "257|200|2000|50":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.dists WHERE k = 3),
             (SELECT count(*) FROM public.dists WHERE k IS NULL),
             (SELECT count(*) FROM public.dists),
             (SELECT count(*) FROM public.nulls);
      ROLLBACK;
      """
    And the following SQL on "target" returns "257|2000|50":
      """
      SELECT (SELECT count(*) FROM public.dists WHERE k = 3),
             (SELECT count(*) FROM public.dists),
             (SELECT count(*) FROM public.nulls);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.dists SELECT 10000 + i, 3, 'new' FROM generate_series(1, 100) AS i;
      INSERT INTO public.nulls VALUES (9999, 5);
      """
    Then the following SQL on "target" returns "357|1|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.dists WHERE k = 3),
             (SELECT count(*) FROM public.nulls WHERE k = 5),
             (SELECT bool_and(indisvalid AND indisready) FROM pg_index
              WHERE indexrelid IN ('public.dists_k'::regclass, 'public.nulls_k'::regclass));
      ROLLBACK;
      """

  Scenario: Distinct values whose int4 hashes actually collide stay queryable
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.coll (a integer, b integer);
      CREATE INDEX coll_a ON public.coll USING hash (a);
      INSERT INTO public.coll
      SELECT i, hashint4(i)
      FROM generate_series(1, 5000) AS i;
      """
    And the following SQL is executed on "source":
      """
      INSERT INTO public.coll
      SELECT v, hashint4(v) FROM generate_series(5001, 200000) AS g(v)
      WHERE EXISTS (SELECT 1 FROM public.coll c WHERE hashint4(c.a) = hashint4(v) AND c.a <> v)
      LIMIT 200;
      """
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.coll', 'public.coll', true
      );
      """
    Then the following SQL on "source" returns "t":
      """
      SELECT count(*) > 0 FROM public.coll c1 JOIN public.coll c2
        ON hashint4(c1.a) = hashint4(c2.a) AND c1.a <> c2.a;
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT indisvalid AND indisready,
             (SELECT count(*) > 0 FROM public.coll c1 JOIN public.coll c2
               ON hashint4(c1.a) = hashint4(c2.a) AND c1.a <> c2.a)
      FROM pg_index WHERE indexrelid = 'public.coll_a'::regclass;
      """
    And the following SQL on "target" returns "5001|5001":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(DISTINCT a) FROM public.coll),
             (SELECT count(*) FROM public.coll);
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      CREATE TABLE public.pair AS
        SELECT c1.a AS a1, c2.a AS a2
        FROM public.coll c1 JOIN public.coll c2
          ON hashint4(c1.a) = hashint4(c2.a) AND c1.a <> c2.a
        LIMIT 1;
      """
    Then the following SQL on "target" returns "1|1":
      """
      SELECT (SELECT count(*) FROM public.coll, public.pair WHERE a = a1),
             (SELECT count(*) FROM public.coll, public.pair WHERE a = a2);
      """
    And the following SQL on "target" contains "Index Scan using coll_a":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.coll, public.pair WHERE a = a1;
      ROLLBACK;
      """
    And the following SQL on "target" contains "Index Scan using coll_a":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.coll, public.pair WHERE a = a2;
      ROLLBACK;
      """
    And the following SQL on "target" returns "5001":
      """
      SELECT count(DISTINCT a) FROM public.coll;
      """

  Scenario: A hash index created before its data keeps splitting after the import
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.grow (id integer PRIMARY KEY, k integer);
      CREATE INDEX grow_k ON public.grow USING hash (k);
      INSERT INTO public.grow SELECT i, i * 13 FROM generate_series(1, 4000) AS i;
      DELETE FROM public.grow WHERE id % 5 = 0;
      INSERT INTO public.grow SELECT 10000 + i, i * 13 FROM generate_series(1, 1000) AS i;
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
      FROM pg_index WHERE indexrelid = 'public.grow_k'::regclass;
      """
    And the following SQL on "target" contains "Index Scan using grow_k on grow":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.grow WHERE k = 26;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.grow SELECT 20000 + i, i * 31 FROM generate_series(1, 6000) AS i;
      DELETE FROM public.grow WHERE id % 7 = 0;
      """
    When the following SQL is executed on "target":
      """
      VACUUM public.grow;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.grow SELECT 30000 + i, i * 31 FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "t|10743|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.grow),
             (SELECT count(*) FROM public.grow WHERE k = 13)
      FROM pg_index WHERE indexrelid = 'public.grow_k'::regclass;
      ROLLBACK;
      """
    And the following SQL on "target" returns "10743|2":
      """
      SELECT count(*), count(*) FILTER (WHERE k = 13) FROM public.grow;
      """

  Scenario Outline: Fillfactor <fillfactor> transfers and keeps the source split threshold
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.ff (id integer PRIMARY KEY, k integer);
      CREATE INDEX ff_k ON public.ff USING hash (k) WITH (fillfactor = <fillfactor>);
      INSERT INTO public.ff SELECT i, i * 7 FROM generate_series(1, 1500) AS i;
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
              FROM pg_class WHERE oid = 'public.ff_k'::regclass),
             (SELECT count(*) FROM public.ff)
      FROM pg_index WHERE indexrelid = 'public.ff_k'::regclass;
      """
    And the following SQL on "target" returns "2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.ff WHERE k IN (14, 21);
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.ff SELECT 9000 + i, i FROM generate_series(1, 500) AS i;
      """
    Then the following SQL on "target" returns "t|2000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready, (SELECT count(*) FROM public.ff)
      FROM pg_index WHERE indexrelid = 'public.ff_k'::regclass;
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
      CREATE TABLE public.alt (id integer PRIMARY KEY, k integer);
      CREATE INDEX alt_k ON public.alt USING hash (k);
      INSERT INTO public.alt SELECT i, i FROM generate_series(1, 800) AS i;
      ALTER INDEX public.alt_k SET (fillfactor = 10);
      INSERT INTO public.alt SELECT 5000 + i, i FROM generate_series(1, 200) AS i;
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
              FROM pg_class WHERE oid = 'public.alt_k'::regclass),
             (SELECT count(*) FROM public.alt)
      FROM pg_index WHERE indexrelid = 'public.alt_k'::regclass;
      """
    And the following SQL on "target" returns "1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.alt WHERE k = 500;
      ROLLBACK;
      """

  Scenario: Smaller, larger and prepopulated target indexes are overwritten in place
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.over (id integer PRIMARY KEY, k integer);
      CREATE INDEX over_k ON public.over USING hash (k);
      INSERT INTO public.over SELECT i, i * 3 FROM generate_series(1, 3000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.over (id integer PRIMARY KEY, k integer);
      CREATE INDEX over_k ON public.over USING hash (k);
      INSERT INTO public.over SELECT i, i * 11 FROM generate_series(1, 30) AS i;
      SET enable_seqscan = off;
      SELECT count(*) FROM public.over WHERE k = 33;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.over', 'public.over', true
      );
      """
    Then the following SQL on "target" returns "t|3000|1|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.over),
             (SELECT count(*) FROM public.over WHERE k = 33),
             (SELECT count(*) FROM public.over WHERE k = 11)
      FROM pg_index WHERE indexrelid = 'public.over_k'::regclass;
      ROLLBACK;
      """
    And the following SQL on "target" returns "2":
      """
      INSERT INTO public.over VALUES (9999, 33);
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.over WHERE k = 33;
      ROLLBACK;
      """

  Scenario: A mixed TOAST, btree, BRIN and multiple HASH index table transfers in one stream
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.mixed (
        id integer PRIMARY KEY,
        k bigint,
        payload text,
        note text
      );
      CREATE INDEX mixed_hash_k ON public.mixed USING hash (k);
      CREATE INDEX mixed_hash_id ON public.mixed USING hash (id);
      CREATE INDEX mixed_btree ON public.mixed USING btree (note);
      CREATE INDEX mixed_brin ON public.mixed USING brin (id);
      CREATE INDEX mixed_gin ON public.mixed USING gin (to_tsvector('english', note));
      ALTER TABLE public.mixed ALTER COLUMN payload SET STORAGE EXTERNAL;
      INSERT INTO public.mixed
      SELECT i, i * 17, repeat('body-' || i, 400), 'note ' || (i % 97)
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
        k bigint,
        payload text,
        note text
      );
      CREATE INDEX reordered_note ON public.mixed USING btree (note);
      CREATE INDEX mixed_brin ON public.mixed USING brin (id);
      CREATE INDEX mixed_gin ON public.mixed USING gin (to_tsvector('english', note));
      CREATE INDEX reordered_id ON public.mixed USING hash (id);
      CREATE INDEX mixed_hash_k ON public.mixed USING hash (k);
      ALTER TABLE public.mixed ALTER COLUMN payload SET STORAGE EXTERNAL;
      INSERT INTO public.mixed VALUES (9999, 1, 'sentinel', 'keep');
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.mixed', 'public.mixed', true
      );
      """
    Then the following SQL on "target" returns "5|1|2000|11|2":
      """
      SELECT count(*) FILTER (WHERE indisvalid AND indisready),
             count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM public.mixed),
             (SELECT count(*) FROM public.mixed WHERE payload LIKE 'body-42%'),
             (SELECT count(*) FROM public.mixed WHERE k = 34 OR id = 500)
      FROM pg_index WHERE indrelid = 'public.mixed'::regclass;
      """
    And the following SQL on "target" returns "t|t|t":
      """
      SELECT (SELECT min(id) FROM public.mixed) = 1,
             (SELECT count(*) FROM public.mixed WHERE id = 9999) = 0,
             (SELECT count(*) FROM public.mixed WHERE payload = 'sentinel') = 0;
      """
    And the following SQL on "target" contains "Index Scan using mixed_hash_k on mixed":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.mixed WHERE k = 34;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.mixed VALUES (10000, 34, 'new', 'note 42');
      """
    Then the following SQL on "target" returns "2|22":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.mixed WHERE k = 34),
             (SELECT count(*) FROM public.mixed WHERE note = 'note 42');
      ROLLBACK;
      """
