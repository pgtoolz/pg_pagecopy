@gist @local
Feature: pagecopy.clone transfers GIST indexes inside one cluster

  Local clone auto-creates the target with its gist indexes (keeping the
  source index name only when it is free), replaces an existing matching
  target in place, and rolls the whole clone back on a mid-stream failure.

  Scenario: A populated GIST index clones physically
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t
      SELECT i, point((i % 199) - 99, ((i * 13) % 197) - 98)
      FROM generate_series(1, 3000) AS i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', true);
      """
    Then the following SQL on "target" returns "t|t|3000|3000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             pg_relation_size(c.oid) > 8192,
             (SELECT count(*) FROM public.t_copy),
             (SELECT count(*) FROM public.t_copy
                WHERE p <@ box(point(-99, -98), point(99, 98)))
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_am am ON am.oid = c.relam
      WHERE i.indrelid = 'public.t_copy'::regclass AND am.amname = 'gist';
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t_copy
      SELECT 9000 + i, point((i % 199) - 99, ((i * 13) % 197) - 98)
      FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "5000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.t_copy;
      ROLLBACK;
      """

  Scenario: Cloning over an existing target replaces its GIST index in place
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t
      SELECT i, point(i, i) FROM generate_series(1, 1500) AS i;
      CREATE TABLE public.t_copy (id integer PRIMARY KEY, p point);
      CREATE INDEX existing_p ON public.t_copy USING gist (p);
      INSERT INTO public.t_copy VALUES (9999, point(9999, 9999));
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', true);
      """
    Then the following SQL on "target" returns "1500|0|1|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t_copy),
             (SELECT count(*) FROM public.t_copy WHERE id = 9999),
             (SELECT count(*) FROM public.t_copy WHERE p ~= point(500, 500)),
             (SELECT indisvalid AND indisready FROM pg_index
                WHERE indexrelid = 'public.existing_p'::regclass);
      ROLLBACK;
      """

  Scenario: A failed local clone rolls back the auto-created GIST target and unlocks the source
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t
      SELECT i, point(i, i) FROM generate_series(1, 500) AS i;
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = 8184;
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

  Scenario: Mixed gist, btree and degraded GIST indexes auto-create on an absent target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.mix (id integer PRIMARY KEY, p point, b box, note text);
      CREATE INDEX mix_p ON public.mix USING gist (p);
      CREATE INDEX mix_note ON public.mix USING btree (note);
      CREATE INDEX mix_b ON public.mix USING gist (b);
      INSERT INTO public.mix
      SELECT i, point(i, i), box(point(i, i), point(i + 5, i + 5)), 'note' || i
      FROM generate_series(1, 400) AS i;
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
             (SELECT count(*) FROM public.mix_copy WHERE p ~= point(4, 4))
      FROM pg_index WHERE indrelid = 'public.mix_copy'::regclass;
      """
