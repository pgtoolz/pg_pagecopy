@brin @local
Feature: pagecopy.clone transfers BRIN indexes inside one cluster

  The local clone path shares the physical pipeline but never runs
  VACUUM (FREEZE), so unsummarized and desummarized ranges are preserved
  as-is, mixed frozen/unfrozen tuples keep their xids, and rollback,
  savepoints, WAL choices and crash recovery behave like the network path.

  Background:
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """

  Scenario Outline: A populated <label> index with pages_per_range <ppr> clones physically
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.t (id integer, k <coldef>);
      CREATE INDEX t_brin ON public.t USING brin (k <opc>) WITH (pages_per_range = <ppr>);
      <datagen>
      CREATE TABLE public.t_copy (id integer, k <coldef>);
      CREATE INDEX t_copy_brin ON public.t_copy USING brin (k <opc>) WITH (pages_per_range = <ppr>);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', true);
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.t_copy_brin'::regclass),
             pg_relation_size('public.t_copy_brin'::regclass) >= 3 * 8192;
      """
    And the following SQL on "target" returns "t":
      """
      SELECT pg_relation_size('public.t_brin'::regclass)
           = pg_relation_size('public.t_copy_brin'::regclass);
      """
    And the following SQL on "target" contains "Bitmap Index Scan on t_copy_brin":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.t_copy WHERE <sel>;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|<seln>":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.t_copy WHERE <sel>;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.t_copy WHERE <sel>;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d)
           || '|' || (SELECT count(*) FROM pc_indexed);
      """

    Examples:
      | label       | ppr | coldef      | opc                   | datagen                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | sel                                        | seln |
      | smallint    | 4   | smallint    | int2_minmax_ops       | INSERT INTO public.t SELECT i, (i % 7 - 3)::smallint FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, (5800 + i)::smallint FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, -32768), (3002, 32767), (3003, NULL), (3004, NULL), (3005, 0);                                                                                                                                                                                                                                                                                          | k > 8000                                   | 201  |
      | integer     | 128 | integer     | int4_minmax_ops       | INSERT INTO public.t SELECT i, (i % 7 - 3)::integer FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, (5800 + i)::integer FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, (-2147483648)::integer), (3002, 2147483647), (3003, NULL), (3004, NULL), (3005, 0);                                                                                                                                                                                                                                                                        | k > 8000                                   | 201  |
      | bigint      | 4   | bigint      | int8_minmax_ops       | INSERT INTO public.t SELECT i, (i % 7 - 3)::bigint FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, (5800 + i)::bigint FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, (-9223372036854775808)::bigint), (3002, 9223372036854775807), (3003, NULL), (3004, NULL), (3005, 0);                                                                                                                                                                                                                                                     | k > 8000                                   | 201  |
      | date        | 128 | date        | date_minmax_ops       | INSERT INTO public.t SELECT i, date '2000-01-01' + (i % 7 - 3) FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, date '2030-01-01' + (i - 2801) FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, date '0001-01-01 BC'), (3002, date 'infinity'), (3003, date '-infinity'), (3004, NULL), (3005, NULL), (3006, date '2000-01-01');                                                                                                                                  | k >= date '2030-01-01'                     | 201  |
      | timestamp   | 4   | timestamp   | timestamp_minmax_ops  | INSERT INTO public.t SELECT i, timestamp '2000-01-01' + make_interval(days => i % 7 - 3) FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, timestamp '2030-01-01' + interval '1 second' * (i - 2801) + interval '1 microsecond' * i FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, timestamp '0001-01-01 00:00:00 BC'), (3002, timestamp 'infinity'), (3003, timestamp '-infinity'), (3004, NULL), (3005, NULL), (3006, timestamp '2000-01-01 00:00:00.000001');                                                                        | k >= timestamp '2030-01-01'                | 201  |
      | timestamptz | 128 | timestamptz | timestamptz_minmax_ops | INSERT INTO public.t SELECT i, timestamptz '2000-01-01 00:00:00+00' + make_interval(days => i % 7 - 3) FROM generate_series(1, 2800) AS i; INSERT INTO public.t SELECT i, timestamptz '2030-01-01 00:00:00+00' + interval '1 second' * (i - 2801) + interval '1 microsecond' * i FROM generate_series(2801, 3000) AS i; INSERT INTO public.t VALUES (3001, timestamptz '0001-01-01 00:00:00+00 BC'), (3002, timestamptz 'infinity'), (3003, timestamptz '-infinity'), (3004, NULL), (3005, NULL), (3006, timestamptz '2024-06-01 00:00:00+00'), (3007, timestamptz '2024-06-01 02:00:00+02'), (3008, timestamptz '2024-05-31 19:00:00-05'), (3009, timestamptz '2024-06-01 00:00:00+00'); | k >= timestamptz '2030-01-01 00:00:00+00' | 201  |

  Scenario: An unsummarized tail survives a local clone and stays queryable
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.tail (id integer, k bigint) WITH (fillfactor = 10);
      CREATE INDEX tail_brin ON public.tail
        USING brin (k) WITH (pages_per_range = 4, autosummarize = off);
      INSERT INTO public.tail
      SELECT i, i * 37 FROM generate_series(1, 6000) AS i;
      CREATE TABLE public.tail_copy (id integer, k bigint) WITH (fillfactor = 10);
      CREATE INDEX tail_copy_brin ON public.tail_copy
        USING brin (k) WITH (pages_per_range = 4, autosummarize = off);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.tail', 'public.tail_copy', true);
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.tail_copy_brin'::regclass;
      """
    And the following SQL on "target" returns "6000|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*), count(*) FILTER (WHERE k = 3700)
      FROM public.tail_copy;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.tail_copy WHERE k < 300;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.tail_copy WHERE k < 300;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """
    And the following SQL on "target" returns "t":
      """
      SELECT brin_summarize_new_values('public.tail_copy_brin'::regclass) > 0;
      """

  Scenario: A desummarized range survives a local clone and stays queryable
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.desum (id integer, k bigint);
      INSERT INTO public.desum SELECT i, i * 37 FROM generate_series(1, 6000) AS i;
      CREATE INDEX desum_brin ON public.desum USING brin (k) WITH (pages_per_range = 4);
      SELECT brin_desummarize_range('public.desum_brin'::regclass, 0);
      CREATE TABLE public.desum_copy (id integer, k bigint);
      CREATE INDEX desum_copy_brin ON public.desum_copy USING brin (k) WITH (pages_per_range = 4);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.desum', 'public.desum_copy', true);
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.desum_copy_brin'::regclass;
      """
    And the following SQL on "target" returns "8|8":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.desum_copy WHERE k < 300;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.desum_copy WHERE k < 300;
      COMMIT;
      SELECT (SELECT count(*) FROM pc_indexed)
           || '|' || (SELECT count(*) FROM pc_sequential);
      """
    And the following SQL on "target" returns "t":
      """
      SELECT brin_summarize_new_values('public.desum_copy_brin'::regclass) > 0;
      """

  Scenario: Mixed frozen and unfrozen tuples, updates and deletes clone with visibility intact
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.vis (id integer, k bigint, payload text);
      INSERT INTO public.vis
      SELECT i, i * 37, repeat(md5(i::text), 100)
      FROM generate_series(1, 1500) AS i;
      """
    And the following SQL is executed on "target":
      """
      VACUUM (FREEZE) public.vis;
      """
    Given the following SQL is executed on "target":
      """
      INSERT INTO public.vis
      SELECT 1500 + i, 1500 * 37 + i * 37, repeat(md5(i::text), 100)
      FROM generate_series(1, 1500) AS i;
      UPDATE public.vis SET k = -k WHERE id <= 100;
      DELETE FROM public.vis WHERE id BETWEEN 200 AND 300;
      CREATE INDEX vis_brin ON public.vis USING brin (k) WITH (pages_per_range = 4);
      CREATE TABLE public.vis_copy (id integer, k bigint, payload text);
      CREATE INDEX vis_copy_brin ON public.vis_copy USING brin (k) WITH (pages_per_range = 4);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.vis', 'public.vis_copy', true);
      """
    Then the following SQL on "target" returns "t|2899|t|100|0":
      """
      SELECT (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.vis_copy_brin'::regclass),
             count(*),
             (SELECT c2.relfrozenxid = c1.relfrozenxid FROM pg_class c1, pg_class c2
              WHERE c1.oid = 'public.vis'::regclass
                AND c2.oid = 'public.vis_copy'::regclass),
             count(*) FILTER (WHERE k < 0),
             count(*) FILTER (WHERE id BETWEEN 200 AND 300)
      FROM public.vis_copy;
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.vis_copy WHERE k < 0;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.vis_copy WHERE k < 0;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """
    When the following SQL is executed on "target":
      """
      UPDATE public.vis_copy SET k = -1000000 WHERE id <= 50;
      """
    And the following SQL is executed on "target":
      """
      VACUUM public.vis_copy;
      """
    Then the following SQL on "target" returns "100":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT count(*) FROM public.vis_copy WHERE k < 0;
      ROLLBACK;
      """

  Scenario: Cloning to a genuinely absent same-schema target creates it; cloning over an existing target replaces it exactly
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.src (id integer, k bigint);
      INSERT INTO public.src SELECT i, i * 37 FROM generate_series(1, 2000) AS i;
      CREATE INDEX src_brin ON public.src USING brin (k) WITH (pages_per_range = 4);
      CREATE TABLE public.existing (id integer, k bigint);
      CREATE INDEX existing_brin ON public.existing USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.existing VALUES (1, 1), (2, 2);
      CREATE TABLE public.src_probe AS
      SELECT c.oid, c.relname FROM pg_class c WHERE c.oid = 'public.src_brin'::regclass;
      CREATE SCHEMA archive;
      """
    Then the following SQL on "target" returns "t|t|t":
      """
      SELECT to_regclass('public.fresh_copy') IS NULL,
             to_regclass('public.fresh_copy2') IS NULL,
             to_regclass('archive.fresh_copy') IS NULL;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.src', 'public.fresh_copy', true);
      SELECT pagecopy.clone('public.src', 'public.existing', true);
      """
    Then the following SQL on "target" returns "2000|74037000|2000|74037000|t|t|t|t":
      """
      SELECT (SELECT count(*) FROM public.fresh_copy),
             (SELECT sum(k) FROM public.fresh_copy),
             (SELECT count(*) FROM public.existing),
             (SELECT sum(k) FROM public.existing),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.existing_brin'::regclass),
             (SELECT count(*) = 1 AND bool_and(indisvalid AND indisready) FROM pg_index
              WHERE indrelid = 'public.fresh_copy'::regclass),
             pg_relation_size((SELECT indexrelid FROM pg_index
                               WHERE indrelid = 'public.fresh_copy'::regclass))
               = pg_relation_size('public.src_brin'::regclass),
             (SELECT count(*) FROM public.src_probe p JOIN pg_class c ON c.oid = p.oid
              WHERE c.relname = p.relname) = 1;
      """
    And the following SQL on "target" returns "t|existing_brin":
      """
      SELECT (SELECT c.relname LIKE 'fresh_copy\_%'
              FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
              WHERE i.indrelid = 'public.fresh_copy'::regclass),
             (SELECT c.relname
              FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
              WHERE i.indrelid = 'public.existing'::regclass);
      """
    And the following SQL on "target" contains "Bitmap Index Scan on fresh_copy_":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.fresh_copy WHERE k = 37000;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.fresh_copy WHERE k = 37000;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.fresh_copy WHERE k = 37000;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d)
           || '|' || (SELECT count(*) FROM pc_indexed);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.src', 'public.fresh_copy2', true);
      SELECT pagecopy.clone('public.src', 'archive.fresh_copy', true);
      """
    Then the following SQL on "target" returns "t|t|2000|src_brin":
      """
      SELECT (SELECT count(*) = 1 AND bool_and(indisvalid AND indisready) FROM pg_index
              WHERE indrelid = 'public.fresh_copy2'::regclass),
             (SELECT c.relname LIKE 'fresh_copy2\_%'
              FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
              WHERE i.indrelid = 'public.fresh_copy2'::regclass),
             (SELECT count(*) FROM public.fresh_copy2),
             (SELECT c.relname
              FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
              WHERE i.indrelid = 'archive.fresh_copy'::regclass);
      """

  Scenario: A degraded text BRIN index auto-creates as an INVALID definition and REINDEXes back
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.textsrc (id integer, body text);
      INSERT INTO public.textsrc
      SELECT i, repeat('x', 40) || i FROM generate_series(1, 2000) AS i;
      CREATE INDEX textsrc_brin ON public.textsrc USING brin (body) WITH (pages_per_range = 4);
      """
    Then the following SQL on "target" returns "definition|t":
      """
      SELECT (SELECT method FROM pagecopy.check('public.textsrc')
              WHERE name = 'textsrc_brin' AND type = 'index'),
             to_regclass('public.text_dst') IS NULL;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.textsrc', 'public.text_dst', true);
      """
    Then the following SQL on "target" returns "1|f|f|t|2000|1":
      """
      SELECT (SELECT count(*) FROM pg_index WHERE indrelid = 'public.text_dst'::regclass),
             (SELECT indisvalid FROM pg_index WHERE indrelid = 'public.text_dst'::regclass),
             (SELECT indisready FROM pg_index WHERE indrelid = 'public.text_dst'::regclass),
             (SELECT c.relname LIKE 'text_dst\_%'
              FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
              WHERE i.indrelid = 'public.text_dst'::regclass),
             (SELECT count(*) FROM public.text_dst),
             (SELECT count(*) FROM public.text_dst WHERE body = repeat('x', 40) || '1');
      """
    When the following SQL is executed on "target":
      """
      REINDEX TABLE public.text_dst;
      """
    Then the following SQL on "target" returns "t|t":
      """
      SELECT (SELECT indisvalid FROM pg_index WHERE indrelid = 'public.text_dst'::regclass),
             (SELECT indisready FROM pg_index WHERE indrelid = 'public.text_dst'::regclass);
      """

  Scenario: Mixed physical, unique, degraded and duplicate index definitions auto-create on an absent target
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.mixsrc (id integer, k bigint, body text);
      INSERT INTO public.mixsrc
      SELECT i, i * 37, repeat('x', 30) || i FROM generate_series(1, 2000) AS i;
      CREATE INDEX mixsrc_phys ON public.mixsrc USING brin (k) WITH (pages_per_range = 4);
      CREATE UNIQUE INDEX mixsrc_uniq ON public.mixsrc (id);
      CREATE INDEX mixsrc_text ON public.mixsrc USING brin (body);
      CREATE INDEX mixsrc_dup1 ON public.mixsrc USING brin (k) WITH (pages_per_range = 4);
      CREATE INDEX mixsrc_dup2 ON public.mixsrc USING brin (k) WITH (pages_per_range = 4);
      CREATE TABLE public.mixsrc_probe AS
      SELECT c.oid, c.relname FROM pg_class c
      WHERE c.oid IN ('public.mixsrc_phys'::regclass, 'public.mixsrc_uniq'::regclass,
                      'public.mixsrc_text'::regclass, 'public.mixsrc_dup1'::regclass,
                      'public.mixsrc_dup2'::regclass);
      """
    Then the following SQL on "target" returns "t":
      """
      SELECT to_regclass('public.mix_dst') IS NULL;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.mixsrc', 'public.mix_dst', true);
      """
    Then the following SQL on "target" returns "5|1|1|4|5|2000|5|5":
      """
      SELECT (SELECT count(*) FROM pg_index WHERE indrelid = 'public.mix_dst'::regclass),
             (SELECT count(*) FROM pg_index WHERE indrelid = 'public.mix_dst'::regclass
              AND indisunique),
             (SELECT count(*) FROM pg_index WHERE indrelid = 'public.mix_dst'::regclass
              AND NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM pg_index WHERE indrelid = 'public.mix_dst'::regclass
              AND indisvalid AND indisready),
             (SELECT count(*) FROM public.mixsrc_probe p JOIN pg_class c ON c.oid = p.oid
              WHERE c.relname = p.relname),
             (SELECT count(*) FROM public.mix_dst),
             (SELECT count(DISTINCT c.relname) FROM pg_index i
              JOIN pg_class c ON c.oid = i.indexrelid
              WHERE i.indrelid = 'public.mix_dst'::regclass),
             (SELECT count(*) FROM pg_index i
              JOIN pg_class c ON c.oid = i.indexrelid
              WHERE i.indrelid = 'public.mix_dst'::regclass AND c.relname LIKE 'mix_dst\_%');
      """
    And the following SQL on "target" contains "Bitmap Index Scan on mix_dst_":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.mix_dst WHERE k = 37000;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.mix_dst WHERE k = 37000;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.mix_dst WHERE k = 37000;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d)
           || '|' || (SELECT count(*) FROM pc_indexed);
      """
    Then the following SQL on "target" fails with "duplicate key value violates unique constraint":
      """
      INSERT INTO public.mix_dst VALUES (1, 37, 'dup');
      """

  Scenario: Savepoint rollback and transaction rollback leave no half-cloned target
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.src (id integer, k bigint);
      INSERT INTO public.src SELECT i, i * 37 FROM generate_series(1, 1000) AS i;
      CREATE INDEX src_brin ON public.src USING brin (k) WITH (pages_per_range = 4);
      CREATE SCHEMA archive;
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      SAVEPOINT before_clone;
      SELECT pagecopy.clone('public.src', 'archive.rolled_back', true);
      ROLLBACK TO SAVEPOINT before_clone;
      COMMIT;
      BEGIN;
      SELECT pagecopy.clone('public.src', 'archive.rolled_back', true);
      ROLLBACK;
      """
    Then the following SQL on "target" returns "0":
      """
      SELECT count(*) FROM pg_class
      WHERE relname LIKE 'rolled_back%'
        AND relnamespace = 'archive'::regnamespace::oid;
      """

  Scenario Outline: Cloning with checksums <checksums> and WAL <wal> survives a crash
    Given a fresh PostgreSQL pair with checksums "<checksums>"
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE public.t (id integer, k bigint);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 4000) AS i;
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      CREATE TABLE public.t_copy (id integer, k bigint);
      CREATE INDEX t_copy_brin ON public.t_copy USING brin (k) WITH (pages_per_range = 4);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', <wal>);
      """
    When target postmaster is crashed and restarted
    Then the following SQL on "target" returns "t|4000|4000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid = 'public.t_copy_brin'::regclass),
             count(*),
             (SELECT count(*) FROM public.t)
