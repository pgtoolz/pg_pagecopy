Feature: Local clone transaction and catalog semantics

  Background:
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      """

  @local
  Scenario: Local clone preserves mixed frozen and unfrozen tuples
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pageinspect;
      CREATE TABLE public.mixed_freeze (id integer PRIMARY KEY, value text)
      WITH (autovacuum_enabled = false);
      INSERT INTO public.mixed_freeze VALUES (1, 'frozen');
      """
    And the following SQL is executed on "target":
      """
      VACUUM (FREEZE) public.mixed_freeze;
      """
    And the following SQL is executed on "target":
      """
      INSERT INTO public.mixed_freeze VALUES (2, 'new');
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.mixed_freeze', 'public.mixed_copy', true);
      """
    Then the following SQL on "target" returns "2|1|1|true|true":
      """
      WITH source_items AS (
        SELECT lp, t_xmin, t_xmax, t_infomask
        FROM heap_page_items(get_raw_page('public.mixed_freeze', 0))
      ), target_items AS (
        SELECT lp, t_xmin, t_xmax, t_infomask
        FROM heap_page_items(get_raw_page('public.mixed_copy', 0))
      )
      SELECT (SELECT count(*) FROM public.mixed_copy)
          || '|' || (SELECT count(*) FROM target_items WHERE (t_infomask & 768) = 768)
          || '|' || (SELECT count(*) FROM target_items WHERE (t_infomask & 768) <> 768)
          || '|' || (SELECT count(*) = 0 FROM (
                (SELECT lp, t_xmin, t_xmax FROM source_items
                 EXCEPT SELECT lp, t_xmin, t_xmax FROM target_items)
                UNION ALL
                (SELECT lp, t_xmin, t_xmax FROM target_items
                 EXCEPT SELECT lp, t_xmin, t_xmax FROM source_items)) delta)
          || '|' || (SELECT s.relfrozenxid = t.relfrozenxid AND s.relminmxid = t.relminmxid
                     FROM pg_class s, pg_class t
                     WHERE s.oid = 'public.mixed_freeze'::regclass
                       AND t.oid = 'public.mixed_copy'::regclass);
      """
    When the following SQL is executed on "target":
      """
      VACUUM (FREEZE) public.mixed_copy;
      """
    Then the following SQL on "target" returns "frozen|new":
      """
      SELECT string_agg(value, '|' ORDER BY id) FROM public.mixed_copy;
      """

  @local
  Scenario: Local clone preserves an aborted subtransaction xid
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION pageinspect;
      CREATE TABLE public.subxid_source (id integer, value text)
      WITH (autovacuum_enabled = false);
      DO $do$
      BEGIN
        INSERT INTO public.subxid_source VALUES (1, 'live');
        BEGIN
          INSERT INTO public.subxid_source VALUES (2, 'aborted subxid');
          RAISE EXCEPTION 'rollback the subtransaction';
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
      END
      $do$;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.subxid_source', 'public.subxid_copy', true);
      """
    Then the following SQL on "target" returns "1|live|2|true|true":
      """
      WITH source_items AS (
        SELECT lp, t_xmin, t_xmax
        FROM heap_page_items(get_raw_page('public.subxid_source', 0))
      ), target_items AS (
        SELECT lp, t_xmin, t_xmax
        FROM heap_page_items(get_raw_page('public.subxid_copy', 0))
      )
      SELECT (SELECT count(*) FROM public.subxid_copy)
          || '|' || (SELECT value FROM public.subxid_copy)
          || '|' || (SELECT count(*) FROM target_items)
          || '|' || (SELECT count(*) = 0 FROM (
                (SELECT * FROM source_items EXCEPT SELECT * FROM target_items)
                UNION ALL
                (SELECT * FROM target_items EXCEPT SELECT * FROM source_items)) delta)
          || '|' || (SELECT bool_and(t_xmin::text::bigint > 2) FROM target_items);
      """
    When the following SQL is executed on "target":
      """
      VACUUM (FREEZE) public.subxid_copy;
      """
    Then the following SQL on "target" returns "1|live":
      """
      SELECT count(*) || '|' || min(value) FROM public.subxid_copy;
      """

  @local
  Scenario: Local clone preserves a committed multixact and its horizon
    Given the following SQL is executed on "target":
      """
      CREATE EXTENSION dblink;
      CREATE TABLE public.multi_source (id integer PRIMARY KEY, value text)
      WITH (autovacuum_enabled = false);
      INSERT INTO public.multi_source VALUES (1, 'locked');
      """
    When the following SQL is executed on "target":
      """
      SELECT dblink_connect('lock1', 'host=127.0.0.1 port=${TARGET_PORT} dbname=postgres user=postgres');
      SELECT dblink_connect('lock2', 'host=127.0.0.1 port=${TARGET_PORT} dbname=postgres user=postgres');
      SELECT dblink_exec('lock1', 'BEGIN');
      SELECT dblink_exec('lock2', 'BEGIN');
      SELECT * FROM dblink('lock1', 'SELECT * FROM public.multi_source WHERE id = 1 FOR SHARE')
        AS result(id integer, value text);
      SELECT * FROM dblink('lock2', 'SELECT * FROM public.multi_source WHERE id = 1 FOR SHARE')
        AS result(id integer, value text);
      SELECT dblink_exec('lock1', 'COMMIT');
      SELECT dblink_exec('lock2', 'COMMIT');
      SELECT dblink_disconnect('lock1');
      SELECT dblink_disconnect('lock2');
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.multi_source', 'public.multi_copy', true);
      """
    Then the following SQL on "target" returns "true|true|true|true|1":
      """
      SELECT (SELECT s.xmin = t.xmin AND s.xmax = t.xmax
              FROM public.multi_source s JOIN public.multi_copy t USING (id))
          || '|' || (SELECT s.xmax::text::bigint <> 0 FROM public.multi_source s)
          || '|' || (SELECT s.relfrozenxid = t.relfrozenxid AND s.relminmxid = t.relminmxid
                     FROM pg_class s, pg_class t
                     WHERE s.oid = 'public.multi_source'::regclass
                       AND t.oid = 'public.multi_copy'::regclass)
          || '|' || (SELECT value = 'locked' FROM public.multi_copy)
          || '|' || (SELECT count(*) FROM public.multi_copy);
      """
    When the following SQL is executed on "target":
      """
      VACUUM (FREEZE) public.multi_copy;
      """
    Then the following SQL on "target" returns "1|locked":
      """
      SELECT count(*) || '|' || min(value) FROM public.multi_copy;
      """

  @local
  Scenario: Local clone rolls back all target changes with its outer transaction
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.tx_source (id integer PRIMARY KEY, value text);
      INSERT INTO public.tx_source VALUES (1, 'source');
      CREATE TABLE public.tx_target (id integer PRIMARY KEY, value text);
      INSERT INTO public.tx_target VALUES (0, 'kept');
      """
    And the following SQL is executed on "target":
      """
      BEGIN;
      SELECT pagecopy.clone('public.tx_source', 'public.tx_target', true);
      SELECT pagecopy.clone('public.tx_source', 'public.tx_auto', true);
      ROLLBACK;
      """
    Then the following SQL on "target" returns "1|kept|true":
      """
      SELECT count(*) || '|' || min(value)
          || '|' || (to_regclass('public.tx_auto') IS NULL)
      FROM public.tx_target;
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      LOCK TABLE public.tx_source IN ACCESS EXCLUSIVE MODE NOWAIT;
      COMMIT;
      """

  @local
  Scenario: An error after local clone rolls back the target changes
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.after_source (id integer PRIMARY KEY);
      INSERT INTO public.after_source VALUES (1);
      CREATE TABLE public.after_target (id integer PRIMARY KEY);
      INSERT INTO public.after_target VALUES (0);
      """
    Then the following SQL on "target" fails with "duplicate key value":
      """
      BEGIN;
      SELECT pagecopy.clone('public.after_source', 'public.after_target', true);
      INSERT INTO public.after_target VALUES (1);
      COMMIT;
      """
    Then the following SQL on "target" returns "1|0":
      """
      SELECT count(*) || '|' || min(id) FROM public.after_target;
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      LOCK TABLE public.after_source IN ACCESS EXCLUSIVE MODE NOWAIT;
      COMMIT;
      """

  @local
  Scenario: Local clone advances an owned target sequence without changing the source
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.serial_source (id serial PRIMARY KEY, value text);
      INSERT INTO public.serial_source(value) VALUES ('one'), ('two');
      CREATE SEQUENCE public.target_id_seq;
      CREATE TABLE public.serial_target (
        id integer PRIMARY KEY DEFAULT nextval('public.target_id_seq'),
        value text
      );
      ALTER SEQUENCE public.target_id_seq OWNED BY public.serial_target.id;
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.serial_source', 'public.serial_target', true);
      INSERT INTO public.serial_target(value) VALUES ('target three');
      INSERT INTO public.serial_source(value) VALUES ('source three');
      """
    Then the following SQL on "target" returns "3|3|3|3|3|3":
      """
      SELECT (SELECT id FROM public.serial_target WHERE value = 'target three')
          || '|' || (SELECT id FROM public.serial_source WHERE value = 'source three')
          || '|' || (SELECT count(*) FROM public.serial_target)
          || '|' || (SELECT count(*) FROM public.serial_source)
          || '|' || (SELECT last_value FROM public.serial_source_id_seq)
          || '|' || (SELECT last_value FROM public.target_id_seq);
      """

  @local
  Scenario: Local clone handles quoted dots spaces and apostrophes in identifiers
    Given the following SQL is executed on "target":
      """
      CREATE SCHEMA "odd'schema";
      CREATE TABLE "odd'schema"."Source.Table" ("Id" integer PRIMARY KEY, "Value" text);
      INSERT INTO "odd'schema"."Source.Table" VALUES (1, 'quoted');
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone(
        '"odd''schema"."Source.Table"',
        '"new''schema"."copy.table"',
        true
      );
      """
    Then the following SQL on "target" returns "1|quoted":
      """
      SELECT count(*) || '|' || min("Value") FROM "new'schema"."copy.table";
      """

  @local
  Scenario: Local clone preserves values and nulls across data type widths
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.kitchen_sink (
        id integer PRIMARY KEY,
        flag boolean,
        small smallint,
        big bigint,
        amount numeric(12,2),
        payload bytea,
        labels text[],
        document jsonb,
        moment timestamp,
        nullable text
      );
      INSERT INTO public.kitchen_sink VALUES (
        1, true, 32767, 9223372036854775806, 12345.67,
        '\x000102ff', ARRAY[NULL, 'one', 'two'],
        '{"a":[1,null,{"b":true}]}', '2024-01-02 03:04:05', NULL
      ), (
        2, false, -32768, -9223372036854775807, -0.01,
        NULL, ARRAY[]::text[], NULL, NULL, 'present'
      );
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.clone('public.kitchen_sink', 'public.kitchen_copy', true);
      """
    Then the following SQL on "target" returns "2|true|true":
      """
      SELECT (SELECT count(*) FROM public.kitchen_copy)
          || '|' || (SELECT bool_and(to_jsonb(s) = to_jsonb(t))
                     FROM public.kitchen_sink s JOIN public.kitchen_copy t USING (id))
          || '|' || (SELECT bool_and(s.xmin = t.xmin)
                     FROM public.kitchen_sink s JOIN public.kitchen_copy t USING (id));
      """
