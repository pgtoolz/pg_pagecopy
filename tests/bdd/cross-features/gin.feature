@cross-major @gin @cross
Feature: Approved GIN indexes transfer physically across major versions

  The core array_ops keys on int[] and jsonb_ops keys on jsonb are
  byte-stable on PostgreSQL 13-18, so their indexes cross majors as page
  images; a nonempty fastupdate pending list crosses too and keeps
  accumulating on the newer major.

  Scenario Outline: PostgreSQL <source_major> to <target_major> transfers int[] and jsonb gin indexes physically
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (
        id integer PRIMARY KEY,
        items integer[],
        doc jsonb
      );
      CREATE INDEX t_items ON public.t USING gin (items);
      CREATE INDEX t_doc ON public.t USING gin (doc);
      INSERT INTO public.t
      SELECT i, ARRAY[i % 20, 42], jsonb_build_object('k', i % 50, 'v', i)
      FROM generate_series(1, 2000) AS i;
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
    Then the following SQL on "target" returns "2|2|2000":
      """
      SELECT count(*), count(*) FILTER (WHERE indisvalid AND indisready),
             (SELECT count(*) FROM public.t)
      FROM pg_index WHERE indrelid = 'public.t'::regclass
       AND indexrelid <> ('public.t_pkey'::regclass);
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_items":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t WHERE items @> ARRAY[42];
      ROLLBACK;
      """
    And the following SQL on "target" returns "2000|100|40":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t WHERE items @> ARRAY[42]),
             (SELECT count(*) FROM public.t WHERE items @> ARRAY[19]),
             (SELECT count(*) FROM public.t WHERE doc @> '{"k": 7}'::jsonb);
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t VALUES (9999, ARRAY[19], '{"k": 7}');
      """
    Then the following SQL on "target" returns "101|41":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t WHERE items @> ARRAY[19]),
             (SELECT count(*) FROM public.t WHERE doc @> '{"k": 7}'::jsonb);
      ROLLBACK;
      """

    Examples:
      | source_major | target_major |
      | 13           | 14           |
      | 13           | 18           |
      | 17           | 18           |

  Scenario Outline: PostgreSQL 13 to 18 moves a pending list with WAL <wal> and checksums <checksums>
    Given a fresh PostgreSQL 13 to 18 pair with checksums "<checksums>"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, items integer[]);
      CREATE INDEX t_items ON public.t USING gin (items);
      INSERT INTO public.t
      SELECT i, ARRAY[7, i % 7] FROM generate_series(1, 5000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', <wal>
      );
      """
    Then the following SQL on "target" returns "t|t|5000|5000":
      """
      SELECT indisvalid AND indisready,
             pg_relation_size('public.t_items'::regclass) >= 12 * 8192,
             (SELECT count(*) FROM public.t),
             (SELECT count(*) FROM public.t WHERE items @> ARRAY[7])
      FROM pg_index WHERE indexrelid = 'public.t_items'::regclass;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t
      SELECT 10000 + i, ARRAY[7, i % 7] FROM generate_series(1, 2000) AS i;
      SELECT gin_clean_pending_list('public.t_items');
      """
    Then the following SQL on "target" returns "7000|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT count(*) FROM public.t WHERE items @> ARRAY[7]),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_items'::regclass);
      ROLLBACK;
      """

    Examples:
      | wal  | checksums |
      | true | enabled   |
      | true | disabled  |
      | false | enabled  |
      | false | disabled |
