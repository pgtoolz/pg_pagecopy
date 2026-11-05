@gin @local
Feature: pagecopy.clone transfers GIN indexes inside one cluster

  Local clone auto-creates the target with its gin indexes (keeping the
  source index name only when it is free), replaces an existing matching
  target in place, and rolls the whole clone back on a mid-stream failure.

  Scenario: A populated gin index with its pending list clones physically
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, items integer[]);
      CREATE INDEX t_items ON public.t USING gin (items);
      INSERT INTO public.t
      SELECT i, ARRAY[7, i % 7] FROM generate_series(1, 5000) AS i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', true);
      """
    And target relation "public.t_copy_items_idx" block 0 is recorded as a gin "meta" page
    And target relation "public.t_copy_items_idx" block 1 is recorded as a gin "entry" page
    And target relation "public.t_copy_items_idx" block 2 is recorded as a gin "pending" page
    And target postmaster is crashed and restarted
    Then the recorded target block is unchanged after crash recovery
    Then the following SQL on "target" returns "t|t|5000|5000":
      """
      SELECT indisvalid AND indisready,
             pg_relation_size(c.oid) >= 12 * 8192,
             (SELECT count(*) FROM public.t_copy),
             (SELECT count(*) FROM public.t_copy WHERE items @> ARRAY[7])
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam
      WHERE i.indrelid = 'public.t_copy'::regclass AND am.amname = 'gin';
      """
    And the following SQL on "target" returns "5000|5000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t_copy),
             (SELECT count(*) FROM public.t_copy WHERE items @> ARRAY[7]);
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t_copy
      SELECT 10000 + i, ARRAY[7, i % 7] FROM generate_series(1, 2000) AS i;
      SELECT gin_clean_pending_list((SELECT c.oid::regclass FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am am ON am.oid = c.relam WHERE i.indrelid = 'public.t_copy'::regclass AND am.amname = 'gin'));
      """
    Then the following SQL on "target" returns "7000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.t_copy WHERE items @> ARRAY[7];
      ROLLBACK;
      """

  Scenario: Cloning over an existing target replaces its gin index in place
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, items integer[]);
      CREATE INDEX t_items ON public.t USING gin (items);
      INSERT INTO public.t
      SELECT i, ARRAY[i % 9] FROM generate_series(1, 1500) AS i;
      CREATE TABLE public.t_copy (id integer PRIMARY KEY, items integer[]);
      CREATE INDEX existing_items ON public.t_copy USING gin (items);
      INSERT INTO public.t_copy VALUES (9999, ARRAY[999999]);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', true);
      """
    Then the following SQL on "target" returns "t|1500|167|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.t_copy),
             (SELECT count(*) FROM public.t_copy WHERE items @> ARRAY[3]),
             (SELECT count(*) FROM public.t_copy WHERE items @> ARRAY[999999])
      FROM pg_index WHERE indexrelid = 'public.existing_items'::regclass;
      ROLLBACK;
      """

  Scenario: Clone auto-creation avoids an index-name collision in a case-sensitive schema
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE SCHEMA "Case";
      CREATE TABLE "Case".src (id integer PRIMARY KEY, items integer[]);
      CREATE INDEX "t_items" ON "Case".src USING gin (items);
      INSERT INTO "Case".src SELECT i, ARRAY[i] FROM generate_series(1, 100) AS i;
      CREATE TABLE "Case".collide (id integer);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('"Case".src', '"Case".dst', true);
      """
    Then the following SQL on "target" returns "t|2|100|t":
      """
      SELECT bool_and(indisvalid AND indisready),
             count(*),
             (SELECT count(*) FROM "Case".dst),
             (SELECT c.relname LIKE 'dst\_%' FROM pg_index i
              JOIN pg_class c ON c.oid = i.indexrelid
              JOIN pg_am am ON am.oid = c.relam
              WHERE i.indrelid = '"Case".dst'::regclass AND am.amname = 'gin')
      FROM pg_index WHERE indrelid = '"Case".dst'::regclass;
      """

  Scenario: A failed local clone rolls back the auto-created gin target and unlocks the source
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, items integer[]);
      CREATE INDEX t_items ON public.t USING gin (items);
      INSERT INTO public.t
      SELECT i, ARRAY[i % 7, i % 3] FROM generate_series(1, 500) AS i;
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = 24;
      SET pagecopy.debug_corrupt_index_ordinal = 2;
      SELECT pagecopy.clone('public.t', 'public.auto_created', true);
      """
    Then the following SQL on "target" returns "0|0":
      """
      SELECT (SELECT count(*) FROM pg_tables WHERE tablename = 'auto_created'),
             (SELECT count(*) FROM pg_locks WHERE relation = 'public.t'::regclass)
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.t', 'public.auto_created', true);
      """
    Then the following SQL on "target" returns "t|500":
      """
      SELECT bool_and(indisvalid AND indisready),
             (SELECT count(*) FROM public.auto_created)
      FROM pg_index WHERE indrelid = 'public.auto_created'::regclass;
      """

  Scenario: Mixed gin, btree and degraded gin indexes auto-create on an absent target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.mix (id integer PRIMARY KEY, items integer[], note text);
      CREATE INDEX mix_items ON public.mix USING gin (items);
      CREATE INDEX mix_note ON public.mix USING btree (note);
      CREATE INDEX mix_expr ON public.mix USING gin (to_tsvector('simple', note));
      INSERT INTO public.mix
      SELECT i, ARRAY[i % 23], 'note' || i FROM generate_series(1, 400) AS i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.mix', 'public.mix_copy', true);
      """
    Then the following SQL on "target" returns "3|1|400|17":
      """
      SELECT count(*) FILTER (WHERE indisvalid AND indisready),
             count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM public.mix_copy),
             (SELECT count(*) FROM public.mix_copy WHERE items @> ARRAY[22])
      FROM pg_index WHERE indrelid = 'public.mix_copy'::regclass;
      """
