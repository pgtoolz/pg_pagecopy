@hash @local
Feature: pagecopy.clone transfers HASH indexes inside one cluster

  Local clone auto-creates the target with its hash indexes (keeping the
  source index name only when it is free), replaces an existing matching
  target in place, and rolls the whole clone back on a mid-stream failure.

  Scenario: A populated hash index clones physically, sparse pages included
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k) WITH (fillfactor = 10);
      INSERT INTO public.t SELECT i, i * 3 FROM generate_series(1, 3000) AS i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', true);
      """
    Then the following SQL on "target" returns "t|t|3000":
      """
      SELECT indisvalid AND indisready,
             pg_relation_size(c.oid) >= 111 * 8192,
             (SELECT count(*) FROM public.t_copy)
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam
      WHERE i.indrelid = 'public.t_copy'::regclass AND am.amname = 'hash';
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t_copy SELECT 9000 + i, i * 3 FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "5000|3000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*), count(*) FILTER (WHERE id <= 3000)
      FROM public.t_copy;
      ROLLBACK;
      """

  Scenario: Cloning over an existing target replaces its hash index in place
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t SELECT i, i * 3 FROM generate_series(1, 1500) AS i;
      CREATE TABLE public.t_copy (id integer PRIMARY KEY, k integer);
      CREATE INDEX existing_k ON public.t_copy USING hash (k);
      INSERT INTO public.t_copy VALUES (9999, 999999);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', true);
      """
    Then the following SQL on "target" returns "t|1500|1|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.t_copy),
             (SELECT count(*) FROM public.t_copy WHERE k = 3),
             (SELECT count(*) FROM public.t_copy WHERE k = 999999)
      FROM pg_index WHERE indexrelid = 'public.existing_k'::regclass;
      ROLLBACK;
      """

  Scenario: Clone auto-creation avoids an index-name collision in a case-sensitive schema
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE SCHEMA "Case";
      CREATE TABLE "Case".src (id integer PRIMARY KEY, k integer);
      CREATE INDEX "t_k" ON "Case".src USING hash (k);
      INSERT INTO "Case".src SELECT i, i FROM generate_series(1, 100) AS i;
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
              WHERE i.indrelid = '"Case".dst'::regclass AND am.amname = 'hash')
      FROM pg_index WHERE indrelid = '"Case".dst'::regclass;
      """

  Scenario: A failed local clone rolls back the auto-created hash target and unlocks the source
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k);
      INSERT INTO public.t SELECT i, i FROM generate_series(1, 500) AS i;
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = 24;
      SET pagecopy.debug_corrupt_index_ordinal = 1;
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

  Scenario: Mixed hash, btree and degraded hash indexes auto-create on an absent target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.mix (id integer PRIMARY KEY, k bigint, note text);
      CREATE INDEX mix_k ON public.mix USING hash (k);
      CREATE INDEX mix_note ON public.mix USING btree (note);
      CREATE INDEX mix_body ON public.mix USING hash (note);
      INSERT INTO public.mix SELECT i, i * 2, 'note' || i FROM generate_series(1, 400) AS i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.mix', 'public.mix_copy', true);
      """
    Then the following SQL on "target" returns "3|1|400|1":
      """
      SELECT count(*) FILTER (WHERE indisvalid AND indisready),
             count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM public.mix_copy),
             (SELECT count(*) FROM public.mix_copy WHERE k = 4)
      FROM pg_index WHERE indrelid = 'public.mix_copy'::regclass;
      """
