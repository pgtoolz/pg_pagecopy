@cross-major @type_recheck
Feature: Real PostgreSQL types and expressions are rechecked after physical transfer

  Scenario Outline: PostgreSQL <source_major> to <target_major> rechecks operators, casts and an expression btree
    Given a fresh PostgreSQL <source_major> to <target_major> pair with checksums "enabled"
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(
        id integer PRIMARY KEY,
        amount numeric(12,2),
        happened timestamp,
        payload text
      );
      CREATE INDEX events_payload_lower ON public.events USING btree (lower(payload));
      INSERT INTO public.events VALUES
        (42, 1010.00, '2023-11-14 22:13:20', 'Hello');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events(
        id integer PRIMARY KEY,
        amount numeric(12,2),
        happened timestamp,
        payload text
      );
      CREATE INDEX events_payload_lower ON public.events USING btree (lower(payload));
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1262.50|2023-11-14 22:13:20|HELLO|43":
      """
      SET enable_seqscan = off;
      SELECT round(amount * 1.25, 2)::text,
             to_char(happened, 'YYYY-MM-DD HH24:MI:SS'),
             upper(payload),
             (id::bigint + 1)::text
      FROM public.events WHERE lower(payload) = 'hello';
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
