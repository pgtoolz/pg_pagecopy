@degraded_indexes @unsupported_btree
Feature: Currently unsupported Btree variants remain rebuildable

  Scenario Outline: <name> is transferred as an invalid definition without an error
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      INSERT INTO public.events VALUES (1, 'Alpha'), (2, 'beta'), (3, NULL);
      <setup>
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE OPERATOR CLASS public.custom_text_ops FOR TYPE text USING btree AS
        OPERATOR 1 <, OPERATOR 2 <=, OPERATOR 3 =, OPERATOR 4 >=, OPERATOR 5 >,
        FUNCTION 1 bttextcmp(text, text);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    Then the following SQL on "target" returns "1|0|3":
      """
      SELECT count(*) FILTER (WHERE NOT indisvalid AND NOT indisready),
             count(*) FILTER (WHERE indisvalid AND indisready),
             (SELECT count(*) FROM public.events)
      FROM pg_index WHERE indrelid = 'public.events'::regclass;
      """
    And the following SQL on "source" returns "<source_state>":
      """
      SELECT concat(indisvalid, ':', indisready) FROM pg_index
      WHERE indexrelid = 'public.events_unsupported'::regclass;
      """
    When the following SQL is executed on "target":
      """
      REINDEX TABLE public.events;
      """
    Then the following SQL on "target" returns "0|3|2":
      """
      SELECT count(*) FILTER (WHERE NOT indisvalid OR NOT indisready),
             (SELECT count(*) FROM public.events),
             (SELECT count(note) FROM public.events)
      FROM pg_index WHERE indrelid = 'public.events'::regclass;
      """

    Examples:
      | name                    | setup | source_state |
      | partial Btree           | CREATE INDEX events_unsupported ON public.events USING btree (note) WHERE note IS NOT NULL; | t:t |
      | expression Btree        | CREATE INDEX events_unsupported ON public.events USING btree (lower(note)); | t:t |
      | invalid Btree           | CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean) RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT; CREATE INDEX events_unsupported ON public.events USING btree (note); SELECT pc_test_empty_index_state('events_unsupported', false, false); | f:f |
      | invalid but ready Btree | CREATE INDEX events_unsupported ON public.events USING btree (note); UPDATE pg_index SET indisvalid = false, indisready = true WHERE indexrelid = 'events_unsupported'::regclass; | f:t |
      | not-ready Btree         | CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean) RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT; CREATE INDEX events_unsupported ON public.events USING btree (note); SELECT pc_test_empty_index_state('events_unsupported', true, false); | t:f |

  Scenario: Custom Btree opclass is rejected even in degraded mode
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE TABLE public.events (id integer, note text);
      CREATE OPERATOR CLASS public.custom_text_ops FOR TYPE text USING btree AS
        OPERATOR 1 <, OPERATOR 2 <=, OPERATOR 3 =, OPERATOR 4 >=, OPERATOR 5 >,
        FUNCTION 1 bttextcmp(text, text);
      CREATE INDEX events_note_idx ON public.events USING btree (note public.custom_text_ops);
      INSERT INTO public.events VALUES (1, 'Alpha');
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE OPERATOR CLASS public.custom_text_ops FOR TYPE text USING btree AS
        OPERATOR 1 <, OPERATOR 2 <=, OPERATOR 3 =, OPERATOR 4 >=, OPERATOR 5 >,
        FUNCTION 1 bttextcmp(text, text);
      """
    Then the following SQL on "target" fails with "custom opclass":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', true
      );
      """
    And the following SQL on "target" returns "absent":
      """
      SELECT COALESCE(to_regclass('public.events')::text, 'absent');
      """

  Scenario: Empty invalid Btree does not require a metapage or capture a unique peer
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.events (id integer);
      CREATE INDEX events_id_plain ON public.events USING btree (id);
      CREATE UNIQUE INDEX events_id_unique ON public.events USING btree (id);
      INSERT INTO public.events VALUES (1), (2);
      SELECT pc_test_empty_index_state('events_id_plain', false, false);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.events (id integer);
      CREATE INDEX events_id_plain ON public.events USING btree (id);
      CREATE UNIQUE INDEX events_id_unique ON public.events USING btree (id);
      INSERT INTO public.events VALUES (99);
      SELECT pc_test_empty_index_state('events_id_plain', false, false);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', false
      );
      """
    Then the following SQL on "target" returns "2|f|f|0":
      """
      SELECT count(*),
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 'events_id_plain'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 'events_id_plain'::regclass),
             pg_relation_size('events_id_plain'::regclass)
      FROM public.events;
      """
    And the following SQL on "target" returns "t|t":
      """
      SELECT indisvalid, indisready FROM pg_index
      WHERE indexrelid = 'events_id_unique'::regclass;
      """
    When the following SQL is executed on "target":
      """
      REINDEX TABLE public.events;
      """
    Then the following SQL on "target" returns "0|2":
      """
      SELECT count(*) FILTER (WHERE NOT indisvalid OR NOT indisready),
             (SELECT count(*) FROM public.events)
      FROM pg_index WHERE indrelid = 'public.events'::regclass;
      """

  Scenario: Physical matching skips an earlier unrelated empty invalid Btree
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.events (id integer, note text);
      CREATE INDEX events_valid ON public.events USING btree (id);
      CREATE INDEX events_empty ON public.events USING btree (note);
      INSERT INTO public.events VALUES (1, 'source'), (2, NULL);
      SELECT pc_test_empty_index_state('events_empty', false, false);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.events (id integer, note text);
      CREATE INDEX events_empty ON public.events USING btree (note);
      CREATE INDEX events_valid ON public.events USING btree (id);
      INSERT INTO public.events VALUES (99, 'target');
      SELECT pc_test_empty_index_state('events_empty', false, false);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', false
      );
      """
    Then the following SQL on "target" returns "t|t|f|f|2":
      """
      SELECT (SELECT indisvalid FROM pg_index WHERE indexrelid = 'events_valid'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 'events_valid'::regclass),
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 'events_empty'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 'events_empty'::regclass),
             (SELECT count(*) FROM public.events);
      """

  Scenario: Duplicate definitions reserve a valid Btree for physical import
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.events (id integer);
      CREATE INDEX s_invalid ON public.events (id);
      CREATE INDEX s_valid ON public.events (id);
      INSERT INTO public.events VALUES (1), (2);
      SELECT pc_test_empty_index_state('s_invalid', false, false);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.events (id integer);
      CREATE INDEX t_valid ON public.events (id);
      CREATE INDEX t_invalid ON public.events (id);
      INSERT INTO public.events VALUES (99);
      SELECT pc_test_empty_index_state('t_invalid', false, false);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', false
      );
      """
    Then the following SQL on "target" returns "t|t|f|f|2":
      """
      SELECT (SELECT indisvalid FROM pg_index WHERE indexrelid = 't_valid'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 't_valid'::regclass),
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 't_invalid'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 't_invalid'::regclass),
             (SELECT count(*) FROM public.events);
      """


  Scenario: Mixed duplicate definitions preserve their physical and degraded roles
    Given a fresh PostgreSQL pair
    And the following SQL is executed on "source":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.events (id integer);
      CREATE INDEX s_physical ON public.events (id) WITH (fillfactor = 90);
      CREATE INDEX s_degraded ON public.events (id) WITH (fillfactor = 80);
      INSERT INTO public.events VALUES (1), (2);
      SELECT pc_test_empty_index_state('s_degraded', false, false);
      """
    And the following SQL is executed on "target":
      """
      CREATE EXTENSION pg_pagecopy;
      CREATE FUNCTION pc_test_empty_index_state(regclass, boolean, boolean)
        RETURNS void AS 'pc_bdd_fixtures', 'pc_test_empty_index_state' LANGUAGE C STRICT;
      CREATE TABLE public.events (id integer);
      CREATE INDEX t_degraded ON public.events (id) WITH (fillfactor = 80);
      CREATE INDEX t_physical ON public.events (id) WITH (fillfactor = 90);
      INSERT INTO public.events VALUES (99);
      SELECT pc_test_empty_index_state('t_degraded', false, false);
      """
    When the following SQL is executed on "target":
      """
      SELECT pagecopy.pull(
        'host=127.0.0.1 port=${SOURCE_PORT} dbname=postgres user=postgres',
        'public.events', 'public.events', false
      );
      """
    Then the following SQL on "target" returns "t|t|f|f|2":
      """
      SELECT (SELECT indisvalid FROM pg_index WHERE indexrelid = 't_physical'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 't_physical'::regclass),
             (SELECT indisvalid FROM pg_index WHERE indexrelid = 't_degraded'::regclass),
             (SELECT indisready FROM pg_index WHERE indexrelid = 't_degraded'::regclass),
             (SELECT count(*) FROM public.events);
      """
