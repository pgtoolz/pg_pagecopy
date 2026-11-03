Feature: Local table clone inside a single database
  The same-page pipeline as the cross-instance import, but inside one
  postmaster: pagecopy.clone keeps original xids valid in the shared xid
  space, so it never runs VACUUM (FREEZE) and instead inherits the source
  freeze horizons on the target.

  Background:
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """

  @local
  Scenario: Local clone transfers TOAST and btree pages
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.events (
        id integer PRIMARY KEY,
        payload text NOT NULL,
        note text
      );
      INSERT INTO public.events
        SELECT i, repeat(md5(i::text), 700), CASE WHEN i % 2 = 0 THEN 'even' ELSE 'odd' END
        FROM generate_series(1, 500) AS i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.events', 'public.events_copy', true);
      """
    Then the following SQL on "target" returns "500|500|700|even":
      """
      SELECT (SELECT count(*) FROM public.events_copy)
          || '|' || (SELECT count(*) FROM public.events_copy WHERE id BETWEEN 1 AND 500)
          || '|' || (SELECT length(payload) / 32 FROM public.events_copy WHERE id = 42)
          || '|' || (SELECT note FROM public.events_copy WHERE id = 42);
      """

  @local
  Scenario: Local clone transfers unfrozen tuples without VACUUM FREEZE
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.warm (id integer PRIMARY KEY, value text NOT NULL);
      INSERT INTO public.warm VALUES (1, 'one');
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.warm', 'public.warm_copy', false);
      """
    Then the following SQL on "target" returns "1|one|true|true":
      """
      SELECT (SELECT count(*) FROM public.warm_copy)
          || '|' || (SELECT value FROM public.warm_copy WHERE id = 1)
          || '|' || (SELECT bool_and(xmin::text::bigint > 2) FROM public.warm_copy)
          || '|' || (SELECT count(*) = 0 FROM pg_stat_activity
                      WHERE query LIKE '%VACUUM (FREEZE)%' AND state = 'active'
                        AND pid <> pg_backend_pid());
      """

  @local
  Scenario: Local clone inherits freeze horizons and keeps every xid
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.unfrozen (id integer PRIMARY KEY, value text NOT NULL);
      INSERT INTO public.unfrozen
      SELECT i, 'v' || i FROM generate_series(1, 50) AS i;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.unfrozen', 'public.unfrozen_copy', true);
      """
    Then the following SQL on "target" returns "true|true|true|true|50":
      """
      SELECT (SELECT relfrozenxid = (SELECT relfrozenxid FROM pg_class
                                     WHERE oid = 'public.unfrozen'::regclass)
              FROM pg_class WHERE oid = 'public.unfrozen_copy'::regclass)
          || '|' || (SELECT relminmxid = (SELECT relminmxid FROM pg_class
                                          WHERE oid = 'public.unfrozen'::regclass)
                     FROM pg_class WHERE oid = 'public.unfrozen_copy'::regclass)
          || '|' || (SELECT count(*) = 0 FROM (
                (SELECT id, xmin FROM public.unfrozen
                 EXCEPT SELECT id, xmin FROM public.unfrozen_copy)
                UNION ALL
                (SELECT id, xmin FROM public.unfrozen_copy
                 EXCEPT SELECT id, xmin FROM public.unfrozen)) delta)
          || '|' || (SELECT bool_and(xmin::text::bigint > 2) FROM public.unfrozen_copy)
          || '|' || (SELECT count(*) FROM public.unfrozen_copy);
      """
    When the following SQL is executed on "target":
      """
      VACUUM (FREEZE) public.unfrozen_copy;
      """
    Then the following SQL on "target" returns "50":
      """
      SELECT count(*) FROM public.unfrozen_copy;
      """

  @local
  Scenario: Local clone without WAL keeps rows readable
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.small (id integer PRIMARY KEY, value text NOT NULL);
      INSERT INTO public.small VALUES (1, 'one'), (2, 'two');
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.small', 'public.small_copy', false);
      """
    Then the following SQL on "target" returns "2|two":
      """
      SELECT (SELECT count(*) FROM public.small_copy)
          || '|' || (SELECT value FROM public.small_copy WHERE id = 2);
      """

  @local
  Scenario: Local clone rejects the source table as its own target
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.self (id integer PRIMARY KEY);
      INSERT INTO public.self VALUES (1);
      """
    Then the following SQL on "target" fails with "must differ from the source table":
      """
      SELECT pagecopy.clone('public.self', 'public.self', true);
      """

  @local
  Scenario: Local clone preserves HOT dead and aborted tuple versions
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pageinspect;
      CREATE TABLE public.versions (id integer, value text) WITH (autovacuum_enabled = false);
      INSERT INTO public.versions VALUES (1, 'old'), (2, 'deleted');
      UPDATE public.versions SET value = 'hot' WHERE id = 1;
      DELETE FROM public.versions WHERE id = 2;
      """
    And the following SQL is executed on "target":
      """
      BEGIN;
      INSERT INTO public.versions VALUES (3, 'aborted');
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.versions', 'public.versions_copy', true);
      """
    Then the following SQL on "target" returns "1|1|true|true|true":
      """
      WITH source_items AS (
        SELECT lp, t_xmin, t_xmax
        FROM heap_page_items(get_raw_page('public.versions', 0))
      ), target_items AS (
        SELECT lp, t_xmin, t_xmax
        FROM heap_page_items(get_raw_page('public.versions_copy', 0))
      )
      SELECT (SELECT count(*) FROM public.versions_copy)
          || '|' || (SELECT count(*) FROM public.versions_copy WHERE id = 1 AND value = 'hot')
          || '|' || (SELECT count(*) = 0 FROM (
                (SELECT * FROM source_items EXCEPT SELECT * FROM target_items)
                UNION ALL
                (SELECT * FROM target_items EXCEPT SELECT * FROM source_items)) delta)
          || '|' || (SELECT count(*) >= 4 FROM target_items)
          || '|' || (SELECT bool_and(t_xmin::text::bigint > 2) FROM target_items);
      """
    When the following SQL is executed on "target":
      """
      VACUUM (FREEZE) public.versions_copy;
      """
    Then the following SQL on "target" returns "1|hot":
      """
      SELECT count(*) || '|' || min(value) FROM public.versions_copy;
      """

  @local
  Scenario: Local clone preserves TOAST chunk xids and freeze horizons
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pgcrypto;
      CREATE EXTENSION pageinspect;
      CREATE TABLE public.toast_meta (
        id integer PRIMARY KEY,
        external_data bytea,
        extended_data text
      ) WITH (autovacuum_enabled = false);
      ALTER TABLE public.toast_meta ALTER COLUMN external_data SET STORAGE EXTERNAL;
      ALTER TABLE public.toast_meta ALTER COLUMN extended_data SET STORAGE EXTENDED;
      INSERT INTO public.toast_meta VALUES (
        1, decode(repeat('ab', 50000), 'hex'), repeat('payload-' || md5('seed'), 2000)
      );
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.toast_meta', 'public.toast_meta_copy', true);
      """
    Then the following SQL on "target" returns "true|true|true|true":
      """
      WITH source_toast AS (
        SELECT reltoastrelid AS oid FROM pg_class WHERE oid = 'public.toast_meta'::regclass
      ), target_toast AS (
        SELECT reltoastrelid AS oid FROM pg_class WHERE oid = 'public.toast_meta_copy'::regclass
      ), source_items AS (
        SELECT h.lp, h.t_xmin, h.t_xmax
        FROM source_toast s
        CROSS JOIN LATERAL generate_series(0, (pg_relation_size(s.oid) / 8192 - 1)::integer) p
        CROSS JOIN LATERAL heap_page_items(get_raw_page(s.oid::regclass::text, p)) h
      ), target_items AS (
        SELECT h.lp, h.t_xmin, h.t_xmax
        FROM target_toast t
        CROSS JOIN LATERAL generate_series(0, (pg_relation_size(t.oid) / 8192 - 1)::integer) p
        CROSS JOIN LATERAL heap_page_items(get_raw_page(t.oid::regclass::text, p)) h
      )
      SELECT (SELECT s.md5 = t.md5 AND s.text_md5 = t.text_md5
              FROM (SELECT md5(external_data), md5(extended_data) FROM public.toast_meta) s(md5, text_md5)
              CROSS JOIN (SELECT md5(external_data), md5(extended_data) FROM public.toast_meta_copy) t(md5, text_md5))
          || '|' || (SELECT count(*) = 0 FROM (
                (SELECT * FROM source_items EXCEPT SELECT * FROM target_items)
                UNION ALL
                (SELECT * FROM target_items EXCEPT SELECT * FROM source_items)) delta)
          || '|' || (SELECT s.relfrozenxid = t.relfrozenxid AND s.relminmxid = t.relminmxid
                     FROM source_toast st CROSS JOIN target_toast tt
                     JOIN pg_class s ON s.oid = st.oid JOIN pg_class t ON t.oid = tt.oid)
          || '|' || (SELECT count(*) > 0 AND bool_and(t_xmin::text::bigint > 2) FROM target_items);
      """
    When the following SQL is executed on "target":
      """
      VACUUM (FREEZE) public.toast_meta_copy;
      """
    Then the following SQL on "target" returns "t":
      """
      SELECT md5(s.external_data) = md5(t.external_data)
         AND md5(s.extended_data) = md5(t.extended_data)
      FROM public.toast_meta s JOIN public.toast_meta_copy t USING (id);
      """

  @local
  Scenario: Local clone inherits a genuinely old freeze horizon
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.old_source (id integer PRIMARY KEY) WITH (autovacuum_enabled = false);
      INSERT INTO public.old_source SELECT i FROM generate_series(1, 20) i;
      UPDATE pg_class SET relfrozenxid = '3'::xid, relminmxid = '1'::xid
      WHERE oid = 'public.old_source'::regclass;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.old_source', 'public.old_copy', true);
      """
    Then the following SQL on "target" returns "3|1|20":
      """
      SELECT c.relfrozenxid::text || '|' || c.relminmxid::text
          || '|' || (SELECT count(*) FROM public.old_copy)
      FROM pg_class c WHERE c.oid = 'public.old_copy'::regclass;
      """
    When the following SQL is executed on "target":
      """
      VACUUM (FREEZE) public.old_copy;
      """
    Then the following SQL on "target" returns "20":
      """
      SELECT count(*) FROM public.old_copy;
      """

  @local
  Scenario: Local clone copies VM and FSM without marking unfrozen pages frozen
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_visibility;
      CREATE EXTENSION pg_freespacemap;
      CREATE TABLE public.vm_source (id integer, payload text) WITH (autovacuum_enabled = false);
      INSERT INTO public.vm_source SELECT i, md5(i::text) FROM generate_series(1, 1000) i;
      DELETE FROM public.vm_source WHERE id % 10 = 0;
      """
    And the following SQL is executed on "target":
      """
      VACUUM public.vm_source;
      """
    And the following SQL is executed on "target":
      """
      CREATE TABLE public.never_vacuumed (id integer) WITH (autovacuum_enabled = false);
      INSERT INTO public.never_vacuumed VALUES (1);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.vm_source', 'public.vm_copy', true);
      SELECT pagecopy.clone('public.never_vacuumed', 'public.never_vacuumed_copy', true);
      """
    Then the following SQL on "target" returns "true|true|true|true|true":
      """
      WITH source_map AS (
        SELECT * FROM pg_visibility_map('public.vm_source')
      ), target_map AS (
        SELECT * FROM pg_visibility_map('public.vm_copy')
      ), source_free AS (
        SELECT * FROM pg_freespace('public.vm_source')
      ), target_free AS (
        SELECT * FROM pg_freespace('public.vm_copy')
      )
      SELECT (SELECT count(*) = 0 FROM (
                (SELECT * FROM source_map EXCEPT SELECT * FROM target_map)
                UNION ALL
                (SELECT * FROM target_map EXCEPT SELECT * FROM source_map)) delta)
          || '|' || (SELECT bool_or(all_visible) FROM target_map)
          || '|' || (SELECT NOT bool_or(all_frozen) FROM target_map)
          || '|' || (SELECT count(*) = 0 FROM (
                (SELECT * FROM source_free EXCEPT SELECT * FROM target_free)
                UNION ALL
                (SELECT * FROM target_free EXCEPT SELECT * FROM source_free)) delta)
          || '|' || (SELECT count(*) = 0 FROM pg_visibility_map('public.never_vacuumed_copy')
                      WHERE all_visible OR all_frozen);
      """

  @local
  Scenario: A failed local clone rolls back targets and releases the source lock
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.events (id integer PRIMARY KEY, payload text);
      INSERT INTO public.events SELECT i, md5(i::text) FROM generate_series(1, 1000) i;
      CREATE TABLE public.interrupted (id integer PRIMARY KEY, payload text);
      INSERT INTO public.interrupted VALUES (0, 'kept');
      """
    Then the following SQL on "target" fails with "page verification failed":
      """
      SET pagecopy.debug_corrupt_page = 1;
      SET pagecopy.debug_corrupt_offset = 13;
      SELECT pagecopy.clone('public.events', 'public.interrupted', true);
      """
    And the following SQL on "target" fails with "page verification failed":
      """
      SET pagecopy.debug_corrupt_page = 1;
      SET pagecopy.debug_corrupt_offset = 13;
      SELECT pagecopy.clone('public.events', 'public.auto_created', true);
      """
    Then the following SQL on "target" returns "1|kept|true":
      """
      SELECT count(*) || '|' || min(payload)
          || '|' || (to_regclass('public.auto_created') IS NULL)
      FROM public.interrupted;
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      LOCK TABLE public.events IN ACCESS EXCLUSIVE MODE NOWAIT;
      COMMIT;
      """

  @local
  Scenario: Local clone preserves empty and physical column layouts
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.empty_source (id integer PRIMARY KEY);
      CREATE TABLE public.layout_source (
        id integer,
        dropped text,
        n integer DEFAULT 7,
        doubled integer GENERATED ALWAYS AS (n * 2) STORED
      );
      INSERT INTO public.layout_source (id, dropped, n) VALUES (1, 'drop', 3);
      ALTER TABLE public.layout_source DROP COLUMN dropped;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.empty_source', 'public.empty_copy', true);
      SELECT pagecopy.clone('public.layout_source', 'public.layout_copy', true);
      INSERT INTO public.layout_copy(id) VALUES (2);
      """
    Then the following SQL on "target" returns "0|2|7|14|true":
      """
      SELECT (SELECT count(*) FROM public.empty_copy)
          || '|' || (SELECT count(*) FROM public.layout_copy)
          || '|' || (SELECT n FROM public.layout_copy WHERE id = 2)
          || '|' || (SELECT doubled FROM public.layout_copy WHERE id = 2)
          || '|' || (SELECT count(*) = 0 FROM (
                (SELECT attname, attnum, atttypid FROM pg_attribute
                 WHERE attrelid = 'public.layout_source'::regclass
                   AND attnum > 0 AND NOT attisdropped
                 EXCEPT SELECT attname, attnum, atttypid FROM pg_attribute
                 WHERE attrelid = 'public.layout_copy'::regclass
                   AND attnum > 0 AND NOT attisdropped)
                UNION ALL
                (SELECT attname, attnum, atttypid FROM pg_attribute
                 WHERE attrelid = 'public.layout_copy'::regclass
                   AND attnum > 0 AND NOT attisdropped
                 EXCEPT SELECT attname, attnum, atttypid FROM pg_attribute
                 WHERE attrelid = 'public.layout_source'::regclass
                   AND attnum > 0 AND NOT attisdropped)) delta);
      """

  @local
  Scenario: Repeated local clones replace stale target contents
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.repeat_source (id integer PRIMARY KEY);
      INSERT INTO public.repeat_source VALUES (1);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.repeat_source', 'public.copy_a', true);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.repeat_source VALUES (2);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.repeat_source', 'public.copy_b', true);
      """
    When the following SQL is executed on "target":
      """
      INSERT INTO public.repeat_source VALUES (3);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.repeat_source', 'public.copy_a', true);
      """
    Then the following SQL on "target" returns "3|3|2|2|true":
      """
      SELECT (SELECT count(*) FROM public.copy_a)
          || '|' || (SELECT max(id) FROM public.copy_a)
          || '|' || (SELECT count(*) FROM public.copy_b)
          || '|' || (SELECT max(id) FROM public.copy_b)
          || '|' || (SELECT s.relfrozenxid = a.relfrozenxid AND s.relminmxid = a.relminmxid
                     FROM pg_class s, pg_class a
                     WHERE s.oid = 'public.repeat_source'::regclass
                       AND a.oid = 'public.copy_a'::regclass);
      """

  @local
  Scenario: Local clone rejects unlogged sources and targets without changes
    Given the following SQL is executed on "target":
      """
      CREATE UNLOGGED TABLE public.unlogged_source (id integer PRIMARY KEY);
      INSERT INTO public.unlogged_source VALUES (1);
      CREATE TABLE public.logged_target (id integer PRIMARY KEY, value text);
      INSERT INTO public.logged_target VALUES (0, 'kept');
      CREATE TABLE public.logged_source (id integer PRIMARY KEY);
      INSERT INTO public.logged_source VALUES (1);
      CREATE UNLOGGED TABLE public.unlogged_target (id integer PRIMARY KEY, value text);
      INSERT INTO public.unlogged_target VALUES (0, 'kept');
      """
    Then the following SQL on "target" fails with "only plain logged tables transfer":
      """
      SELECT pagecopy.clone('public.unlogged_source', 'public.logged_target', true);
      """
    And the following SQL on "target" fails with "only plain logged tables transfer":
      """
      SELECT pagecopy.clone('public.logged_source', 'public.unlogged_target', true);
      """
    Then the following SQL on "target" returns "kept|kept":
      """
      SELECT (SELECT value FROM public.logged_target)
          || '|' || (SELECT value FROM public.unlogged_target);
      """

  @local
  Scenario: Local clone rejects a non-superuser before changing the target
    Given the following SQL is executed on "target":
      """
      CREATE ROLE loader LOGIN;
      CREATE TABLE public.secure_source (id integer PRIMARY KEY);
      INSERT INTO public.secure_source VALUES (1);
      CREATE TABLE public.secure_target (id integer PRIMARY KEY, value text);
      INSERT INTO public.secure_target VALUES (0, 'kept');
      ALTER TABLE public.secure_target OWNER TO loader;
      GRANT USAGE ON SCHEMA pagecopy TO loader;
      GRANT EXECUTE ON FUNCTION pagecopy.clone(text, text, boolean) TO loader;
      """
    Then the following SQL on "target" fails with "physical source export requires superuser":
      """
      SET ROLE loader;
      SELECT pagecopy.clone('public.secure_source', 'public.secure_target', true);
      """
    Then the following SQL on "target" returns "kept":
      """
      SELECT value FROM public.secure_target;
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      LOCK TABLE public.secure_source IN ACCESS EXCLUSIVE MODE NOWAIT;
      COMMIT;
      """
