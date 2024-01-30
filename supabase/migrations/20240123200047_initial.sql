
SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

CREATE SCHEMA IF NOT EXISTS "archive";

CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgsodium" WITH SCHEMA "pgsodium";

CREATE SCHEMA IF NOT EXISTS "secrets";

CREATE EXTENSION IF NOT EXISTS "plv8" WITH SCHEMA "pg_catalog";

CREATE EXTENSION IF NOT EXISTS "http" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";

CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";

CREATE OR REPLACE FUNCTION "archive"."save_function_history"("function_name" "text", "args" "text", "return_type" "text", "source_code" "text", "schema_name" "text" DEFAULT 'public'::"text", "lang_settings" "text" DEFAULT 'plpgsql'::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'archive'
    AS $$
BEGIN
  INSERT INTO archive.function_history (
        schema_name, 
        function_name, 
        args, 
        return_type, 
        source_code, 
        lang_settings)
  VALUES (schema_name, function_name, args, return_type, source_code, lang_settings);
END;
$$;

CREATE OR REPLACE FUNCTION "archive"."setup_function_history"("schema_name" "text" DEFAULT 'public'::"text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  function_record record;
BEGIN
  -- Loop through existing functions in the specified schema
  FOR function_record IN (
    SELECT
      n.nspname AS schema_name,
      p.proname AS function_name,
      pg_catalog.pg_get_function_arguments(p.oid) AS args,
      pg_catalog.pg_get_function_result(p.oid) AS return_type,
      pg_catalog.pg_get_functiondef(p.oid) AS source_code,
      l.lanname AS lang_settings
    FROM pg_catalog.pg_proc p
    LEFT JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    LEFT JOIN pg_catalog.pg_language l ON l.oid = p.prolang
    WHERE n.nspname = schema_name
  )
  LOOP
    -- Insert information about the function into the history table
    PERFORM archive.save_function_history(
      function_record.function_name,
      function_record.args,
      function_record.return_type,
      function_record.source_code,
      function_record.schema_name,
      function_record.lang_settings
    );
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."calculate_version"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Calculate the version number only for new rows
    SELECT COALESCE(MAX(version), 0) + 1
    INTO NEW.version
    FROM archive.function_history
    WHERE schema_name = NEW.schema_name
      AND function_name = NEW.function_name
      AND return_type = NEW.return_type
      AND args = NEW.args;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."check_due_tasks_and_update"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _task RECORD;
    _response JSONB;
    _response_row JSONB;
    _ticket_id text;
    _have_replied BOOLEAN;
    _ticket_array text;
    _lock_key CONSTANT int := 42;
    _lock_acquired boolean;
BEGIN
    -- Try to acquire the advisory lock
    _lock_acquired := pg_try_advisory_lock(_lock_key);
    IF NOT _lock_acquired THEN
        RAISE NOTICE 'Could not acquire lock. Another instance is running. Exiting function...';
        RETURN;
    END IF;

    -- Call create_ticket_array() 
    RAISE NOTICE 'Calling create_ticket_array()';
    _ticket_array := public.create_ticket_array();

    -- Check IF _ticket_array is '[]'
    IF _ticket_array = '[]' THEN
        RAISE NOTICE 'No tickets to process. Exiting function...';
        -- Release the advisory lock
        PERFORM pg_advisory_unlock(_lock_key);
        RETURN;
    END IF;

    -- Call help_plataform_wrapper() using _ticket_array
    RAISE NOTICE 'Calling help_plataform_wrapper()';
    _response := public.help_plataform_wrapper(_ticket_array);

    -- Check IF _response is NULL
    IF _response IS NULL THEN
        RAISE NOTICE 'Response is NULL. Exiting function...';
        -- Release the advisory lock
        PERFORM pg_advisory_unlock(_lock_key);
        RETURN;
    END IF;

    -- Process the response
    FOR _response_row IN SELECT * FROM jsonb_array_elements(_response)
    LOOP
        _ticket_id := _response_row->>'ticket_id';
        _have_replied := (_response_row->>'have_replied')::BOOLEAN;
        RAISE NOTICE 'Processing response for ticket_id: %, have_replied: %', _ticket_id, _have_replied;
        IF _have_replied THEN
            RAISE NOTICE 'Ticket % has a reply. Updating...', _ticket_id;
            -- Perform actions for replied tickets
            UPDATE public.checking_tasks_queue
            SET replied_at = NOW(), replied = TRUE
            WHERE payload->>'ticket_id' = _ticket_id;
        ELSE
            RAISE NOTICE 'Ticket % has no reply. Taking actions...', _ticket_id;
            -- Perform actions for no reply
            SELECT * INTO _task FROM public.checking_tasks_queue
            WHERE payload->>'ticket_id' = _ticket_id AND status = '' AND due_time <= NOW()
            ORDER BY due_time ASC
            LIMIT 1;

            IF FOUND THEN
                RAISE NOTICE 'Sending Slack notification for ticket %', _ticket_id;
                -- Use EXCEPTION to handle duplicate keys
                BEGIN
                    INSERT INTO post_to_slack_log(payload) VALUES (_task.payload);
                    PERFORM slack_post_wrapper(_task.payload);
                EXCEPTION
                    WHEN unique_violation THEN
                        RAISE NOTICE 'Duplicate entry for ticket %. Skipping...', _ticket_id;
                    WHEN OTHERS THEN
                        RAISE NOTICE 'Error while inserting into post_to_slack_log. Skipping...';
                        RAISE NOTICE '% %', SQLERRM, SQLSTATE;
                END;
                -- Update the status to 'sent' after calling slack_post_wrapper
                UPDATE public.checking_tasks_queue
                SET status = 'sent'
                WHERE id = _task.id;
            ELSE
                RAISE NOTICE 'Task for ticket % not found!', _ticket_id;
            END IF;
        END IF;
    END LOOP;
    -- Release the advisory lock
    PERFORM pg_advisory_unlock(_lock_key);
END;
$$;

CREATE OR REPLACE FUNCTION "public"."check_due_tasks_and_update_debug"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _task RECORD;
    _payload_array JSONB[];
    _unique_ticket_ids text[];
    _result text := '[';
BEGIN
    _payload_array := ARRAY[]::JSONB[];
    _unique_ticket_ids := '{}';

    -- Collect tasks that meet the condition and have distinct ticket IDs
    FOR _task IN 
        SELECT * FROM public.checking_tasks_queue 
        WHERE due_time <= NOW() AND replied IS FALSE
    LOOP
        -- Add the ticket_id to the array IF it's not already there
        IF NOT (_task.payload->>'ticket_id') = ANY(_unique_ticket_ids) THEN
            _unique_ticket_ids := _unique_ticket_ids || (_task.payload->>'ticket_id');
            _payload_array := _payload_array || jsonb_build_object('ticket_id', _task.payload->>'ticket_id', 'timestamp', EXTRACT(EPOCH FROM _task.created_at)::BIGINT)::JSONB;
        END IF;
    END LOOP;

    FOR i IN 1..array_length(_payload_array, 1)
    LOOP
        IF i != 1 THEN
            _result := _result || ',';
        END IF;

        _result := _result || _payload_array[i]::text;
    END LOOP;

    _result := _result || ']';
    RETURN _result;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."check_mention_reply_log"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _payload jsonb;
    _channel text;
    _thread_ts text;
    exists boolean;
BEGIN
    _payload := NEW.payload;
    _channel := _payload->>'channel_id';
    _thread_ts := _payload->>'thread_ts';
    
    SELECT EXISTS (
        SELECT 1 
        FROM mention_reply_log 
        WHERE channel = _channel AND thread_ts = _thread_ts
    ) INTO exists;

    IF exists THEN
        NEW.due_time = NEW.due_time + INTERVAL '30 minute';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."create_function_from_source"("function_text" "text", "schema_name" "text" DEFAULT 'public'::"text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  function_name text;
  argument_types text;
  return_type text;
  function_source text;
  lang_settings text;
BEGIN
  -- Execute the function text to create the function
  EXECUTE function_text;

  -- Extract function name FROM function text
  SELECT (regexp_matches(function_text, 'create (or replace )?function (public\.)?(\w+)', 'i'))[3]
  INTO function_name;

  -- Get function details FROM the system catalog
  SELECT pg_get_function_result(p.oid), 
                pg_get_function_arguments(p.oid), p.prosrc, l.lanname
  INTO return_type, argument_types, function_source, lang_settings
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = schema_name AND p.proname = function_name;

  -- Save function history
  PERFORM archive.save_function_history(function_name, argument_types, return_type, function_text, schema_name, lang_settings);

  RETURN 'Function created successfully.';
EXCEPTION
  WHEN others THEN
    RAISE EXCEPTION 'Error creating function: %', sqlerrm;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."create_ticket_array"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _task RECORD;
    _payload_array JSONB[];
    _unique_ticket_ids text[];
    _result text := '[';
BEGIN
    _payload_array := ARRAY[]::JSONB[];
    _unique_ticket_ids := '{}';

    -- Collect tasks that meet the condition and have distinct ticket IDs
    FOR _task IN 
        SELECT * FROM public.checking_tasks_queue 
        WHERE due_time <= NOW() AND replied IS FALSE
    LOOP
        -- Add the ticket_id to the array IF it's not already there
        IF NOT (_task.payload->>'ticket_id') = ANY(_unique_ticket_ids) THEN
            _unique_ticket_ids := _unique_ticket_ids || (_task.payload->>'ticket_id');
            _payload_array := _payload_array || jsonb_build_object('ticket_id', _task.payload->>'ticket_id', 'timestamp', EXTRACT(EPOCH FROM _task.created_at)::BIGINT)::JSONB;
        END IF;
    END LOOP;

    -- Check IF _payload_array is empty
    IF array_length(_payload_array, 1) IS NULL THEN
        _result := '[]';
        RETURN _result;
    END IF;

    FOR i IN 1..array_length(_payload_array, 1)
    LOOP
        IF i != 1 THEN
            _result := _result || ',';
        END IF;
        _result := _result || _payload_array[i]::text;
    END LOOP;
    _result := _result || ']';
    RETURN _result;
END;
$$;


CREATE OR REPLACE FUNCTION "public"."exclude_old_messages"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- If the ts timestamp is older than 24 hours
  IF (NEW.ts < NOW() - INTERVAL '12 hours') THEN
    -- Raise an exception
    RAISE EXCEPTION 'Cannot INSERT a row with a ts timestamp older than 24 hours.';
  END IF;
  -- If the ts timestamp is not older than 24 hours, continue with the INSERT operation
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."get_current_events"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions', 'vault'
    AS $$
DECLARE
  target_date timestamp with time zone := now();
  start_date timestamp with time zone := target_date;
  end_date timestamp with time zone := start_date + INTERVAL '1 hours';
  time_min text := to_char(start_date, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  time_max text := to_char(end_date, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  base_url text;
  api_url text;
  response jsonb;
  events jsonb;
  current_event_names text[];
BEGIN
  SELECT decrypted_secret
  INTO base_url
  FROM vault.decrypted_secrets
  WHERE name = 'calendar_base_url';
  api_url := base_url || '&timeMin=' || time_min || '&timeMax=' || time_max;
  SELECT "content"::jsonb INTO response FROM http_get(api_url);
  events := response->'items';
  SELECT ARRAY_AGG(event->>'summary')
  INTO current_event_names
  FROM jsonb_array_elements(events) AS event;
  RETURN COALESCE(to_jsonb(current_event_names)::text,'[]');
END;
$$;

CREATE OR REPLACE FUNCTION "public"."get_embedded_event_names"("date_param" timestamp with time zone DEFAULT "now"()) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions', 'vault'
    AS $$
DECLARE
  target_date timestamp with time zone := COALESCE(date_param, now());
  start_date timestamp with time zone := target_date + INTERVAL '2 hours';
  end_date timestamp with time zone := start_date + INTERVAL '1 day' - INTERVAL '1 millisecond';
  time_min text := to_char(start_date, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  time_max text := to_char(end_date, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  base_url text;
  api_url text;
  response jsonb;
  events jsonb; -- Change the declaration to jsonb
  embedded_event_names text[];
BEGIN
  SELECT decrypted_secret
  INTO base_url
  FROM vault.decrypted_secrets
  WHERE name = 'calendar_base_url';
  
  api_url := base_url || '&timeMin=' || time_min || '&timeMax=' || time_max;
  
  SELECT "content"::jsonb INTO response FROM http_get(api_url);
  events := response->'items'; -- Remove the typecast to ::jsonb

  SELECT ARRAY_AGG(event->>'summary')
  INTO embedded_event_names
  FROM jsonb_array_elements(events) AS event -- Use jsonb_array_elements function
  WHERE (event->>'summary') ILIKE '%embedded%';

  RETURN COALESCE(to_jsonb(embedded_event_names)::text,'[]');
END;
$$;

CREATE OR REPLACE FUNCTION "public"."get_secret"("secret_name" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    decrypted text;
BEGIN
    IF current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role' OR current_user = 'postgres' THEN
        SELECT decrypted_secret
        INTO decrypted
        FROM vault.decrypted_secrets
        WHERE name = secret_name;
        RETURN decrypted;
    ELSE
        RAISE EXCEPTION 'Access denied: only service_role or postgres user can execute this function.';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."http_get_with_auth"("url_address" "text", "bearer" "text") RETURNS TABLE("_status" "text", "_content" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions', 'secrets'
    AS $$
DECLARE
  full_bearer text := 'Bearer ' || bearer;
BEGIN
 RETURN QUERY SELECT status::text, content::text
  FROM http((
          'GET',
           url_address,
           ARRAY[http_header('Authorization',full_bearer)],
           NULL,
           NULL
        )::http_request);
END;
$$;

CREATE OR REPLACE FUNCTION "public"."http_post_with_auth"("url_address" "text", "bearer" "text", "payload" "jsonb") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions', 'secrets', 'net'
    AS $$
DECLARE
  full_bearer text := 'Bearer ' || bearer;
  response_body jsonb;
  response_status text;
BEGIN
  -- Make an async HTTP POST request using pg_net
  PERFORM net.http_post(
    url := url_address,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', full_bearer
    ),
    body := payload,
    timeout_milliseconds := 15000
  ) AS request_id;
  return 'SENT';
END;
$$;

CREATE OR REPLACE FUNCTION "public"."http_post_with_auth"("url_address" "text", "post_data" "text", "bearer" "text") RETURNS TABLE("_status" "text", "_content" "jsonb")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
  full_bearer TEXT := 'Bearer ' || bearer;
  response RECORD;
BEGIN
  -- Make the HTTP POST request with the given URL, data, and bearer token
  SELECT status::text, content::jsonb
  INTO response
  FROM http((
          'POST',
           url_address,
           ARRAY[http_header('Authorization', full_bearer), http_header('Content-Type', 'application/json')],
           'application/json',
           coalesce(post_data, '') -- Set content to an empty string IF post_data is NULL
        )::http_request);

  -- Raise an exception IF the response content is NULL
  IF response.content IS NULL THEN
    RAISE EXCEPTION 'Error: Edge Function returned NULL content. Status: %', response.status;
  END IF;

  -- Return the status and content of the response
  RETURN QUERY SELECT response.status, response.content;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."help_plataform_wrapper"("payload" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
  api_key TEXT;
  url_address TEXT;
  full_bearer TEXT;
  response RECORD;
BEGIN
  -- Get secrets FROM Vault
  SELECT decrypted_secret
  INTO api_key
  FROM vault.decrypted_secrets
  WHERE name = 'revops_anon_key';
  full_bearer := 'Bearer ' || api_key;

  SELECT decrypted_secret
  INTO url_address
  FROM vault.decrypted_secrets
  WHERE name = 'help_plataform_edge_function_url';

  -- Make the HTTP POST request with the given URL, data, and bearer token
  SELECT status::text, content::jsonb
  INTO response
  FROM http((
          'POST',
           url_address,
           ARRAY[http_header('Authorization', full_bearer)],
           'application/json',
           coalesce(payload::text, '') -- Set content to an empty string IF post_data is NULL
        )::http_request);

  -- Raise an exception IF the response content is NULL
  IF response.content IS NULL THEN
    RAISE EXCEPTION 'Error: Edge Function returned NULL content. Status: %', response.status;
  END IF;
  -- Return the status and content of the response
  RETURN response.content;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."increase_due_time"("channel" "text", "thread_ts" "text", "ts" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  _payload jsonb;
  api_key text;
  full_bearer text;
  row_count integer;
  edge_function_url text;
BEGIN
    -- Create JSON FROM channel & ts arguments
    _payload := jsonb_build_object('channel', channel, 'thread_ts', thread_ts, 'ts', ts);
    -- Get the bearer
    SELECT decrypted_secret
    INTO api_key
    FROM vault.decrypted_secrets
    WHERE name = 'service_role';
    full_bearer := 'Bearer ' || api_key;
    -- Get the edge function URL
    SELECT decrypted_secret
    INTO edge_function_url
    FROM vault.decrypted_secrets
    WHERE name = 'mention_reply_edge_function_url';
    full_bearer := 'Bearer ' || api_key;

    -- Try to INSERT a row into the unlogged table
    BEGIN
        INSERT INTO mention_reply_log (channel, thread_ts, ts) VALUES (channel, thread_ts, ts);
        GET DIAGNOSTICS row_count = ROW_COUNT;
    EXCEPTION WHEN unique_violation THEN
        -- If there is a unique violation error, do nothing and set row_count to 0
        row_count := 0;
    END;
    -- If the row was inserted successfully, call the edge function
    IF row_count > 0 THEN
        PERFORM public.http_post_with_auth(
            url_address := edge_function_url,
            bearer := full_bearer,
            payload := _payload
        );
        UPDATE public.checking_tasks_queue
        SET due_time = due_time + INTERVAL '30 minutes'
        WHERE payload->>'thread_ts' = thread_ts;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."insert_tasks"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
    escalationtimeintervals int[];
    currentinterval int;
    threadts text;

BEGIN
    IF new.channel_id <> '' THEN
        SELECT escalation_time INTO escalationtimeintervals FROM priority WHERE channel_id = new.channel_id;
    ELSE
        escalationtimeintervals := array[10, 20, 35, 50]; -- minutes
    END IF;
    -- INSERT tasks for each escalation level
    FOR i IN 1..4
    LOOP
        -- set the current escalation time interval
        currentinterval := escalationtimeintervals[i];
        -- format thread_ts as (epoch time as a big int) + '.' + ts_ms
        threadts := extract(epoch FROM new.ts)::bigint::text || '.' || new.ts_ms;

        -- check IF ticket_type is not 'feedback'
        IF lower(new.ticket_type) <> 'feedback' THEN
            INSERT INTO checking_tasks_queue (http_verb, payload, due_time, replied)
            values (
                'POST',
                jsonb_build_object(
                    'channel_id', new.channel_id,
                    'thread_ts', threadts,
                    'escalation_level', i,
                    'ticket_id', new.ticket_number,
                    'ticket_priority', new.ticket_priority,
                    'ticket_type', new.ticket_type
                ),
                new.ts + (currentinterval * interval '1 minute'),
                false
            );
        END IF;
    END LOOP;
    -- return the new slack_msg row
    return new;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."process_channels"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions', 'secrets', 'net'
    AS $$
DECLARE
  channel RECORD;
BEGIN
  -- Update worker_status to lock it in secrets schema
  UPDATE secrets.worker_status
  SET locked = true
  WHERE id = 1;
  -- Loop through channels
  FOR channel IN
    SELECT channel_id FROM slack_channels WHERE is_alert_channel
  LOOP
    PERFORM scan_channel(channel.channel_id);
    -- Pooling delay of 1.5 seconds
    PERFORM pg_sleep(1.5);
  END LOOP;
  -- Update worker_status in the secrets schema and set id=1 to false
  UPDATE secrets.worker_status
  SET locked = false
  WHERE id = 1;
  return 'Done';
END;
$$;

CREATE OR REPLACE FUNCTION "public"."process_channels_if_unlocked"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions', 'secrets', 'net'
    AS $$
BEGIN
  IF (SELECT locked FROM secrets.worker_status WHERE id = 1) = false THEN
    PERFORM process_channels_twice_per_call();
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."process_channels_twice_per_call"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions', 'secrets', 'net'
    AS $$
BEGIN
  -- Call process_channels() for the first time
  PERFORM public.process_channels();
  
  -- Delay for 20 seconds
  PERFORM pg_sleep(20);
  
  -- Call process_channels() for the second time
  PERFORM public.process_channels();
  
  return 'Done';
END;
$$;

CREATE OR REPLACE FUNCTION "public"."rollback_function"("func_name" "text", "schema_n" "text" DEFAULT 'public'::"text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  function_text text;
BEGIN
  -- Get the most recent function version FROM the function_history table
  SELECT source_code
  INTO function_text
  FROM archive.function_history
  WHERE function_name = func_name AND schema_name = schema_n
  ORDER BY updated_at DESC
  LIMIT 1;

  -- If no previous version is found, raise an error
  IF function_text IS NULL THEN
    RAISE EXCEPTION 'No previous version of function % found.', func_name;
  END IF;

  -- Add 'or replace' to the function text IF it's not already there (case-insensitive search and replace)
  IF NOT function_text ~* 'or replace' THEN
    function_text := regexp_replace(function_text, 'create function', 'create or replace function', 'i');
  END IF;

  -- Execute the function text to create the function
  EXECUTE function_text;

  RETURN 'Function rolled back successfully.';
EXCEPTION
  WHEN others THEN
    RAISE EXCEPTION 'Error rolling back function: %', sqlerrm;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."scan_channel"("channel_id" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions', 'net'
    AS $_$
 DECLARE
    service_role text;
    channel_payload text;
    url_address text;
 BEGIN
 -- Get the API key FROM the vault
  SELECT decrypted_secret
  INTO service_role
  FROM vault.decrypted_secrets
  WHERE name = 'service_role';
  SELECT decrypted_secret
  INTO url_address
  FROM vault.decrypted_secrets
  WHERE name = 'scan_help_plataform_channel_edge_function_url';
  channel_payload := $${"channel_id":  "$$ || channel_id || $$"}$$;
  perform http_post_with_auth(url_address, service_role, channel_payload::jsonb);
  RETURN 'OK';
 END;
$_$;

CREATE OR REPLACE FUNCTION "public"."slack_post_wrapper"("payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
     DECLARE
       api_key TEXT;
       url_address TEXT;
       full_bearer TEXT;
       response RECORD;
     BEGIN
       -- Get secrets FROM Vault
       SELECT decrypted_secret
       INTO api_key
       FROM vault.decrypted_secrets
       WHERE name = 'service_role';
       full_bearer := 'Bearer ' || api_key;
     
       SELECT decrypted_secret
       INTO url_address
       FROM vault.decrypted_secrets
       WHERE name = 'slack_escalation_function_url';
     
       -- Make the HTTP POST request with the given URL, data, and bearer token
       BEGIN
         SELECT status::text, content::jsonb
         INTO response
         FROM http((
                 'POST',
                  url_address,
                  ARRAY[http_header('Authorization', full_bearer), http_header('Content-Type', 'application/json')],
                  'application/json',
                  coalesce(payload::text, '') -- Set content to an empty string IF post_data is NULL
               )::http_request);
       EXCEPTION
         WHEN others THEN
           -- Handle the exception here (e.g., set a default value)
           response := ('error', '{}'::jsonb);
       END;
     
       -- Raise an exception IF the response content is NULL
       IF response.content IS NULL THEN
         RAISE EXCEPTION 'Error: Edge Function returned NULL content. Status: %', response.status;
       END IF;
       -- Return the status and content of the response
       RETURN response.content;
     END;
     $$;

SET default_tablespace = '';

SET default_table_access_method = "heap";

CREATE TABLE IF NOT EXISTS "archive"."function_history" (
    "schema_name" "text",
    "function_name" "text",
    "args" "text",
    "return_type" "text",
    "source_code" "text",
    "lang_settings" "text",
    "updated_at" timestamp without time zone DEFAULT "now"(),
    "version" numeric DEFAULT '1'::numeric,
    "id" bigint NOT NULL
);

ALTER TABLE "archive"."function_history" OWNER TO "postgres";

ALTER TABLE "archive"."function_history" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "archive"."function_history_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."base_url" (
    "decrypted_secret" "text" COLLATE "pg_catalog"."C"
);

ALTER TABLE "public"."base_url" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."checking_tasks_queue" (
    "id" bigint NOT NULL,
    "http_verb" "text" DEFAULT 'POST'::"text" NOT NULL,
    "payload" "jsonb",
    "status" "text" DEFAULT ''::"text" NOT NULL,
    "replied" boolean,
    "url_path" "text" DEFAULT ''::"text",
    "content" "text" DEFAULT ''::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "due_time" timestamp with time zone DEFAULT "now"(),
    "replied_at" timestamp with time zone,
    CONSTRAINT "checking_tasks_queue_verb_check" CHECK (("http_verb" = ANY (ARRAY['GET'::"text", 'POST'::"text", 'DELETE'::"text"])))
);

ALTER TABLE "public"."checking_tasks_queue" OWNER TO "postgres";

ALTER TABLE "public"."checking_tasks_queue" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."checking_tasks_queue_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."destination_channels" (
    "created_at" timestamp with time zone DEFAULT "now"(),
    "channel_id" "text" DEFAULT ''::"text" NOT NULL,
    "description" "text",
    "name" "text"
);

ALTER TABLE "public"."destination_channels" OWNER TO "postgres";

CREATE UNLOGGED TABLE "public"."mention_reply_log" (
    "channel" "text" NOT NULL,
    "thread_ts" "text" NOT NULL,
    "ts" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE "public"."mention_reply_log" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."lock_monitor" AS
 SELECT COALESCE((("blockingl"."relation")::"regclass")::"text", "blockingl"."locktype") AS "locked_item",
    ("now"() - "blockeda"."query_start") AS "waiting_duration",
    "blockeda"."pid" AS "blocked_pid",
    "blockeda"."query" AS "blocked_query",
    "blockedl"."mode" AS "blocked_mode",
    "blockinga"."pid" AS "blocking_pid",
    "blockinga"."query" AS "blocking_query",
    "blockingl"."mode" AS "blocking_mode"
   FROM ((("pg_locks" "blockedl"
     JOIN "pg_stat_activity" "blockeda" ON (("blockedl"."pid" = "blockeda"."pid")))
     JOIN "pg_locks" "blockingl" ON (((("blockingl"."transactionid" = "blockedl"."transactionid") OR (("blockingl"."relation" = "blockedl"."relation") AND ("blockingl"."locktype" = "blockedl"."locktype"))) AND ("blockedl"."pid" <> "blockingl"."pid"))))
     JOIN "pg_stat_activity" "blockinga" ON ((("blockingl"."pid" = "blockinga"."pid") AND ("blockinga"."datid" = "blockeda"."datid"))))
  WHERE ((NOT "blockedl"."granted") AND ("blockinga"."datname" = "current_database"()));

ALTER TABLE "public"."lock_monitor" OWNER TO "postgres";

CREATE UNLOGGED TABLE "public"."post_to_slack_log" (
    "id" bigint NOT NULL,
    "payload" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "ticket_id" "text" GENERATED ALWAYS AS (("payload" ->> 'ticket_id'::"text")) STORED NOT NULL,
    "escalation_level" "text" GENERATED ALWAYS AS (("payload" ->> 'escalation_level'::"text")) STORED NOT NULL
);

ALTER TABLE "public"."post_to_slack_log" OWNER TO "postgres";

ALTER TABLE "public"."post_to_slack_log" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."post_to_slack_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."priority" (
    "id" integer NOT NULL,
    "level" "text" NOT NULL,
    "channel_id" "text" NOT NULL,
    "message" "text" NOT NULL
);

ALTER TABLE "public"."priority" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."slack_channels" (
    "id" bigint NOT NULL,
    "channel" "text",
    "channel_id" "text",
    "p_level" "text",
    "dest_channel" "text",
    "dest_channel_id" "text",
    "private" bigint DEFAULT '0'::bigint NOT NULL,
    "expiration_date" timestamp with time zone,
    "is_alert_channel" boolean DEFAULT true NOT NULL,
    "escalation_time" INTEGER[] DEFAULT '{10, 20, 35, 50}'::INTEGER[] NOT NULL,
);

ALTER TABLE "public"."slack_channels" OWNER TO "postgres";

ALTER TABLE "public"."slack_channels" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."slack_channels_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."slack_msg" (
    "channel_name" "text",
    "channel_id" "text" NOT NULL,
    "message" "text",
    "ts" timestamp with time zone NOT NULL,
    "ts_ms" "text" NOT NULL,
    "ticket_number" "text",
    "ticket_priority" "text" DEFAULT ''::"text",
    "ticket_type" "text" DEFAULT ''::"text" NOT NULL
);

ALTER TABLE "public"."slack_msg" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."support_agents" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "first_name" "text" DEFAULT ''::"text" NOT NULL,
    "last_name" "text" DEFAULT ''::"text" NOT NULL,
    "nickname" "text" DEFAULT ''::"text" NOT NULL,
    "fts" "tsvector" GENERATED ALWAYS AS ("to_tsvector"('"english"'::"regconfig", (((("lower"(COALESCE("first_name", ''::"text")) || ' '::"text") || COALESCE("lower"("last_name"))) || ' '::"text") || COALESCE("lower"("nickname"))))) STORED,
    "slack_id" "text"
);

ALTER TABLE "public"."support_agents" OWNER TO "postgres";

ALTER TABLE "public"."support_agents" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."support_agents_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "secrets"."worker_status" (
    "id" bigint NOT NULL,
    "locked" boolean DEFAULT true NOT NULL
);

ALTER TABLE "secrets"."worker_status" OWNER TO "postgres";

ALTER TABLE "secrets"."worker_status" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "secrets"."worker_status_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY "archive"."function_history"
    ADD CONSTRAINT "function_history_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."checking_tasks_queue"
    ADD CONSTRAINT "checking_tasks_queue_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."destination_channels"
    ADD CONSTRAINT "destination_channels_pkey" PRIMARY KEY ("channel_id");

ALTER TABLE ONLY "public"."mention_reply_log"
    ADD CONSTRAINT "mention_reply_log_pkey" PRIMARY KEY ("channel", "thread_ts", "ts");

ALTER TABLE ONLY "public"."post_to_slack_log"
    ADD CONSTRAINT "pk_post_to_slack_log" PRIMARY KEY ("ticket_id", "escalation_level");

ALTER TABLE ONLY "public"."slack_msg"
    ADD CONSTRAINT "pk_slack_msg" PRIMARY KEY ("channel_id", "ts", "ts_ms");

ALTER TABLE ONLY "public"."priority"
    ADD CONSTRAINT "priority_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."slack_channels"
    ADD CONSTRAINT "slack_channels_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."support_agents"
    ADD CONSTRAINT "support_agents_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."slack_channels"
    ADD CONSTRAINT "unique_channel_id" UNIQUE ("channel_id");

ALTER TABLE ONLY "secrets"."worker_status"
    ADD CONSTRAINT "worker_status_pkey" PRIMARY KEY ("id");

CREATE INDEX "support_agents_fts" ON "public"."support_agents" USING "gin" ("fts");

CREATE OR REPLACE TRIGGER "before_INSERT_function_history" BEFORE INSERT ON "archive"."function_history" FOR EACH ROW EXECUTE FUNCTION "public"."calculate_version"();

CREATE OR REPLACE TRIGGER "before_INSERT_checking_tasks_queue" BEFORE INSERT ON "public"."checking_tasks_queue" FOR EACH ROW EXECUTE FUNCTION "public"."check_mention_reply_log"();

CREATE OR REPLACE TRIGGER "check_ts_trigger" BEFORE INSERT ON "public"."slack_msg" FOR EACH ROW EXECUTE FUNCTION "public"."exclude_old_messages"();

CREATE OR REPLACE TRIGGER "insert_tasks_trigger" AFTER INSERT ON "public"."slack_msg" FOR EACH ROW EXECUTE FUNCTION "public"."insert_tasks"();

ALTER TABLE ONLY "public"."slack_channels"
    ADD CONSTRAINT "slack_channels_dest_channel_id_fkey" FOREIGN KEY ("dest_channel_id") REFERENCES "public"."destination_channels"("channel_id") ON DELETE SET NULL;

ALTER TABLE "public"."base_url" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."checking_tasks_queue" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."destination_channels" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."mention_reply_log" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."post_to_slack_log" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."priority" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."slack_channels" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."slack_msg" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."support_agents" ENABLE ROW LEVEL SECURITY;

REVOKE USAGE ON SCHEMA "public" FROM PUBLIC;
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

REVOKE ALL ON FUNCTION "archive"."save_function_history"("function_name" "text", "args" "text", "return_type" "text", "source_code" "text", "schema_name" "text", "lang_settings" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."calculate_version"() TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_version"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_version"() TO "service_role";

GRANT ALL ON FUNCTION "public"."check_due_tasks_and_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_due_tasks_and_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_due_tasks_and_update"() TO "service_role";

GRANT ALL ON FUNCTION "public"."check_due_tasks_and_update_debug"() TO "postgres";
GRANT ALL ON FUNCTION "public"."check_due_tasks_and_update_debug"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_due_tasks_and_update_debug"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_due_tasks_and_update_debug"() TO "service_role";

GRANT ALL ON FUNCTION "public"."check_mention_reply_log"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_mention_reply_log"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_mention_reply_log"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."create_function_from_source"("function_text" "text", "schema_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_function_from_source"("function_text" "text", "schema_name" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."create_ticket_array"() TO "postgres";
GRANT ALL ON FUNCTION "public"."create_ticket_array"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_ticket_array"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_ticket_array"() TO "service_role";

GRANT ALL ON FUNCTION "public"."exclude_old_messages"() TO "anon";
GRANT ALL ON FUNCTION "public"."exclude_old_messages"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."exclude_old_messages"() TO "service_role";

GRANT ALL ON FUNCTION "public"."get_current_events"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_current_events"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_current_events"() TO "service_role";

GRANT ALL ON FUNCTION "public"."get_embedded_event_names"("date_param" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."get_embedded_event_names"("date_param" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_embedded_event_names"("date_param" timestamp with time zone) TO "service_role";

GRANT ALL ON FUNCTION "public"."get_secret"("secret_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_secret"("secret_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_secret"("secret_name" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."http_get_with_auth"("url_address" "text", "bearer" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."http_get_with_auth"("url_address" "text", "bearer" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_get_with_auth"("url_address" "text", "bearer" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."http_post_with_auth"("url_address" "text", "bearer" "text", "payload" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."http_post_with_auth"("url_address" "text", "bearer" "text", "payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_post_with_auth"("url_address" "text", "bearer" "text", "payload" "jsonb") TO "service_role";

GRANT ALL ON FUNCTION "public"."http_post_with_auth"("url_address" "text", "post_data" "text", "bearer" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."http_post_with_auth"("url_address" "text", "post_data" "text", "bearer" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_post_with_auth"("url_address" "text", "post_data" "text", "bearer" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."help_plataform_wrapper"("payload" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."help_plataform_wrapper"("payload" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."help_plataform_wrapper"("payload" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."help_plataform_wrapper"("payload" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."increase_due_time"("channel" "text", "thread_ts" "text", "ts" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."increase_due_time"("channel" "text", "thread_ts" "text", "ts" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."increase_due_time"("channel" "text", "thread_ts" "text", "ts" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."insert_tasks"() TO "anon";
GRANT ALL ON FUNCTION "public"."insert_tasks"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_tasks"() TO "service_role";

GRANT ALL ON FUNCTION "public"."process_channels"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_channels"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_channels"() TO "service_role";

GRANT ALL ON FUNCTION "public"."process_channels_if_unlocked"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_channels_if_unlocked"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_channels_if_unlocked"() TO "service_role";

GRANT ALL ON FUNCTION "public"."process_channels_twice_per_call"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_channels_twice_per_call"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_channels_twice_per_call"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."rollback_function"("func_name" "text", "schema_n" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rollback_function"("func_name" "text", "schema_n" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."scan_channel"("channel_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."scan_channel"("channel_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."scan_channel"("channel_id" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."slack_post_wrapper"("payload" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."slack_post_wrapper"("payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."slack_post_wrapper"("payload" "jsonb") TO "service_role";

GRANT ALL ON TABLE "public"."base_url" TO "anon";
GRANT ALL ON TABLE "public"."base_url" TO "authenticated";
GRANT ALL ON TABLE "public"."base_url" TO "service_role";

GRANT ALL ON TABLE "public"."checking_tasks_queue" TO "anon";
GRANT ALL ON TABLE "public"."checking_tasks_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."checking_tasks_queue" TO "service_role";

GRANT ALL ON SEQUENCE "public"."checking_tasks_queue_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."checking_tasks_queue_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."checking_tasks_queue_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."destination_channels" TO "anon";
GRANT ALL ON TABLE "public"."destination_channels" TO "authenticated";
GRANT ALL ON TABLE "public"."destination_channels" TO "service_role";

GRANT ALL ON TABLE "public"."mention_reply_log" TO "anon";
GRANT ALL ON TABLE "public"."mention_reply_log" TO "authenticated";
GRANT ALL ON TABLE "public"."mention_reply_log" TO "service_role";

GRANT ALL ON TABLE "public"."lock_monitor" TO "anon";
GRANT ALL ON TABLE "public"."lock_monitor" TO "authenticated";
GRANT ALL ON TABLE "public"."lock_monitor" TO "service_role";

GRANT ALL ON TABLE "public"."post_to_slack_log" TO "anon";
GRANT ALL ON TABLE "public"."post_to_slack_log" TO "authenticated";
GRANT ALL ON TABLE "public"."post_to_slack_log" TO "service_role";

GRANT ALL ON SEQUENCE "public"."post_to_slack_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."post_to_slack_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."post_to_slack_log_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."priority" TO "anon";
GRANT ALL ON TABLE "public"."priority" TO "authenticated";
GRANT ALL ON TABLE "public"."priority" TO "service_role";

GRANT ALL ON TABLE "public"."slack_channels" TO "anon";
GRANT ALL ON TABLE "public"."slack_channels" TO "authenticated";
GRANT ALL ON TABLE "public"."slack_channels" TO "service_role";

GRANT ALL ON SEQUENCE "public"."slack_channels_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."slack_channels_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."slack_channels_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."slack_msg" TO "anon";
GRANT ALL ON TABLE "public"."slack_msg" TO "authenticated";
GRANT ALL ON TABLE "public"."slack_msg" TO "service_role";

GRANT ALL ON TABLE "public"."support_agents" TO "anon";
GRANT ALL ON TABLE "public"."support_agents" TO "authenticated";
GRANT ALL ON TABLE "public"."support_agents" TO "service_role";

GRANT ALL ON SEQUENCE "public"."support_agents_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."support_agents_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."support_agents_id_seq" TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";

RESET ALL;