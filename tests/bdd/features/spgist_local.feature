@spgist @local
Feature: pagecopy.clone transfers SP-GiST indexes inside one cluster

  Local clone auto-creates the target with its spgist indexes (keeping the
  source index name only when it is free), replaces an existing matching
  target in place, and rolls the whole clone back on a mid-stream failure.

  Scenario: A populated spgist index clones physically, nulls tree included
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t
      SELECT i, CASE WHEN i % 13 = 0 THEN NULL
                     ELSE point(i % 97, i % 89) END
      FROM generate_series(1, 3000) AS i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', true);
      """
    Then the following SQL on "target" returns "t|t|3000":
      """
      SELECT indisvalid AND indisready,
             pg_relation_size(c.oid) > 3 * 8192,
             (SELECT count(*) FROM public.t_copy)
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam
      WHERE i.indrelid = 'public.t_copy'::regclass AND am.amname = 'spgist';
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t_copy SELECT 9000 + i, point(i % 83, i % 79) FROM generate_series(1, 2000) AS i;
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

  Scenario: Cloning over an existing target replaces its spgist index in place
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i % 97, i % 89) FROM generate_series(1, 1500) AS i;
      CREATE TABLE public.t_copy (id integer PRIMARY KEY, p point);
      CREATE INDEX existing_q ON public.t_copy USING spgist (p);
      INSERT INTO public.t_copy VALUES (9999, point(-99, -99));
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', true);
      """
    Then the following SQL on "target" returns "t|1500|8|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.t_copy),
             (SELECT count(*) FROM public.t_copy
               WHERE p <@ box(point(0, 0), point(4, 4))),
             (SELECT count(*) FROM public.t_copy
               WHERE p <@ box(point(-100, -100), point(-98, -98)))
      FROM pg_index WHERE indexrelid = 'public.existing_q'::regclass;
      ROLLBACK;
      """

  Scenario: Clone auto-creation avoids an index-name collision in a case-sensitive schema
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE SCHEMA "Case";
      CREATE TABLE "Case".src (id integer PRIMARY KEY, p point);
      CREATE INDEX "t_q" ON "Case".src USING spgist (p);
      INSERT INTO "Case".src SELECT i, point(i, i) FROM generate_series(1, 100) AS i;
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
              WHERE i.indrelid = '"Case".dst'::regclass AND am.amname = 'spgist')
      FROM pg_index WHERE indrelid = '"Case".dst'::regclass;
      """

  Scenario: A failed local clone rolls back the auto-created spgist target and unlocks the source
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_q ON public.t USING spgist (p);
      INSERT INTO public.t SELECT i, point(i, i) FROM generate_series(1, 500) AS i;
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

  Scenario: Mixed spgist, btree and degraded spgist indexes auto-create on an absent target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.mix (id integer PRIMARY KEY, p point, body text);
      CREATE INDEX mix_q ON public.mix USING spgist (p);
      CREATE INDEX mix_body ON public.mix USING btree (body);
      CREATE INDEX mix_text ON public.mix USING spgist (body);
      INSERT INTO public.mix SELECT i, point(i % 97, i % 89), 'note' || i FROM generate_series(1, 400) AS i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.mix', 'public.mix_copy', true);
      """
    Then the following SQL on "target" returns "3|1|400|4":
      """
      SELECT count(*) FILTER (WHERE indisvalid AND indisready),
             count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM public.mix_copy),
             (SELECT count(*) FROM public.mix_copy
               WHERE p <@ box(point(0, 0), point(4, 4)))
      FROM pg_index WHERE indrelid = 'public.mix_copy'::regclass;
      """
