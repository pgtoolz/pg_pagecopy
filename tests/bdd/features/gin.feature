@gin
Feature: Approved GIN indexes transfer as page images

  Physical transfer covers exactly the core array_ops opclass on plain
  int[] keys and jsonb_ops on plain jsonb keys; every other GIN index
  keeps degrading to a rebuildable definition. Every positive scenario
  proves the physical classification, the target index flags, the intended
  GIN access path and containment results against a sequential-scan
  baseline, then keeps writing through the imported index. A nonempty
  fastupdate pending list transfers fully and keeps accumulating.

  Scenario: int[] keys with NULL, empty, duplicate and multi-element arrays transfer physically
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.tags (
        id integer PRIMARY KEY,
        items integer[]
      );
      CREATE INDEX tags_items ON public.tags USING gin (items);
      INSERT INTO public.tags VALUES
        (1, NULL),
        (2, '{}'),
        (3, ARRAY[42]),
        (4, ARRAY[42]),
        (5, ARRAY[7, 42, 1024]),
        (6, ARRAY[-2147483648, 2147483647]),
        (7, ARRAY[0]),
        (8, ARRAY[42, 42, 42]);
      INSERT INTO public.tags
      SELECT i, ARRAY[i % 10, 42] FROM generate_series(9, 2000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.tags', 'public.tags', true
      );
      """
    Then the following SQL on "target" returns "t|2|2000":
      """
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM pg_index WHERE indrelid = 'public.tags'::regclass),
             (SELECT count(*) FROM public.tags)
      FROM pg_index WHERE indexrelid = 'public.tags_items'::regclass;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on tags_items":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.tags WHERE items @> ARRAY[42];
      ROLLBACK;
      """
    And the following SQL on "target" returns "1996|200|2|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.tags WHERE items @> ARRAY[42]),
             (SELECT count(*) FROM public.tags WHERE items @> ARRAY[7]),
             (SELECT count(*) FROM public.tags WHERE items = ARRAY[42]),
             (SELECT count(*) FROM public.tags WHERE items && ARRAY[1024]);
      ROLLBACK;
      """
    And the following SQL on "target" returns "1996|200|2|1":
      """
      SELECT (SELECT count(*) FROM public.tags WHERE items @> ARRAY[42]),
             (SELECT count(*) FROM public.tags WHERE items @> ARRAY[7]),
             (SELECT count(*) FROM public.tags WHERE items = ARRAY[42]),
             (SELECT count(*) FROM public.tags WHERE items && ARRAY[1024]);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.tags VALUES (9999, ARRAY[42]), (9998, NULL), (9997, ARRAY[55]);
      """
    Then the following SQL on "target" returns "1997|1|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.tags WHERE items @> ARRAY[42]),
             (SELECT count(*) FROM public.tags WHERE items @> ARRAY[55]),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.tags_items'::regclass);
      ROLLBACK;
      """

  Scenario: jsonb keys with nested values, long keys and NULLs transfer physically
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.docs (
        id integer PRIMARY KEY,
        body jsonb
      );
      CREATE INDEX docs_body ON public.docs USING gin (body);
      INSERT INTO public.docs VALUES
        (1, NULL),
        (2, '{}'),
        (3, '[]'),
        (4, '{"a": 1}'),
        (5, '{"a": 1, "b": [1, 2, 3]}'),
        (6, ('{"long": "' || repeat('x', 500) || '"}')::jsonb),
        (7, '{"num": 12345.6789}'),
        (8, '{"b": true}');
      INSERT INTO public.docs
      SELECT i, jsonb_build_object('k', i % 50, 'arr', ARRAY_TO_STRING(ARRAY[i % 3, i % 5], ','))
      FROM generate_series(9, 1500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.docs', 'public.docs', true
      );
      """
    Then the following SQL on "target" returns "t|1500":
      """
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.docs)
      FROM pg_index WHERE indexrelid = 'public.docs_body'::regclass;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on docs_body":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.docs WHERE body @> '{"a": 1}'::jsonb;
      ROLLBACK;
      """
    And the following SQL on "target" returns "2|1|1|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.docs WHERE body @> '{"a": 1}'::jsonb),
             (SELECT count(*) FROM public.docs WHERE body @> '{"b": [1, 2, 3]}'::jsonb),
             (SELECT count(*) FROM public.docs WHERE body ? 'long'),
             (SELECT count(*) FROM public.docs WHERE body @> '{"num": 12345.6789}'::jsonb);
      ROLLBACK;
      """
    And the following SQL on "target" returns "2|1|1|1":
      """
      SELECT (SELECT count(*) FROM public.docs WHERE body @> '{"a": 1}'::jsonb),
             (SELECT count(*) FROM public.docs WHERE body @> '{"b": [1, 2, 3]}'::jsonb),
             (SELECT count(*) FROM public.docs WHERE body ? 'long'),
             (SELECT count(*) FROM public.docs WHERE body @> '{"num": 12345.6789}'::jsonb);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.docs VALUES (9999, '{"a": 1}');
      """
    Then the following SQL on "target" returns "3|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.docs WHERE body @> '{"a": 1}'::jsonb),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.docs_body'::regclass);
      ROLLBACK;
      """

  Scenario: A nonempty fastupdate pending list transfers fully and keeps accumulating
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.fast (id integer PRIMARY KEY, items integer[]);
      CREATE INDEX fast_items ON public.fast USING gin (items);
      INSERT INTO public.fast
      SELECT i, ARRAY[7, i % 7] FROM generate_series(1, 5000) AS i;
      """
    Then the following SQL on "source" returns "t":
      """
      SELECT pg_relation_size('public.fast_items'::regclass) >= 12 * 8192;
      """
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.fast', 'public.fast', true
      );
      """
    Then the following SQL on "target" returns "t|t|5000|5000":
      """
      SELECT indisvalid AND indisready,
             pg_relation_size('public.fast_items'::regclass) >= 12 * 8192,
             (SELECT count(*) FROM public.fast),
             (SELECT count(*) FROM public.fast WHERE items @> ARRAY[7])
      FROM pg_index WHERE indexrelid = 'public.fast_items'::regclass;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on fast_items":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.fast WHERE items @> ARRAY[7];
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.fast
      SELECT 10000 + i, ARRAY[7, i % 7] FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "7000|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.fast WHERE items @> ARRAY[7]),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.fast_items'::regclass);
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      SELECT gin_clean_pending_list('public.fast_items');
      """
    Then the following SQL on "target" returns "7000|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.fast WHERE items @> ARRAY[7]),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.fast_items'::regclass);
      ROLLBACK;
      """
    And the following SQL on "target" returns "0":
      """
      SELECT count(*) FROM public.fast WHERE id = 1 AND NOT items @> ARRAY[1];
      """

  Scenario: An empty GIN index transfers its format identity
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.fresh (id integer PRIMARY KEY, items integer[]);
      CREATE INDEX fresh_items ON public.fresh USING gin (items);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.fresh', 'public.fresh', true
      );
      """
    Then the following SQL on "target" returns "t|0":
      """
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.fresh)
      FROM pg_index WHERE indexrelid = 'public.fresh_items'::regclass;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.fresh VALUES (1, ARRAY[3]), (2, NULL);
      """
    Then the following SQL on "target" returns "1|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.fresh WHERE items @> ARRAY[3]),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.fresh_items'::regclass);
      ROLLBACK;
      """

  Scenario: A mixed TOAST, btree, BRIN, HASH and GIN index table transfers in one stream
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.mixed (
        id integer PRIMARY KEY,
        k bigint,
        payload text,
        items integer[]
      );
      CREATE INDEX mixed_hash_k ON public.mixed USING hash (k);
      CREATE INDEX mixed_btree ON public.mixed USING btree (payload);
      CREATE INDEX mixed_brin ON public.mixed USING brin (id);
      CREATE INDEX mixed_gin ON public.mixed USING gin (items);
      CREATE INDEX mixed_gin_expr ON public.mixed USING gin (to_tsvector('simple', payload));
      ALTER TABLE public.mixed ALTER COLUMN payload SET STORAGE EXTERNAL;
      INSERT INTO public.mixed
      SELECT i, i * 17, repeat('body-' || i, 400), ARRAY[i % 20, i % 17]
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
        items integer[]
      );
      CREATE INDEX reordered_payload ON public.mixed USING btree (payload);
      CREATE INDEX mixed_brin ON public.mixed USING brin (id);
      CREATE INDEX mixed_gin_expr ON public.mixed USING gin (to_tsvector('simple', payload));
      CREATE INDEX mixed_hash_k ON public.mixed USING hash (k);
      CREATE INDEX mixed_gin ON public.mixed USING gin (items);
      ALTER TABLE public.mixed ALTER COLUMN payload SET STORAGE EXTERNAL;
      INSERT INTO public.mixed VALUES (9999, 1, 'sentinel', ARRAY[9999]);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.mixed', 'public.mixed', true
      );
      """
    Then the following SQL on "target" returns "5|1|2000|11|100":
      """
      SELECT count(*) FILTER (WHERE indisvalid AND indisready),
             count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM public.mixed),
             (SELECT count(*) FROM public.mixed WHERE payload LIKE 'body-42%'),
             (SELECT count(*) FROM public.mixed WHERE items @> ARRAY[19])
      FROM pg_index WHERE indrelid = 'public.mixed'::regclass;
      """
    And the following SQL on "target" returns "t|t|t":
      """
      SELECT (SELECT min(id) FROM public.mixed) = 1,
             (SELECT count(*) FROM public.mixed WHERE id = 9999) = 0,
             (SELECT count(*) FROM public.mixed WHERE payload = 'sentinel') = 0;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on mixed_gin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.mixed WHERE items @> ARRAY[19];
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.mixed VALUES (10000, 34, 'new', ARRAY[19]);
      """
    Then the following SQL on "target" returns "101|2":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.mixed WHERE items @> ARRAY[19]),
             (SELECT count(*) FROM public.mixed WHERE k = 34);
      ROLLBACK;
      """
