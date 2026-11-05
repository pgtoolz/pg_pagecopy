@gist @recovery
Feature: GIST transfers survive WAL, checksum and restart combinations

  GIST pages are standard pages (keys in the item area, no data in the
  [pd_lower, pd_upper) hole), so they use the ordinary whole-page WAL path.
  The transferred pages carry the GistBuildLSN NSN stamp, which crash
  recovery restores byte for byte together with the page contents.

  Scenario: WAL full-page images restore the GIST root and leaf pages
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.scatter (id integer PRIMARY KEY, p point);
      CREATE INDEX scatter_p ON public.scatter USING gist (p) WITH (fillfactor = 10);
      INSERT INTO public.scatter
      SELECT i, point((i % 199) - 99, ((i * 13) % 197) - 98)
      FROM generate_series(1, 3000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CHECKPOINT;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.scatter', 'public.scatter', true
      );
      """
    And target relation "public.scatter_p" block 0 is recorded as a gist "root" page
    And target relation "public.scatter_p" block 1 is recorded as a gist "leaf" page
    And target postmaster is crashed
    And the recorded target data file is removed
    And target postmaster is started
    Then the recorded target block is unchanged after crash recovery except the WAL hole
    And the following SQL on "target" returns "t|3000|3000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.scatter),
             (SELECT count(*) FROM public.scatter
                WHERE p <@ box(point(-99, -98), point(99, 98)))
      FROM pg_index WHERE indexrelid = 'public.scatter_p'::regclass;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.scatter
      SELECT 9000 + i, point((i % 199) - 99, ((i * 13) % 197) - 98)
      FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "5000|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.scatter
                WHERE p <@ box(point(-99, -98), point(99, 98))),
             (SELECT indisvalid AND indisready FROM pg_index
                WHERE indexrelid = 'public.scatter_p'::regclass);
      ROLLBACK;
      """
    And target data checksums verify after a clean shutdown

  Scenario: A no-WAL GIST import survives an intact restart and keeps growing
    Given a fresh PostgreSQL pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.scatter (id integer PRIMARY KEY, p point);
      CREATE INDEX scatter_p ON public.scatter USING gist (p);
      INSERT INTO public.scatter
      SELECT i, point((i % 199) - 99, ((i * 13) % 197) - 98)
      FROM generate_series(1, 3000) AS i;
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.scatter', 'public.scatter', false
      );
      """
    And target relation "public.scatter_p" block 0 is recorded as a gist "root" page
    And target postmaster is crashed and restarted
    Then the recorded target block is unchanged after crash recovery
    And the following SQL on "target" returns "t|3000|3000":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.scatter),
             (SELECT count(*) FROM public.scatter
                WHERE p <@ box(point(-99, -98), point(99, 98)))
      FROM pg_index WHERE indexrelid = 'public.scatter_p'::regclass;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.scatter
      SELECT 9000 + i, point((i % 199) - 99, ((i * 13) % 197) - 98)
      FROM generate_series(1, 2000) AS i;
      """
    Then the following SQL on "target" returns "5000|t":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT (SELECT count(*) FROM public.scatter
                WHERE p <@ box(point(-99, -98), point(99, 98))),
             (SELECT indisvalid AND indisready FROM pg_index
                WHERE indexrelid = 'public.scatter_p'::regclass);
      ROLLBACK;
      """
    And target data checksums verify after a clean shutdown

  Scenario Outline: WAL <wal> with checksums <checksums> transfers and accepts writes
    Given a fresh PostgreSQL pair with checksums "<checksums>"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.t (id integer PRIMARY KEY, p point);
      CREATE INDEX t_p ON public.t USING gist (p);
      INSERT INTO public.t
      SELECT i, point((i % 199) - 99, ((i * 13) % 197) - 98)
      FROM generate_series(1, 1200) AS i;
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
    Then the following SQL on "target" returns "t|1200|1200":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT indisvalid AND indisready,
             (SELECT count(*) FROM public.t),
             (SELECT count(*) FROM public.t
                WHERE p <@ box(point(-99, -98), point(99, 98)))
      FROM pg_index WHERE indexrelid = 'public.t_p'::regclass;
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.t
      SELECT 9000 + i, point((i % 199) - 99, ((i * 13) % 197) - 98)
      FROM generate_series(1, 300) AS i;
      """
    Then the following SQL on "target" returns "1500":
      """
      BEGIN;
      SET LOCAL enable_seqscan = off;
      SET LOCAL enable_bitmapscan = off;
      SELECT count(*) FROM public.t;
      ROLLBACK;
      """

    Examples:
      | wal  | checksums |
      | true | enabled   |
      | true | disabled  |
      | false | enabled  |
      | false | disabled |
