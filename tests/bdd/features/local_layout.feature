Feature: Local clone physical layout edge cases

  Background:
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """

  @local
  Scenario: Local clone preserves a wide null bitmap and every attribute number
    Given the following SQL is executed on "target":
      """
      DO $do$
      DECLARE
        columns_sql text;
        values_sql text;
      BEGIN
        SELECT string_agg(format('c%s integer', i), ', ' ORDER BY i),
               string_agg(format('CASE WHEN %s %% 3 = 0 THEN NULL ELSE %s END', i, i), ', ' ORDER BY i)
        INTO columns_sql, values_sql
        FROM generate_series(1, 70) i;
        EXECUTE format('CREATE TABLE public.wide_source (id integer PRIMARY KEY, %s)', columns_sql);
        EXECUTE format('INSERT INTO public.wide_source SELECT 1, %s', values_sql);
      END
      $do$;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.wide_source', 'public.wide_copy', true);
      """
    Then the following SQL on "target" returns "1|47|true|true":
      """
      SELECT (SELECT count(*) FROM public.wide_copy)
          || '|' || (SELECT count(*) FROM public.wide_copy w
                     CROSS JOIN LATERAL jsonb_object_keys(to_jsonb(w)) AS keys(key)
                     WHERE to_jsonb(w) ->> keys.key IS NOT NULL AND keys.key ~ '^c')
          || '|' || (SELECT to_jsonb(s) = to_jsonb(t)
                     FROM public.wide_source s JOIN public.wide_copy t USING (id))
          || '|' || (SELECT count(*) = 0 FROM (
                (SELECT attnum, atttypid, attlen, attbyval, attalign, attnotnull
                 FROM pg_attribute WHERE attrelid = 'public.wide_source'::regclass AND attnum > 0
                 EXCEPT SELECT attnum, atttypid, attlen, attbyval, attalign, attnotnull
                 FROM pg_attribute WHERE attrelid = 'public.wide_copy'::regclass AND attnum > 0)
                UNION ALL
                (SELECT attnum, atttypid, attlen, attbyval, attalign, attnotnull
                 FROM pg_attribute WHERE attrelid = 'public.wide_copy'::regclass AND attnum > 0
                 EXCEPT SELECT attnum, atttypid, attlen, attbyval, attalign, attnotnull
                 FROM pg_attribute WHERE attrelid = 'public.wide_source'::regclass AND attnum > 0)) delta);
      """

  @local
  Scenario: Local clone handles a table with zero user columns
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.zero_columns ();
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.zero_columns', 'public.zero_copy', true);
      """
    Then the following SQL on "target" returns "0|0|1":
      """
      SELECT (SELECT count(*) FROM public.zero_copy)
          || '|' || (SELECT count(*) FROM pg_attribute
                     WHERE attrelid = 'public.zero_copy'::regclass AND attnum > 0)
          || '|' || (SELECT count(*) FROM pg_class
                     WHERE oid = 'public.zero_copy'::regclass AND relkind = 'r');
      """

  @local
  Scenario: Local clone preserves live dead and aborted TOAST versions
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pgcrypto;
      CREATE EXTENSION pageinspect;
      CREATE TABLE public.toast_churn (id integer PRIMARY KEY, payload bytea)
      WITH (autovacuum_enabled = false);
      ALTER TABLE public.toast_churn ALTER COLUMN payload SET STORAGE EXTERNAL;
      INSERT INTO public.toast_churn VALUES
        (1, decode(repeat('a', 80000), 'hex')),
        (2, decode(repeat('b', 80000), 'hex'));
      UPDATE public.toast_churn
      SET payload = decode(repeat('c', 90000), 'hex') WHERE id = 1;
      DELETE FROM public.toast_churn WHERE id = 2;
      """
    And the following SQL is executed on "target":
      """
      BEGIN;
      INSERT INTO public.toast_churn VALUES (3, decode(repeat('d', 90000), 'hex'));
      ROLLBACK;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.toast_churn', 'public.toast_churn_copy', true);
      """
    Then the following SQL on "target" returns "true|true":
      """
      WITH source_toast AS (
        SELECT reltoastrelid AS oid FROM pg_class WHERE oid = 'public.toast_churn'::regclass
      ), target_toast AS (
        SELECT reltoastrelid AS oid FROM pg_class WHERE oid = 'public.toast_churn_copy'::regclass
      ), source_pages AS (
        SELECT p, md5(substring(get_raw_page(s.oid::regclass::text, p) FROM 25)) AS page_hash
        FROM source_toast s
        CROSS JOIN LATERAL generate_series(0, (pg_relation_size(s.oid) / 8192 - 1)::integer) p
      ), target_pages AS (
        SELECT p, md5(substring(get_raw_page(t.oid::regclass::text, p) FROM 25)) AS page_hash
        FROM target_toast t
        CROSS JOIN LATERAL generate_series(0, (pg_relation_size(t.oid) / 8192 - 1)::integer) p
      )
      SELECT (SELECT count(*) = 0 FROM (
                (SELECT * FROM source_pages EXCEPT SELECT * FROM target_pages)
                UNION ALL
                (SELECT * FROM target_pages EXCEPT SELECT * FROM source_pages)) delta)
          || '|' || (SELECT s.relfrozenxid = t.relfrozenxid AND s.relminmxid = t.relminmxid
                     FROM source_toast st CROSS JOIN target_toast tt
                     JOIN pg_class s ON s.oid = st.oid JOIN pg_class t ON t.oid = tt.oid);
      """
    Then the following SQL on "target" returns "1|true":
      """
      SELECT count(*) || '|' || bool_and(s.payload = t.payload)
      FROM public.toast_churn s JOIN public.toast_churn_copy t USING (id);
      """
    When the following SQL is executed on "target":
      """
      VACUUM (FREEZE) public.toast_churn_copy;
      """
    Then the following SQL on "target" returns "1|true":
      """
      SELECT count(*) || '|' || bool_and(s.payload = t.payload)
      FROM public.toast_churn s JOIN public.toast_churn_copy t USING (id);
      """

  @local
  Scenario: Local clone rejects a different physical attribute layout without data loss
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.layout_mismatch_source (id integer, value text, amount bigint);
      INSERT INTO public.layout_mismatch_source VALUES (1, 'new', 10);
      CREATE TABLE public.layout_mismatch_target (id integer, amount bigint, value text);
      INSERT INTO public.layout_mismatch_target VALUES (0, 99, 'kept');
      """
    Then the following SQL on "target" fails with "source and target table attributes differ":
      """
      SELECT pagecopy.clone(
        'public.layout_mismatch_source', 'public.layout_mismatch_target', true
      );
      """
    Then the following SQL on "target" returns "1|kept|99":
      """
      SELECT count(*) || '|' || min(value) || '|' || min(amount)
      FROM public.layout_mismatch_target;
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      LOCK TABLE public.layout_mismatch_source IN ACCESS EXCLUSIVE MODE NOWAIT;
      COMMIT;
      """

  @local
  Scenario: Local clone rejects automatic serial target creation cleanly
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.auto_serial_source (id serial PRIMARY KEY, value text);
      INSERT INTO public.auto_serial_source(value) VALUES ('one');
      """
    Then the following SQL on "target" fails with "automatic target creation does not support serial/nextval defaults":
      """
      SELECT pagecopy.clone('public.auto_serial_source', 'public.auto_serial_target', true);
      """
    Then the following SQL on "target" returns "true|1":
      """
      SELECT (to_regclass('public.auto_serial_target') IS NULL)
          || '|' || (SELECT last_value FROM public.auto_serial_source_id_seq);
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      LOCK TABLE public.auto_serial_source IN ACCESS EXCLUSIVE MODE NOWAIT;
      COMMIT;
      """

  @local
  Scenario: Local clone rejects non-heap relation kinds without creating targets
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.parent_source (id integer) PARTITION BY RANGE (id);
      CREATE TABLE public.child_source PARTITION OF public.parent_source FOR VALUES FROM (1) TO (10);
      CREATE VIEW public.view_source AS SELECT 1 AS id;
      CREATE MATERIALIZED VIEW public.matview_source AS SELECT 1 AS id;
      """
    Then the following SQL on "target" fails with "partitioned: transfer partitions individually":
      """
      SELECT pagecopy.clone('public.parent_source', 'public.parent_target', true);
      """
    And the following SQL on "target" fails with "view: only plain logged tables transfer":
      """
      SELECT pagecopy.clone('public.view_source', 'public.view_target', true);
      """
    And the following SQL on "target" fails with "materialized view: only plain logged tables transfer":
      """
      SELECT pagecopy.clone('public.matview_source', 'public.matview_target', true);
      """
    Then the following SQL on "target" returns "true|true|true":
      """
      SELECT (to_regclass('public.parent_target') IS NULL)
          || '|' || (to_regclass('public.view_target') IS NULL)
          || '|' || (to_regclass('public.matview_target') IS NULL);
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      LOCK TABLE public.child_source IN ACCESS EXCLUSIVE MODE NOWAIT;
      COMMIT;
      """
