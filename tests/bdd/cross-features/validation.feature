@cross-major @validation
Feature: Cross-major transfer rejects unsafe physical layouts

  Scenario Outline: Downgrade <source_major> to <target_major> is rejected before VACUUM and target changes
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "disabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, payload text);
      INSERT INTO public.events VALUES (1, 'source');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, payload text);
      INSERT INTO public.events VALUES (42, 'kept');
      """
    Then the following SQL on "target" fails with "PostgreSQL major":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|42|kept":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """
    And the following SQL on "source" returns "0|0":
      """
      SELECT vacuum_count, autovacuum_count FROM pg_stat_user_tables
      WHERE relid = 'public.events'::regclass;
      """

    Examples:
      | source_major | target_major |
      | 18           | 17           |
      | 18           | 16           |
      | 17           | 16           |
      | 18           | 15           |
      | 17           | 15           |
      | 16           | 15           |
      | 18           | 14           |
      | 17           | 14           |
      | 16           | 14           |
      | 15           | 14           |
      | 18           | 13           |
      | 17           | 13           |
      | 16           | 13           |
      | 15           | 13           |
      | 14           | 13           |

  Scenario Outline: Different checksum modes are rejected before VACUUM
    Given a fresh PostgreSQL <source_major> to <target_major> pair with source checksums "<source_checksums>" and target checksums "<target_checksums>"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY);
      INSERT INTO public.events VALUES (1);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY);
      INSERT INTO public.events VALUES (42);
      """
    Then the following SQL on "target" fails with "data checksums":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|42":
      """
      SELECT count(*), min(id) FROM public.events;
      """
    And the following SQL on "source" returns "0|0":
      """
      SELECT vacuum_count, autovacuum_count FROM pg_stat_user_tables
      WHERE relid = 'public.events'::regclass;
      """

    Examples:
      | source_major | target_major | source_checksums | target_checksums |
      | 13           | 14           | disabled          | enabled         |
      | 13           | 14           | enabled          | disabled         |
      | 13           | 15           | disabled          | enabled         |
      | 13           | 15           | enabled          | disabled         |
      | 13           | 16           | disabled          | enabled         |
      | 13           | 16           | enabled          | disabled         |
      | 13           | 17           | disabled          | enabled         |
      | 13           | 17           | enabled          | disabled         |
      | 13           | 18           | disabled          | enabled         |
      | 13           | 18           | enabled          | disabled         |
      | 14           | 15           | disabled          | enabled         |
      | 14           | 15           | enabled          | disabled         |
      | 14           | 16           | disabled          | enabled         |
      | 14           | 16           | enabled          | disabled         |
      | 14           | 17           | disabled          | enabled         |
      | 14           | 17           | enabled          | disabled         |
      | 14           | 18           | disabled          | enabled         |
      | 14           | 18           | enabled          | disabled         |
      | 15           | 16           | disabled          | enabled         |
      | 15           | 16           | enabled          | disabled         |
      | 15           | 17           | disabled          | enabled         |
      | 15           | 17           | enabled          | disabled         |
      | 15           | 18           | disabled          | enabled         |
      | 15           | 18           | enabled          | disabled         |
      | 16           | 17           | disabled          | enabled         |
      | 16           | 17           | enabled          | disabled         |
      | 16           | 18           | disabled          | enabled         |
      | 16           | 18           | enabled          | disabled         |
      | 17           | 18           | disabled          | enabled         |
      | 17           | 18           | enabled          | disabled         |

  Scenario Outline: OID-bearing <label> values are rejected by a <source_major> to <target_major> transfer
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "disabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TYPE public.mood AS ENUM ('happy', 'sad');
      CREATE TABLE public.events(id integer PRIMARY KEY, unsafe_value <type>);
      INSERT INTO public.events VALUES (1, <value>);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TYPE public.mood AS ENUM ('sad', 'happy');
      """
    Then the following SQL on "target" fails with "unsafe type":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.imported_events', true
      );
      """
    And the following SQL on "target" returns "NULL":
      """
      SELECT to_regclass('public.imported_events');
      """

    Examples:
      | source_major | target_major | label            | type                | value                       |
      | 13           | 14           | enum             | public.mood         | 'happy'::public.mood        |
      | 13           | 14           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 13           | 14           | regclass         | regclass            | 'pg_class'::regclass        |
      | 13           | 14           | OID              | oid                 | 42                          |
      | 13           | 14           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 13           | 14           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 13           | 14           | system composite | pg_class            | NULL::pg_class              |
      | 13           | 15           | enum             | public.mood         | 'happy'::public.mood        |
      | 13           | 15           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 13           | 15           | regclass         | regclass            | 'pg_class'::regclass        |
      | 13           | 15           | OID              | oid                 | 42                          |
      | 13           | 15           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 13           | 15           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 13           | 15           | system composite | pg_class            | NULL::pg_class              |
      | 13           | 16           | enum             | public.mood         | 'happy'::public.mood        |
      | 13           | 16           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 13           | 16           | regclass         | regclass            | 'pg_class'::regclass        |
      | 13           | 16           | OID              | oid                 | 42                          |
      | 13           | 16           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 13           | 16           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 13           | 16           | system composite | pg_class            | NULL::pg_class              |
      | 13           | 17           | enum             | public.mood         | 'happy'::public.mood        |
      | 13           | 17           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 13           | 17           | regclass         | regclass            | 'pg_class'::regclass        |
      | 13           | 17           | OID              | oid                 | 42                          |
      | 13           | 17           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 13           | 17           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 13           | 17           | system composite | pg_class            | NULL::pg_class              |
      | 13           | 18           | enum             | public.mood         | 'happy'::public.mood        |
      | 13           | 18           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 13           | 18           | regclass         | regclass            | 'pg_class'::regclass        |
      | 13           | 18           | OID              | oid                 | 42                          |
      | 13           | 18           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 13           | 18           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 13           | 18           | system composite | pg_class            | NULL::pg_class              |
      | 14           | 15           | enum             | public.mood         | 'happy'::public.mood        |
      | 14           | 15           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 14           | 15           | regclass         | regclass            | 'pg_class'::regclass        |
      | 14           | 15           | OID              | oid                 | 42                          |
      | 14           | 15           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 14           | 15           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 14           | 15           | system composite | pg_class            | NULL::pg_class              |
      | 14           | 16           | enum             | public.mood         | 'happy'::public.mood        |
      | 14           | 16           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 14           | 16           | regclass         | regclass            | 'pg_class'::regclass        |
      | 14           | 16           | OID              | oid                 | 42                          |
      | 14           | 16           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 14           | 16           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 14           | 16           | system composite | pg_class            | NULL::pg_class              |
      | 14           | 17           | enum             | public.mood         | 'happy'::public.mood        |
      | 14           | 17           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 14           | 17           | regclass         | regclass            | 'pg_class'::regclass        |
      | 14           | 17           | OID              | oid                 | 42                          |
      | 14           | 17           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 14           | 17           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 14           | 17           | system composite | pg_class            | NULL::pg_class              |
      | 14           | 18           | enum             | public.mood         | 'happy'::public.mood        |
      | 14           | 18           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 14           | 18           | regclass         | regclass            | 'pg_class'::regclass        |
      | 14           | 18           | OID              | oid                 | 42                          |
      | 14           | 18           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 14           | 18           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 14           | 18           | system composite | pg_class            | NULL::pg_class              |
      | 15           | 16           | enum             | public.mood         | 'happy'::public.mood        |
      | 15           | 16           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 15           | 16           | regclass         | regclass            | 'pg_class'::regclass        |
      | 15           | 16           | OID              | oid                 | 42                          |
      | 15           | 16           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 15           | 16           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 15           | 16           | system composite | pg_class            | NULL::pg_class              |
      | 15           | 17           | enum             | public.mood         | 'happy'::public.mood        |
      | 15           | 17           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 15           | 17           | regclass         | regclass            | 'pg_class'::regclass        |
      | 15           | 17           | OID              | oid                 | 42                          |
      | 15           | 17           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 15           | 17           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 15           | 17           | system composite | pg_class            | NULL::pg_class              |
      | 15           | 18           | enum             | public.mood         | 'happy'::public.mood        |
      | 15           | 18           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 15           | 18           | regclass         | regclass            | 'pg_class'::regclass        |
      | 15           | 18           | OID              | oid                 | 42                          |
      | 15           | 18           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 15           | 18           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 15           | 18           | system composite | pg_class            | NULL::pg_class              |
      | 16           | 17           | enum             | public.mood         | 'happy'::public.mood        |
      | 16           | 17           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 16           | 17           | regclass         | regclass            | 'pg_class'::regclass        |
      | 16           | 17           | OID              | oid                 | 42                          |
      | 16           | 17           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 16           | 17           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 16           | 17           | system composite | pg_class            | NULL::pg_class              |
      | 16           | 18           | enum             | public.mood         | 'happy'::public.mood        |
      | 16           | 18           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 16           | 18           | regclass         | regclass            | 'pg_class'::regclass        |
      | 16           | 18           | OID              | oid                 | 42                          |
      | 16           | 18           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 16           | 18           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 16           | 18           | system composite | pg_class            | NULL::pg_class              |
      | 17           | 18           | enum             | public.mood         | 'happy'::public.mood        |
      | 17           | 18           | enum array       | public.mood[]       | ARRAY['happy'::public.mood] |
      | 17           | 18           | regclass         | regclass            | 'pg_class'::regclass        |
      | 17           | 18           | OID              | oid                 | 42                          |
      | 17           | 18           | oidvector        | oidvector           | '42 43'::oidvector          |
      | 17           | 18           | aclitem          | aclitem             | 'postgres=r/postgres'       |
      | 17           | 18           | system composite | pg_class            | NULL::pg_class              |

  Scenario Outline: Fast defaults are rejected by a <source_major> to <target_major> transfer
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "disabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, payload text);
      INSERT INTO public.events VALUES (1, 'before default');
      ALTER TABLE public.events ADD COLUMN missing_value text NOT NULL DEFAULT 'fast default';
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "target" fails with "missing values":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.imported_events', true
      );
      """
    And the following SQL on "target" returns "NULL":
      """
      SELECT to_regclass('public.imported_events');
      """

    Examples:
      | source_major | target_major |
      | 13           | 14           |
      | 13           | 15           |
      | 13           | 16           |
      | 13           | 17           |
      | 13           | 18           |
      | 14           | 15           |
      | 14           | 16           |
      | 14           | 17           |
      | 14           | 18           |
      | 15           | 16           |
      | 15           | 17           |
      | 15           | 18           |
      | 16           | 17           |
      | 16           | 18           |
      | 17           | 18           |

  Scenario: Virtual generated columns are rejected instead of being recreated as stored
    Given a fresh PostgreSQL 18 to 18 pair with checksums "disabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(
        id integer PRIMARY KEY,
        payload text,
        virtual_value text GENERATED ALWAYS AS (payload || '-virtual') VIRTUAL
      );
      INSERT INTO public.events(id, payload) VALUES (1, 'source');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """
    Then the following SQL on "target" fails with "virtual generated":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.imported_events', true
      );
      """
    And the following SQL on "target" returns "NULL":
      """
      SELECT to_regclass('public.imported_events');
      """

  Scenario Outline: Collation-version drift is rejected by a <source_major> to <target_major> transfer
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "disabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, payload text COLLATE "C");
      INSERT INTO public.events VALUES (1, 'source');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, payload text COLLATE "C");
      INSERT INTO public.events VALUES (42, 'kept');
      UPDATE pg_collation SET collversion = 'bdd-mismatch' WHERE oid = '"C"'::regcollation;
      """
    Then the following SQL on "target" fails with "collation":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|42|kept":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """

    Examples:
      | source_major | target_major |
      | 13           | 14           |
      | 13           | 15           |
      | 13           | 16           |
      | 13           | 17           |
      | 13           | 18           |
      | 14           | 15           |
      | 14           | 16           |
      | 14           | 17           |
      | 14           | 18           |
      | 15           | 16           |
      | 15           | 17           |
      | 15           | 18           |
      | 16           | 17           |
      | 16           | 18           |
      | 17           | 18           |

  Scenario Outline: Unsupported lz4 is rejected by a <source_major> to <target_major> transfer
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "disabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, payload text);
      ALTER TABLE public.events ALTER COLUMN payload SET STORAGE EXTENDED;
      ALTER TABLE public.events ALTER COLUMN payload SET COMPRESSION lz4;
      INSERT INTO public.events VALUES (1, repeat('lz4', 10000));
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY, payload text);
      ALTER TABLE public.events ALTER COLUMN payload SET STORAGE EXTENDED;
      INSERT INTO public.events VALUES (42, 'kept');
      """
    Then the following SQL on "target" fails with "lz4":
      """
      SET pagecopy.debug_disable_lz4 = on;
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "1|42|kept":
      """
      SELECT count(*), min(id), min(payload) FROM public.events;
      """

    Examples:
      | source_major | target_major |
      | 14           | 15           |
      | 14           | 16           |
      | 14           | 17           |
      | 14           | 18           |
      | 15           | 16           |
      | 15           | 17           |
      | 15           | 18           |
      | 16           | 17           |
      | 16           | 18           |
      | 17           | 18           |

  Scenario Outline: A <source_major> to <target_major> export rejects a corrupted source page
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION dblink;
      CREATE TABLE public.events(id integer PRIMARY KEY) WITH (autovacuum_enabled = false);
      INSERT INTO public.events VALUES (1);
      """
    And the following SQL is executed on "source":
      """
      VACUUM (FREEZE) public.events;
      """
    And the following SQL is executed on "source":
      """
      CHECKPOINT;
      """
    And the following SQL is executed on "source":
      """
      CREATE FUNCTION pc_test_corrupt_page(regclass, integer, integer)
      RETURNS void AS 'pc_bdd_fixtures', 'pc_test_corrupt_page'
      LANGUAGE C STRICT;
      SELECT pc_test_corrupt_page('public.events', 0, 100);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(id integer PRIMARY KEY);
      INSERT INTO public.events VALUES (42);
      """
    Then the following SQL on "source" fails with "checksum":
      """
      BEGIN;
      SELECT pagecopy_internal.pagecopy_lock_source('public.events');
      SELECT dblink_exec('host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres', 'CHECKPOINT');
      SELECT pagecopy_internal.pagecopy_export_stream('public.events', 'public.events', 0::oid, true, true, false);
      COMMIT;
      """
    And the following SQL on "source" returns "1":
      """
      SELECT count(*) FROM public.events;
      """
    And the following SQL on "target" returns "1|42":
      """
      SELECT count(*), min(id) FROM public.events;
      """

    Examples:
      | source_major | target_major |
      | 13           | 14           |
      | 13           | 15           |
      | 13           | 16           |
      | 13           | 17           |
      | 13           | 18           |
      | 14           | 15           |
      | 14           | 16           |
      | 14           | 17           |
      | 14           | 18           |
      | 15           | 16           |
      | 15           | 17           |
      | 15           | 18           |
      | 16           | 17           |
      | 16           | 18           |
      | 17           | 18           |
