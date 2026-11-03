Feature: Local clone source locking and snapshot boundary

  Background:
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE EXTENSION dblink;
      """

  @local
  Scenario: Local clone waits for an earlier writer and includes its committed row
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.before_source (id integer PRIMARY KEY, value text);
      INSERT INTO public.before_source VALUES (1, 'before');
      """
    When the following SQL is executed on "target":
      """
      SELECT dblink_connect('writer',
        'host=127.0.0.1 port=${TARGET_PORT} dbname=postgres user=postgres application_name=local-writer');
      SELECT dblink_connect('clone',
        'host=127.0.0.1 port=${TARGET_PORT} dbname=postgres user=postgres application_name=local-clone');
      SELECT dblink_exec('writer', 'BEGIN');
      SELECT dblink_exec('writer', 'INSERT INTO public.before_source VALUES (2, ''writer'')');
      SELECT dblink_send_query('clone',
        'SELECT (pagecopy.clone(''public.before_source'', ''public.before_copy'', true) IS NULL)::int');
      DO $do$
      BEGIN
        FOR attempt IN 1..100 LOOP
          IF EXISTS (
            SELECT FROM pg_locks
            WHERE relation = 'public.before_source'::regclass
              AND mode = 'AccessExclusiveLock' AND NOT granted
          ) THEN
            RETURN;
          END IF;
          IF dblink_is_busy('clone') = 0 THEN
            RAISE EXCEPTION 'local clone finished before waiting for the earlier writer';
          END IF;
          PERFORM pg_sleep(0.05);
        END LOOP;
        RAISE EXCEPTION 'local clone did not wait for the earlier writer';
      END
      $do$;
      SELECT dblink_exec('writer', 'COMMIT');
      SELECT * FROM dblink_get_result('clone') AS result(finished integer);
      SELECT dblink_disconnect('clone');
      SELECT dblink_disconnect('writer');
      """
    Then the following SQL on "target" returns "2|before|writer|true":
      """
      SELECT count(*) || '|' || min(s.value) || '|' || max(s.value)
          || '|' || bool_and(s.xmin = t.xmin)
      FROM public.before_source s JOIN public.before_copy t USING (id);
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      LOCK TABLE public.before_source IN ACCESS EXCLUSIVE MODE NOWAIT;
      COMMIT;
      """

  @local
  Scenario: Local clone excludes and releases a writer that arrives after its source lock
    Given the following SQL is executed on "target":
      """
      CREATE TABLE public.after_lock_source (id integer PRIMARY KEY, value text);
      INSERT INTO public.after_lock_source VALUES (1, 'snapshot');
      ALTER FUNCTION pagecopy_internal.pagecopy_lock_source(text)
        RENAME TO real_lock_source;
      CREATE FUNCTION pagecopy_internal.pagecopy_lock_source(source_table text)
        RETURNS void LANGUAGE plpgsql AS $function$
      BEGIN
        PERFORM pagecopy_internal.real_lock_source(source_table);
        PERFORM pg_sleep(1);
      END
      $function$;
      """
    When the following SQL is executed on "target":
      """
      SELECT dblink_connect('writer',
        'host=127.0.0.1 port=${TARGET_PORT} dbname=postgres user=postgres application_name=local-writer');
      SELECT dblink_connect('clone',
        'host=127.0.0.1 port=${TARGET_PORT} dbname=postgres user=postgres application_name=local-clone');
      SELECT dblink_send_query('clone',
        'SELECT (pagecopy.clone(''public.after_lock_source'', ''public.after_lock_copy'', true) IS NULL)::int');
      SELECT pg_sleep(0.2);
      DO $do$
      BEGIN
        IF dblink_is_busy('clone') = 0 THEN
          RAISE EXCEPTION 'local clone did not acquire its source lock';
        END IF;
      END
      $do$;
      SELECT dblink_send_query('writer',
        'INSERT INTO public.after_lock_source VALUES (2, ''too late'')');
      SELECT pg_sleep(0.2);
      DO $do$
      BEGIN
        IF dblink_is_busy('writer') = 0 THEN
          RAISE EXCEPTION 'writer did not wait for the local clone source lock';
        END IF;
      END
      $do$;
      SELECT * FROM dblink_get_result('clone') AS result(finished integer);
      SELECT * FROM dblink_get_result('writer') AS result(status text);
      SELECT dblink_disconnect('clone');
      SELECT dblink_disconnect('writer');
      """
    Then the following SQL on "target" returns "1|snapshot|2|snapshot|too late":
      """
      SELECT (SELECT count(*) FROM public.after_lock_copy)
          || '|' || (SELECT value FROM public.after_lock_copy)
          || '|' || (SELECT count(*) FROM public.after_lock_source)
          || '|' || (SELECT min(value) FROM public.after_lock_source)
          || '|' || (SELECT max(value) FROM public.after_lock_source);
      """
    When the following SQL is executed on "target":
      """
      BEGIN;
      LOCK TABLE public.after_lock_source IN ACCESS EXCLUSIVE MODE NOWAIT;
      COMMIT;
      """