FROM public.t_copy;
      ROLLBACK;
      """
    And the following SQL on "target" returns "0|0":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      CREATE TEMP TABLE pc_indexed AS SELECT id FROM public.t_copy WHERE k < 300;
      SET LOCAL enable_seqscan = on;
      SET LOCAL enable_bitmapscan = off;
      CREATE TEMP TABLE pc_sequential AS SELECT id FROM public.t_copy WHERE k < 300;
      COMMIT;
      SELECT (SELECT count(*) FROM (SELECT id FROM pc_indexed
                                    EXCEPT ALL SELECT id FROM pc_sequential) AS d)
           || '|' || (SELECT count(*) FROM (SELECT id FROM pc_sequential
                                            EXCEPT ALL SELECT id FROM pc_indexed) AS d);
      """

    Examples:
      | checksums | wal   |
      | enabled   | true  |
      | enabled   | false |
      | disabled  | true  |
      | disabled  | false |

  Scenario: Invalid and degraded source indexes match through clone by the same rules
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.mix (id integer, body text);
      CREATE INDEX mix_ok ON public.mix USING brin (id) WITH (pages_per_range = 4);
      CREATE INDEX mix_invalid ON public.mix USING brin (id) WITH (pages_per_range = 4);
      INSERT INTO public.mix
      SELECT i, repeat('x', 50) FROM generate_series(1, 2000) AS i;
      UPDATE pg_index SET indisvalid = false, indisready = false
      WHERE indexrelid = 'public.mix_invalid'::regclass;
      CREATE INDEX mix_text ON public.mix USING brin (body);
      CREATE TABLE public.mix_copy (id integer, body text);
      CREATE INDEX mix_copy_ok ON public.mix_copy USING brin (id) WITH (pages_per_range = 4);
      CREATE INDEX mix_copy_invalid ON public.mix_copy USING brin (id) WITH (pages_per_range = 4);
      CREATE INDEX mix_copy_text ON public.mix_copy USING brin (body);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.mix', 'public.mix_copy', true);
      """
    Then the following SQL on "target" returns "3|1|2|2000|2000":
      """
      SELECT count(*),
             count(*) FILTER (WHERE indisvalid AND indisready),
             count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             (SELECT count(*) FROM public.mix_copy),
             (SELECT count(*) FROM public.mix)
      FROM pg_index WHERE indrelid = 'public.mix_copy'::regclass;
      """
    And the following SQL on "target" contains "Bitmap Index Scan on mix_copy_ok":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      EXPLAIN (COSTS OFF) SELECT count(*) FROM public.mix_copy WHERE id > 1900;
      ROLLBACK;
      """

  Scenario: Local crash recovery restores the cloned revmap and summary pages with valid checksums
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE public.t (id integer, k bigint);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 6000) AS i;
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      CREATE TABLE public.t_copy (id integer, k bigint);
      CREATE INDEX t_copy_brin ON public.t_copy USING brin (k) WITH (pages_per_range = 4);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', true);
      """
    When target relation "public.t_copy_brin" block 1 is recorded as a brin "revmap" page
    And target relation "public.t_copy_brin" block 2 is recorded as a brin "summary" page
    And target postmaster is crashed and restarted
    Then the recorded target block is unchanged after crash recovery
    And target data checksums verify after a clean shutdown
    And the following SQL on "target" returns "t|1":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT (SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid = 'public.t_copy_brin'::regclass),
             count(*) FILTER (WHERE k = 3700)
FROM public.t_copy;
      ROLLBACK;
      """

  Scenario: Clone auto-creation avoids an index-name collision in a case-sensitive schema
    Given the following SQL is executed on "target":
      """
      CREATE SCHEMA "Case";
      CREATE TABLE "Case".src (id integer, k bigint);
      INSERT INTO "Case".src SELECT i, i * 37 FROM generate_series(1, 1000) AS i;
      CREATE INDEX src_brin ON "Case".src USING brin (k);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('"Case".src', '"Case".dst', true);
      """
    Then the following SQL on "target" returns "t|t|1000|1000":
      """
      SELECT (SELECT source_index.relname = 'src_brin'
              FROM pg_index AS i
              JOIN pg_class AS source_index ON source_index.oid = i.indexrelid
              WHERE i.indrelid = '"Case".src'::regclass),
             (SELECT target_index.relname <> 'src_brin'
              FROM pg_index AS i
              JOIN pg_class AS target_index ON target_index.oid = i.indexrelid
              WHERE i.indrelid = '"Case".dst'::regclass),
             (SELECT count(*) FROM "Case".src),
             (SELECT count(*) FROM "Case".dst);
      """

  Scenario: Clone auto-creation preserves a free index name in a schema containing a dot
    Given the following SQL is executed on "target":
      """
      CREATE SCHEMA "dest.schema";
      CREATE TABLE public.src (id integer, k bigint);
      INSERT INTO public.src SELECT i, i * 37 FROM generate_series(1, 1000) AS i;
      CREATE INDEX src_brin ON public.src USING brin (k);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.src', '"dest.schema".dst', true);
      """
    Then the following SQL on "target" returns "src_brin|src_brin|1000":
      """
      SELECT (SELECT source_index.relname
              FROM pg_index AS i
              JOIN pg_class AS source_index ON source_index.oid = i.indexrelid
              WHERE i.indrelid = 'public.src'::regclass),
             (SELECT target_index.relname
              FROM pg_index AS i
              JOIN pg_class AS target_index ON target_index.oid = i.indexrelid
              WHERE i.indrelid = '"dest.schema".dst'::regclass),
             (SELECT count(*) FROM "dest.schema".dst);
      """
