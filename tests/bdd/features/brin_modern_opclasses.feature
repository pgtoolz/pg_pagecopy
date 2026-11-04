@brin
Feature: PG14+ bloom and minmax-multi BRIN opclasses degrade instead of transferring

  These opclasses do not exist on PostgreSQL 13; the file is removed from
  the PG13 image. On PG14-18 they are outside the approved ordinary-minmax
  list and must degrade to rebuildable definitions with exact preflight
  classification, invalid target state and a working REINDEX.

  Scenario Outline: A <opc> BRIN index degrades and rebuilds
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k <coldef>);
      INSERT INTO public.t SELECT i, <value> FROM generate_series(1, 1000) AS i;
      CREATE INDEX t_brin ON public.t USING brin (k <opc>);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "definition|t":
      """
      SELECT (SELECT method FROM pagecopy.check('public.t')
              WHERE name = 't_brin' AND type = 'index'),
             (SELECT detail LIKE '%pg_catalog.<opc> on %'
              FROM pagecopy.check('public.t')
              WHERE name = 't_brin' AND type = 'index')
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    Then the following SQL on "target" returns "f|f|1000":
      """
      SELECT indisvalid, indisready,
             (SELECT count(*) FROM public.t)
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """
    When the following SQL is executed on "target":
      """
      REINDEX INDEX public.t_brin;
      """
    Then the following SQL on "target" returns "t|t|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT indisvalid, indisready,
             (SELECT count(*) FROM public.t WHERE <eq>)
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      ROLLBACK;
      """

    Examples:
      | opc                       | coldef      | value                        | eq     |
      | int4_minmax_multi_ops     | integer     | i                            | k = 500 |
      | int8_minmax_multi_ops     | bigint      | i::bigint                    | k = 500 |
      | timestamp_minmax_multi_ops | timestamp  | timestamp '2000-01-01' + make_interval(secs => i) | k = timestamp '2000-01-01 00:08:20' |
      | timestamptz_minmax_multi_ops | timestamptz | timestamptz '2000-01-01 00:00:00+00' + make_interval(secs => i) | k = timestamptz '2000-01-01 00:08:20+00' |
      | int4_bloom_ops            | integer     | i                            | k = 500 |
      | timestamptz_bloom_ops     | timestamptz | timestamptz '2000-01-01 00:00:00+00' + make_interval(secs => i) | k = timestamptz '2000-01-01 00:08:20+00' |
