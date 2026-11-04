Feature: Production build excludes test-only debug hooks
  Scenario: Every debug GUC is unavailable without test-hooks
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      LOAD 'pg_pagecopy';
      SHOW pagecopy.debug_corrupt_page;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      LOAD 'pg_pagecopy';
      SHOW pagecopy.debug_corrupt_offset;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      LOAD 'pg_pagecopy';
      SHOW pagecopy.debug_corrupt_page_relation;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      LOAD 'pg_pagecopy';
      SHOW pagecopy.debug_corrupt_index_metapage_offset;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      LOAD 'pg_pagecopy';
      SHOW pagecopy.debug_corrupt_index_ordinal;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      LOAD 'pg_pagecopy';
      SHOW pagecopy.debug_drop_index_page_relation;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      LOAD 'pg_pagecopy';
      SHOW pagecopy.debug_drop_index_page_block;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      LOAD 'pg_pagecopy';
      SHOW pagecopy.debug_hold_index_page_block;
      """
    And the following SQL on "source" fails with "unrecognized configuration parameter":
      """
      LOAD 'pg_pagecopy';
      SHOW pagecopy.debug_disable_lz4;
      """

  Scenario: A normal hash pull succeeds on a release build
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, k integer);
      CREATE INDEX t_k ON public.t USING hash (k) WITH (fillfactor = 10);
      INSERT INTO public.t SELECT i, i * 3 FROM generate_series(1, 3000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "t|3000|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.t),
             (SELECT count(*) FROM public.t WHERE k = 3)
      FROM pg_index WHERE indexrelid = 'public.t_k'::regclass;
      ROLLBACK;
      """
