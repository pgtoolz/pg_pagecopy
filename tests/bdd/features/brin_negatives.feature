@brin
Feature: BRIN corruption and unsupported-type rejection boundaries

  Only rejection contracts production actually provides are asserted: the
  metapage reader validates block 0 (version, magic, pages_per_range,
  revmap extent against the index size); arbitrary revmap or summary
  structural validation is NOT claimed. Streams that drop index pages hit
  the out-of-order and stream-ended-early checks. Checksum corruption is
  detected at the source read and the incoming page verification. Unsupported
  opclasses, domains and mixed keys degrade to rebuildable definitions.

  Scenario Outline: A corrupted source BRIN metapage is rejected with "<detail>"
    The network pull runs VACUUM (FREEZE) before reading the index
    metadata, and a zero pages_per_range hangs PostgreSQL's own BRIN vacuum
    before pg_pagecopy can reject it; that variant is covered on the local
    clone path below, which never vacuums.
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id bigint, ts timestamptz);
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = <ppr>);
      INSERT INTO public.events
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i)
      FROM generate_series(1, 500) AS i;
      CREATE FUNCTION pc_test_zero_index_page(regclass, integer)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_zero_index_page'
        LANGUAGE C STRICT;
      CREATE FUNCTION pc_test_corrupt_index_byte(regclass, integer, integer)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_corrupt_index_byte'
        LANGUAGE C STRICT;
      <corrupt>
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id bigint, ts timestamptz);
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = <ppr>);
      INSERT INTO public.events VALUES (9999, timestamptz '2030-01-01');
      """
    Then the following SQL on "target" fails with "<detail>":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|9999|t":
      """
      SELECT (SELECT count(*) FROM public.events),
             (SELECT max(id) FROM public.events),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.events_brin'::regclass);
      """

    Examples:
      | ppr | corrupt | detail |
      | 4 | SELECT pc_test_corrupt_index_byte('public.events_brin', 0, 28); | unsupported brin metapage version |

  Scenario Outline: A <case> metapage is rejected on the local clone path
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = <ppr>);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 500) AS i;
      CREATE TABLE public.t_copy (id integer, k bigint);
      CREATE INDEX t_copy_brin ON public.t_copy USING brin (k) WITH (pages_per_range = <ppr>);
      CREATE FUNCTION pc_test_corrupt_index_byte(regclass, integer, integer)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_corrupt_index_byte'
        LANGUAGE C STRICT;
      CREATE FUNCTION pc_test_zero_index_page(regclass, integer)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_zero_index_page'
        LANGUAGE C STRICT;
      <corrupt>
      """
    Then the following SQL on "target" fails with "<detail>":
      """
      SELECT pagecopy.clone('public.t', 'public.t_copy', true);
      """
    And the following SQL on "target" returns "500|0":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT count(*) FROM public.t_copy);
      """

    Examples:
      | case | ppr | corrupt | detail |
      | zero pages_per_range | 255 | SELECT pc_test_corrupt_index_byte('public.t_brin', 0, 32); | brin pages_per_range out of range |
      | uninitialized | 4 | SELECT pc_test_zero_index_page('public.t_brin', 0); | brin page is uninitialized |

  Scenario Outline: A corrupted incoming BRIN metapage fails verification on the target
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id bigint, ts timestamptz);
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = <ppr>);
      INSERT INTO public.events
      SELECT i, timestamptz '2024-01-01' + make_interval(secs => i)
      FROM generate_series(1, 500) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id bigint, ts timestamptz);
      CREATE INDEX events_brin ON public.events USING brin (ts) WITH (pages_per_range = <ppr>);
      INSERT INTO public.events VALUES (9999, timestamptz '2030-01-01');
      """
    Then the following SQL on "target" fails with "index metapage verification failed":
      """
      SET pagecopy.debug_corrupt_index_metapage_offset = <offset>;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|9999|t":
      """
      SELECT (SELECT count(*) FROM public.events),
             (SELECT max(id) FROM public.events),
             (SELECT indisvalid AND indisready FROM pg_index
              WHERE indexrelid = 'public.events_brin'::regclass);
      """

    Examples:
      | ppr | offset |
      | 4   | 28     |
      | 255 | 32     |

  Scenario: An out-of-order incoming index page is rejected
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 4000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t VALUES (9999, 999999);
      """
    Then the following SQL on "target" fails with "out-of-order block":
      """
      SET pagecopy.debug_drop_index_page_relation = 3;
      SET pagecopy.debug_drop_index_page_block = 1;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|999999|t|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(k) FROM public.t),
             indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """

  Scenario Outline: A source <kind> page with a stale checksum fails the export read
    The pull's own VACUUM (FREEZE) rewrites cached index pages over an
    on-disk corruption, so the checksum contract is exercised on the export
    path directly, exactly like the heap-page safety test: freeze and
    checkpoint first, corrupt the file, then stream.
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 4000) AS i;
      """
    And the following SQL is executed on "source":
      """
      VACUUM (FREEZE) public.t;
      """
    And the following SQL is executed on "source":
      """
      CHECKPOINT;
      """
    And the following SQL is executed on "source":
      """
      CREATE FUNCTION pc_test_corrupt_index_page(regclass, integer, integer)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_corrupt_index_page'
        LANGUAGE C STRICT;
      SELECT pc_test_corrupt_index_page('public.t_brin', <block>, 100);
      """
    Then the following SQL on "source" fails with "source page verification failed":
      """
      BEGIN;
      SELECT pagecopy_internal.pagecopy_lock_source('public.t');
      SELECT pagecopy_internal.pagecopy_export_stream('public.t', 'public.t', 0::oid, true, true, false);
      COMMIT;
      """
    And the following SQL on "source" returns "4000":
      """
      SELECT count(*) FROM public.t;
      """

    Examples:
      | block | kind |
      | 1     | revmap |
      | 2     | summary |

  Scenario Outline: An incoming index page with a corrupted checksum fails verification
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t SELECT i, i * 37 FROM generate_series(1, 4000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, k bigint);
      CREATE INDEX t_brin ON public.t USING brin (k) WITH (pages_per_range = 4);
      INSERT INTO public.t VALUES (9999, 999999);
      """
    Then the following SQL on "target" fails with "page verification failed":
      """
      SET pagecopy.debug_corrupt_page_relation = 3;
      SET pagecopy.debug_corrupt_page = <block>;
      SET pagecopy.debug_corrupt_offset = 100;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "1|999999|t|t":
      """
      SELECT (SELECT count(*) FROM public.t),
             (SELECT max(k) FROM public.t),
             indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """

    Examples:
      | block | kind |
      | 1     | revmap |
      | 2     | summary |

  Scenario Outline: Ordinary minmax opclasses outside the approved list degrade to definitions
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
    Then the following SQL on "target" returns "t|t|<eqn>":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SELECT indisvalid, indisready,
             (SELECT count(*) FROM public.t WHERE <eq>)
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      ROLLBACK;
      """

    Examples:
      | coldef    | opc                | value | eq          | eqn |
      | double precision | float8_minmax_ops | i::double precision | k = 500.0 | 1 |
      | uuid      | uuid_minmax_ops    | md5(i::text)::uuid | k = md5('500')::uuid | 1 |
      | interval  | interval_minmax_ops | make_interval(secs => i) | k = make_interval(secs => 500) | 1 |
      | char(8)   | bpchar_minmax_ops  | (i % 10)::text | k = '5' | 100 |

  Scenario: A domain column is rejected as an unsafe type before any transfer
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE DOMAIN public.posint AS integer CHECK (VALUE > 0);
      CREATE TABLE public.t (id integer, k public.posint);
      INSERT INTO public.t SELECT i, (i % 1000) + 1 FROM generate_series(1, 1000) AS i;
      CREATE INDEX t_brin ON public.t USING brin (k int4_minmax_ops);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" contains "brin opclass pg_catalog.int4_minmax_ops on posint":
      """
      SELECT detail FROM pagecopy.check('public.t')
      WHERE name = 't_brin' AND type = 'index';
      """
    Then the following SQL on "target" fails with "unsafe type public.posint":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.t', 'public.t', true
      );
      """
    And the following SQL on "target" returns "0":
      """
      SELECT count(*) FROM pg_class WHERE oid = to_regclass('public.t');
      """

  Scenario: One unsupported key in a multi-column index degrades the whole index
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer, f double precision);
      INSERT INTO public.t SELECT i, i::double precision FROM generate_series(1, 1000) AS i;
      CREATE INDEX t_brin ON public.t
        USING brin (id int4_minmax_ops, f float8_minmax_ops);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "source" returns "definition":
      """
      SELECT method FROM pagecopy.check('public.t')
      WHERE name = 't_brin' AND type = 'index';
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
    Then the following SQL on "target" returns "t|t":
      """
      SELECT indisvalid, indisready
      FROM pg_index WHERE indexrelid = 'public.t_brin'::regclass;
      """
