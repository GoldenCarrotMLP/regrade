--
-- PostgreSQL database dump
--

-- Dumped from database version 15.8
-- Dumped by pg_dump version 15.8

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: http_response_with_headers; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.http_response_with_headers AS (
	content text,
	headers text
);


--
-- Name: assign_grades_to_phones(text[], bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_grades_to_phones(imei_param text[], grade_id_param bigint) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    imei_value TEXT;
    phone_id BIGINT;
    valid_phone_ids BIGINT[] := '{}';
    invalid_imeis TEXT[] := '{}';
BEGIN
    -- Loop through all IMEIs once
    FOREACH imei_value IN ARRAY imei_param
    LOOP
        SELECT p.id
        INTO phone_id
        FROM public.phones p
        WHERE p.imei = imei_value
          AND p.is_active = TRUE
        ORDER BY p.id DESC
        LIMIT 1;

        IF phone_id IS NULL THEN
            -- Collect invalid or inactive IMEIs
            invalid_imeis := array_append(invalid_imeis, imei_value);
        ELSE
            -- Collect valid phone IDs
            valid_phone_ids := array_append(valid_phone_ids, phone_id);
        END IF;
    END LOOP;

    -- If any invalid IMEIs found, abort and list them all
    IF array_length(invalid_imeis, 1) > 0 THEN
        RAISE EXCEPTION 'The following IMEIs were not found or inactive: %',
            array_to_string(invalid_imeis, ', ')
            USING ERRCODE = 'P0001';
    END IF;

    -- All IMEIs are valid → insert grades in bulk
    INSERT INTO public.phone_grades (grade_id, phone_id)
    SELECT grade_id_param, unnest(valid_phone_ids);
END;
$$;


--
-- Name: assign_repair_job(bigint, text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_repair_job(repair_type_param bigint, status_param text, technician_param bigint) RETURNS bigint
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$DECLARE
  new_repair_job_id BIGINT;
BEGIN
  -- Insert into repair_jobs and capture the new ID
  INSERT INTO public.repair_jobs (status_id, technician)
  VALUES (status_param::bigint, technician_param)
  RETURNING id INTO new_repair_job_id;

  -- Insert into jobs_assigned using the captured ID
  INSERT INTO public.jobs_assigned (repair_jobs_id, job_id)
  VALUES (new_repair_job_id, repair_type_param);

  -- Return the new repair_jobs ID
  RETURN new_repair_job_id;
END;$$;


--
-- Name: batch_update_phones3(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.batch_update_phones3(updates jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
DECLARE
    imeis        text[];
    done_map     jsonb;
    invalid_cols text[];
    assignments  text;
    phone        RECORD;
    rec          RECORD;
BEGIN
    -- Extract IMEIs and done_id_param
    imeis := ARRAY(
        SELECT jsonb_array_elements_text(updates->'imei_param')
    );

    done_map := updates->'done_id_param';

    -- Validate IMEIs
    IF EXISTS (
        SELECT 1
        FROM unnest(imeis) AS i
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.phones AS p
            WHERE p.imei = i
              AND p.is_active = TRUE
        )
    ) THEN
        RAISE EXCEPTION 'One or more IMEIs not found or inactive';
    END IF;

    -- Blacklist imei and id explicitly
    IF EXISTS (
        SELECT 1
        FROM jsonb_object_keys(updates)
        WHERE key IN ('imei','id')
    ) THEN
        RAISE EXCEPTION 'Properties imei and id are not allowed to be updated';
    END IF;

    -- Validate column names
    invalid_cols := ARRAY(
        SELECT key
        FROM jsonb_each_text(updates)
        WHERE key NOT IN ('imei_param','done_id_param')
          AND NOT EXISTS (
              SELECT 1
              FROM information_schema.columns
              WHERE table_schema = 'public'
                AND table_name   = 'phones'
                AND column_name  = key
          )
    );

    IF array_length(invalid_cols, 1) IS NOT NULL THEN
        RAISE EXCEPTION 'Invalid column(s): %',
            array_to_string(invalid_cols, ', ');
    END IF;

    -- Build assignment list safely
    assignments := (
        SELECT string_agg(
            format(
                '%I = (updates->>%L)::%s',
                j.key,
                j.key,
                (
                    SELECT data_type
                    FROM information_schema.columns
                    WHERE table_schema = 'public'
                      AND table_name   = 'phones'
                      AND column_name  = j.key
                )
            ),
            ', '
        )
        FROM jsonb_each(updates) AS j
        WHERE j.key NOT IN ('imei_param','done_id_param')
    );

    -- Execute dynamic update
    IF assignments IS NOT NULL THEN
        EXECUTE
            'UPDATE public.phones
             SET ' || assignments || '
             WHERE imei = ANY($1)
               AND is_active = TRUE'
        USING imeis;
    END IF;

    -- Upsert phone_jobs_done
    FOR phone IN
        SELECT id
        FROM public.phones
        WHERE imei = ANY(imeis)
          AND is_active = TRUE
    LOOP
        FOR rec IN
            SELECT key, value
            FROM jsonb_each(done_map)
        LOOP
            INSERT INTO public.phone_jobs_done (phone_id, done_id, is_done)
            VALUES (phone.id, rec.key::int, rec.value::boolean)
            ON CONFLICT (phone_id, done_id)
            DO UPDATE SET is_done = EXCLUDED.is_done;
        END LOOP;
    END LOOP;

    -- Return summary JSON
    RETURN jsonb_build_object(
        'updated_imeis', imeis,
        'done_updates', done_map
    );
END;
$_$;


--
-- Name: batch_update_phones_params(text[], jsonb, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.batch_update_phones_params(imei_param text[], done_id_param jsonb DEFAULT NULL::jsonb, sent_out_param boolean DEFAULT NULL::boolean, pending_param boolean DEFAULT NULL::boolean) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
DECLARE
    invalid_imeis text[];
BEGIN
    -- Validate IMEIs are present and active
    SELECT array_agg(i.imei)
    INTO invalid_imeis
    FROM unnest(imei_param) AS i(imei)
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.phones AS p
        WHERE p.imei = i.imei
          AND p.is_active = TRUE
    );

    IF invalid_imeis IS NOT NULL THEN
        RAISE EXCEPTION
            'The following IMEIs do not exist or are inactive: %',
            array_to_string(invalid_imeis, ', ');
    END IF;

    -- Update only sent_out and pending (no changes if params are NULL)
    UPDATE public.phones AS p
    SET
        sent_out = COALESCE(sent_out_param, p.sent_out),
        pending  = COALESCE(pending_param,  p.pending)
    WHERE p.imei = ANY(imei_param)
      AND p.is_active = TRUE;

    -- Upsert phone_jobs_done if provided
    IF done_id_param IS NOT NULL THEN

        -- Validate keys (integers) and values (booleans)
        IF EXISTS (
            SELECT 1
            FROM jsonb_each_text(done_id_param) AS j
            WHERE j.key !~ '^\d+$'
               OR j.value NOT IN ('true','false')
        ) THEN
            RAISE EXCEPTION
                'done_id_param must be a JSON object with integer keys and boolean values, e.g. {"2":true,"7":false}';
        END IF;

        INSERT INTO public.phone_jobs_done (phone_id, done_id, is_done)
        SELECT
            p.id,
            (kv.key)::int,
            (kv.value)::boolean
        FROM public.phones AS p
        CROSS JOIN LATERAL jsonb_each_text(done_id_param) AS kv
        WHERE p.imei = ANY(imei_param)
          AND p.is_active = TRUE
        ON CONFLICT (phone_id, done_id)
        DO UPDATE SET is_done = EXCLUDED.is_done;

    END IF;
END;
$_$;


--
-- Name: batch_update_phones_simple(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.batch_update_phones_simple(updates jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    imeis      text[];
    done_map   jsonb;
    phone      RECORD;
    k          text;
    v          jsonb;
BEGIN
    -- Extract IMEIs and done_id_param
    imeis := ARRAY(
        SELECT jsonb_array_elements_text(updates->'imei_param')
    );

    done_map := updates->'done_id_param';

    -- Validate IMEIs
    IF EXISTS (
        SELECT 1
        FROM unnest(imeis) AS i
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.phones AS p
            WHERE p.imei = i
              AND p.is_active = TRUE
        )
    ) THEN
        RAISE EXCEPTION 'One or more IMEIs not found or inactive';
    END IF;

    -- Update only sent_out and pending if provided
    UPDATE public.phones
    SET
        sent_out = COALESCE((updates->>'sent_out')::boolean, sent_out),
        pending  = COALESCE((updates->>'pending')::boolean, pending)
    WHERE imei = ANY(imeis)
      AND is_active = TRUE;

    -- Upsert phone_jobs_done
    FOR phone IN
        SELECT id
        FROM public.phones
        WHERE imei = ANY(imeis)
          AND is_active = TRUE
    LOOP
        FOR k, v IN
            SELECT key, value
            FROM jsonb_each(done_map)
        LOOP
            INSERT INTO public.phone_jobs_done (phone_id, done_id, is_done)
            VALUES (phone.id, k::int, v::boolean)
            ON CONFLICT (phone_id, done_id)
            DO UPDATE SET is_done = EXCLUDED.is_done;
        END LOOP;
    END LOOP;

    -- Return summary JSON
    RETURN jsonb_build_object(
        'updated_imeis', imeis,
        'done_updates', done_map,
        'sent_out', updates->>'sent_out',
        'pending', updates->>'pending'
    );
END;
$$;


--
-- Name: bulk_insert_phones(text, text, text, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.bulk_insert_phones(IN imei_list text, IN model_name text, IN status_name text, IN order_id bigint)
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    imei_array TEXT[];  -- Declare the array to hold IMEIs
    imei TEXT;  -- Declare the loop variable
BEGIN
    -- Convert the single line string to an array using \n as the delimiter
    imei_array := string_to_array(imei_list, E'\n');

    -- Loop through the array and insert each IMEI
    FOREACH imei IN ARRAY imei_array LOOP
        INSERT INTO public.phones (imei, model, status, order_id)
        VALUES (imei, model_name, status_name, order_id);
    END LOOP;
END $$;


--
-- Name: calc_order_current_job(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calc_order_current_job() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_order_id bigint;
    v_job_count int;
    v_calculated_job_id bigint;
BEGIN
    -- 1. Determine Order ID based on the phone involved in the change
    IF TG_OP = 'DELETE' THEN
        SELECT order_id INTO v_order_id FROM public.phones WHERE id = OLD.phone_id;
    ELSE
        SELECT order_id INTO v_order_id FROM public.phones WHERE id = NEW.phone_id;
    END IF;

    -- If no order found (orphan phone?), exit
    IF v_order_id IS NULL THEN RETURN NULL; END IF;

    -- 2. Check how many jobs are defined for this order
    SELECT count(*) INTO v_job_count
    FROM public.orders_jobs
    WHERE order_id = v_order_id;

    -- RULE: If only 1 job exists, that is always the current_job
    IF v_job_count = 1 THEN
        SELECT job_id INTO v_calculated_job_id
        FROM public.orders_jobs
        WHERE order_id = v_order_id
        LIMIT 1;

        UPDATE public.orders 
        SET current_job = v_calculated_job_id 
        WHERE id = v_order_id AND current_job IS DISTINCT FROM v_calculated_job_id;
        
        RETURN NULL;
    END IF;

    -- 3. Complex Logic: Find the lowest priority job that is still "Pending" 
    --    on ANY active phone within this order.
    
    WITH 
    -- A. Get the list of required jobs and their mappings for this order
    required_jobs AS (
        SELECT 
            oj.job_id, 
            eoj.priority, 
            eoj.done_id -- The mapping ID to check against phone_jobs_done
        FROM public.orders_jobs oj
        JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
        WHERE oj.order_id = v_order_id
    ),
    -- B. Get all active phones for this order
    active_phones AS (
        SELECT id AS phone_id 
        FROM public.phones 
        WHERE order_id = v_order_id AND is_active = true
    ),
    -- C. For every phone, calculate its "Next Pending Job Priority"
    --    We exclude jobs that are already marked done in phone_jobs_done
    phone_next_jobs AS (
        SELECT 
            ap.phone_id,
            rj.job_id,
            rj.priority
        FROM active_phones ap
        CROSS JOIN required_jobs rj
        WHERE NOT EXISTS (
            -- Filter out jobs that are already done
            SELECT 1 
            FROM public.phone_jobs_done pjd 
            WHERE pjd.phone_id = ap.phone_id 
              AND pjd.done_id = rj.done_id
              AND pjd.is_done = true
        )
    ),
    -- D. Determine the Order Status
    --    If Phone A is on Priority 1, and Phone B is on Priority 3,
    --    The Order is technically held back at Priority 1.
    lowest_pending_job AS (
        SELECT job_id
        FROM phone_next_jobs
        ORDER BY priority ASC -- Lowest priority first (e.g., 1 before 5)
        LIMIT 1
    )
    SELECT job_id INTO v_calculated_job_id FROM lowest_pending_job;

    -- 4. Handle "All Done" Case
    -- If v_calculated_job_id is NULL, it means there are no pending jobs for any phone.
    -- In this case, the current job is the one with the HIGHEST priority (the last step).
    IF v_calculated_job_id IS NULL THEN
        SELECT oj.job_id INTO v_calculated_job_id
        FROM public.orders_jobs oj
        JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
        WHERE oj.order_id = v_order_id
        ORDER BY eoj.priority DESC
        LIMIT 1;
    END IF;

    -- 5. Update the Order record
    IF v_calculated_job_id IS NOT NULL THEN
        UPDATE public.orders
        SET current_job = v_calculated_job_id
        WHERE id = v_order_id
          AND current_job IS DISTINCT FROM v_calculated_job_id;
    END IF;

    RETURN NULL;
END;
$$;


--
-- Name: calc_order_current_job_from_phones(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calc_order_current_job_from_phones() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_order_id bigint;
    v_lowest_job_id bigint;
BEGIN
    -- Determine Order ID
    IF TG_OP = 'DELETE' THEN
        v_order_id := OLD.order_id;
    ELSE
        v_order_id := NEW.order_id;
    END IF;

    -- Find the job with the LOWEST priority currently assigned to ANY active phone
    SELECT p.current_job
    INTO v_lowest_job_id
    FROM public.phones p
    JOIN public.enum_order_jobs eoj ON p.current_job = eoj.id
    WHERE p.order_id = v_order_id
      AND p.is_active = true
      AND p.current_job IS NOT NULL
    ORDER BY eoj.priority ASC
    LIMIT 1;

    -- If no active phones or no jobs assigned, update the order only if we found a job
    IF v_lowest_job_id IS NOT NULL THEN
        UPDATE public.orders o
        SET current_job = v_lowest_job_id
        WHERE o.id = v_order_id
          AND o.current_job IS DISTINCT FROM v_lowest_job_id;
    END IF;

    RETURN NULL;
END;
$$;


--
-- Name: calc_phone_current_job(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calc_phone_current_job() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_phone_id bigint;
    v_order_id bigint;
    v_next_job_id bigint;
BEGIN
    -- 1. Determine Phone ID
    IF TG_OP = 'DELETE' THEN
        v_phone_id := OLD.phone_id;
    ELSE
        v_phone_id := NEW.phone_id;
    END IF;

    -- 2. Get Order ID
    SELECT p.order_id
    INTO v_order_id
    FROM public.phones p
    WHERE p.id = v_phone_id;

    IF v_order_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- 3. Find the lowest priority job that is NOT present in phone_jobs_done
    SELECT oj.job_id
    INTO v_next_job_id
    FROM public.orders_jobs oj
    JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
    WHERE oj.order_id = v_order_id
      AND NOT EXISTS (
          SELECT 1
          FROM public.phone_jobs_done pjd
          WHERE pjd.phone_id = v_phone_id
            AND pjd.done_id = eoj.done_id
      )
    ORDER BY eoj.priority ASC
    LIMIT 1;

    -- 4. Handle "All Done" Case
    IF v_next_job_id IS NULL THEN
        SELECT oj.job_id
        INTO v_next_job_id
        FROM public.orders_jobs oj
        JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
        WHERE oj.order_id = v_order_id
        ORDER BY eoj.priority DESC
        LIMIT 1;
    END IF;

    -- 5. Update the Phone
    UPDATE public.phones
    SET current_job = v_next_job_id
    WHERE id = v_phone_id
      AND current_job IS DISTINCT FROM v_next_job_id;

    RETURN NULL;
END;
$$;


--
-- Name: calc_phone_current_job_batch(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calc_phone_current_job_batch() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    v_sql text;
BEGIN
    -- Determine which transition tables exist
    IF TG_OP = 'INSERT' THEN
        v_sql := 'SELECT phone_id FROM new_table WHERE phone_id IS NOT NULL';
    ELSIF TG_OP = 'DELETE' THEN
        v_sql := 'SELECT phone_id FROM old_table WHERE phone_id IS NOT NULL';
    ELSIF TG_OP = 'UPDATE' THEN
        v_sql := 'SELECT phone_id FROM new_table WHERE phone_id IS NOT NULL 
                  UNION 
                  SELECT phone_id FROM old_table WHERE phone_id IS NOT NULL';
    END IF;

    EXECUTE '
    WITH touched_phones AS (
        ' || v_sql || '
    ),
    phone_states AS (
        SELECT 
            tp.phone_id,
            p.order_id,
            (
                SELECT oj.job_id
                FROM public.orders_jobs oj
                JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                WHERE oj.order_id = p.order_id
                  AND eoj.done_id IS NOT NULL 
                  AND NOT EXISTS (
                      SELECT 1 
                      FROM public.phone_jobs_done pjd 
                      WHERE pjd.phone_id = tp.phone_id 
                        AND pjd.done_id = eoj.done_id 
                        AND pjd.is_done = true
                  )
                ORDER BY eoj.priority ASC
                LIMIT 1
            ) as next_job_id,
            (
                SELECT oj.job_id
                FROM public.orders_jobs oj
                JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                WHERE oj.order_id = p.order_id
                ORDER BY eoj.priority DESC
                LIMIT 1
            ) as last_job_id
        FROM touched_phones tp
        JOIN public.phones p ON tp.phone_id = p.id
    )
    UPDATE public.phones p
    SET current_job = COALESCE(ps.next_job_id, ps.last_job_id)
    FROM phone_states ps
    WHERE p.id = ps.phone_id
      AND p.current_job IS DISTINCT FROM COALESCE(ps.next_job_id, ps.last_job_id);
    ';

    RETURN NULL;
END;
$$;


--
-- Name: check_part_stock_and_notify(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_part_stock_and_notify() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_technician_name text;
    v_phone_model text;
    v_part_needed text;
    v_current_stock integer;
    v_notification_message text;
BEGIN
    -- Get technician name
    SELECT name INTO v_technician_name FROM public.technicians WHERE uuid = auth.uid();

    -- Get part details and current stock
    SELECT
        pi.part_name,
        pi.stock
    INTO
        v_part_needed,
        v_current_stock
    FROM
        public.parts_inventory pi
    WHERE
        pi.serial = NEW.part_serial;

    -- Get phone model if a phone_id is provided in the parts_queue record
    IF NEW.phone_id IS NOT NULL THEN
        SELECT
            em.name
        INTO
            v_phone_model
        FROM
            public.phones p
        JOIN
            public.enum_models em ON em.id = p.model_id
        WHERE
            p.id = NEW.phone_id;
    ELSE
        v_phone_model := 'an unknown phone'; -- Default message if no phone is linked
    END IF;

    -- Check if stock is 0 or less
    IF v_current_stock IS NOT NULL AND v_current_stock <= 0 THEN
        v_notification_message := format(
            '%s has requested a %s for %s because there is 0 on the inventory',
            v_technician_name,
            v_part_needed,
            v_phone_model
        );

        -- Call the notification function
        PERFORM public.send_notification_to_users(
            ARRAY['15827eab-1f98-466a-95ee-cf7a0ef04612'::uuid, 'ba7fef70-a8b1-4a46-a46b-80f867945a94'::uuid],
            v_notification_message,
            'Pending piece'
        );

        -- Update status_id for the inserted row
        NEW.status_id := 2;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: clone_repair_job(bigint, bigint, smallint, bigint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.clone_repair_job(repair_job_id_param bigint, new_technician bigint, new_repair_level smallint, repair_types bigint[]) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$DECLARE
    new_repair_job_id BIGINT;
    repair_type BIGINT;
BEGIN
    -- Create a new repair job with the provided parameters
    INSERT INTO public.repair_jobs (
        repair_level,
        technician,
        status_id
    ) VALUES (
        new_repair_level,
        new_technician,
        1
    )
    RETURNING id INTO new_repair_job_id;
    
    -- Clone all repairs associated with the original repair job
    INSERT INTO public.repairs (
        
        
        phone_id,
        repair_job_id
    )
    SELECT
       
        
        phone_id,
        new_repair_job_id
    FROM
        public.repairs
    WHERE
        repair_job_id = repair_job_id_param;
    
    -- Insert jobs_assigned records for each repair type
    FOREACH repair_type IN ARRAY repair_types LOOP
        INSERT INTO public.jobs_assigned (
            repair_jobs_id,
            job_id
        ) VALUES (
            new_repair_job_id,
            repair_type
        );
    END LOOP;
    
    -- Update the status of the original repair job to 'completed'
    UPDATE public.repair_jobs
    SET status_id = 4
    WHERE id = repair_job_id_param;
    
    -- Return the new repair job ID
    RETURN new_repair_job_id;
END;$$;


--
-- Name: compute_pending(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.compute_pending(p_phone_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    latest_report_status BIGINT;
    has_unreceived_repair BOOLEAN;
    result BOOLEAN;
BEGIN
    -- Latest report status
    SELECT r.status_id
    INTO latest_report_status
    FROM public.reports r
    WHERE r.reported_phone = p_phone_id
    ORDER BY r.id DESC
    LIMIT 1;

    -- Any outside repair still not received?
    SELECT EXISTS (
        SELECT 1
        FROM public.outside_repair_phones orp
        WHERE orp.phone_id = p_phone_id
          AND (orp.received IS DISTINCT FROM TRUE)
    )
    INTO has_unreceived_repair;

    -- Compute final pending value
    result := COALESCE(
        (latest_report_status IS NOT NULL 
         AND latest_report_status NOT IN (5, 12))
        OR has_unreceived_repair,
        false
    );

    RETURN result;
END;
$$;


--
-- Name: create_repair_with_jobs(bigint[], bigint[], bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_repair_with_jobs(phone_ids bigint[], job_ids bigint[], technician_id bigint) RETURNS bigint
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    new_repair_job_id bigint;
    pid bigint;
    jid bigint;
BEGIN
    -- 1. Create a new repair_jobs record
    INSERT INTO public.repair_jobs (technician)
    VALUES (technician_id)
    RETURNING id INTO new_repair_job_id;

    -- 2. For each phone_id, insert into repairs
    FOREACH pid IN ARRAY phone_ids LOOP
        INSERT INTO public.repairs (repair_job_id, phone_id)
        VALUES (new_repair_job_id, pid);
    END LOOP;

    -- 3. For each job_id, insert into jobs_assigned
    FOREACH jid IN ARRAY job_ids LOOP
        INSERT INTO public.jobs_assigned (repair_jobs_id, job_id)
        VALUES (new_repair_job_id, jid);
    END LOOP;

    -- Return the new repair_jobs.id for reference
    RETURN new_repair_job_id;
END;
$$;


--
-- Name: create_reports_by_imei(text[], bigint, bigint, bigint, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_reports_by_imei(imei_array_param text[], issue_id_param bigint, causer_id_param bigint, reporter_id_param bigint, status_id_param bigint DEFAULT NULL::bigint, notes_param text DEFAULT NULL::text) RETURNS bigint[]
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    imei_variable TEXT;
    phone_record  RECORD;
    inserted_ids  BIGINT[] := '{}';
    report_id     BIGINT;
BEGIN
    FOREACH imei_variable IN ARRAY imei_array_param LOOP
        SELECT id
        INTO phone_record
        FROM public.phones
        WHERE phones.imei = imei_variable
          AND is_active = TRUE
        ORDER BY id
        LIMIT 1;

        IF phone_record.id IS NOT NULL THEN
            IF status_id_param IS NULL THEN
                -- No status passed, let the table's default handle it
                INSERT INTO public.reports (reported_phone, issue_id, causer_id, reporter_id, notes)
                VALUES (phone_record.id, issue_id_param, causer_id_param, reporter_id_param, notes_param)
                RETURNING id INTO report_id;
            ELSE
                -- Status explicitly passed, set it
                INSERT INTO public.reports (reported_phone, issue_id, causer_id, reporter_id, status_id, notes)
                VALUES (phone_record.id, issue_id_param, causer_id_param, reporter_id_param, status_id_param, notes_param)
                RETURNING id INTO report_id;
            END IF;

            inserted_ids := array_append(inserted_ids, report_id);
        END IF;
    END LOOP;

    RETURN inserted_ids;
END;
$$;


--
-- Name: current_company_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_company_id() RETURNS bigint
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  cid bigint;
BEGIN
  SELECT ec.id
  INTO cid
  FROM public.enum_companies ec
  WHERE ec.uuid = auth.uid() -- or hardcode for testing
  LIMIT 1;

  RETURN cid;
END;
$$;


--
-- Name: decrement_stock_on_approval(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.decrement_stock_on_approval() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    current_stock integer;
BEGIN
    -- Fetch current stock for the part
    SELECT stock INTO current_stock
    FROM public.parts_inventory
    WHERE serial = NEW.part_serial;

    -- Throw error if stock is NULL
    IF current_stock IS NULL THEN
        RAISE EXCEPTION 'Stock is NULL for part_serial=%', NEW.part_serial
            USING ERRCODE = '22004'; -- null value not allowed
    END IF;

    -- Case 1: status changes TO approved (10)
    IF NEW.status_id = 10 AND OLD.status_id != 10 THEN
        UPDATE public.parts_inventory
        SET stock = stock - 1
        WHERE serial = NEW.part_serial;
    END IF;

    -- Case 2: status changes FROM approved (10) to something else
    IF OLD.status_id = 10 AND NEW.status_id != 10 THEN
        UPDATE public.parts_inventory
        SET stock = stock + 1
        WHERE serial = NEW.part_serial;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: enforce_pending_rule(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_pending_rule() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    should_be_pending BOOLEAN;
BEGIN
    should_be_pending := public.compute_pending(NEW.id);

    IF NEW.pending = false AND should_be_pending = true THEN
        RAISE EXCEPTION
            'Cannot set phone % (IMEI=%) pending=false while conditions require pending=true',
            NEW.id, NEW.imei
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: generate_repair_job_json(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_repair_job_json(p_repair_job_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    repair_job RECORD;
    repair_counts JSONB;
BEGIN
    -- Fetch the repair job details
    SELECT * INTO repair_job
    FROM public.repair_jobs
    WHERE id = p_repair_job_id;  -- Use the new parameter name

    -- Check if the repair job exists
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Repair job with ID % does not exist', p_repair_job_id;
    END IF;

    -- Count the total number of repairs grouped by repair_type from the repair_jobs table
    WITH repair_summary AS (
        SELECT r.repair_type, COUNT(*) AS total
        FROM public.repairs rp  -- Alias the repairs table as rp
        JOIN public.repair_jobs r ON rp.repair_job_id = r.id  -- Join with repair_jobs to get repair_type
        WHERE rp.repair_job_id = p_repair_job_id
        GROUP BY r.repair_type
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   repair_type, total,  -- Count of repairs for each repair_type
                   repair_type || '_repair_level', repair_job.repair_level
               )
           ) INTO repair_counts
    FROM repair_summary;

    -- Return the JSON output
    RETURN COALESCE(repair_counts, '[]'::jsonb);  -- Return an empty JSON array if no repairs found
END;
$$;


--
-- Name: get_current_month_sentout_breakdown(bigint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_month_sentout_breakdown(job_ids bigint[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    result jsonb;
BEGIN
    WITH job_map AS (
        SELECT ej.id AS job_id, ej.name AS department
        FROM public.enum_order_jobs ej
        WHERE ej.id = ANY(job_ids)
    ),
    orders_with_jobs AS (
        SELECT DISTINCT oj.order_id, jm.department
        FROM public.orders_jobs oj
        JOIN job_map jm ON jm.job_id = oj.job_id
    ),
    phones_in_orders AS (
        SELECT p.id AS phone_id, o.order_id, o.department
        FROM public.phones p
        JOIN orders_with_jobs o ON o.order_id = p.order_id
    ),
    filtered AS (
        SELECT DISTINCT
            pul.phone_id,
            o.order_id,
            o.department,
            pul.updated_at::date AS update_date
        FROM public.phone_update_log pul
        JOIN phones_in_orders o ON o.phone_id = pul.phone_id
        WHERE (pul.old_sent_out IS NULL OR pul.old_sent_out = false)
          AND pul.new_sent_out = true
          AND pul.updated_at >= date_trunc('month', CURRENT_DATE)
          AND pul.updated_at < (date_trunc('month', CURRENT_DATE) + interval '1 month')
    ),
    order_jobs AS (
        SELECT oj.order_id, array_agg(ej.name ORDER BY ej.priority) AS job_names
        FROM public.orders_jobs oj
        JOIN public.enum_order_jobs ej ON ej.id = oj.job_id
        GROUP BY oj.order_id
    ),
    breakdown AS (
        SELECT
            f.department,
            f.update_date,
            f.order_id,
            COUNT(DISTINCT f.phone_id) AS sent_out_amount,
            oj.job_names,
            c.name AS company
        FROM filtered f
        JOIN public.orders o ON o.id = f.order_id
        LEFT JOIN order_jobs oj ON oj.order_id = f.order_id
        LEFT JOIN public.enum_companies c ON c.id = o.company_id
        GROUP BY f.department, f.update_date, f.order_id, oj.job_names, c.name
    ),
    dept_totals AS (
        SELECT
            department,
            to_char(date_trunc('month', CURRENT_DATE), 'YYYY-Mon') AS date,
            SUM(sent_out_amount) AS sentout_phones,
            jsonb_agg(
                jsonb_build_object(
                    'order_id', b.order_id,
                    'sent_out_amount', b.sent_out_amount,
                    'update_date', to_char(b.update_date, 'YYYY-MM-DD'),
                    'order_jobs', b.job_names,
                    'company', b.company
                ) ORDER BY b.update_date, b.order_id
            ) AS data
        FROM breakdown b
        GROUP BY department
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'department', d.department,
            'date', d.date,
            'sentout_phones', d.sentout_phones,
            'data', d.data
        )
    )
    INTO result
    FROM dept_totals d;

    RETURN result;
END;
$$;


--
-- Name: get_current_month_sentout_by_jobs(bigint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_month_sentout_by_jobs(job_ids bigint[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    result jsonb;
BEGIN
    WITH job_map AS (
        SELECT ej.id AS job_id, ej.name AS department
        FROM public.enum_order_jobs ej
        WHERE ej.id = ANY(job_ids)
    ),
    orders_with_jobs AS (
        SELECT DISTINCT oj.order_id, jm.department
        FROM public.orders_jobs oj
        JOIN job_map jm ON jm.job_id = oj.job_id
    ),
    phones_in_orders AS (
        SELECT p.id AS phone_id, o.department
        FROM public.phones p
        JOIN orders_with_jobs o ON o.order_id = p.order_id
    ),
    filtered AS (
        SELECT DISTINCT
            pul.phone_id,
            o.department
        FROM public.phone_update_log pul
        JOIN phones_in_orders o ON o.phone_id = pul.phone_id
        WHERE (pul.old_sent_out IS NULL OR pul.old_sent_out = false)
          AND pul.new_sent_out = true
          AND pul.updated_at >= date_trunc('month', CURRENT_DATE)
          AND pul.updated_at < (date_trunc('month', CURRENT_DATE) + interval '1 month')
    ),
    counts AS (
        SELECT
            department,
            COUNT(DISTINCT phone_id) AS sentout_phones
        FROM filtered
        GROUP BY department
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'department', c.department,
            'date', to_char(date_trunc('month', CURRENT_DATE), 'YYYY-Mon'),
            'sentout_phones', c.sentout_phones
        )
    )
    INTO result
    FROM counts c;

    RETURN result;
END;
$$;


--
-- Name: get_current_technician(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_technician() RETURNS TABLE(id bigint, created_at timestamp with time zone, name text, role text, role_id bigint, picture_url text, uuid uuid, panel_access text[], chat_perms boolean, panel_access_data jsonb, managers bigint[], is_manager boolean)
    LANGUAGE sql
    SET search_path TO ''
    AS $$
WITH tech AS (
    -- 🟢 FIX: Select ALL columns required by the function signature
    SELECT t.id,
           t.created_at,
           t.name,
           re.name AS role,
           t.role_id,
           t.picture_url,
           t.uuid,
           t.panel_access,
           t.chat_perms
    FROM public.technicians t
    JOIN public.enum_roles re ON re.id = t.role_id
    WHERE t.uuid = CASE
        WHEN auth.role() = 'service_role'
        THEN '3c132ec9-d397-471a-a95f-3a4606d43447'::uuid
        ELSE auth.uid()
    END
),
-- ⚡️ CORE OPTIMIZATION (Your new logic): 
shop_floor_state AS (
    SELECT 
        o.id AS order_id,
        o.status_id AS order_status,
        o.current_job,
        p.id AS phone_id,
        lr.status_id AS report_status
    FROM public.orders o
    JOIN public.phones p ON p.order_id = o.id
    -- ⚡️ LATERAL JOIN: Looks up the report ONLY for the active phones found above
    LEFT JOIN LATERAL (
        SELECT r.status_id 
        FROM public.reports r
        WHERE r.reported_phone = p.id
        ORDER BY r.id DESC
        LIMIT 1
    ) lr ON true
    WHERE o.status_id IN (1, 2, 8)
      AND p.is_active = true
),
---------------------------------------------------------
-- METRICS
---------------------------------------------------------
metrics AS (
    -- 1. Receiving
    SELECT 'receiving' AS panel,
           jsonb_build_object(
               'waiting_orders', COUNT(*) FILTER (WHERE status_id = 2),
               'working_orders', COUNT(*) FILTER (WHERE status_id = 8)
           ) AS data
    FROM public.orders
    WHERE status_id IN (2, 8, 1)

    UNION ALL

    -- 2. Paint
    SELECT 'paint',
           jsonb_build_object(
               'waiting_orders', COUNT(DISTINCT order_id) FILTER (WHERE order_status = 2),
               'working_orders', COUNT(DISTINCT order_id) FILTER (WHERE order_status = 8),
               'pending', COUNT(phone_id) FILTER (WHERE report_status = 6)
           )
    FROM shop_floor_state
    WHERE current_job IN (10, 11, 22)

    UNION ALL

    -- 3. Body
    SELECT 'body',
           jsonb_build_object(
               'waiting_orders', COUNT(DISTINCT order_id) FILTER (WHERE order_status = 2),
               'working_orders', COUNT(DISTINCT order_id) FILTER (WHERE order_status = 8),
               'pending', COUNT(phone_id) FILTER (WHERE report_status = 6)
           )
    FROM shop_floor_state
    WHERE current_job IN (8, 24)

    UNION ALL

    -- 4. Polish
    SELECT 'polish',
           jsonb_build_object(
               'waiting_orders', COUNT(DISTINCT order_id) FILTER (WHERE order_status = 2),
               'working_orders', COUNT(DISTINCT order_id) FILTER (WHERE order_status = 8),
               'pending', COUNT(phone_id) FILTER (WHERE report_status = 6)
           )
    FROM shop_floor_state
    WHERE current_job IN (12, 13, 14, 23)

    UNION ALL

    -- 5. Battery
    SELECT 'battery',
           jsonb_build_object(
               'waiting_orders', COUNT(DISTINCT order_id) FILTER (WHERE order_status = 2),
               'working_orders', COUNT(DISTINCT order_id) FILTER (WHERE order_status = 8),
               'pending', COUNT(phone_id) FILTER (WHERE report_status = 6)
           )
    FROM shop_floor_state
    WHERE current_job = 7

    UNION ALL

    -- 6. Polish Plus
    SELECT 'polish-plus',
           jsonb_build_object(
               'waiting_orders', COUNT(DISTINCT order_id) FILTER (WHERE order_status = 2),
               'working_orders', COUNT(DISTINCT order_id) FILTER (WHERE order_status = 8),
               'pending', COUNT(phone_id) FILTER (WHERE report_status = 6)
           )
    FROM shop_floor_state
    WHERE current_job IN (15, 21)

    UNION ALL

    -- 7. Glass
    SELECT 'glass',
           jsonb_build_object(
               'waiting_orders', COUNT(DISTINCT order_id) FILTER (WHERE order_status = 2),
               'working_orders', COUNT(DISTINCT order_id) FILTER (WHERE order_status = 8),
               'pending', COUNT(phone_id) FILTER (WHERE report_status = 6)
           )
    FROM shop_floor_state
    WHERE current_job = 25

    UNION ALL

    -- 8. Packing
    SELECT 'packing', jsonb_build_object('waiting_orders', COUNT(*))
    FROM public.orders WHERE status_id = 2

    UNION ALL

    -- 9. Parts
    SELECT 'phone-parts',
           jsonb_build_object(
               'pending', COUNT(*) FILTER (WHERE status_id = 1),
               'working_orders', COUNT(*) FILTER (WHERE status_id = 2)
           )
    FROM public.parts_queue WHERE status_id IN (1, 2)

    UNION ALL

    -- 10. See Reports
    SELECT 'see-reports', jsonb_build_object('working_orders', COUNT(*))
    FROM public.reports WHERE status_id = 1
),
managers_cte AS (
  SELECT
    array_agg(m.manager_id) AS managers,
    COALESCE(bool_or(m.manager_id = t.id), false) AS is_manager
  FROM public.managers m
  JOIN tech t ON m.employee_id = t.id
)
SELECT
    tech.*, -- This now expands to the full column list matching the RETURN TABLE
    (
        SELECT jsonb_object_agg(m.panel, m.data)
        FROM metrics m
        WHERE ('*' = ANY(tech.panel_access)) OR m.panel = ANY(tech.panel_access)
    ) AS panel_access_data,
    managers_cte.managers,
    managers_cte.is_manager
FROM tech
LEFT JOIN managers_cte ON true

-- 🟢 MAINTAIN FALLBACK FOR NO USER (Keeps the original function's behavior)
UNION ALL

SELECT
    NULL::bigint AS id,
    NULL::timestamptz AS created_at,
    NULL::text AS name,
    NULL::text AS role,
    NULL::bigint AS role_id,
    NULL::text AS picture_url,
    NULL::uuid AS uuid,
    NULL::text[] AS panel_access,
    NULL::boolean AS chat_perms,
    jsonb_build_object(
        'claim.role', COALESCE(current_setting('request.jwt.claim.role', true), 'no claimrole'),
        'claim.sub',  COALESCE(current_setting('request.jwt.claim.sub', true), 'no claimsub'),
        'auth.uid',   COALESCE(auth.uid()::text, 'null'),
        'auth.role',  COALESCE(auth.role(), 'null'),
        'current_user', current_user,
        'session_user', session_user
    ) AS panel_access_data,
    NULL::bigint[] AS managers,
    false AS is_manager
WHERE NOT EXISTS (SELECT 1 FROM tech);
$$;


--
-- Name: get_current_technician_old(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_technician_old() RETURNS TABLE(id bigint, created_at timestamp with time zone, name text, role text, role_id bigint, picture_url text, uuid uuid, panel_access text[], chat_perms boolean, panel_access_data jsonb, managers bigint[], is_manager boolean)
    LANGUAGE sql
    SET search_path TO ''
    AS $$
WITH tech AS (
    SELECT t.id,
           t.created_at,
           t.name,
           re.name AS role,
           t.role_id,
           t.picture_url,
           t.uuid,
           t.panel_access,
           t.chat_perms
    FROM public.technicians t
    JOIN public.enum_roles re ON re.id = t.role_id
    WHERE t.uuid = CASE
        WHEN auth.role() = 'service_role'
        THEN '3c132ec9-d397-471a-a95f-3a4606d43447'::uuid
        ELSE auth.uid()
    END
),
latest_reports AS (
    SELECT r.*
    FROM public.reports r
    JOIN (
        SELECT reported_phone, MAX(id) AS max_id
        FROM public.reports
        GROUP BY reported_phone
    ) lr ON lr.max_id = r.id
),
-- Active orders CTE
active_orders AS (
    SELECT 
        o.id, 
        o.status_id, 
        o.current_job -- This is the integer ID
    FROM public.orders o
    WHERE o.status_id IN (1, 2, 8)
),
-- 1. Receiving Panel
receiving_metrics AS (
    SELECT 'receiving' AS panel,
           jsonb_build_object(
               'waiting_orders', COUNT(*) FILTER (WHERE status_id = 2),
               'working_orders', COUNT(*) FILTER (WHERE status_id = 8)
           ) AS data
    FROM public.orders
    WHERE status_id IN (2, 8, 1)
),
-- 2. Paint Panel (IDs: 10=Paint, 11=Paint After Polish, 22=Rework Paint)
paint_metrics AS (
    SELECT 'paint' AS panel,
           jsonb_build_object(
               'waiting_orders', COUNT(DISTINCT ao.id) FILTER (WHERE ao.status_id = 2),
               'working_orders', COUNT(DISTINCT ao.id) FILTER (WHERE ao.status_id = 8),
               'pending', COUNT(DISTINCT p.id) FILTER (WHERE lr.status_id = 6)
           ) AS data
    FROM active_orders ao
    JOIN public.phones p ON p.order_id = ao.id
    LEFT JOIN latest_reports lr ON lr.reported_phone = p.id
    WHERE ao.current_job IN (10, 11, 22)
),
-- 3. Body Panel (IDs: 8=Body, 24=New ID added)
body_metrics AS (
    SELECT 'body' AS panel,
           jsonb_build_object(
               'waiting_orders', COUNT(DISTINCT ao.id) FILTER (WHERE ao.status_id = 2),
               'working_orders', COUNT(DISTINCT ao.id) FILTER (WHERE ao.status_id = 8),
               'pending', COUNT(DISTINCT p.id) FILTER (WHERE lr.status_id = 6)
           ) AS data
    FROM active_orders ao
    JOIN public.phones p ON p.order_id = ao.id
    LEFT JOIN latest_reports lr ON lr.reported_phone = p.id
    WHERE ao.current_job IN (8, 24) -- ✅ Added 24 here
),
-- 4. Polish Panel (IDs: 12=Polish, 13=Polish Back, 14=Polish Front, 23=Back)
polish_metrics AS (
    SELECT 'polish' AS panel,
           jsonb_build_object(
               'waiting_orders', COUNT(DISTINCT ao.id) FILTER (WHERE ao.status_id = 2),
               'working_orders', COUNT(DISTINCT ao.id) FILTER (WHERE ao.status_id = 8),
               'pending', COUNT(DISTINCT p.id) FILTER (WHERE lr.status_id = 6)
           ) AS data
    FROM active_orders ao
    JOIN public.phones p ON p.order_id = ao.id
    LEFT JOIN latest_reports lr ON lr.reported_phone = p.id
    WHERE ao.current_job IN (12, 13, 14, 23)
),
-- 5. Battery Panel (ID: 7=Battery)
battery_metrics AS (
    SELECT 'battery' AS panel, -- ✅ Split from polishp
           jsonb_build_object(
               'waiting_orders', COUNT(DISTINCT ao.id) FILTER (WHERE ao.status_id = 2),
               'working_orders', COUNT(DISTINCT ao.id) FILTER (WHERE ao.status_id = 8),
               'pending', COUNT(DISTINCT p.id) FILTER (WHERE lr.status_id = 6)
           ) AS data
    FROM active_orders ao
    JOIN public.phones p ON p.order_id = ao.id
    LEFT JOIN latest_reports lr ON lr.reported_phone = p.id
    WHERE ao.current_job = 7
),
-- 6. Polish Plus Panel (ID: 15=Polish Plus, 21=Rework Polish Plus)
polish_plus_metrics AS (
    SELECT 'polish-plus' AS panel, -- ✅ Split from battery
           jsonb_build_object(
               'waiting_orders', COUNT(DISTINCT ao.id) FILTER (WHERE ao.status_id = 2),
               'working_orders', COUNT(DISTINCT ao.id) FILTER (WHERE ao.status_id = 8),
               'pending', COUNT(DISTINCT p.id) FILTER (WHERE lr.status_id = 6)
           ) AS data
    FROM active_orders ao
    JOIN public.phones p ON p.order_id = ao.id
    LEFT JOIN latest_reports lr ON lr.reported_phone = p.id
    WHERE ao.current_job IN (15, 21)
),
-- 7. Glass Panel (ID: 25=Glass)
glass_metrics AS (
    SELECT 'glass' AS panel, -- ✅ New Panel
           jsonb_build_object(
               'waiting_orders', COUNT(DISTINCT ao.id) FILTER (WHERE ao.status_id = 2),
               'working_orders', COUNT(DISTINCT ao.id) FILTER (WHERE ao.status_id = 8),
               'pending', COUNT(DISTINCT p.id) FILTER (WHERE lr.status_id = 6)
           ) AS data
    FROM active_orders ao
    JOIN public.phones p ON p.order_id = ao.id
    LEFT JOIN latest_reports lr ON lr.reported_phone = p.id
    WHERE ao.current_job = 25
),
-- 8. Packing Panel
packing_metrics AS (
    SELECT 'packing' AS panel,
           jsonb_build_object(
               'waiting_orders', COUNT(*)
           ) AS data
    FROM public.orders
    WHERE status_id = 2
),
-- 9. Phone Parts Panel
phone_parts_metrics AS (
    SELECT 'phone-parts' AS panel,
           jsonb_build_object(
               'pending', COUNT(*) FILTER (WHERE o.status_id = 1),
               'working_orders', COUNT(*) FILTER (WHERE o.status_id = 2)
           ) AS data
    FROM public.parts_queue o
    WHERE o.status_id IN (1, 2)
),
-- 10. Reports Panel
see_reports_metrics AS (
    SELECT 'see-reports' AS panel,
           jsonb_build_object(
               'working_orders', COUNT(*)
           ) AS data
    FROM public.reports
    WHERE status_id = 1
),
-- Combine all metrics
metrics AS (
    SELECT * FROM receiving_metrics
    UNION ALL SELECT * FROM paint_metrics
    UNION ALL SELECT * FROM body_metrics
    UNION ALL SELECT * FROM polish_metrics
    UNION ALL SELECT * FROM battery_metrics      -- ✅ Added
    UNION ALL SELECT * FROM polish_plus_metrics  -- ✅ Added
    UNION ALL SELECT * FROM glass_metrics        -- ✅ Added
    UNION ALL SELECT * FROM packing_metrics
    UNION ALL SELECT * FROM phone_parts_metrics
    UNION ALL SELECT * FROM see_reports_metrics
),
managers_cte AS (
  SELECT
    array_agg(m.manager_id) AS managers,
    COALESCE(bool_or(m.manager_id = t.id), false) AS is_manager
  FROM public.managers m
  JOIN tech t ON m.employee_id = t.id
)
SELECT
    tech.*,
    (
        SELECT jsonb_object_agg(m.panel, m.data)
        FROM metrics m
        WHERE ('*' = ANY(tech.panel_access))
           OR m.panel = ANY(tech.panel_access)
    ) AS panel_access_data,
    managers_cte.managers,
    managers_cte.is_manager
FROM tech
LEFT JOIN managers_cte ON true

UNION ALL

SELECT
    NULL::bigint AS id,
    NULL::timestamptz AS created_at,
    NULL::text AS name,
    NULL::text AS role,
    NULL::bigint AS role_id,
    NULL::text AS picture_url,
    NULL::uuid AS uuid,
    NULL::text[] AS panel_access,
    NULL::boolean AS chat_perms,
    jsonb_build_object(
        'claim.role', COALESCE(current_setting('request.jwt.claim.role', true), 'no claimrole'),
        'claim.sub',  COALESCE(current_setting('request.jwt.claim.sub', true), 'no claimsub'),
        'auth.uid',   COALESCE(auth.uid()::text, 'null'),
        'auth.role',  COALESCE(auth.role(), 'null'),
        'current_user', current_user,
        'session_user', session_user
    ) AS panel_access_data,
    NULL::bigint[] AS managers,
    false AS is_manager
WHERE NOT EXISTS (SELECT 1 FROM tech);
$$;


--
-- Name: get_current_user_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_user_id() RETURNS uuid
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  SELECT auth.uid();
$$;


--
-- Name: get_daily_leaderboard(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_leaderboard(target_date date DEFAULT NULL::date) RETURNS TABLE(technician_name text, technician_picture text, role_id bigint, total_points numeric, penalty_points numeric, bonus_points numeric, goal_percentage numeric, devices_fixed bigint, last_active text, time_spent text, has_open_job boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    search_date date;
BEGIN
    -- 1. Determine the Date (Default to Today in NY)
    search_date := COALESCE(target_date, (NOW() AT TIME ZONE 'America/New_York')::date);

    RETURN QUERY
    WITH valid_todays_jobs AS (
        -- 2. Filter Repair Jobs (Timezone & Duration Rules)
        SELECT
            rj.id,
            rj.technician,
            rj.completed_date,
            rj.created_at,
            (rj.completed_date - rj.created_at) AS job_duration
        FROM
            public.repair_jobs rj
        WHERE
            rj.status_id = 4 -- Completed
            AND (rj.completed_date AT TIME ZONE 'America/New_York')::date = search_date
            AND (rj.completed_date - rj.created_at) < INTERVAL '7 hours'
    ),
    ticket_scoring AS (
        -- 3. Calculate Points per Ticket (Standard vs Multiplier)
        SELECT
            ja.repair_jobs_id,
            
            -- A: The "Applied" Score (With Multiplier Logic)
            CASE 
                WHEN COUNT(*) FILTER (WHERE ja.job_id = 6) > 0 THEN
                    SUM(CASE WHEN ja.job_id != 6 THEN COALESCE(ej.points, 0) ELSE 0 END) * 
                    MAX(CASE WHEN ja.job_id = 6 THEN COALESCE(ej.points, 1) ELSE 1 END)
                ELSE
                    SUM(COALESCE(ej.points, 0))
            END AS applied_score,
            
            -- B: The "Raw" Score (Simple Sum, no magic)
            SUM(COALESCE(ej.points, 0)) AS raw_score
            
        FROM
            public.jobs_assigned ja
        JOIN
            public.enum_jobs ej ON ja.job_id = ej.id
        WHERE
            exists (select 1 from valid_todays_jobs v where v.id = ja.repair_jobs_id)
        GROUP BY
            ja.repair_jobs_id
    ),
    time_stats AS (
        -- 4. Calculate Time Spent
        SELECT
            technician,
            SUM(job_duration) AS total_duration,
            MAX(completed_date) AS last_seen
        FROM
            valid_todays_jobs
        GROUP BY
            technician
    ),
    earned_stats AS (
        -- 5. Calculate Gross Points & Bonus Points
        SELECT
            vtj.technician,
            COUNT(r.id) AS device_count,
            
            -- Total Points used for leaderboard (Applied Score)
            SUM(COALESCE(ts.applied_score, 0)) AS gross_points,
            
            -- Bonus Points = (Applied Score - Raw Score)
            SUM(COALESCE(ts.applied_score, 0) - COALESCE(ts.raw_score, 0)) AS bonus_points
            
        FROM
            valid_todays_jobs vtj
        JOIN
            public.repairs r ON vtj.id = r.repair_job_id
        LEFT JOIN
            ticket_scoring ts ON vtj.id = ts.repair_jobs_id
        GROUP BY
            vtj.technician
    ),
    penalty_stats AS (
        -- 6. Calculate Penalties from Damages
        SELECT
            r.causer_id AS technician,
            SUM(COALESCE(ed.penalty, 0)) AS total_penalty
        FROM
            public.reports r
        JOIN
            public.enum_damages ed ON r.issue_id = ed.id
        WHERE
            r.causer_id IS NOT NULL
            AND (r.created_at AT TIME ZONE 'America/New_York')::date = search_date
        GROUP BY
            r.causer_id
    ),
    current_status AS (
        -- 7. Check for Open Jobs
        SELECT DISTINCT technician
        FROM public.repair_jobs
        WHERE status_id = 1
    )
    -- 8. Final Assembly
    SELECT
        t.name::text,
        t.picture_url::text,
        t.role_id,
        
        -- Net Total (Gross - Penalties)
        ROUND((COALESCE(es.gross_points, 0) - COALESCE(ps.total_penalty, 0))::numeric, 2) AS total_points,
        
        -- Penalty Display (Negative)
        ROUND((COALESCE(ps.total_penalty, 0) * -1)::numeric, 2) AS penalty_points,
        
        -- Bonus Display (The extra points gained from Rework multiplier)
        ROUND(COALESCE(es.bonus_points, 0)::numeric, 2) AS bonus_points,
        
        -- Percentage based on Net Total
        ROUND(((COALESCE(es.gross_points, 0) - COALESCE(ps.total_penalty, 0)) / 500.0 * 100)::numeric, 1) AS goal_percentage,
        
        COALESCE(es.device_count, 0) AS devices_fixed,
        
        ts.last_seen::text AS last_active,
        
        (
            TO_CHAR(FLOOR(EXTRACT(EPOCH FROM ts.total_duration) / 3600), 'FM999') || ':' || 
            TO_CHAR(EXTRACT(MINUTE FROM ts.total_duration), 'FM00')
        )::text AS time_spent,
        
        (cs.technician IS NOT NULL) AS has_open_job
        
    FROM
        public.technicians t
    LEFT JOIN
        time_stats ts ON t.id = ts.technician
    LEFT JOIN
        earned_stats es ON t.id = es.technician
    LEFT JOIN
        penalty_stats ps ON t.id = ps.technician
    LEFT JOIN
        current_status cs ON t.id = cs.technician
    WHERE
        es.gross_points IS NOT NULL OR ps.total_penalty IS NOT NULL OR cs.technician IS NOT NULL
    ORDER BY
        total_points DESC;
END;
$$;


--
-- Name: get_daily_technician_progress_grouped(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_daily_technician_progress_grouped(p_start_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_date timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
WITH daily_stats AS (
    SELECT
        t.id AS technician_id,
        t.name AS technician_name,
        DATE(rj.created_at) AS work_date,
        ej.name AS work,
        ROUND(SUM(EXTRACT(EPOCH FROM (rj.completed_date - rj.created_at)) / 3600)::numeric, 2) AS amount_hours,
        COUNT(DISTINCT rep.phone_id) AS devices_done
    FROM public.repair_jobs rj
    JOIN public.technicians t ON t.id = rj.technician
    JOIN public.jobs_assigned ja ON ja.repair_jobs_id = rj.id
    JOIN public.enum_jobs ej ON ej.id = ja.job_id
    JOIN public.repairs rep ON rep.repair_job_id = rj.id
    WHERE (p_start_date IS NULL OR rj.created_at >= p_start_date)
      AND (p_end_date   IS NULL OR rj.created_at <= p_end_date)
    GROUP BY t.id, t.name, DATE(rj.created_at), ej.name
),
grouped_by_tech AS (
    SELECT
        technician_id,
        technician_name,
        jsonb_agg(
            jsonb_build_object(
                'day', to_char(work_date, 'MM/DD/YYYY'),
                'work', work,
                'amount_hours', amount_hours,
                'devices_done', devices_done
            ) ORDER BY work_date, work
        ) AS daily
    FROM daily_stats
    GROUP BY technician_id, technician_name
)
SELECT jsonb_agg(
    jsonb_build_object(
        'technician_id', technician_id,
        'technician_name', technician_name,
        'daily', daily
    ) ORDER BY technician_name
)
FROM grouped_by_tech;
$$;


--
-- Name: get_hosts(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_hosts() RETURNS SETOF firewall.hosts
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$select * from firewall.hosts;$$;


--
-- Name: get_ip_whitelist(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_ip_whitelist() RETURNS SETOF firewall.ip_whitelist
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$select * from firewall.ip_whitelist;$$;


--
-- Name: get_marks_count2(bigint, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_marks_count2(order_id_parameter bigint, boxnumbers text[]) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    RETURN (
        WITH phone_data AS (
            SELECT
                p.id AS phone_id,
                em.name AS model,
                p.mark,
                p.imei,
                (
                    SELECT string_agg(eoj.name, ' & ')
                    FROM public.orders_jobs oj
                    JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                    WHERE oj.order_id = o.id
                ) AS order_type,
                o.boxes,
                o.order_color,
                ec.name AS company_name,
                o.tag,
                (
                  SELECT pg.grade_id
                  FROM public.phone_grades pg
                  WHERE pg.phone_id = p.id
                  ORDER BY pg.id DESC
                  LIMIT 1
                ) AS latest_grade_id
            FROM
                public.phones p
            JOIN
                public.orders o ON p.order_id = o.id
            JOIN
                public.enum_companies ec ON o.company_id = ec.id
            JOIN
                public.enum_models em ON p.model_id = em.id
            WHERE
                p.order_id = order_id_parameter
                AND p.mark = ANY(boxnumbers)
        ),
        graded_phone_data AS (
            SELECT
                pd.*,
                COALESCE(eg.name, 'No Grade') AS grade_name
            FROM
                phone_data pd
            LEFT JOIN
                public.enum_grade eg ON pd.latest_grade_id = eg.id
        ),
        -- Aggregate counts per grade for each model/mark/order
        grade_level_aggregations AS (
            SELECT
                gpd.model,
                gpd.mark,
                gpd.order_type,
                gpd.boxes,
                gpd.order_color,
                gpd.company_name,
                gpd.tag,
                gpd.grade_name,
                COUNT(*) AS grade_count
            FROM
                graded_phone_data gpd
            GROUP BY
                gpd.model,
                gpd.mark,
                gpd.order_type,
                gpd.boxes,
                gpd.order_color,
                gpd.company_name,
                gpd.tag,
                gpd.grade_name
        ),
        model_level_aggregations AS (
            SELECT
                ga.model,
                ga.mark,
                ga.order_type,
                ga.boxes,
                ga.order_color,
                ga.company_name,
                ga.tag,
                SUM(ga.grade_count) AS total_count_for_model,
                json_agg(
                    json_build_object(
                        'grade_name', ga.grade_name,
                        'count', ga.grade_count
                    ) ORDER BY ga.grade_name
                ) AS grades_array,
                (
                    SELECT json_agg(gpd.imei ORDER BY gpd.imei)
                    FROM graded_phone_data gpd
                    WHERE gpd.model = ga.model
                      AND gpd.mark = ga.mark
                      AND gpd.order_type = ga.order_type
                      AND gpd.boxes = ga.boxes
                      AND gpd.order_color = ga.order_color
                      AND gpd.company_name = ga.company_name
                      AND gpd.tag IS NOT DISTINCT FROM ga.tag
                ) AS imeis
            FROM
                grade_level_aggregations ga
            GROUP BY
                ga.model,
                ga.mark,
                ga.order_type,
                ga.boxes,
                ga.order_color,
                ga.company_name,
                ga.tag
        )
        SELECT json_agg(
            json_build_object(
                'mark', mark_data.mark,
                'order_type', mark_data.order_type,
                'models', mark_data.models
            )
        ) AS marks_count
        FROM (
            SELECT
                mark,
                order_type,
                json_agg(
                    json_build_object(
                        'model', model,
                        'boxes', boxes,
                        'order_color', order_color,
                        'company_name', company_name,
                        'tag', tag,
                        'count', total_count_for_model,
                        'grades', grades_array,
                        'imeis', imeis
                    ) ORDER BY model
                ) AS models
            FROM
                model_level_aggregations
            GROUP BY
                mark,
                order_type
        ) AS mark_data
    );
END;
$$;


--
-- Name: get_monthly_department_jobs(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_monthly_department_jobs() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    result jsonb;
BEGIN
    WITH job_map AS (
        SELECT ej.id AS job_id, ej.done_id, ej.name AS department
        FROM public.enum_order_jobs ej
        WHERE ej.done_id IS NOT NULL
    ),
    joined AS (
        SELECT
            jm.department,
            date_trunc('month', pjd.created_at)::date AS month_bucket,
            pjd.id AS phone_job_done_id
        FROM public.orders o
        JOIN public.orders_jobs oj
          ON oj.order_id = o.id
        JOIN job_map jm
          ON jm.job_id = oj.job_id
        JOIN public.phones p
          ON p.order_id = o.id
        JOIN public.phone_jobs_done pjd
          ON pjd.phone_id = p.id
         AND pjd.done_id = jm.done_id
        WHERE pjd.is_done = true
          AND pjd.created_at IS NOT NULL
    ),
    counts AS (
        SELECT
            department,
            to_char(month_bucket, 'Mon') AS date,
            COUNT(DISTINCT phone_job_done_id) AS jobs_done_count
        FROM joined
        GROUP BY department, month_bucket
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'department', c.department,
            'data', (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'date', c2.date,
                        'jobs_done_count', c2.jobs_done_count
                    )
                    ORDER BY c2.date
                )
                FROM counts c2
                WHERE c2.department = c.department
            )
        )
    )
    INTO result
    FROM (SELECT DISTINCT department FROM counts) c;

    RETURN result;
END;
$$;


--
-- Name: get_monthly_marked_phones(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_monthly_marked_phones() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    result jsonb;
BEGIN
    WITH filtered AS (
        SELECT DISTINCT phone_id, date_trunc('month', updated_at)::date AS month_bucket
        FROM public.phone_update_log
        WHERE old_mark IS NULL
          AND new_mark IS NOT NULL
          AND updated_at IS NOT NULL
    ),
    counts AS (
        SELECT
            to_char(month_bucket, 'Mon') AS date,
            COUNT(DISTINCT phone_id)     AS marked_phones
        FROM filtered
        GROUP BY month_bucket
        ORDER BY month_bucket
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'date', c.date,
            'marked_phones', c.marked_phones
        )
    )
    INTO result
    FROM counts c;

    RETURN result;
END;
$$;


--
-- Name: get_monthly_sentout_phones(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_monthly_sentout_phones() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    result jsonb;
BEGIN
    WITH filtered AS (
        SELECT DISTINCT phone_id, date_trunc('month', updated_at)::date AS month_bucket
        FROM public.phone_update_log
        WHERE (old_sent_out IS NULL OR old_sent_out = false)
          AND new_sent_out = true
          AND updated_at IS NOT NULL
    ),
    counts AS (
        SELECT
            to_char(month_bucket, 'Mon') AS date,
            COUNT(DISTINCT phone_id)     AS sentout_phones
        FROM filtered
        GROUP BY month_bucket
        ORDER BY month_bucket
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'date', c.date,
            'sentout_phones', c.sentout_phones
        )
    )
    INTO result
    FROM counts c;

    RETURN result;
END;
$$;


--
-- Name: get_my_sessions(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_sessions() RETURNS TABLE(id uuid, user_id uuid, created_at timestamp with time zone, refreshed_at timestamp with time zone, user_agent text, ip inet, aal text, factor_id uuid, not_after timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select
    s.id,
    s.user_id,
    s.created_at,
    s.refreshed_at,
    s.user_agent,
    s.ip,
    s.aal,
    s.factor_id,
    s.not_after
  from auth.sessions s
  where s.user_id = auth.uid()
    and (s.not_after is null or s.not_after > now())
    and s.id::text <> (auth.jwt() ->> 'session_id')
  order by s.created_at desc;
$$;


--
-- Name: get_or_create_dm_channel(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_or_create_dm_channel(p_target_uuid uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_self_id bigint;
    v_target_id bigint;
    v_channel_id uuid;
BEGIN
    -- Look up technician IDs for self and target
    SELECT id INTO v_self_id
    FROM public.technicians
    WHERE uuid = auth.uid();

    IF v_self_id IS NULL THEN
        RAISE EXCEPTION 'Current user not found in technicians table';
    END IF;

    SELECT id INTO v_target_id
    FROM public.technicians
    WHERE uuid = p_target_uuid;

    IF v_target_id IS NULL THEN
        RAISE EXCEPTION 'Target user not found in technicians table';
    END IF;

    -- Try to find an existing DM channel with exactly these two members
    SELECT c.id
    INTO v_channel_id
    FROM public.channels c
    WHERE c.id IN (
        SELECT cm.channel_id
        FROM public.channel_members cm
        WHERE cm.technician_id = v_self_id
        INTERSECT
        SELECT cm.channel_id
        FROM public.channel_members cm
        WHERE cm.technician_id = v_target_id
    )
    AND (
        SELECT COUNT(*) 
        FROM public.channel_members m 
        WHERE m.channel_id = c.id
    ) = 2
    LIMIT 1;

    -- If no channel found, create one and add both members
    IF v_channel_id IS NULL THEN
        INSERT INTO public.channels (name)
        VALUES (format('DM: %s-%s', v_self_id, v_target_id))
        RETURNING id INTO v_channel_id;

        INSERT INTO public.channel_members (channel_id, technician_id)
        VALUES (v_channel_id, v_self_id),
               (v_channel_id, v_target_id);
    ELSE
        -- Ensure both users are members (in case one was missing)
        INSERT INTO public.channel_members (channel_id, technician_id)
        SELECT v_channel_id, v_self_id
        WHERE NOT EXISTS (
            SELECT 1 FROM public.channel_members
            WHERE channel_id = v_channel_id AND technician_id = v_self_id
        );

        INSERT INTO public.channel_members (channel_id, technician_id)
        SELECT v_channel_id, v_target_id
        WHERE NOT EXISTS (
            SELECT 1 FROM public.channel_members
            WHERE channel_id = v_channel_id AND technician_id = v_target_id
        );
    END IF;

    RETURN v_channel_id;
END;
$$;


--
-- Name: get_order_details_with_phone_count_nested2(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_order_details_with_phone_count_nested2() RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
SELECT jsonb_build_object(
    'orders', (
        SELECT jsonb_agg(order_row)
        FROM (
            SELECT
                o.id AS order_id,
                o.id,
                o.order_color,
                ec.name AS company_name,
                o.company_id,
                o.tag,
                o.parent_id,
                
                -- List of all jobs
                COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object('name', eoj.name, 'id', eoj.id)
                        )
                        FROM public.orders_jobs oj
                        JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                        WHERE oj.order_id = o.id
                    ),
                    '[]'::jsonb
                ) AS order_type,

                -- ✅ NEW: Current Job Object
                CASE WHEN o.current_job IS NOT NULL THEN
                    jsonb_build_object(
                        'id', o.current_job,
                        'name', cj.name
                    )
                ELSE
                    NULL
                END AS current_job,
                
                es.name AS status,
                o.status_id,
                o.recieved_date,
                o.completion_date,
                o.locked,
                o.boxes,
                -- Correlated subquery for active phone count
                (SELECT COUNT(*) FROM public.phones p WHERE p.order_id = o.id AND p.is_active = true) AS total_phones
            FROM public.orders o
            LEFT JOIN public.enum_companies ec ON o.company_id = ec.id
            LEFT JOIN public.enum_status es ON o.status_id = es.id
            LEFT JOIN public.enum_order_jobs cj ON o.current_job = cj.id -- Join to get current job name
            ORDER BY o.id DESC
        ) AS order_row
    ),
    'phones', (
        SELECT jsonb_agg(phone_row ORDER BY phone_row.id ASC)
        FROM (
            SELECT
                p.id,
                p.imei,
                p.date_scanned,
                p.order_id,
                em.name AS model
            FROM public.phones p
            LEFT JOIN public.enum_models em ON p.model_id = em.id
            WHERE p.is_active = true
        ) AS phone_row
    )
);
$$;


--
-- Name: get_order_flow_graph_data(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_order_flow_graph_data(order_id_param bigint) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    result JSONB;
BEGIN
    WITH
    child_orders AS (
        SELECT 
            o.id,
            -- ✅ Dynamic Order Type Generation
            COALESCE(
                (
                    SELECT string_agg(eoj.name, ' & ')
                    FROM public.orders_jobs oj
                    JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                    WHERE oj.order_id = o.id
                ),
                'Unknown Job'
            ) AS order_type,
            o.order_color
        FROM public.orders o
        -- 🔁 CHANGED: tag-based → parent-based
        WHERE o.parent_id = order_id_param
    ),
    all_relevant_phone_ids AS (
        SELECT p.id
        FROM public.phones p
        WHERE p.order_id = order_id_param
        UNION
        SELECT p.id
        FROM public.phones p
        WHERE p.order_id IN (SELECT id FROM child_orders)
    ),
    phones_in_child_orders AS (
        SELECT DISTINCT p.id AS phone_id, p.order_id AS initial_order_id
        FROM public.phones p
        WHERE p.order_id IN (SELECT id FROM child_orders)
    ),
    phone_grade_history AS (
        SELECT
            pico.initial_order_id,
            pg.phone_id,
            pg.id AS grade_id,
            eg.name AS grade_name,
            MIN(pg.id) OVER (PARTITION BY pg.phone_id) AS min_grade_id,
            MAX(pg.id) OVER (PARTITION BY pg.phone_id) AS max_grade_id
        FROM public.phone_grades pg
        JOIN public.enum_grade eg ON pg.grade_id = eg.id
        JOIN phones_in_child_orders pico ON pg.phone_id = pico.phone_id
    ),
    child_input_grades AS (
        SELECT
            initial_order_id AS order_id,
            COALESCE(jsonb_object_agg(grade_name, count), '{}'::jsonb) AS input_grades
        FROM (
            SELECT initial_order_id, grade_name, COUNT(*) AS count
            FROM phone_grade_history
            WHERE grade_id = min_grade_id
            GROUP BY initial_order_id, grade_name
        ) sq
        GROUP BY initial_order_id
    ),
    child_output_grades AS (
        SELECT
            initial_order_id AS order_id,
            COALESCE(jsonb_object_agg('new ' || grade_name, count), '{}'::jsonb) AS output_grades
        FROM (
            SELECT initial_order_id, grade_name, COUNT(*) AS count
            FROM phone_grade_history
            WHERE grade_id = max_grade_id AND min_grade_id <> max_grade_id
            GROUP BY initial_order_id, grade_name
        ) sq
        GROUP BY initial_order_id
    ),
    child_orders_data AS (
        SELECT
            COALESCE(jsonb_agg(
                jsonb_build_object(
                    'id', co.id,
                    'orderType', co.order_type,
                    'orderColor', co.order_color,
                    'inputGrades', COALESCE(cig.input_grades, '{}'::jsonb),
                    'outputGrades', COALESCE(cog.output_grades, '{}'::jsonb)
                )
            ), '[]'::jsonb) AS data
        FROM child_orders co
        LEFT JOIN child_input_grades cig ON co.id = cig.order_id
        LEFT JOIN child_output_grades cog ON co.id = cog.order_id
    ),
    level0_data AS (
        SELECT jsonb_build_object('Starting', COALESCE(jsonb_object_agg(grade_name, count), '{}'::jsonb)) AS data
        FROM (
            SELECT eg.name AS grade_name, COUNT(*) AS count
            FROM public.phones p
            JOIN public.phone_grades pg ON p.id = pg.phone_id
            JOIN public.enum_grade eg ON pg.grade_id = eg.id
            WHERE p.order_id = order_id_param
            GROUP BY eg.name
        ) sq
    )
    SELECT jsonb_build_object(
        'level0', COALESCE((SELECT data FROM level0_data), '{"Starting": {}}'::jsonb),
        'childOrders', (SELECT data FROM child_orders_data),
        'totalPhoneCount', (SELECT COUNT(*) FROM all_relevant_phone_ids)
    )
    INTO result;

    RETURN result;
END;
$$;


--
-- Name: get_order_grade_counts(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_order_grade_counts(order_id_parameter integer) RETURNS TABLE(base_name text, count_work integer, no_work_count integer, increased_grade integer, total integer)
    LANGUAGE sql
    SET search_path TO ''
    AS $$
WITH grade_stats AS (
    SELECT
        pg.phone_id,
        MAX(pg.id) AS latest_grade_id,
        COUNT(*) AS grade_count
    FROM public.phone_grades pg
    GROUP BY pg.phone_id
),
latest_grade AS (
    SELECT
        gs.phone_id,
        gs.grade_count,
        TRIM(REPLACE(eg.name, ' Work', '')) AS base_name,
        (eg.name ILIKE '% Work') AS is_work
    FROM grade_stats gs
    JOIN public.phone_grades pg
        ON pg.id = gs.latest_grade_id
    JOIN public.enum_grade eg
        ON pg.grade_id = eg.id
),
classified AS (
    SELECT
        lg.phone_id,
        lg.base_name,
        CASE
            WHEN lg.grade_count > 1 THEN 'increased'
            WHEN lg.is_work THEN 'work'
            ELSE 'no_work'
        END AS category
    FROM latest_grade lg
    JOIN public.phones p
        ON p.id = lg.phone_id
    JOIN public.orders o
        ON o.id = p.order_id
    WHERE o.id = order_id_parameter
       OR o.tag = '#' || order_id_parameter::TEXT
),
counts AS (
    SELECT
        base_name,
        COUNT(CASE WHEN category = 'work' THEN phone_id END) AS count_work,
        COUNT(CASE WHEN category = 'no_work' THEN phone_id END) AS no_work_count,
        COUNT(CASE WHEN category = 'increased' THEN phone_id END) AS increased_grade,
        COUNT(phone_id) AS total
    FROM classified
    GROUP BY base_name
)
SELECT *
FROM (
    SELECT *
    FROM counts
    UNION ALL
    SELECT
        'Total' AS base_name,
        SUM(count_work),
        SUM(no_work_count),
        SUM(increased_grade),
        SUM(total)
    FROM counts
) AS combined_results
ORDER BY CASE WHEN base_name = 'Total' THEN 1 ELSE 0 END, base_name;
$$;


--
-- Name: get_order_summary_with_phone_counts2(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_order_summary_with_phone_counts2() RETURNS TABLE(order_id bigint, status text, company_name text, order_type text, boxes smallint, total_phones bigint, pending_count bigint, not_pending_count bigint, null_pending_count bigint, mark_number bigint, mark_non_number bigint, tag text, job_stats jsonb, job_ids bigint[], job_details jsonb)
    LANGUAGE sql
    SET search_path TO ''
    AS $_$
SELECT  
    o.id AS order_id,  
    es.name AS status,
    ec.name AS company_name,
    
    -- Dynamic Order Type String
    COALESCE(
        (
            SELECT string_agg(eoj.name, ' & ')
            FROM public.orders_jobs oj
            JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
            WHERE oj.order_id = o.id
        )
    ) AS order_type,
    
    o.boxes,
    COUNT(p.id) AS total_phones,
    
    -- Pending Stats
    COUNT(CASE WHEN p.pending IS TRUE THEN 1 END) AS pending_count,
    COUNT(CASE WHEN p.pending IS FALSE THEN 1 END) AS not_pending_count,
    COUNT(CASE WHEN p.pending IS NULL THEN 1 END) AS null_pending_count,
    
    -- Mark Stats
    COUNT(CASE WHEN p.mark ~ '^[0-9]+$' THEN 1 END) AS mark_number,
    COUNT(CASE WHEN p.mark !~ '^[0-9]+$' OR p.mark IS NULL THEN 1 END) AS mark_non_number,
    
    o.tag,

    -- Dynamic Job Stats (True/False/Null counts per job type)
    COALESCE(
        (
            SELECT jsonb_object_agg(
                stats.name,
                jsonb_build_object(
                    'true', stats.true_count,
                    'false', stats.false_count,
                    'null', (
                        (SELECT COUNT(*) FROM public.phones WHERE order_id = o.id AND is_active = true) 
                        - stats.total_records
                    )
                )
            )
            FROM (
                SELECT 
                    epd.name,
                    COUNT(CASE WHEN pjd.is_done IS TRUE THEN 1 END) as true_count,
                    COUNT(CASE WHEN pjd.is_done IS FALSE THEN 1 END) as false_count,
                    COUNT(pjd.id) as total_records
                FROM public.phones p2
                JOIN public.phone_jobs_done pjd ON p2.id = pjd.phone_id
                JOIN public.enum_phone_done epd ON pjd.done_id = epd.id
                WHERE p2.order_id = o.id 
                  AND p2.is_active = true
                GROUP BY epd.name
            ) stats
        ),
        '{}'::jsonb
    ) AS job_stats,

    -- Simple Array of Job IDs
    COALESCE(
        (
            SELECT array_agg(oj.job_id ORDER BY oj.job_id)
            FROM public.orders_jobs oj
            WHERE oj.order_id = o.id
        ),
        '{}'::bigint[]
    ) AS job_ids,

    -- ✅ New: Job Details (Array of Objects with ID and Name)
    COALESCE(
        (
            SELECT jsonb_agg(
                jsonb_build_object(
                    'id', eoj.id,
                    'name', eoj.name
                ) ORDER BY eoj.id
            )
            FROM public.orders_jobs oj
            JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
            WHERE oj.order_id = o.id
        ),
        '[]'::jsonb
    ) AS job_details

FROM public.orders o
LEFT JOIN public.phones p ON o.id = p.order_id AND p.is_active = true
LEFT JOIN public.enum_companies ec ON o.company_id = ec.id
LEFT JOIN public.enum_status es ON o.status_id = es.id
WHERE 
    o.status_id NOT IN (4)
GROUP BY  
    o.id, ec.name, es.name, o.boxes, o.tag
ORDER BY  
    o.id ASC;
$_$;


--
-- Name: get_orders_with_tagged2(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_orders_with_tagged2(target_job_id bigint DEFAULT 16) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO ''
    AS $$
  SELECT COALESCE(
    jsonb_agg(
      (
        to_jsonb(p)
        || jsonb_build_object(
             'status', es.name,
             'company', ec.name,

             -- 1. Dynamic Order Type String (for UI display)
             'order_type', (
                 SELECT string_agg(eoj.name, ' & ')
                 FROM public.orders_jobs oj
                 JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                 WHERE oj.order_id = p.id
             ),

             'phones_amount', (
               SELECT count(*)
               FROM public.phones ph
               WHERE ph.order_id = p.id AND ph.is_active = true
             ),

             -- 2. Children (using parent_id instead of tag)
             'children', COALESCE(
               (
                 SELECT jsonb_agg(
                   to_jsonb(c)
                   || jsonb_build_object(
                        'status', ces.name,
                        'company', cec.name,

                        -- Child order type
                        'order_type', (
                            SELECT string_agg(ceoj.name, ' & ')
                            FROM public.orders_jobs coj
                            JOIN public.enum_order_jobs ceoj ON coj.job_id = ceoj.id
                            WHERE coj.order_id = c.id
                        ),

                        'phones_amount', (
                          SELECT count(*)
                          FROM public.phones phc
                          WHERE phc.order_id = c.id AND phc.is_active = true
                        )
                      )
                 )
                 FROM public.orders c
                 LEFT JOIN public.enum_status ces ON ces.id = c.status_id
                 LEFT JOIN public.enum_companies cec ON cec.id = c.company_id
                 WHERE c.parent_id = p.id
               ),
               '[]'::jsonb
             )
           )
      )
    ),
    '[]'::jsonb
  )
  FROM public.orders p
  LEFT JOIN public.enum_status es ON es.id = p.status_id
  LEFT JOIN public.enum_companies ec ON ec.id = p.company_id

  -- Filter by job (Project = 16)
  WHERE EXISTS (
    SELECT 1
    FROM public.orders_jobs oj
    WHERE oj.order_id = p.id
      AND oj.job_id = target_job_id
  );
$$;


--
-- Name: get_original_box_count(bigint, smallint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_original_box_count(order_id_parameter bigint, boxnumbers smallint[]) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    RETURN (
        WITH phone_data AS (
            SELECT
                p.id AS phone_id,
                em.name AS model,
                p.original_box,
                p.imei,
                (
                    SELECT string_agg(eoj.name, ' & ')
                    FROM public.orders_jobs oj
                    JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                    WHERE oj.order_id = o.id
                ) AS order_type,
                o.boxes,
                o.order_color,
                ec.name AS company_name,
                o.tag,
                (
                  SELECT pg.grade_id
                  FROM public.phone_grades pg
                  WHERE pg.phone_id = p.id
                  ORDER BY pg.id DESC
                  LIMIT 1
                ) AS latest_grade_id
            FROM public.phones p
            JOIN public.orders o ON p.order_id = o.id
            JOIN public.enum_companies ec ON o.company_id = ec.id
            JOIN public.enum_models em ON p.model_id = em.id
            WHERE p.order_id = order_id_parameter
              AND p.original_box = ANY(boxnumbers)
        ),
        graded_phone_data AS (
            SELECT
                pd.*,
                COALESCE(eg.name, 'No Grade') AS grade_name
            FROM phone_data pd
            LEFT JOIN public.enum_grade eg ON pd.latest_grade_id = eg.id
        ),
        model_level_aggregations AS (
            SELECT
                gpd.model,
                gpd.original_box,
                gpd.order_type,
                gpd.boxes,
                gpd.order_color,
                gpd.company_name,
                gpd.tag,
                COUNT(*) AS total_count_for_model,
                json_agg(
                    json_build_object(
                        'grade_name', gpd.grade_name,
                        'count', 1
                    ) ORDER BY gpd.grade_name
                ) AS grades_array,
                json_agg(gpd.imei ORDER BY gpd.imei) AS imeis
            FROM graded_phone_data gpd
            GROUP BY
                gpd.model,
                gpd.original_box,
                gpd.order_type,
                gpd.boxes,
                gpd.order_color,
                gpd.company_name,
                gpd.tag
        )
        SELECT json_agg(
            json_build_object(
                'original_box', box_data.original_box,
                'order_type', box_data.order_type,
                'models', box_data.models
            )
        ) AS box_counts
        FROM (
            SELECT
                original_box,
                order_type,
                json_agg(
                    json_build_object(
                        'model', model,
                        'boxes', boxes,
                        'order_color', order_color,
                        'company_name', company_name,
                        'tag', tag,
                        'count', total_count_for_model,
                        'grades', grades_array,
                        'imeis', imeis
                    ) ORDER BY model
                ) AS models
            FROM model_level_aggregations
            GROUP BY original_box, order_type
        ) AS box_data
    );
END;
$$;


--
-- Name: get_original_box_count2(bigint, smallint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_original_box_count2(order_id_parameter bigint, boxnumbers smallint[]) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    RETURN (
        WITH phone_data AS (
            SELECT
                p.id AS phone_id,
                em.name AS model,
                p.paint_color,
                p.original_box,
                p.imei,
                (
                    SELECT string_agg(eoj.name, ' & ')
                    FROM public.orders_jobs oj
                    JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                    WHERE oj.order_id = o.id
                ) AS order_type,
                o.boxes,
                o.order_color,
                ec.name AS company_name,
                o.tag,
                (
                  SELECT pg.grade_id
                  FROM public.phone_grades pg
                  WHERE pg.phone_id = p.id
                  ORDER BY pg.id DESC
                  LIMIT 1
                ) AS latest_grade_id
            FROM public.phones p
            JOIN public.orders o ON p.order_id = o.id
            JOIN public.enum_companies ec ON o.company_id = ec.id
            JOIN public.enum_models em ON p.model_id = em.id
            WHERE p.order_id = order_id_parameter
              AND p.original_box = ANY(boxnumbers)
        ),
        graded_phone_data AS (
            SELECT
                pd.*,
                COALESCE(eg.name, 'No Grade') AS grade_name
            FROM phone_data pd
            LEFT JOIN public.enum_grade eg ON pd.latest_grade_id = eg.id
        ),
        model_level_aggregations AS (
            SELECT
                gpd.model,
                gpd.paint_color,
                gpd.original_box,
                gpd.order_type,
                gpd.boxes,
                gpd.order_color,
                gpd.company_name,
                gpd.tag,
                COUNT(*) AS total_count_for_model,
                json_agg(
                    json_build_object(
                        'grade_name', gpd.grade_name,
                        'count', 1
                    ) ORDER BY gpd.grade_name
                ) AS grades_array,
                json_agg(gpd.imei ORDER BY gpd.imei) AS imeis
            FROM graded_phone_data gpd
            GROUP BY
                gpd.model,
                gpd.paint_color,
                gpd.original_box,
                gpd.order_type,
                gpd.boxes,
                gpd.order_color,
                gpd.company_name,
                gpd.tag
        )
        SELECT json_agg(
            json_build_object(
                'original_box', box_data.original_box,
                'order_type', box_data.order_type,
                'models', box_data.models
            )
        ) AS box_counts
        FROM (
            SELECT
                original_box,
                order_type,
                json_agg(
                    json_build_object(
                        'model', model,
                        'paint_color', paint_color,
                        'boxes', boxes,
                        'order_color', order_color,
                        'company_name', company_name,
                        'tag', tag,
                        'count', total_count_for_model,
                        'grades', grades_array,
                        'imeis', imeis
                    ) ORDER BY model, paint_color
                ) AS models
            FROM model_level_aggregations
            GROUP BY original_box, order_type
        ) AS box_data
    );
END;
$$;


--
-- Name: get_parts_queue_with_details(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_parts_queue_with_details(input_date text) RETURNS TABLE(part_name text, part_serial bigint, parts_queue_id bigint, created_at timestamp with time zone, phone_id bigint, order_id bigint, company_name text)
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        pi.part_name,
        pq.part_serial,
        pq.id AS parts_queue_id,
        pq.created_at,
        pq.phone_id,
        p.order_id,
        ec.name AS company_name
    FROM public.parts_queue pq
    JOIN public.phones p ON pq.phone_id = p.id
    JOIN public.reports r ON r.reported_phone = p.id
    LEFT JOIN public.orders o ON p.order_id = o.id
    LEFT JOIN public.enum_companies ec ON o.company_id = ec.id
    LEFT JOIN public.parts_inventory pi ON pq.part_serial = pi.serial
    WHERE r.causer_id = 57
      AND pq.created_at::date = input_date::date;
END;
$$;


--
-- Name: get_phones_by_imei2(text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_phones_by_imei2(imei_array text[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    result jsonb;
BEGIN
    SELECT jsonb_agg(t) INTO result
    FROM (
        WITH latest_reports AS (
            SELECT 
                reported_phone, 
                MAX(id) AS max_report_id
            FROM public.reports
            GROUP BY reported_phone
        )
        SELECT 
            r.*, 
            p.imei,
            p.id AS phone_id,
            p.mark,
            em.name AS model,
            ec.name AS company_name,
            o.order_color,

            -- Dynamic Order Type
            (
                SELECT string_agg(eoj.name, ' & ')
                FROM public.orders_jobs oj
                JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                WHERE oj.order_id = o.id
            ) AS order_type,

            o.tag,
            o.id AS order_id,

            -- Extract parent order JSON
            (
  SELECT to_jsonb(po) || jsonb_build_object(
    'jobs',
    (
      SELECT jsonb_agg(eoj.name)
      FROM public.orders_jobs oj
      JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
      WHERE oj.order_id = po.id
    )
  )
  FROM public.orders po
  WHERE po.id = (
    CASE 
      WHEN o.tag ~ '#[0-9]+' 
      THEN (regexp_replace(o.tag, '.*#([0-9]+).*', '\1'))::bigint
      ELSE NULL
    END
  )
) AS parent_order

        FROM public.phones p
        LEFT JOIN public.enum_models em
            ON p.model_id = em.id
        LEFT JOIN latest_reports lr
            ON p.id = lr.reported_phone
        LEFT JOIN public.reports r
            ON lr.max_report_id = r.id
        LEFT JOIN public.orders o
            ON p.order_id = o.id
        LEFT JOIN public.enum_companies ec
            ON o.company_id = ec.id
        WHERE 
            p.imei = ANY(imei_array)
            AND p.is_active = true
        ORDER BY 
            array_position(imei_array, p.imei)
    ) t;

    RETURN result;
END;
$$;


--
-- Name: get_reports_data(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_reports_data() RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    phones_data jsonb;
    orders_data jsonb;
    reports_data jsonb;
    orders_labels_data jsonb;
    technician_totals jsonb;
    parts_data jsonb;
BEGIN
    -- Phones data
    SELECT jsonb_agg(t) INTO phones_data
    FROM (
        SELECT 
            to_char(date_scanned::date, 'MM/DD/YYYY') AS date,
            COUNT(*) AS "Phones"
        FROM public.phones
        WHERE date_scanned >= CURRENT_DATE - INTERVAL '30 days'
        GROUP BY date_scanned::date
        ORDER BY date_scanned::date
    ) t;

    -- Orders data
    WITH date_series AS (
        SELECT generate_series(CURRENT_DATE - INTERVAL '30 days', CURRENT_DATE, '1 day')::date AS date
    ),
    added AS (
        SELECT o.recieved_date::date AS date, COUNT(*) AS added
        FROM public.orders o
        WHERE o.status_id = 8
          AND o.recieved_date >= CURRENT_DATE - INTERVAL '30 days'
        GROUP BY o.recieved_date::date
    ),
    completed AS (
        SELECT o.completion_date::date AS date, COUNT(*) AS completed
        FROM public.orders o
        WHERE o.status_id = 4
          AND o.completion_date >= CURRENT_DATE - INTERVAL '30 days'
        GROUP BY o.completion_date::date
    )
    SELECT jsonb_agg(t) INTO orders_data
    FROM (
        SELECT 
            to_char(ds.date, 'MM/DD/YYYY') AS date,
            COALESCE(a.added,0) AS "Orders Added",
            COALESCE(c.completed,0) AS "Orders Completed"
        FROM date_series ds
        LEFT JOIN added a ON a.date = ds.date
        LEFT JOIN completed c ON c.date = ds.date
        ORDER BY ds.date
    ) t;

    -- Reports data
    SELECT jsonb_agg(t) INTO reports_data
    FROM (
        SELECT 
            to_char(r.created_at::date, 'MM/DD/YYYY') AS date,
            ed.name AS issue,
            COUNT(*) AS "Reports Made"
        FROM public.reports r
        LEFT JOIN public.enum_damages ed ON r.issue_id = ed.id
        WHERE r.created_at >= CURRENT_DATE - INTERVAL '30 days'
        GROUP BY r.created_at::date, ed.name
        ORDER BY r.created_at::date, ed.name
    ) t;

    -- Orders labels data
    SELECT jsonb_agg(t) INTO orders_labels_data
    FROM (
        SELECT 
            ec.name AS Labels,
            COUNT(*) FILTER (WHERE status_id = 8) AS "Data"
        FROM public.orders
        LEFT JOIN public.enum_companies ec ON company_id = ec.id
        GROUP BY ec.name
        HAVING COUNT(*) FILTER (WHERE status_id = 8) > 0
        ORDER BY ec.name
    ) t;

    -- Technician totals
    WITH dr_agg AS (
        SELECT technician_id, created_at::date AS date, SUM(amount) AS total_amount
        FROM (
            SELECT DISTINCT technician_id, created_at::date, amount
            FROM public.daily_report_new
            WHERE created_at >= CURRENT_DATE - INTERVAL '30 days'
        ) dr
        GROUP BY technician_id, created_at::date
    ),
    rj_agg AS (
        SELECT rj.technician AS technician_id, rj.completed_date::date AS date, COUNT(r.id) AS total_amount
        FROM public.repair_jobs rj
        JOIN public.repairs r ON r.repair_job_id = rj.id
        WHERE rj.completed_date >= CURRENT_DATE - INTERVAL '30 days'
        GROUP BY rj.technician, rj.completed_date::date
    ),
    final_totals AS (
        SELECT technician_id, date, SUM(total_amount) AS total_amount
        FROM (
            SELECT * FROM dr_agg
            UNION ALL
            SELECT * FROM rj_agg
        ) combined
        GROUP BY technician_id, date
    )
    SELECT jsonb_agg(t) INTO technician_totals
    FROM (
        SELECT 
            to_char(ft.date, 'MM/DD/YYYY') AS date,
            ft.technician_id,
            t.name AS technician_name,
            er.name AS role,
            ft.total_amount
        FROM final_totals ft
        JOIN public.technicians t ON t.id = ft.technician_id
        JOIN public.enum_roles er ON er.id = t.role_id
        ORDER BY ft.date, technician_name
    ) t;

    -- Parts data (new block)
    -- Parts data (restricted to reports with causer_id = 57)
SELECT jsonb_agg(t) INTO parts_data
FROM (
    SELECT 
        to_char(pq.created_at::date, 'MM/DD/YYYY') AS date,
        pi.part_name,
        COUNT(*) AS amount
    FROM public.parts_queue pq
    JOIN public.parts_inventory pi ON pq.part_serial = pi.serial
    JOIN public.reports r ON r.reported_phone = pq.phone_id
    WHERE pq.created_at >= CURRENT_DATE - INTERVAL '30 days'
      AND r.causer_id = 57
    GROUP BY pq.created_at::date, pi.part_name
    ORDER BY pq.created_at::date, pi.part_name
) t;

    -- Final JSON response
    RETURN jsonb_build_object(
        'phones_data', phones_data,
        'orders_data', orders_data,
        'reports_data', reports_data,
        'orders_labels_data', orders_labels_data,
        'technician_totals', technician_totals,
        'parts_data', parts_data
    );
END;
$$;


--
-- Name: get_reports_with_phone_order_details2(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_reports_with_phone_order_details2(input_date text) RETURNS TABLE(issue text, id bigint, created_at timestamp with time zone, reported_phone bigint, order_id bigint, phone_model text, order_type text, company_name text)
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ed.name AS issue,
        r.id,
        r.created_at,
        r.reported_phone,
        p.order_id,
        em.name AS phone_model,
        
        -- Dynamic order_type generation
        (
            SELECT string_agg(eoj.name, ' & ')
            FROM public.orders_jobs oj
            JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
            WHERE oj.order_id = o.id
        ) AS order_type,
        
        ec.name as company_name
    FROM public.reports r
    LEFT JOIN public.phones p ON r.reported_phone = p.id
    LEFT JOIN public.orders o ON p.order_id = o.id
    LEFT JOIN public.enum_damages ed ON r.issue_id = ed.id
    LEFT JOIN public.enum_companies ec ON o.company_id = ec.id
    LEFT JOIN public.enum_models em ON p.model_id = em.id
    WHERE r.created_at::date = input_date::date;
END;
$$;


--
-- Name: get_technician_dashboard_json(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_technician_dashboard_json(p_start_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_date timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    cnt int;
    result jsonb;
BEGIN
    -- Step 1: ensure there are jobs in range
    SELECT COUNT(*) INTO cnt
    FROM public.repair_jobs rj
    WHERE (p_start_date IS NULL OR rj.created_at >= p_start_date)
      AND (p_end_date   IS NULL OR rj.created_at <= p_end_date)
      AND rj.status_id = 4;
    IF cnt = 0 THEN
        RAISE EXCEPTION 'No repair_jobs matched date/status filter';
    END IF;

    -- Step 2: build JSON
    WITH date_filtered_repair_jobs AS (
        SELECT rj.*
        FROM public.repair_jobs rj
        WHERE (p_start_date IS NULL OR rj.created_at >= p_start_date)
          AND (p_end_date   IS NULL OR rj.created_at <= p_end_date)
          AND rj.status_id = 4
    ),
    all_days AS (
        SELECT generate_series(
            (COALESCE(p_start_date, (SELECT MIN(created_at) FROM public.repair_jobs))),
            (COALESCE(p_end_date,   (SELECT MAX(created_at) FROM public.repair_jobs))),
            interval '1 day'
        )::date AS work_date
    ),
    days_worked AS (
        SELECT
            t.id AS technician_id,
            (rj.created_at)::date AS work_date
        FROM date_filtered_repair_jobs rj
        JOIN public.technicians t ON t.id = rj.technician
        GROUP BY t.id, (rj.created_at)::date
    ),
    days_no_work AS (
        SELECT
            t.id AS technician_id,
            COALESCE(COUNT(d.work_date), 0) AS total_days_no_work
        FROM public.technicians t
        CROSS JOIN all_days d
        LEFT JOIN days_worked w
          ON w.technician_id = t.id
         AND w.work_date = d.work_date
        WHERE w.work_date IS NULL
        GROUP BY t.id
    ),
    job_durations_unique AS (
        SELECT
            rj.id AS repair_job_id,
            t.id AS technician_id,
            t.name AS technician_name,
            t.picture_url,
            t.role_id,
            r.name AS role_name,
            DATE(rj.created_at) AS work_date,
            EXTRACT(EPOCH FROM (rj.completed_date - rj.created_at)) / 3600 AS job_hours
        FROM date_filtered_repair_jobs rj
        JOIN public.technicians t ON t.id = rj.technician
        JOIN public.enum_roles r ON r.id = t.role_id
    ),
    job_assignments AS (
        SELECT
            ja.repair_jobs_id AS repair_job_id,
            ej.id AS job_id,
            ej.name AS job_name
        FROM public.jobs_assigned ja
        JOIN public.enum_jobs ej ON ej.id = ja.job_id
    ),
    job_phone_counts AS (
        SELECT
            rj.id AS repair_job_id,
            COUNT(r.id) AS phones_repaired
        FROM date_filtered_repair_jobs rj
        JOIN public.repairs r ON r.repair_job_id = rj.id
        GROUP BY rj.id
    ),
    parts_prices_per_tech AS (
        SELECT
            r.causer_id AS technician_id,
            COALESCE(SUM(pi.price),0) AS total_parts_price
        FROM public.reports r
        JOIN public.parts_queue pq
          ON pq.phone_id = r.reported_phone
         AND pq.status_id = 10
        JOIN public.parts_inventory pi
          ON pi.serial = pq.part_serial
        WHERE (p_start_date IS NULL OR r.created_at >= p_start_date)
          AND (p_end_date   IS NULL OR r.created_at <= p_end_date)
        GROUP BY r.causer_id
    ),
    jobs_with_counts AS (
        SELECT
            jd.technician_id,
            jd.technician_name,
            jd.picture_url,
            jd.role_id,
            jd.role_name,
            ja.job_id,
            ja.job_name,
            jd.work_date,
            pc.phones_repaired,
            ROUND(AVG(jd.job_hours), 2) AS avg_hours_per_job,
            ROUND(SUM(jd.job_hours), 2) AS total_hours
        FROM job_durations_unique jd
        JOIN job_assignments ja ON ja.repair_job_id = jd.repair_job_id
        JOIN job_phone_counts pc ON pc.repair_job_id = jd.repair_job_id
        GROUP BY jd.technician_id, jd.technician_name, jd.picture_url,
                 jd.role_id, jd.role_name,
                 ja.job_id, ja.job_name, jd.work_date, pc.phones_repaired
    ),
    breakages_per_tech AS (
        SELECT
            causer_id AS technician_id,
            COUNT(*) AS total_breakages
        FROM public.reports
        WHERE (p_start_date IS NULL OR created_at >= p_start_date)
          AND (p_end_date   IS NULL OR created_at <= p_end_date)
        GROUP BY causer_id
    ),
    daily_json AS (
        SELECT
            technician_id,
            job_id,
            JSONB_AGG(
                JSONB_BUILD_OBJECT(
                    'date', work_date,
                    'phones_repaired', phones_repaired,
                    'avg_hours', avg_hours_per_job,
                    'total_hours', total_hours
                ) ORDER BY work_date
            ) AS daily
        FROM jobs_with_counts
        GROUP BY technician_id, job_id
    ),
    jobs_json AS (
        SELECT
            c.technician_id,
            c.technician_name,
            c.picture_url,
            c.role_id,
            c.role_name,
            c.job_id,
            c.job_name,
            SUM(c.phones_repaired) AS total_phones,
            ROUND(AVG(c.avg_hours_per_job), 2) AS avg_hours_per_job,
            SUM(c.total_hours) AS total_hours,
            d.daily
        FROM jobs_with_counts c
        JOIN daily_json d
          ON d.technician_id = c.technician_id
         AND d.job_id = c.job_id
        GROUP BY c.technician_id, c.technician_name, c.picture_url,
                 c.role_id, c.role_name,
                 c.job_id, c.job_name, d.daily
    ),
    technician_json AS (
        SELECT
            j.technician_id,
            j.technician_name,
            j.picture_url,
            j.role_id,
            j.role_name,
            (SELECT COALESCE(SUM(pc.phones_repaired),0)
             FROM job_phone_counts pc
             JOIN job_durations_unique u ON u.repair_job_id = pc.repair_job_id
             WHERE u.technician_id = j.technician_id) AS total_phones_repaired,
            (SELECT COALESCE(SUM(u.job_hours),0)
             FROM job_durations_unique u
             WHERE u.technician_id = j.technician_id) AS total_hours,
            COALESCE(pp.total_parts_price,0) AS total_parts_price,
            COALESCE(b.total_breakages, 0) AS total_breakages,
            CASE WHEN (SELECT SUM(pc.phones_repaired)
                       FROM job_phone_counts pc
                       JOIN job_durations_unique u ON u.repair_job_id = pc.repair_job_id
                       WHERE u.technician_id = j.technician_id) > 0
                 THEN ROUND(COALESCE(b.total_breakages,0)::numeric /
                            (SELECT SUM(pc.phones_repaired)
                             FROM job_phone_counts pc
                             JOIN job_durations_unique u ON u.repair_job_id = pc.repair_job_id
                             WHERE u.technician_id = j.technician_id), 4)
                 ELSE 0 END AS breakage_rate,
            dn.total_days_no_work,
            JSONB_AGG(
                JSONB_BUILD_OBJECT(
                    'job_id', job_id,
                    'job_name', job_name,
                    'total_phones', total_phones,
                    'avg_hours_per_job', avg_hours_per_job,
                    'total_hours', total_hours,
                    'daily', daily
                ) ORDER BY job_name
            ) AS jobs
        FROM jobs_json j
        LEFT JOIN days_no_work dn
          ON dn.technician_id = j.technician_id
        LEFT JOIN breakages_per_tech b
          ON b.technician_id = j.technician_id
        LEFT JOIN parts_prices_per_tech pp
          ON pp.technician_id = j.technician_id
        GROUP BY j.technician_id, j.technician_name, j.picture_url,
                 j.role_id, j.role_name,
                 dn.total_days_no_work, b.total_breakages, pp.total_parts_price
    )
    SELECT JSONB_AGG(
        JSONB_BUILD_OBJECT(
            'technician_id', technician_id,
            'technician_name', technician_name,
            'picture_url', picture_url,
            'role_id', role_id,
            'role_name', role_name,
            'total_phones_repaired', total_phones_repaired,
            'total_hours', total_hours,
            'total_parts_price', total_parts_price,
            'total_breakages', total_breakages,
            'breakage_rate', breakage_rate,
            'total_days_no_work', total_days_no_work,
            'jobs', jobs
        ) ORDER BY technician_name
    )
    INTO result
    FROM technician_json;

    IF result IS NULL THEN
        RAISE EXCEPTION 'get_technician_dashboard_json returned no data. Check joins.';
    END IF;

    RETURN result;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id bigint NOT NULL,
    channel_id uuid NOT NULL,
    message text NOT NULL,
    sender_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    type text,
    meta jsonb
);


--
-- Name: get_unread_notifications(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_unread_notifications() RETURNS SETOF public.notifications
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    -- We get the ID of the user calling this function from their authentication token.
    RETURN QUERY
    SELECT n.*
    FROM public.notifications n
    JOIN public.notification_reads nr ON n.id = nr.notification_id
    WHERE nr.user_id = auth.uid() AND nr.read_at IS NULL
    ORDER BY n.created_at DESC;
END;
$$;


--
-- Name: get_unread_notifications2(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_unread_notifications2() RETURNS SETOF public.notifications
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    effective_uid uuid;
BEGIN
    -- If called with the service role, use the fixed UUID
    IF current_user = 'supabase_admin' THEN
        effective_uid := '3c132ec9-d397-471a-a95f-3a4606d43447';
    ELSE
        effective_uid := auth.uid();
    END IF;

    RETURN QUERY
    SELECT n.*
    FROM public.notifications n
    JOIN public.notification_reads nr ON n.id = nr.notification_id
    WHERE nr.user_id = effective_uid
      AND nr.read_at IS NULL
    ORDER BY n.created_at DESC;
END;
$$;


--
-- Name: get_user_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_id() RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
  RETURN auth.uid();
END;
$$;


--
-- Name: handle_no_fix_done(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_no_fix_done() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
  -- If someone tries to insert/update with done_id = 3
  IF NEW.done_id = 3 THEN
    -- Set the flag on the same row
    NEW.no_fix := true;
    -- Nullify done_id so it won't conflict with the unique constraint
    NEW.done_id := NULL;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: handle_status_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_status_update() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
  IF NEW.status_id = 5 THEN
    -- Explicitly update the row
    UPDATE public.reports
    SET completed = CURRENT_TIMESTAMP
    WHERE id = NEW.id;

    -- Recalculate pending status
    PERFORM public.recalc_is_pending(NEW.reported_phone);

  ELSIF NEW.status_id IN (6, 9) THEN
    UPDATE public.reports
    SET repair_date = CURRENT_TIMESTAMP
    WHERE id = NEW.id;

  ELSIF NEW.status_id = 7 THEN
    UPDATE public.reports
    SET received_at = CURRENT_TIMESTAMP
    WHERE id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: handle_still_msg_done(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_still_msg_done() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
  -- If someone tries to insert/update with done_id = 5
  IF NEW.done_id = 5 THEN
    NEW.still_msg := true;
    NEW.done_id := NULL;  -- clear it so the row isn't stored as a "done_id = 5"
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: has_access(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_access(mode text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  u uuid := auth.uid();
  cid uuid;
BEGIN
  SELECT company_id INTO cid FROM public.technicians WHERE uuid = u LIMIT 1;

  IF mode = 'select' THEN
    RETURN cid IS NOT NULL;
  ELSIF mode = 'all' THEN
    RETURN cid IS NULL;
  ELSE
    RETURN false;
  END IF;
END;
$$;


--
-- Name: has_order_access(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_order_access(mode text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  u   uuid := auth.uid();  -- current user id
  cid bigint;              -- technician's company_id (if any)
  is_company boolean;
BEGIN
  -- Look up the technician's company_id (if they are a technician)
  SELECT t.company_id
  INTO cid
  FROM public.technicians t
  WHERE t.uuid = u
  LIMIT 1;

  -- Check if this user is also a company account
  SELECT true
  INTO is_company
  FROM public.enum_companies ec
  WHERE ec.uuid = u
  LIMIT 1;

  IF mode = 'select' THEN
    RETURN (
      cid IS NOT NULL
      AND is_company
      AND EXISTS (
        SELECT 1
        FROM public.enum_companies ec
        WHERE ec.uuid = u
          AND ec.id = cid
      )
    );

  ELSIF mode = 'all' THEN
    RETURN (cid IS NULL);

  ELSE
    RETURN false;
  END IF;
END;
$$;


--
-- Name: increment_stock_on_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.increment_stock_on_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    -- If the deleted row was "approved" (status_id = 10),
    -- restore the stock for that part
    IF OLD.status_id = 10 THEN
        UPDATE public.parts_inventory
        SET stock = stock + 1
        WHERE serial = OLD.part_serial;
    END IF;

    RETURN OLD;
END;
$$;


--
-- Name: insert_employee_repair(bigint[], bigint, numeric, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.insert_employee_repair(jobs_to_perform bigint[], technician_id_param bigint, base_price_param numeric, status_id_param bigint DEFAULT NULL::bigint, imei_override_param text DEFAULT NULL::text) RETURNS TABLE(employee_repair_id bigint, bin_id bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    new_repair_job_id bigint;
    new_employee_repair_id bigint;
    technician_phone_id bigint;
    job_id_var bigint;
BEGIN
    -- If imei_override_param is provided, use that instead of technician.current_phone
    IF imei_override_param IS NOT NULL THEN
        SELECT id INTO technician_phone_id
        FROM public.phones
        WHERE imei = imei_override_param AND is_active = true
        LIMIT 1;

        IF technician_phone_id IS NULL THEN
            RAISE EXCEPTION 'Phone with IMEI % not found or inactive', imei_override_param;
        END IF;
    ELSE
        -- Get technician's current phone
        SELECT current_phone INTO technician_phone_id
        FROM public.technicians
        WHERE id = technician_id_param AND is_active = true;

        IF technician_phone_id IS NULL THEN
            RAISE EXCEPTION 'Technician % has no current phone assigned', technician_id_param;
        END IF;
    END IF;

    -- Create repair_job with NULL technician
    IF status_id_param IS NULL THEN
        INSERT INTO public.repair_jobs (technician, order_id)
        VALUES (NULL, NULL)
        RETURNING id INTO new_repair_job_id;
    ELSE
        INSERT INTO public.repair_jobs (technician, order_id, status_id)
        VALUES (NULL, NULL, status_id_param)
        RETURNING id INTO new_repair_job_id;
    END IF;

    -- Link phone to the repair job
    INSERT INTO public.repairs (repair_job_id, phone_id)
    VALUES (new_repair_job_id, technician_phone_id);

    -- Assign jobs
    FOREACH job_id_var IN ARRAY jobs_to_perform LOOP
        INSERT INTO public.jobs_assigned (repair_jobs_id, job_id)
        VALUES (new_repair_job_id, job_id_var);
    END LOOP;

    -- Create employee_repair record
    INSERT INTO public.employee_repairs (technician_id, bin_id, base_price)
    VALUES (technician_id_param, new_repair_job_id, base_price_param)
    RETURNING id INTO new_employee_repair_id;

    -- Return both IDs
    employee_repair_id := new_employee_repair_id;
    bin_id := new_repair_job_id;
    RETURN NEXT;
END;
$$;


--
-- Name: insert_full_repair_job_with_id(bigint[], bigint, text[], bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.insert_full_repair_job_with_id(jobs_to_perform bigint[], technician_id bigint, imei_array text[], status_id_param bigint DEFAULT NULL::bigint) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  new_repair_job_id bigint;
  phone_record_id bigint;
  order_record_id bigint;
  job_id_var bigint;
  phone_imei text;
BEGIN
  -- Handle empty IMEI array
  IF array_length(imei_array, 1) IS NULL OR array_length(imei_array, 1) = 0 THEN
    IF status_id_param IS NULL THEN
      INSERT INTO public.repair_jobs (technician, order_id)
      VALUES (technician_id, NULL)
      RETURNING id INTO new_repair_job_id;
    ELSE
      INSERT INTO public.repair_jobs (technician, order_id, status_id)
      VALUES (technician_id, NULL, status_id_param)
      RETURNING id INTO new_repair_job_id;
    END IF;
  ELSE
    -- Explicitly get the order_id from the first phone
    SELECT order_id INTO order_record_id
    FROM public.phones
    WHERE imei = imei_array[1] AND is_active = true;

    -- Validate order_id exists
    IF order_record_id IS NULL THEN
      RAISE EXCEPTION 'No valid order_id found for the given IMEIs';
    END IF;

    -- Create repair_job with order_id
    IF status_id_param IS NULL THEN
      INSERT INTO public.repair_jobs (technician, order_id)
      VALUES (technician_id, order_record_id)
      RETURNING id INTO new_repair_job_id;
    ELSE
      INSERT INTO public.repair_jobs (technician, order_id, status_id)
      VALUES (technician_id, order_record_id, status_id_param)
      RETURNING id INTO new_repair_job_id;
    END IF;

    -- Link phones by IMEI
    FOREACH phone_imei IN ARRAY imei_array LOOP
      SELECT id INTO phone_record_id
      FROM public.phones
      WHERE imei = phone_imei AND is_active = true
      LIMIT 1;

      IF FOUND THEN
        INSERT INTO public.repairs (repair_job_id, phone_id)
        VALUES (new_repair_job_id, phone_record_id);
      END IF;
    END LOOP;
  END IF;

  -- Assign jobs (always runs, regardless of IMEI array)
  FOREACH job_id_var IN ARRAY jobs_to_perform LOOP
    INSERT INTO public.jobs_assigned (repair_jobs_id, job_id)
    VALUES (new_repair_job_id, job_id_var);
  END LOOP;

  RETURN new_repair_job_id;
END;
$$;


--
-- Name: insert_part_from_json(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.insert_part_from_json(payload jsonb) RETURNS bigint
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    new_part public.parts_inventory;   -- record shaped like your table
    inserted_serial bigint;
    models bigint[];
BEGIN
    -- Populate a record of type public.parts_inventory from JSON
    new_part := jsonb_populate_record(NULL::public.parts_inventory, payload);

    -- Insert into public.parts_inventory
    INSERT INTO public.parts_inventory (
        created_at,
        part_name,
        part_link,
        price,
        serial,
        stock,
        stock_warning,
        is_active
    )
    VALUES (
        COALESCE(new_part.created_at, now()),
        new_part.part_name,
        new_part.part_link,
        new_part.price,
        new_part.serial,
        new_part.stock,
        COALESCE(new_part.stock_warning, 5),
        COALESCE(new_part.is_active, true)
    )
    RETURNING serial INTO inserted_serial;

    -- Handle compatible_models if present
    IF payload ? 'compatible_models' THEN
        models := ARRAY(
            SELECT jsonb_array_elements_text(payload->'compatible_models')::bigint
        );

        INSERT INTO public.parts_inventory_models (part_serial, model_id)
        SELECT inserted_serial, unnest(models);
    END IF;

    RETURN inserted_serial;
END;
$$;


--
-- Name: insert_phones_with_optional_grades(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.insert_phones_with_optional_grades(phone_data jsonb) RETURNS text[]
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
  duplicates text[];
BEGIN
  -- Step 1: find duplicates before inserting
  SELECT pg_catalog.array_agg(p.imei)
  INTO duplicates
  FROM (
    SELECT (elem->>'imei') AS imei
    FROM pg_catalog.jsonb_array_elements(phone_data) elem
  ) incoming
  JOIN public.phones p
    ON p.imei = incoming.imei
   AND p.is_active = true;

  -- Step 2: if duplicates found, return them and exit
  IF duplicates IS NOT NULL THEN
    RETURN duplicates;
  END IF;

  -- Step 3: extract JSON into a CTE with grade, paint_color, and original_box included
  WITH data AS (
    SELECT
      (elem->>'order_id')::bigint AS order_id,
      elem->>'imei'               AS imei,
      elem->>'mark'               AS mark,
      (elem->>'model_id')::bigint AS model_id,
      elem->>'grade'              AS grade,
      elem->>'paint_color'        AS paint_color,
      (elem->>'original_box')::smallint AS original_box
    FROM pg_catalog.jsonb_array_elements(phone_data) elem
  ),
  ins AS (
    INSERT INTO public.phones (order_id, imei, mark, model_id, paint_color, original_box)
    SELECT order_id, imei, mark, model_id, paint_color, original_box
    FROM data
    RETURNING id, imei
  )
  INSERT INTO public.phone_grades (grade_id, phone_id)
  SELECT d.grade::bigint, i.id
  FROM data d
  JOIN ins i ON d.imei = i.imei
  WHERE d.grade IS NOT NULL AND d.grade <> 'null';

  -- Step 4: return empty array if everything succeeded
  RETURN ARRAY[]::text[];
END;
$$;


--
-- Name: is_global_technician(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_global_technician() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.technicians t
    WHERE t.uuid = (SELECT auth.uid())
      AND t.company_id IS NULL
  );
$$;


--
-- Name: is_recent_report(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_recent_report(ts timestamp with time zone) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
    SELECT ts > NOW() - INTERVAL '2 hours'
$$;


--
-- Name: link_phones_to_repair_job(bigint, text[], text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.link_phones_to_repair_job(repair_job_id_param bigint, phone_imei_param text[], notes_param text DEFAULT NULL::text) RETURNS TABLE(inserted_repair_ids bigint[])
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    phone_ids bigint[];
    found_imeis text[];
    missing_imeis text[];
BEGIN
    -- Find active phone IDs matching the provided IMEI numbers
    SELECT 
        array_agg(id),
        array_agg(imei)
    INTO 
        phone_ids, 
        found_imeis
    FROM public.phones
    WHERE imei = ANY(phone_imei_param)
      AND is_active = true;

    -- Check for missing IMEI numbers
    missing_imeis := array(
        SELECT unnest(phone_imei_param) 
        EXCEPT 
        SELECT unnest(found_imeis)
    );

    -- Raise an error if any IMEI is not found
    IF array_length(missing_imeis, 1) > 0 THEN
        RAISE EXCEPTION 'Phone(s) not found or not active for IMEI(s): %', 
            array_to_string(missing_imeis, ', ');
    END IF;

    -- Insert repairs for each found phone ID
    RETURN QUERY
    WITH inserted_repairs AS (
        INSERT INTO public.repairs (repair_job_id, phone_id, notes)   -- ✅ include notes
        SELECT repair_job_id_param, unnest(phone_ids), notes_param
        RETURNING id
    )
    SELECT array_agg(id)
    FROM inserted_repairs;
END;
$$;


--
-- Name: lock_old_orders(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lock_old_orders() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    -- Update all orders older than 2 days except the current one
    UPDATE public.orders
    SET locked = true
    WHERE locked = false 
      AND recieved_date < NOW() - INTERVAL '2 days'
      AND id <> NEW.id;  -- Exclude the current order being created/updated

    RETURN NEW;  -- Return the modified record
END;
$$;


--
-- Name: log_phone_jobs_done_changes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_phone_jobs_done_changes() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_new_done_id bigint;
    v_new_bool boolean;
BEGIN
    -- Handle INSERT
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO public.phone_jobs_done_logs (
            phone_id, 
            operation, 
            new_done_id, 
            new_boolean
        )
        VALUES (
            NEW.phone_id, 
            'INSERT', 
            NEW.done_id, 
            NEW.is_done
        );
        RETURN NEW;

    -- Handle UPDATE
    ELSIF (TG_OP = 'UPDATE') THEN
        -- Only insert log if something relevant actually changed (Phone, ID, or Bool)
        IF (NEW.done_id IS DISTINCT FROM OLD.done_id) OR 
           (NEW.phone_id IS DISTINCT FROM OLD.phone_id) OR
           (NEW.is_done IS DISTINCT FROM OLD.is_done) THEN
           
            -- Logic: Set NEW to value if changed, otherwise NULL.
            IF (NEW.done_id IS DISTINCT FROM OLD.done_id) THEN
                v_new_done_id := NEW.done_id;
            ELSE
                v_new_done_id := NULL;
            END IF;

            -- Logic: Set NEW to value if changed, otherwise NULL.
            IF (NEW.is_done IS DISTINCT FROM OLD.is_done) THEN
                v_new_bool := NEW.is_done;
            ELSE
                v_new_bool := NULL;
            END IF;

            INSERT INTO public.phone_jobs_done_logs (
                phone_id, 
                operation, 
                old_done_id,   -- Always store the old value
                new_done_id,   -- NULL if unchanged
                old_boolean,   -- Always store the old value
                new_boolean    -- NULL if unchanged
            )
            VALUES (
                NEW.phone_id, 
                'UPDATE', 
                OLD.done_id, 
                v_new_done_id,
                OLD.is_done,
                v_new_bool
            );
        END IF;
        RETURN NEW;

    -- Handle DELETE
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO public.phone_jobs_done_logs (
            phone_id, 
            operation, 
            old_done_id,
            old_boolean
        )
        VALUES (
            OLD.phone_id, 
            'DELETE', 
            OLD.done_id,
            OLD.is_done
        );
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$;


--
-- Name: log_phone_updates(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_phone_updates() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    -- Only insert if a relevant column has changed
    IF (OLD.sent_out     IS DISTINCT FROM NEW.sent_out)     OR
       (OLD.order_id     IS DISTINCT FROM NEW.order_id)     OR
       (OLD.imei         IS DISTINCT FROM NEW.imei)         OR
       (OLD.mark         IS DISTINCT FROM NEW.mark)         OR
       (OLD.pending      IS DISTINCT FROM NEW.pending)      OR
       (OLD.is_active    IS DISTINCT FROM NEW.is_active)
    THEN
        INSERT INTO public.phone_update_log (
            phone_id,
            old_sent_out,   new_sent_out,
            old_order_id,   new_order_id,
            old_mark,       new_mark,
            old_is_active,  new_is_active,
            old_pending,    new_pending,
            imei,
            who_changed
        )
        VALUES (
            NEW.id,
            OLD.sent_out,   NEW.sent_out,
            OLD.order_id,   NEW.order_id,
            OLD.mark,       NEW.mark,
            OLD.is_active,  NEW.is_active,
            OLD.pending,    NEW.pending,
            NEW.imei,
            auth.uid()  -- captures the authenticated user's UUID in Supabase
        );
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: log_repair_job_changes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_repair_job_changes() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    changes jsonb := '[]'::jsonb;
    entry jsonb;
    next_index int;
    actor_uuid uuid := auth.uid();
    actor_name text;
BEGIN
    -- Resolve actor name from technicians table
    SELECT t.name INTO actor_name
    FROM public.technicians t
    WHERE t.uuid = actor_uuid;

    IF (TG_OP = 'INSERT') THEN
        next_index := 1;

        changes := jsonb_build_array(
            jsonb_build_object('field','repair_level','new',NEW.repair_level),
            jsonb_build_object('field','completed_date','new',NEW.completed_date),
            jsonb_build_object('field','technician','new',
                (SELECT t.name FROM public.technicians t WHERE t.id = NEW.technician)),
            jsonb_build_object('field','was_split','new',NEW.was_split),
            jsonb_build_object('field','pause','new',NEW.pause),
            jsonb_build_object('field','order_id','new',NEW.order_id),
            jsonb_build_object('field','status','new',
                (SELECT s.name FROM public.enum_status s WHERE s.id = NEW.status_id)),
            jsonb_build_object('field','notes','new',NEW.notes)
        );

        entry := jsonb_build_object(
            'index', next_index,
            'timestamp', now(),
            'actor', coalesce(actor_name, actor_uuid::text),
            'event', 'created',
            'changes', changes
        );

        NEW.logs := jsonb_build_array(entry);
        RETURN NEW;
    END IF;

    IF (TG_OP = 'UPDATE') THEN
        next_index := coalesce(jsonb_array_length(coalesce(OLD.logs, '[]'::jsonb)), 0) + 1;

        IF NEW.technician IS DISTINCT FROM OLD.technician THEN
            changes := changes || jsonb_build_array(
                jsonb_build_object(
                    'field','technician',
                    'old',(SELECT t.name FROM public.technicians t WHERE t.id = OLD.technician),
                    'new',(SELECT t.name FROM public.technicians t WHERE t.id = NEW.technician)
                )
            );
        END IF;

        IF NEW.status_id IS DISTINCT FROM OLD.status_id THEN
            changes := changes || jsonb_build_array(
                jsonb_build_object(
                    'field','status',
                    'old',(SELECT s.name FROM public.enum_status s WHERE s.id = OLD.status_id),
                    'new',(SELECT s.name FROM public.enum_status s WHERE s.id = NEW.status_id)
                )
            );
        END IF;

        IF jsonb_array_length(changes) > 0 THEN
            entry := jsonb_build_object(
                'index', coalesce(jsonb_array_length(coalesce(OLD.logs,'[]'::jsonb)),0)+1,
                'timestamp', now(),
                'actor', coalesce(actor_name, actor_uuid::text),
                'event','updated',
                'changes', changes
            );

            NEW.logs := coalesce(OLD.logs,'[]'::jsonb) || jsonb_build_array(entry);
        END IF;

        RETURN NEW;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: log_table_changes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_table_changes() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    old_row JSONB;
    new_row JSONB;
    diff JSONB := '{}'::JSONB;
    key TEXT;
BEGIN
    -- Convert entire rows to JSONB
    old_row := to_jsonb(OLD);
    new_row := to_jsonb(NEW);

    -- Loop through keys in NEW row
    FOR key IN SELECT jsonb_object_keys(new_row)
    LOOP
        IF old_row->key IS DISTINCT FROM new_row->key THEN
            diff := diff || jsonb_build_object(
                key,
                jsonb_build_object(
                    'old', old_row->key,
                    'new', new_row->key
                )
            );
        END IF;
    END LOOP;

    -- Insert only if something changed
    IF diff <> '{}'::JSONB THEN
        INSERT INTO public.audit_log(table_name, changes_jsonb)
        VALUES (TG_TABLE_NAME, diff);
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: maintain_phone_priority(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.maintain_phone_priority() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    -- Only run if current_job changes
    IF NEW.current_job IS DISTINCT FROM OLD.current_job THEN
        -- Auto-lookup the priority from the enum table
        SELECT priority INTO NEW.current_job_priority
        FROM public.enum_order_jobs
        WHERE id = NEW.current_job;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: manage_outside_repair_phones(text[], text, json); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.manage_outside_repair_phones(imei_array_param text[], operation_param text, payload_param json) RETURNS TABLE(outside_repair_phone_id bigint)
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    phone_id_var bigint;
    current_imei text;
    payload_keys text[];
    payload_values text[];
    update_clause text := '';
    insert_columns text := '';
    insert_values text := '';
    upsert_query text;
    affected_id bigint;
BEGIN
    IF operation_param NOT IN ('POST', 'DELETE', 'PATCH') THEN
        RAISE EXCEPTION 'Invalid operation_param. Must be POST, DELETE, or PATCH.';
    END IF;

    FOREACH current_imei IN ARRAY imei_array_param
    LOOP
        SELECT id INTO phone_id_var
        FROM public.phones
        WHERE imei = current_imei AND is_active = true;

        IF phone_id_var IS NULL THEN
            RAISE EXCEPTION 'IMEI % not found or not active in public.phones. Transaction cancelled.', current_imei;
        END IF;

        IF operation_param = 'POST' THEN
            IF NOT (payload_param::jsonb ? 'outside_order_id') THEN
                RAISE EXCEPTION 'For POST operation, payload_param must include "outside_order_id". Transaction cancelled.';
            END IF;

            SELECT array_agg(key), array_agg(value)
            INTO payload_keys, payload_values
            FROM json_each_text(payload_param);

            insert_columns := 'phone_id';
            insert_values := phone_id_var::text;

            FOR i IN 1 .. array_length(payload_keys, 1)
            LOOP
                insert_columns := insert_columns || ', ' || quote_ident(payload_keys[i]);
                insert_values := insert_values || ', ' || quote_literal(payload_values[i]);
            END LOOP;

            upsert_query := format(
                'INSERT INTO public.outside_repair_phones (%s) VALUES (%s) RETURNING id;',
                insert_columns,
                insert_values
            );

            EXECUTE upsert_query INTO affected_id;
            outside_repair_phone_id := affected_id;
            RETURN NEXT;

        ELSIF operation_param = 'DELETE' THEN
            DELETE FROM public.outside_repair_phones
            WHERE phone_id = phone_id_var
              AND received IS NOT TRUE
            RETURNING id INTO affected_id;

            IF affected_id IS NOT NULL THEN
                outside_repair_phone_id := affected_id;
                RETURN NEXT;
            END IF;

        ELSIF operation_param = 'PATCH' THEN
            SELECT string_agg(
                format('%I = %L', key, value), ', '
            )
            INTO update_clause
            FROM json_each_text(payload_param)
            WHERE key != 'id';

            IF update_clause IS NOT NULL AND update_clause != '' THEN
                EXECUTE format(
                    'UPDATE public.outside_repair_phones
                     SET %s
                     WHERE phone_id = %L
                       AND received IS NOT TRUE
                     RETURNING id;',
                    update_clause,
                    phone_id_var
                ) INTO affected_id;

                IF affected_id IS NOT NULL THEN
                    outside_repair_phone_id := affected_id;
                    RETURN NEXT;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$$;


--
-- Name: mark_notifications_as_read(bigint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_notifications_as_read(notification_ids bigint[]) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    UPDATE public.notification_reads
    SET read_at = now()
    WHERE user_id = auth.uid() AND notification_id = ANY(notification_ids);
END;
$$;


--
-- Name: normalize_employee_name(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_employee_name() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
  BEGIN
    -- Fully qualify built-in functions
    new.employee_name := initcap(trim(new.employee_name));
    return new;
  END;
$$;


--
-- Name: normalize_name(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_name(text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $_$
  SELECT REGEXP_REPLACE(TRIM(LOWER($1)), '\s+', ' ', 'g');
$_$;


--
-- Name: normalize_paint_color(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_paint_color() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
  IF NEW.color IS NOT NULL THEN
    NEW.color := initcap(NEW.color);
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: notify_on_supplies_order_history_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_on_supplies_order_history_insert() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    tech_name TEXT;
    supply_name TEXT;
BEGIN
    -- Get technician name
    SELECT t.name
    INTO tech_name
    FROM public.technicians t
    WHERE t.uuid = NEW.who_requested;

    -- Get supply name
    SELECT si.name
    INTO supply_name
    FROM public.supplies_inventory si
    WHERE si.id = NEW.supplies_inventory_id;

    -- Call your notification function
    PERFORM public.send_notification_to_users(
        ARRAY['d0a2c682-90a0-41cf-a960-10db7c779564']::uuid[], -- recipient_uuids
        'Please go to supplies panel and approve the purchase', -- message
        tech_name || ' wants to buy ' || NEW.amount || ' ' || supply_name -- type
    );

    RETURN NEW;
END;
$$;


--
-- Name: orders_set_path(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.orders_set_path() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'extensions'
    AS $$
DECLARE
  parent_path extensions.ltree;
BEGIN
  IF NEW.parent_id IS NULL THEN
    NEW.path := (NEW.id::text)::extensions.ltree;
  ELSE
    SELECT path INTO parent_path
    FROM public.orders
    WHERE id = NEW.parent_id;

    -- If parent has no path yet, build it now
    IF parent_path IS NULL THEN
      parent_path := (NEW.parent_id::text)::extensions.ltree;
      UPDATE public.orders
      SET path = parent_path
      WHERE id = NEW.parent_id;
    END IF;

    NEW.path := parent_path || (NEW.id::text)::extensions.ltree;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: parts_usage_last_30_days(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.parts_usage_last_30_days() RETURNS TABLE(date date, amount bigint, part_name text, model text)
    LANGUAGE sql
    SET search_path TO ''
    AS $$
select pq.created_at::date as date,
       count(pq.id) as amount,
       pi.part_name,
       em.name as model
from public.parts_queue pq
join public.parts_inventory pi on pi.serial = pq.part_serial

join public.phones p on p.id = pq.phone_id
join public.enum_models em on p.model_id = em.id
where pq.created_at >= current_date - interval '30 days'
group by pq.created_at::date, pi.part_name, em.name
order by date;

$$;


--
-- Name: populate_order_id_from_phone(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.populate_order_id_from_phone() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
  v_order_id bigint;
BEGIN
  -- Step 1: Get order_id from phones using NEW.phone_id
  SELECT order_id INTO v_order_id
  FROM public.phones
  WHERE id = NEW.phone_id
  LIMIT 1;

  -- Step 2: Update repair_jobs with the retrieved order_id
  UPDATE public.repair_jobs
  SET order_id = v_order_id
  WHERE id = NEW.repair_job_id;

  RETURN NEW;
END;
$$;


--
-- Name: prevent_mark_update_on_pending(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_mark_update_on_pending() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  -- Only fire if pending is true and mark is being changed
  if new.pending is true and new.mark is distinct from old.mark then
    raise exception 'cannot pack pending phones (IMEI: %)', old.imei
      using errcode = 'P0001'; -- custom exception code
  end if;

  return new;
end;
$$;


--
-- Name: recalc_current_job_on_order_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalc_current_job_on_order_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    -- Only recalculate if the order_id has actually changed
    IF NEW.order_id IS DISTINCT FROM OLD.order_id THEN
        
        NEW.current_job := COALESCE(
            -- 1. Try to find the lowest priority PENDING job for the NEW order
            --    (Must have a done_id to be trackable, and must NOT exist in phone_jobs_done)
            (
                SELECT oj.job_id
                FROM public.orders_jobs oj
                JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                WHERE oj.order_id = NEW.order_id
                  AND eoj.done_id IS NOT NULL 
                  AND NOT EXISTS (
                      SELECT 1 
                      FROM public.phone_jobs_done pjd 
                      WHERE pjd.phone_id = NEW.id 
                        AND pjd.done_id = eoj.done_id 
                  )
                ORDER BY eoj.priority ASC
                LIMIT 1
            ),
            -- 2. Fallback: If all jobs are done (or none are trackable) for the NEW order,
            --    set to the job with the highest priority (The "Final" Stage)
            (
                SELECT oj.job_id
                FROM public.orders_jobs oj
                JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                WHERE oj.order_id = NEW.order_id
                ORDER BY eoj.priority DESC
                LIMIT 1
            )
        );
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: recalc_is_pending(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalc_is_pending(p_phone_id bigint) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    new_pending BOOLEAN;
BEGIN
    new_pending := public.compute_pending(p_phone_id);

    RAISE LOG 'p_phone_id=%, pending=%', p_phone_id, new_pending;

    UPDATE public.phones
    SET pending = new_pending
    WHERE id = p_phone_id;
END;
$$;


--
-- Name: recalc_phones_on_job_structure_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalc_phones_on_job_structure_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_target_order_id bigint;
BEGIN
    -- 1. Handle INSERT and UPDATE (Target the NEW order_id)
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
        v_target_order_id := NEW.order_id;
        
        UPDATE public.phones p
        SET current_job = COALESCE(
            -- Priority Pending Check
            (
                SELECT oj.job_id
                FROM public.orders_jobs oj
                JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                WHERE oj.order_id = p.order_id
                  AND eoj.done_id IS NOT NULL 
                  AND NOT EXISTS (
                      SELECT 1 
                      FROM public.phone_jobs_done pjd 
                      WHERE pjd.phone_id = p.id 
                        AND pjd.done_id = eoj.done_id 
                  )
                ORDER BY eoj.priority ASC
                LIMIT 1
            ),
            -- Fallback: Last Done Job (Highest Priority)
            (
                SELECT oj.job_id
                FROM public.orders_jobs oj
                JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                WHERE oj.order_id = p.order_id
                ORDER BY eoj.priority DESC
                LIMIT 1
            )
        )
        WHERE p.order_id = v_target_order_id
          AND p.is_active = true;
    END IF;

    -- 2. Handle DELETE and UPDATE (Target the OLD order_id)
    --    (If an ID changed, we need to clean up the old order too)
    IF (TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.order_id IS DISTINCT FROM NEW.order_id)) THEN
        v_target_order_id := OLD.order_id;
        
        UPDATE public.phones p
        SET current_job = COALESCE(
            (
                SELECT oj.job_id
                FROM public.orders_jobs oj
                JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                WHERE oj.order_id = p.order_id
                  AND eoj.done_id IS NOT NULL 
                  AND NOT EXISTS (
                      SELECT 1 
                      FROM public.phone_jobs_done pjd 
                      WHERE pjd.phone_id = p.id 
                        AND pjd.done_id = eoj.done_id 
                  )
                ORDER BY eoj.priority ASC
                LIMIT 1
            ),
            (
                SELECT oj.job_id
                FROM public.orders_jobs oj
                JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                WHERE oj.order_id = p.order_id
                ORDER BY eoj.priority DESC
                LIMIT 1
            )
        )
        WHERE p.order_id = v_target_order_id
          AND p.is_active = true;
    END IF;

    RETURN NULL;
END;
$$;


--
-- Name: recalc_phones_on_orders_jobs_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recalc_phones_on_orders_jobs_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_order_id bigint;
BEGIN
    -- Iterate through relevant Order IDs (Handles INSERT, UPDATE, DELETE safely)
    -- If it's an INSERT, OLD.order_id is null. If DELETE, NEW is null. 
    -- If UPDATE, checks both (usually they are the same, but safe to check).
    FOR v_order_id IN 
        SELECT DISTINCT val 
        FROM (VALUES (OLD.order_id), (NEW.order_id)) AS t(val) 
        WHERE val IS NOT NULL
    LOOP
        -- Update all active phones for this order
        UPDATE public.phones p
        SET current_job = COALESCE(
            -- 1. Try to find the lowest priority PENDING job
            --    (Must have a done_id to be trackable, and must NOT exist in phone_jobs_done)
            (
                SELECT oj.job_id
                FROM public.orders_jobs oj
                JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                WHERE oj.order_id = p.order_id
                  AND eoj.done_id IS NOT NULL 
                  AND NOT EXISTS (
                      SELECT 1 
                      FROM public.phone_jobs_done pjd 
                      WHERE pjd.phone_id = p.id 
                        AND pjd.done_id = eoj.done_id 
                  )
                ORDER BY eoj.priority ASC
                LIMIT 1
            ),
            -- 2. Fallback: If all trackable jobs are present, or no trackable jobs exist,
            --    set to the job with the highest priority (The "Final" Stage)
            (
                SELECT oj.job_id
                FROM public.orders_jobs oj
                JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
                WHERE oj.order_id = p.order_id
                ORDER BY eoj.priority DESC
                LIMIT 1
            )
        )
        WHERE p.order_id = v_order_id
          AND p.is_active = true;
    END LOOP;

    RETURN NULL;
END;
$$;


--
-- Name: send_global_notification(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.send_global_notification(message text, type text DEFAULT 'announcement'::text, meta jsonb DEFAULT '{}'::jsonb) RETURNS bigint
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    new_notification_id BIGINT;
    sender_uuid UUID;
BEGIN
    -- --- THIS IS THE FIX ---
    -- Use COALESCE to get the ID of the currently authenticated user.
    -- If auth.uid() is NULL (like when running in the SQL Editor),
    -- it will fall back to your specified UUID.
    sender_uuid := COALESCE(auth.uid(), '3c132ec9-d397-471a-a95f-3a4606d43447'::uuid);
    -- --- END OF FIX ---

    -- 1. Insert the new notification into the master table.
    INSERT INTO public.notifications (channel_id, message, sender_id, type, meta)
    VALUES (
        'e84d0e21-cdf7-4e82-a955-06fe4b5a31dc',
        send_global_notification.message,
        sender_uuid, -- Use the determined sender UUID
        send_global_notification.type,
        send_global_notification.meta
    )
    RETURNING id INTO new_notification_id;

    -- 2. Create a "notification_reads" entry for ALL users.
    INSERT INTO public.notification_reads (notification_id, user_id, read_at)
    SELECT
        new_notification_id,
        u.id,
        NULL
    FROM auth.users u;

    RETURN new_notification_id;
END;
$$;


--
-- Name: send_notification_to_users(uuid[], text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.send_notification_to_users(recipient_uuids uuid[], message text, type text DEFAULT 'direct_message'::text, meta jsonb DEFAULT '{}'::jsonb) RETURNS bigint
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    new_notification_id BIGINT;
    sender_uuid UUID;
BEGIN
    -- Use COALESCE to get the ID of the currently authenticated user.
    -- If auth.uid() is NULL (like when running in the SQL Editor),
    -- it will fall back to your specified test UUID.
    sender_uuid := COALESCE(auth.uid(), '3c132ec9-d397-471a-a95f-3a4606d43447'::uuid);

    -- 1. Insert the new notification into the master table.
    -- We can still use the global channel_id, as the filtering happens in the notification_reads table.
    INSERT INTO public.notifications (channel_id, message, sender_id, type, meta)
    VALUES (
        'e84d0e21-cdf7-4e82-a955-06fe4b5a31dc',
        send_notification_to_users.message,
        sender_uuid,
        send_notification_to_users.type,
        send_notification_to_users.meta
    )
    RETURNING id INTO new_notification_id;

    -- --- THIS IS THE KEY CHANGE ---
    -- 2. Create a "notification_reads" entry ONLY for the users in the provided array.
    --    The `unnest` function turns the input array into a set of rows we can insert from.
    INSERT INTO public.notification_reads (notification_id, user_id, read_at)
    SELECT
        new_notification_id,
        recipient_id,
        NULL -- `read_at` is NULL, meaning it's unread
    FROM unnest(recipient_uuids) AS recipient_id;
    -- --- END OF KEY CHANGE ---

    RETURN new_notification_id;
END;
$$;


--
-- Name: set_completed_date(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_completed_date() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$BEGIN
  IF NEW.status_id = 4 AND OLD.status_id IS DISTINCT FROM 4 THEN
    NEW.completed_date := CURRENT_TIMESTAMP;
  END IF;
  RETURN NEW;
END;$$;


--
-- Name: set_initial_phone_job(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_initial_phone_job() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    -- Only calculate if not already provided manually
    IF NEW.current_job IS NULL THEN
        SELECT oj.job_id
        INTO NEW.current_job
        FROM public.orders_jobs oj
        JOIN public.enum_order_jobs eoj ON oj.job_id = eoj.id
        WHERE oj.order_id = NEW.order_id
        ORDER BY eoj.priority ASC
        LIMIT 1;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: set_job_done_by_imei(text[], bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_job_done_by_imei(imei_list text[], target_done_id bigint DEFAULT 1) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    missing_imeis text[];
BEGIN
    -- 1. Validation: Identify IMEIs that do not exist or are inactive
    SELECT array_agg(x)
    INTO missing_imeis
    FROM (
        SELECT unnest(imei_list) AS x
        EXCEPT
        SELECT imei 
        FROM public.phones 
        WHERE imei = ANY(imei_list) 
          AND is_active = TRUE
    ) sub;

    -- 2. If validtaion fails, abort the transaction
    IF missing_imeis IS NOT NULL AND array_length(missing_imeis, 1) > 0 THEN
        RAISE EXCEPTION 'Transaction cancelled. The following IMEIs were not found or are inactive: %', 
            array_to_string(missing_imeis, ', ')
            USING ERRCODE = 'P0001';
    END IF;

    -- 3. Execute Upsert
    INSERT INTO public.phone_jobs_done (phone_id, done_id, is_done)
    SELECT p.id, target_done_id, true
    FROM public.phones p
    WHERE p.imei = ANY(imei_list)
      AND p.is_active = TRUE
    ON CONFLICT (phone_id, done_id) 
    DO UPDATE SET is_done = true;
    
END;
$$;


--
-- Name: set_model_id_from_tac(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_model_id_from_tac() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
BEGIN
  -- Only proceed if IMEI looks numeric and at least 8 digits
  IF NEW.imei ~ '^[0-9]{8,}$' THEN
    SELECT model_id
    INTO NEW.model_id
    FROM public."TAC_database"
    WHERE tac_number = SUBSTRING(NEW.imei FROM 1 FOR 8);

    -- If no match found, raise an exception
    IF NEW.model_id IS NULL THEN
      RAISE EXCEPTION 'No model_id found in TAC_database for IMEI: %', NEW.imei
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$_$;


--
-- Name: set_parts_queue_approve_date(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_parts_queue_approve_date() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    IF NEW.status_id = 10 AND OLD.status_id IS DISTINCT FROM 10 THEN
        NEW.approve_date = NOW();
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: set_phone_pending(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_phone_pending() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    UPDATE public.phones
    SET pending = TRUE
    WHERE id = NEW.phone_id;

    RETURN NEW; -- pass the inserted row along
END;
$$;


--
-- Name: set_phone_pending_on_report(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_phone_pending_on_report() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    IF NEW.status_id = 1 THEN
        UPDATE public.phones
        SET pending = TRUE
        WHERE id = NEW.reported_phone;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: set_sent_out_date(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_sent_out_date() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
  -- If sent_out changed to true, set sent_out_date to current timestamp
  IF NEW.sent_out = TRUE AND (OLD.sent_out IS DISTINCT FROM NEW.sent_out) THEN
    NEW.sent_out_date := now();
  -- If sent_out changed to false, clear sent_out_date
  ELSIF NEW.sent_out = FALSE AND (OLD.sent_out IS DISTINCT FROM NEW.sent_out) THEN
    NEW.sent_out_date := NULL;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: set_tac_from_imei(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_tac_from_imei() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
  NEW.tac := SUBSTRING(NEW.imei FROM 1 FOR 8)::bigint;
  RETURN NEW;
END;
$$;


--
-- Name: sync_order_status_batch(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_order_status_batch() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    v_order_ids bigint[];
BEGIN
    -- 1. Identify affected orders, BUT ignore irrelevant updates (like 'sent_out')
    IF TG_OP = 'INSERT' THEN
        SELECT array_agg(DISTINCT order_id) INTO v_order_ids FROM new_phones_table;
        
    ELSIF TG_OP = 'DELETE' THEN
        SELECT array_agg(DISTINCT order_id) INTO v_order_ids FROM old_phones_table;
        
    ELSE -- UPDATE
        -- Only grab order_ids if the columns that affect order status actually changed
        SELECT array_agg(DISTINCT n.order_id) INTO v_order_ids 
        FROM new_phones_table n
        JOIN old_phones_table o ON n.id = o.id
        WHERE n.current_job IS DISTINCT FROM o.current_job
           OR n.current_job_priority IS DISTINCT FROM o.current_job_priority
           OR n.is_active IS DISTINCT FROM o.is_active
           OR n.order_id IS DISTINCT FROM o.order_id;
    END IF;

    -- If nothing relevant changed, EXIT EARLY (This makes your benchmark 0ms)
    IF v_order_ids IS NULL OR array_length(v_order_ids, 1) IS NULL THEN
        RETURN NULL;
    END IF;

    -- 2. Update ONLY the affected orders using the Magic Index (O(1) Lookup)
    WITH calculated_state AS (
        SELECT
            target_oid AS order_id,
            (
                SELECT current_job
                FROM public.phones p
                WHERE p.order_id = target_oid
                  AND p.is_active = true
                  AND p.current_job IS NOT NULL
                -- Uses the new index
                ORDER BY p.current_job_priority ASC 
                LIMIT 1
            ) AS calculated_job_id
        FROM unnest(v_order_ids) AS target_oid
    )
    UPDATE public.orders o
    SET current_job = cs.calculated_job_id
    FROM calculated_state cs
    WHERE o.id = cs.order_id
      AND o.current_job IS DISTINCT FROM cs.calculated_job_id;

    RETURN NULL;
END;
$$;


--
-- Name: sync_parent_id_from_tag(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_parent_id_from_tag() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
DECLARE
    v_extracted_id_text text;
    v_target_parent_id bigint;
BEGIN
    -- 1. Extract digits only if the tag starts with '#' followed immediately by numbers
    --    Pattern: Start of string (^), '#', one or more digits ([0-9]+), End of string ($)
    v_extracted_id_text := substring(NEW.tag from '^#([0-9]+)$');

    -- 2. If the tag matched the format
    IF v_extracted_id_text IS NOT NULL THEN
        
        v_target_parent_id := v_extracted_id_text::bigint;

        -- 3. Validation:
        --    A. The ID must exist in the orders table.
        --    B. The ID cannot be the order's own ID (prevent self-parenting loop).
        IF EXISTS (SELECT 1 FROM public.orders WHERE id = v_target_parent_id) 
           AND (NEW.id IS NULL OR NEW.id <> v_target_parent_id) THEN
            
            -- Apply the sync
            NEW.parent_id := v_target_parent_id;
            
        END IF;
    END IF;

    RETURN NEW;
END;
$_$;


--
-- Name: trg_recalc_pending_on_repair_received(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_recalc_pending_on_repair_received() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    PERFORM public.recalc_is_pending(NEW.phone_id);
    RETURN NEW;
END;
$$;


--
-- Name: update_marks_by_imei(text[], integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_marks_by_imei(imei_list text[], mark_value integer) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    missing_imeis text[];
BEGIN
    -- 1. Identify IMEIs that do not exist or are inactive
    --    We unnest the input array and subtract (EXCEPT) the valid ones found in the DB.
    SELECT array_agg(x)
    INTO missing_imeis
    FROM (
        SELECT unnest(imei_list) AS x
        EXCEPT
        SELECT imei 
        FROM public.phones 
        WHERE imei = ANY(imei_list) 
          AND is_active = TRUE
    ) sub;

    -- 2. If we found any missing IMEIs, abort the transaction
    IF missing_imeis IS NOT NULL AND array_length(missing_imeis, 1) > 0 THEN
        RAISE EXCEPTION 'Transaction cancelled. The following IMEIs were not found or are inactive: %', 
            array_to_string(missing_imeis, ', ')
            USING ERRCODE = 'P0001'; -- Custom error code
    END IF;

    -- 3. All IMEIs are valid, proceed with update
    --    Note: Casting mark_value to text because the schema defines 'mark' as text.
    UPDATE public.phones
    SET mark = mark_value::text
    WHERE imei = ANY(imei_list)
      AND is_active = TRUE;
      
END;
$$;


--
-- Name: update_null_values(text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_null_values(column_name text, target_order_id bigint) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
BEGIN
    EXECUTE format('UPDATE public.phones SET %I = TRUE WHERE %I IS NULL AND order_id = $1', column_name, column_name)
    USING target_order_id;
END;
$_$;


--
-- Name: update_outside_repair_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_outside_repair_status() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    total_phones bigint;
    received_phones bigint;
    new_status_id bigint;
BEGIN
    -- Only proceed if the 'received' column was updated
    IF OLD.received IS DISTINCT FROM NEW.received THEN
        -- Count total phones for the outside_order_id
        SELECT COUNT(*)
        INTO total_phones
        FROM public.outside_repair_phones
        WHERE outside_order_id = NEW.outside_order_id;

        -- Count received phones for the outside_order_id
        SELECT COUNT(*)
        INTO received_phones
        FROM public.outside_repair_phones
        WHERE outside_order_id = NEW.outside_order_id
          AND received = TRUE;

        -- Determine the new status_id for outside_repairs
        IF total_phones > 0 AND received_phones = total_phones THEN
            new_status_id := 4; -- Completed
        ELSE
            new_status_id := 1; -- Pending
        END IF;

        -- Update the status_id in public.outside_repairs
        UPDATE public.outside_repairs
        SET status_id = new_status_id
        WHERE id = NEW.outside_order_id;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: update_phones_and_grades_by_imei(text[], json); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_phones_and_grades_by_imei(imei_array_param text[], updates_param json) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    updates_jsonb jsonb := updates_param::jsonb;
    grade_id_param bigint;
    missing_imei text;
    grade_error_rec record;
BEGIN
    -- STEP 1: Check if all IMEIs exist in the phones table with is_active = true.
    SELECT imei INTO missing_imei
    FROM (
        SELECT unnest(imei_array_param) AS imei
        EXCEPT
        SELECT imei
        FROM public.phones
        WHERE imei = ANY(imei_array_param) AND is_active = true
    ) AS missing_phones
    LIMIT 1;

    IF missing_imei IS NOT NULL THEN
        RAISE EXCEPTION 'IMEI % not found or is not active.', missing_imei;
    END IF;

    -- STEP 2: Check if a grade_id update is requested.
    IF updates_jsonb ? 'grade_id_param' THEN
        grade_id_param := updates_jsonb->>'grade_id_param';

        FOR grade_error_rec IN
            WITH phones_to_check AS (
                SELECT id, imei
                FROM public.phones
                WHERE imei = ANY(imei_array_param) AND is_active = true
            ),
            grade_counts AS (
                SELECT
                    ptc.imei,
                    ptc.id AS phone_id,
                    COUNT(pg.id) AS grade_count
                FROM phones_to_check ptc
                LEFT JOIN public.phone_grades pg ON pg.phone_id = ptc.id
                GROUP BY ptc.imei, ptc.id
            )
            SELECT imei, grade_count
            FROM grade_counts
            WHERE grade_count != 1
        LOOP
            IF grade_error_rec.grade_count = 0 THEN
                RAISE EXCEPTION '% has no grade', grade_error_rec.imei;
            ELSE
                RAISE EXCEPTION '% has more than 1 grade', grade_error_rec.imei;
            END IF;
        END LOOP;
    END IF;

    -- STEP 3: Update phones
    UPDATE public.phones
    SET
        date_scanned = COALESCE((updates_jsonb->>'date_scanned')::timestamptz, date_scanned),
        order_id = COALESCE((updates_jsonb->>'order_id')::bigint, order_id),
        pending = COALESCE((updates_jsonb->>'pending')::boolean, pending),
        sent_out = COALESCE((updates_jsonb->>'sent_out')::boolean, sent_out),
        mark = COALESCE(updates_jsonb->>'mark', mark),
        paint_color = COALESCE(updates_jsonb->>'paint_color', paint_color),
        is_active = COALESCE((updates_jsonb->>'is_active')::boolean, is_active),
        model_id = COALESCE((updates_jsonb->>'model_id')::bigint, model_id)
    WHERE
        imei = ANY(imei_array_param) AND is_active = true;

    -- STEP 4: Update phone_grades if needed
    IF grade_id_param IS NOT NULL THEN
        UPDATE public.phone_grades pg
        SET grade_id = grade_id_param
        FROM public.phones p
        WHERE
            pg.phone_id = p.id
            AND p.imei = ANY(imei_array_param)
            AND p.is_active = true;
    END IF;
END;
$$;


--
-- Name: update_phones_for_completed_order(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_phones_for_completed_order(input_order_id bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    updated_count INTEGER;
BEGIN
    UPDATE public.phones 
    SET is_active = false
    WHERE order_id = input_order_id 
      AND is_active = true 
      AND (pending IS NULL OR pending = false);
    
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    
    RETURN updated_count;
END;
$$;


--
-- Name: update_phones_on_order_complete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_phones_on_order_complete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    -- Update phones when order status changes to Completed
    UPDATE public.phones 
    SET is_active = false
    WHERE order_id = NEW.id 
      AND is_active = true 
      AND (pending IS NULL OR pending = false);
    
    RETURN NEW;
END;
$$;


--
-- Name: update_repair_jobs_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_repair_jobs_status() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    -- Set status to 'waiting' if technician is null
    IF NEW.technician IS NULL THEN
        NEW.status_id := 2;
    END IF;

    -- Update created_at timestamp if status changes from 'waiting' to something else
    IF OLD.status_id = 2 AND NEW.status_id <> 2 THEN
        NEW.created_at := CURRENT_TIMESTAMP;
    END IF;

    -- Set pause timestamp when status_id changes to 3
    IF OLD.status_id <> 3 AND NEW.status_id = 3 THEN
        NEW.pause := CURRENT_TIMESTAMP;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: update_reports_by_imei_new(text[], text, text, text, text, timestamp with time zone, text, timestamp with time zone, bigint, bigint, bigint, bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_reports_by_imei_new(imei_array_param text[], issue_param text DEFAULT NULL::text, who_caused_issue_param text DEFAULT NULL::text, who_reported_param text DEFAULT NULL::text, status_param text DEFAULT NULL::text, completed_param timestamp with time zone DEFAULT NULL::timestamp with time zone, who_signed_completed_param text DEFAULT NULL::text, repair_date_param timestamp with time zone DEFAULT NULL::timestamp with time zone, issue_id_param bigint DEFAULT NULL::bigint, causer_id_param bigint DEFAULT NULL::bigint, signer_id_param bigint DEFAULT NULL::bigint, reporter_id_param bigint DEFAULT NULL::bigint, status_id_param bigint DEFAULT NULL::bigint, receiver_id_param bigint DEFAULT NULL::bigint) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
  found_ids BIGINT[];
BEGIN
  SELECT array_agg(id) INTO found_ids
  FROM public.phones
  WHERE imei = ANY(imei_array_param)
    AND is_active = TRUE;

  IF array_length(found_ids, 1) IS DISTINCT FROM array_length(imei_array_param, 1) THEN
    RAISE EXCEPTION 'Mismatch: Some IMEIs not found or inactive';
  END IF;

  UPDATE public.reports
  SET
    completed   = COALESCE(completed_param, completed),
    repair_date = COALESCE(repair_date_param, repair_date),
    issue_id    = COALESCE(issue_id_param, issue_id),
    causer_id   = COALESCE(causer_id_param, causer_id),
    signer_id   = COALESCE(signer_id_param, signer_id),
    reporter_id = COALESCE(reporter_id_param, reporter_id),
    status_id   = COALESCE(status_id_param, status_id),
    receiver_id = COALESCE(receiver_id_param, receiver_id)
  WHERE reported_phone = ANY(found_ids)
    AND status_id NOT IN (5, 12);  -- prevent updates if already in these statuses

END;
$$;


--
-- Name: update_sent_out_status2(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_sent_out_status2(p_order_id bigint) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    -- 1. Update phone statuses
    -- Set sent_out to TRUE only for active phones that are NOT pending.
    UPDATE public.phones
    SET sent_out = true
    WHERE order_id = p_order_id
      AND is_active = true
      AND (pending IS FALSE OR pending IS NULL);

    -- 2. Stamp the completion timestamp
    UPDATE public.orders
    SET completion_date = CURRENT_TIMESTAMP
    WHERE id = p_order_id;

    -- 3. Update Status
    -- (The previous logic resulted in 8 regardless of the condition, so we set it directly)
    UPDATE public.orders
    SET status_id = 8
    WHERE id = p_order_id;
END;
$$;


--
-- Name: update_status_on_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_status_on_insert() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$BEGIN
    IF NEW.technician IS NOT NULL THEN
        -- Only update the status to 'completed' if it is not already 'completed'
        UPDATE public.repair_jobs
        SET status_id = 4
        WHERE technician = NEW.technician AND status_id <> 4 AND id <> NEW.id;
    END IF;

    RETURN NEW;
END;$$;


--
-- Name: upsert_order(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_order(payload jsonb) RETURNS bigint
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    _order_id bigint;
    _job_ids int[];
    _key text;
    _value jsonb;
    _cols text := '';
    _vals text := '';
    _updates text := '';
    _json_clean jsonb;
    _query text;
BEGIN
    -- 1. Extract the ID to determine if it's an Update or Insert
    IF payload->>'id' IS NOT NULL AND (payload->>'id') <> 'null' THEN
        _order_id := (payload->>'id')::bigint;
    ELSE
        _order_id := NULL;
    END IF;

    -- 2. Extract order_type array separately (to sync orders_jobs)
    SELECT COALESCE(
        ARRAY(
            SELECT jsonb_array_elements_text(payload->'order_type')::int
        ), 
        '{}'::int[]
    ) INTO _job_ids;

    -- 3. Prepare Payload for Orders Table
    --    Remove 'id' (handled in WHERE/RETURNING)
    --    Remove 'order_type' (handled in orders_jobs)
    _json_clean := payload - 'id' - 'order_type';

    -- 4. Build Dynamic SQL
    --    We iterate through the JSON keys, but we FILTER them against the actual database schema.
    FOR _key, _value IN 
        SELECT key, value 
        FROM jsonb_each(_json_clean)
        WHERE EXISTS (
            SELECT 1 
            FROM information_schema.columns 
            WHERE table_schema = 'public' 
              AND table_name = 'orders' 
              AND column_name = key
        )
    LOOP
        -- For Insert: Build comma-separated lists of columns and values
        IF _cols <> '' THEN 
            _cols := _cols || ', '; 
            _vals := _vals || ', ';
        END IF;
        
        _cols := _cols || quote_ident(_key);
        _vals := _vals || quote_nullable(_value #>> '{}'); 

        -- For Update: Build "col = val" string
        IF _updates <> '' THEN 
            _updates := _updates || ', '; 
        END IF;
        _updates := _updates || quote_ident(_key) || ' = ' || quote_nullable(_value #>> '{}');
    END LOOP;

    -- 5. Execute Upsert Logic
    IF _order_id IS NOT NULL AND EXISTS(SELECT 1 FROM public.orders WHERE id = _order_id) THEN
        -- --- UPDATE CASE ---
        -- Only execute if valid columns were found to update
        IF _updates <> '' THEN
            _query := format('UPDATE public.orders SET %s WHERE id = %L', _updates, _order_id);
            EXECUTE _query;
        END IF;
    ELSE
        -- --- INSERT CASE ---
        IF _cols <> '' THEN
            -- Standard insert with provided columns
            _query := format('INSERT INTO public.orders (%s) VALUES (%s) RETURNING id', _cols, _vals);
            EXECUTE _query INTO _order_id;
        ELSE
            -- Edge case: Payload had no valid columns (or was empty), create row with defaults
            INSERT INTO public.orders DEFAULT VALUES RETURNING id INTO _order_id;
        END IF;
    END IF;

    -- 6. Sync orders_jobs Table
    --    A. Delete jobs that are NOT in the new payload array
    DELETE FROM public.orders_jobs 
    WHERE order_id = _order_id 
      AND job_id <> ALL(_job_ids);

    --    B. Insert jobs that are in the array (if not already existing)
    IF array_length(_job_ids, 1) > 0 THEN
        INSERT INTO public.orders_jobs (order_id, job_id)
        SELECT _order_id, unnest(_job_ids)
        ON CONFLICT (order_id, job_id) DO NOTHING;
    END IF;

    -- 7. Return the ID
    RETURN _order_id;
END;
$$;


--
-- Name: user_in_channel(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_in_channel(p_channel_id uuid) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.channel_members cm
    JOIN public.technicians t
      ON t.id = cm.technician_id
    WHERE cm.channel_id = p_channel_id
      AND t.uuid = auth.uid()
  );
$$;


--
-- Name: TAC_database; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."TAC_database" (
    tac_number text NOT NULL,
    model text,
    name text,
    brand text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    "Amanufacturer" text,
    "Abrand" text,
    "Amodel" text,
    "AmodelName" text,
    "jsonExtra" text,
    "jsonExtraFull" text,
    model_id bigint,
    CONSTRAINT "TAC_database_tac_number_check" CHECK ((length(tac_number) = 8))
);


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    editor_uid uuid DEFAULT auth.uid(),
    table_name text,
    changes_jsonb jsonb
);


--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: channel_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_members (
    id bigint NOT NULL,
    channel_id uuid,
    technician_id bigint,
    joined_at timestamp with time zone DEFAULT now(),
    last_read_at timestamp with time zone,
    type text
);


--
-- Name: channel_members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.channel_members ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.channel_members_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: channels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text
);


--
-- Name: daily_report_new; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_report_new (
    id bigint NOT NULL,
    created_at date NOT NULL,
    technician_id bigint,
    job_id bigint,
    device text,
    amount smallint
);


--
-- Name: daily_report2_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.daily_report_new ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.daily_report2_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: employee_repairs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.employee_repairs (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    technician_id bigint,
    bin_id bigint,
    base_price numeric,
    completed_at timestamp with time zone
);


--
-- Name: employee_repairs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.employee_repairs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.employee_repairs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: enum_companies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enum_companies (
    id bigint NOT NULL,
    name text NOT NULL,
    uuid uuid
);


--
-- Name: enum_damages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enum_damages (
    id bigint NOT NULL,
    name text NOT NULL,
    penalty real
);


--
-- Name: enum_grade; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enum_grade (
    id bigint NOT NULL,
    name text NOT NULL,
    work_required boolean
);


--
-- Name: enum_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enum_jobs (
    id bigint NOT NULL,
    name text NOT NULL,
    role bigint DEFAULT '7'::bigint,
    goal smallint,
    points real,
    next_job bigint[]
);


--
-- Name: enum_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enum_models (
    id bigint NOT NULL,
    name text NOT NULL,
    is_popular boolean DEFAULT false NOT NULL
);


--
-- Name: enum_models_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.enum_models ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.enum_models_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: enum_order_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enum_order_jobs (
    id bigint NOT NULL,
    name text,
    done_id bigint,
    priority smallint
);


--
-- Name: enum_phone_done; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enum_phone_done (
    id bigint NOT NULL,
    name text
);


--
-- Name: enum_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enum_roles (
    id bigint NOT NULL,
    name text NOT NULL
);


--
-- Name: enum_status; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enum_status (
    id bigint NOT NULL,
    name text NOT NULL
);


--
-- Name: events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events (
    id bigint NOT NULL,
    title text NOT NULL,
    start date DEFAULT now(),
    "end" date,
    "backgroundColor" text,
    "borderColor" text,
    description text,
    status_id bigint DEFAULT '1'::bigint NOT NULL,
    technician_id bigint
);


--
-- Name: events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.events ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: jobs_assigned; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jobs_assigned (
    id bigint NOT NULL,
    repair_jobs_id bigint,
    job_id bigint
);


--
-- Name: jobs_assigned_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.jobs_assigned ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.jobs_assigned_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.logs (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    table_name text,
    filter text,
    rows_returned numeric,
    "time" numeric,
    requester uuid DEFAULT auth.uid(),
    db_time numeric NOT NULL,
    serialize_time numeric NOT NULL,
    api_time numeric NOT NULL,
    client_time numeric NOT NULL,
    dns_time numeric,
    tcp_time numeric,
    tls_time numeric,
    ttfb numeric,
    download_time numeric
);


--
-- Name: logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.logs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: logs_metric; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.logs_metric (
    id bigint NOT NULL,
    session_id text NOT NULL,
    metric_name text NOT NULL,
    metric_value double precision,
    delta double precision,
    start_time double precision,
    duration double precision,
    element text,
    extra jsonb,
    created_at timestamp with time zone DEFAULT now(),
    component_name text
);


--
-- Name: logs_metric_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.logs_metric_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: logs_metric_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.logs_metric_id_seq OWNED BY public.logs_metric.id;


--
-- Name: managers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.managers (
    id bigint NOT NULL,
    manager_id bigint NOT NULL,
    employee_id bigint NOT NULL
);


--
-- Name: managers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.managers ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.managers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: manual_summary_polish_plus; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.manual_summary_polish_plus (
    created_at date DEFAULT now() NOT NULL,
    polish smallint,
    passed smallint,
    round smallint DEFAULT '1'::smallint NOT NULL,
    drowned smallint,
    damaged smallint,
    CONSTRAINT manual_summary_polish_plus_round_check CHECK ((round > 0))
);


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    channel_id uuid NOT NULL,
    sender_id uuid DEFAULT auth.uid() NOT NULL,
    content text
);


--
-- Name: messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.messages ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: notification_reads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_reads (
    notification_id bigint NOT NULL,
    user_id uuid,
    read_at timestamp with time zone,
    id bigint NOT NULL
);


--
-- Name: notification_reads_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.notification_reads ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.notification_reads_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notifications_id_seq OWNED BY public.notifications.id;


--
-- Name: notifications_id_seq1; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.notifications ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.notifications_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders (
    id bigint NOT NULL,
    order_color text NOT NULL,
    recieved_date timestamp with time zone DEFAULT now() NOT NULL,
    completion_date timestamp with time zone,
    locked boolean DEFAULT false NOT NULL,
    boxes smallint,
    status_id bigint DEFAULT '8'::bigint,
    tag text,
    company_id bigint,
    notes text,
    current_job bigint,
    parent_id bigint,
    path extensions.ltree
);

ALTER TABLE ONLY public.orders REPLICA IDENTITY FULL;


--
-- Name: orders_archive; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders_archive (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    order_structure json NOT NULL,
    order_id bigint
);


--
-- Name: orders_archive_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.orders_archive ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.orders_archive_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.orders ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: orders_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders_jobs (
    id bigint NOT NULL,
    order_id bigint,
    job_id bigint
);


--
-- Name: orders_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.orders_jobs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.orders_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: outside_repair_phones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outside_repair_phones (
    id bigint NOT NULL,
    phone_id bigint NOT NULL,
    outside_order_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    problem_received text,
    received boolean,
    issue_description text
);


--
-- Name: outside_repair_phones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.outside_repair_phones ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.outside_repair_phones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: outside_repairs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outside_repairs (
    id bigint NOT NULL,
    company_id bigint NOT NULL,
    type text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    status_id bigint DEFAULT '1'::bigint NOT NULL
);


--
-- Name: outside_repairs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.outside_repairs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.outside_repairs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: paint_details; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.paint_details (
    id bigint NOT NULL,
    model_id bigint,
    color text,
    paintable boolean DEFAULT false NOT NULL,
    grade text[]
);


--
-- Name: paint_details_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.paint_details ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.paint_details_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: parts_inventory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parts_inventory (
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    part_name text NOT NULL,
    part_link text,
    price numeric,
    serial bigint NOT NULL,
    stock smallint,
    stock_warning smallint DEFAULT '5'::smallint,
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT parts_inventory_stock_check CHECK ((stock >= 0)),
    CONSTRAINT parts_inventory_stock_warning_check CHECK ((stock_warning > 0))
);


--
-- Name: parts_inventory_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parts_inventory_models (
    id bigint NOT NULL,
    part_serial bigint NOT NULL,
    model_id bigint
);


--
-- Name: parts_inventory_models_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.parts_inventory_models ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.parts_inventory_models_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: parts_queue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parts_queue (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    technician_requester_id bigint NOT NULL,
    part_serial bigint,
    phone_id bigint,
    status_id bigint DEFAULT '1'::bigint NOT NULL,
    approve_date timestamp with time zone,
    delay_date timestamp with time zone
);


--
-- Name: parts_queue_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.parts_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.parts_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: phone_grades; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.phone_grades (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    grade_id bigint NOT NULL,
    phone_id bigint
);


--
-- Name: phone_grades_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.phone_grades ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.phone_grades_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: phone_jobs_done; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.phone_jobs_done (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    phone_id bigint,
    done_id bigint,
    is_done boolean NOT NULL
);


--
-- Name: phone_jobs_done_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.phone_jobs_done ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.phone_jobs_done_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: phone_jobs_done_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.phone_jobs_done_logs (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    phone_id bigint,
    updated_by uuid DEFAULT auth.uid(),
    operation text,
    old_done_id bigint,
    new_done_id bigint,
    old_boolean boolean,
    new_boolean boolean
);


--
-- Name: phone_jobs_done_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.phone_jobs_done_logs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.phone_jobs_done_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: phone_update_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.phone_update_log (
    log_id bigint NOT NULL,
    phone_id bigint NOT NULL,
    old_sent_out boolean,
    new_sent_out boolean,
    old_paint_done boolean,
    new_paint_done boolean,
    old_battery_done boolean,
    new_battery_done boolean,
    old_polish_done boolean,
    new_polish_done boolean,
    old_order_id bigint,
    new_order_id bigint,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    imei text,
    modification_time timestamp with time zone DEFAULT (now() AT TIME ZONE 'utc'::text),
    who_changed uuid,
    old_mark text,
    new_mark text,
    old_is_active boolean,
    new_is_active boolean,
    old_pending boolean,
    new_pending boolean
);


--
-- Name: phone_update_log_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.phone_update_log ALTER COLUMN log_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.phone_update_log_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: phones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.phones (
    id bigint NOT NULL,
    imei text NOT NULL,
    date_scanned timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    order_id bigint NOT NULL,
    pending boolean,
    sent_out boolean DEFAULT false,
    mark text,
    paint_color text,
    is_active boolean DEFAULT true,
    model_id bigint NOT NULL,
    current_job bigint,
    sent_out_date timestamp with time zone,
    original_box smallint,
    current_job_priority smallint
);


--
-- Name: phones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.phones ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.phones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: repair_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.repair_jobs (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    repair_level smallint,
    completed_date timestamp with time zone,
    technician bigint,
    was_split boolean,
    pause timestamp with time zone,
    order_id bigint,
    status_id bigint DEFAULT '1'::bigint NOT NULL,
    notes text,
    logs jsonb
);


--
-- Name: repair_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.repair_jobs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.repair_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: repairs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.repairs (
    id bigint NOT NULL,
    repair_job_id bigint,
    phone_id bigint NOT NULL,
    notes text
);


--
-- Name: repairs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.repairs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.repairs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reports (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    received_at timestamp with time zone,
    reported_phone bigint NOT NULL,
    completed timestamp with time zone,
    repair_date timestamp with time zone,
    issue_id bigint NOT NULL,
    causer_id bigint NOT NULL,
    signer_id bigint,
    reporter_id bigint NOT NULL,
    status_id bigint DEFAULT '1'::bigint,
    notes text,
    receiver_id bigint
);


--
-- Name: reports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.reports ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.reports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: supplies_inventory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplies_inventory (
    id bigint NOT NULL,
    name text NOT NULL,
    price numeric,
    link text
);


--
-- Name: supplies_inventory_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.supplies_inventory ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.supplies_inventory_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: supplies_order_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplies_order_history (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    supplies_inventory_id bigint NOT NULL,
    amount numeric DEFAULT '1'::numeric NOT NULL,
    who_requested uuid DEFAULT auth.uid() NOT NULL,
    status_id bigint DEFAULT '1'::bigint NOT NULL,
    notes text
);


--
-- Name: supplies_order_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.supplies_order_history ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.supplies_order_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: technicians; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.technicians (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    name text,
    picture_url text,
    uuid uuid,
    panel_access text[] DEFAULT '{technician}'::text[],
    role_id bigint DEFAULT '1'::bigint,
    is_active boolean DEFAULT true NOT NULL,
    default_job_id bigint,
    chat_perms boolean DEFAULT false NOT NULL,
    company_id bigint,
    current_phone bigint
);


--
-- Name: technicians_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.technicians ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.technicians_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: timesheet; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.timesheet (
    id bigint NOT NULL,
    date date DEFAULT now(),
    clock_in timestamp with time zone DEFAULT now(),
    break_out timestamp with time zone,
    break_in timestamp with time zone,
    clock_out timestamp with time zone,
    employee_name text NOT NULL
);


--
-- Name: timesheet_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.timesheet ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.timesheet_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: logs_metric id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.logs_metric ALTER COLUMN id SET DEFAULT nextval('public.logs_metric_id_seq'::regclass);


--
-- Name: TAC_database TAC_database_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."TAC_database"
    ADD CONSTRAINT "TAC_database_pkey" PRIMARY KEY (tac_number);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: channel_members channel_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_members
    ADD CONSTRAINT channel_members_pkey PRIMARY KEY (id);


--
-- Name: channels channels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channels
    ADD CONSTRAINT channels_pkey PRIMARY KEY (id);


--
-- Name: daily_report_new daily_report2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_new
    ADD CONSTRAINT daily_report2_pkey PRIMARY KEY (id);


--
-- Name: employee_repairs employee_repairs_bin_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_repairs
    ADD CONSTRAINT employee_repairs_bin_id_key UNIQUE (bin_id);


--
-- Name: employee_repairs employee_repairs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_repairs
    ADD CONSTRAINT employee_repairs_pkey PRIMARY KEY (id);


--
-- Name: enum_companies enum_companies_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_companies
    ADD CONSTRAINT enum_companies_name_key UNIQUE (name);


--
-- Name: enum_companies enum_companies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_companies
    ADD CONSTRAINT enum_companies_pkey PRIMARY KEY (id);


--
-- Name: enum_damages enum_damages_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_damages
    ADD CONSTRAINT enum_damages_name_key UNIQUE (name);


--
-- Name: enum_damages enum_damages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_damages
    ADD CONSTRAINT enum_damages_pkey PRIMARY KEY (id);


--
-- Name: enum_grade enum_grade_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_grade
    ADD CONSTRAINT enum_grade_name_key UNIQUE (name);


--
-- Name: enum_grade enum_grade_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_grade
    ADD CONSTRAINT enum_grade_pkey PRIMARY KEY (id);


--
-- Name: enum_models enum_models_model_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_models
    ADD CONSTRAINT enum_models_model_key UNIQUE (name);


--
-- Name: enum_models enum_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_models
    ADD CONSTRAINT enum_models_pkey PRIMARY KEY (id);


--
-- Name: enum_order_jobs enum_order_jobs_priority_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_order_jobs
    ADD CONSTRAINT enum_order_jobs_priority_key UNIQUE (priority);


--
-- Name: enum_order_jobs enum_order_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_order_jobs
    ADD CONSTRAINT enum_order_types_pkey PRIMARY KEY (id);


--
-- Name: enum_phone_done enum_phone_done_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_phone_done
    ADD CONSTRAINT enum_phone_done_pkey PRIMARY KEY (id);


--
-- Name: enum_roles enum_roles_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_roles
    ADD CONSTRAINT enum_roles_name_key UNIQUE (name);


--
-- Name: enum_roles enum_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_roles
    ADD CONSTRAINT enum_roles_pkey PRIMARY KEY (id);


--
-- Name: enum_status enum_status_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_status
    ADD CONSTRAINT enum_status_name_key UNIQUE (name);


--
-- Name: enum_status enum_status_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_status
    ADD CONSTRAINT enum_status_pkey PRIMARY KEY (id);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);


--
-- Name: jobs_assigned jobs_assigned_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs_assigned
    ADD CONSTRAINT jobs_assigned_pkey PRIMARY KEY (id);


--
-- Name: enum_jobs jobs_enum_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_jobs
    ADD CONSTRAINT jobs_enum_name_key UNIQUE (name);


--
-- Name: enum_jobs jobs_enum_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_jobs
    ADD CONSTRAINT jobs_enum_pkey PRIMARY KEY (id);


--
-- Name: logs_metric logs_metric_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.logs_metric
    ADD CONSTRAINT logs_metric_pkey PRIMARY KEY (id);


--
-- Name: logs logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.logs
    ADD CONSTRAINT logs_pkey PRIMARY KEY (id);


--
-- Name: managers managers_manager_employee_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.managers
    ADD CONSTRAINT managers_manager_employee_key UNIQUE (manager_id, employee_id);


--
-- Name: managers managers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.managers
    ADD CONSTRAINT managers_pkey PRIMARY KEY (id);


--
-- Name: manual_summary_polish_plus manual_summary_polish_plus_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.manual_summary_polish_plus
    ADD CONSTRAINT manual_summary_polish_plus_pkey PRIMARY KEY (round, created_at);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: notification_reads notification_reads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_reads
    ADD CONSTRAINT notification_reads_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: orders_archive orders_archive_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_archive
    ADD CONSTRAINT orders_archive_pkey PRIMARY KEY (id);


--
-- Name: orders_jobs orders_jobs_order_id_job_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_jobs
    ADD CONSTRAINT orders_jobs_order_id_job_id_key UNIQUE (order_id, job_id);


--
-- Name: orders_jobs orders_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_jobs
    ADD CONSTRAINT orders_jobs_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: outside_repair_phones outside_repair_phones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outside_repair_phones
    ADD CONSTRAINT outside_repair_phones_pkey PRIMARY KEY (id);


--
-- Name: outside_repairs outside_repairs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outside_repairs
    ADD CONSTRAINT outside_repairs_pkey PRIMARY KEY (id);


--
-- Name: paint_details paint_details_model_color_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.paint_details
    ADD CONSTRAINT paint_details_model_color_key UNIQUE (model_id, color);


--
-- Name: paint_details paint_details_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.paint_details
    ADD CONSTRAINT paint_details_pkey PRIMARY KEY (id);


--
-- Name: parts_inventory parts_definition_part_link_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parts_inventory
    ADD CONSTRAINT parts_definition_part_link_key UNIQUE (part_link);


--
-- Name: parts_inventory_models parts_inventory_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parts_inventory_models
    ADD CONSTRAINT parts_inventory_models_pkey PRIMARY KEY (id);


--
-- Name: parts_inventory parts_inventory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parts_inventory
    ADD CONSTRAINT parts_inventory_pkey PRIMARY KEY (serial);


--
-- Name: parts_queue parts_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parts_queue
    ADD CONSTRAINT parts_queue_pkey PRIMARY KEY (id);


--
-- Name: phone_grades phone_grades_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_grades
    ADD CONSTRAINT phone_grades_pkey PRIMARY KEY (id);


--
-- Name: phone_jobs_done_logs phone_jobs_done_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_jobs_done_logs
    ADD CONSTRAINT phone_jobs_done_logs_pkey PRIMARY KEY (id);


--
-- Name: phone_jobs_done phone_jobs_done_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_jobs_done
    ADD CONSTRAINT phone_jobs_done_pkey PRIMARY KEY (id);


--
-- Name: phone_update_log phone_update_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_update_log
    ADD CONSTRAINT phone_update_log_pkey PRIMARY KEY (log_id);


--
-- Name: phones phones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phones
    ADD CONSTRAINT phones_pkey PRIMARY KEY (id);


--
-- Name: repair_jobs repair_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repair_jobs
    ADD CONSTRAINT repair_jobs_pkey PRIMARY KEY (id);


--
-- Name: repairs repairs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repairs
    ADD CONSTRAINT repairs_pkey PRIMARY KEY (id);


--
-- Name: reports reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_pkey PRIMARY KEY (id);


--
-- Name: supplies_inventory supplies_inventory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplies_inventory
    ADD CONSTRAINT supplies_inventory_pkey PRIMARY KEY (id);


--
-- Name: supplies_order_history supplies_order_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplies_order_history
    ADD CONSTRAINT supplies_order_history_pkey PRIMARY KEY (id);


--
-- Name: technicians technicians_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.technicians
    ADD CONSTRAINT technicians_name_key UNIQUE (name);


--
-- Name: technicians technicians_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.technicians
    ADD CONSTRAINT technicians_pkey PRIMARY KEY (id);


--
-- Name: technicians technicians_uuid_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.technicians
    ADD CONSTRAINT technicians_uuid_key UNIQUE (uuid);


--
-- Name: timesheet timesheet_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timesheet
    ADD CONSTRAINT timesheet_pkey PRIMARY KEY (id);


--
-- Name: jobs_assigned unique_job_per_repair; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs_assigned
    ADD CONSTRAINT unique_job_per_repair UNIQUE (repair_jobs_id, job_id);


--
-- Name: phone_jobs_done unique_phone_job_status; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_jobs_done
    ADD CONSTRAINT unique_phone_job_status UNIQUE (phone_id, done_id);


--
-- Name: repairs unique_phone_repair_combo; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repairs
    ADD CONSTRAINT unique_phone_repair_combo UNIQUE (phone_id, repair_job_id);


--
-- Name: TAC_database_model_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "TAC_database_model_id_idx" ON public."TAC_database" USING btree (model_id);


--
-- Name: TAC_database_tac_number_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "TAC_database_tac_number_idx" ON public."TAC_database" USING btree (tac_number);


--
-- Name: channel_members_channel_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX channel_members_channel_id_idx ON public.channel_members USING btree (channel_id);


--
-- Name: channel_members_technician_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX channel_members_technician_id_idx ON public.channel_members USING btree (technician_id);


--
-- Name: daily_report_new_created_at_technician_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_new_created_at_technician_id_idx ON public.daily_report_new USING btree (created_at, technician_id);


--
-- Name: daily_report_new_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_new_job_id_idx ON public.daily_report_new USING btree (job_id);


--
-- Name: daily_report_new_technician_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX daily_report_new_technician_id_idx ON public.daily_report_new USING btree (technician_id);


--
-- Name: enum_companies_uuid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX enum_companies_uuid_idx ON public.enum_companies USING btree (uuid);


--
-- Name: enum_jobs_role_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX enum_jobs_role_idx ON public.enum_jobs USING btree (role);


--
-- Name: idx_logs_metric_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_logs_metric_created_at ON public.logs_metric USING btree (created_at);


--
-- Name: idx_logs_metric_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_logs_metric_name ON public.logs_metric USING btree (metric_name);


--
-- Name: idx_logs_metric_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_logs_metric_session ON public.logs_metric USING btree (session_id);


--
-- Name: idx_notification_reads_unread; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notification_reads_unread ON public.notification_reads USING btree (user_id) WHERE (read_at IS NULL);


--
-- Name: idx_one_unreceived_per_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_unreceived_per_phone ON public.outside_repair_phones USING btree (phone_id) WHERE (received IS NOT TRUE);


--
-- Name: idx_outside_repair_phones_unique_phone_order; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_outside_repair_phones_unique_phone_order ON public.outside_repair_phones USING btree (phone_id, outside_order_id);


--
-- Name: idx_parts_queue_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_parts_queue_created_at ON public.parts_queue USING btree (created_at);


--
-- Name: idx_pending_phone_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_pending_phone_unique ON public.reports USING btree (reported_phone) WHERE (status_id = (1)::bigint);


--
-- Name: idx_phone_jobs_done_done_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_phone_jobs_done_done_id ON public.phone_jobs_done USING btree (done_id);


--
-- Name: idx_phone_jobs_done_phone_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_phone_jobs_done_phone_id ON public.phone_jobs_done USING btree (phone_id);


--
-- Name: idx_phone_update_log_who_changed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_phone_update_log_who_changed ON public.phone_update_log USING btree (who_changed);


--
-- Name: idx_phones_active_covering; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_phones_active_covering ON public.phones USING btree (is_active, id) INCLUDE (imei, date_scanned, order_id, model_id);


--
-- Name: idx_phones_is_active_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_phones_is_active_id ON public.phones USING btree (is_active, id DESC);


--
-- Name: idx_phones_order_id_is_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_phones_order_id_is_active ON public.phones USING btree (order_id, is_active);


--
-- Name: idx_phones_order_job_fast; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_phones_order_job_fast ON public.phones USING btree (order_id, current_job) WHERE (is_active = true);


--
-- Name: idx_phones_order_priority_fast; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_phones_order_priority_fast ON public.phones USING btree (order_id, current_job_priority) WHERE ((is_active = true) AND (current_job IS NOT NULL));


--
-- Name: idx_repair_jobs_technician; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_repair_jobs_technician ON public.repair_jobs USING btree (technician);


--
-- Name: idx_reports_phone_latest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reports_phone_latest ON public.reports USING btree (reported_phone, id DESC);


--
-- Name: idx_reports_reported_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reports_reported_phone ON public.reports USING btree (reported_phone);


--
-- Name: jobs_assigned_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_assigned_job_id_idx ON public.jobs_assigned USING btree (job_id);


--
-- Name: jobs_assigned_repair_jobs_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_assigned_repair_jobs_id_idx ON public.jobs_assigned USING btree (repair_jobs_id);


--
-- Name: messages_channel_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_channel_id_idx ON public.messages USING btree (channel_id);


--
-- Name: messages_sender_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_sender_id_idx ON public.messages USING btree (sender_id);


--
-- Name: notification_reads_notification_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notification_reads_notification_id_idx ON public.notification_reads USING btree (notification_id);


--
-- Name: notifications_channel_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_channel_id_idx ON public.notifications USING btree (channel_id);


--
-- Name: notifications_sender_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_sender_id_idx ON public.notifications USING btree (sender_id);


--
-- Name: orders_archive_order_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_archive_order_id_idx ON public.orders_archive USING btree (order_id);


--
-- Name: orders_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_company_id_idx ON public.orders USING btree (company_id);


--
-- Name: orders_completion_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_completion_date_idx ON public.orders USING btree (completion_date);


--
-- Name: orders_jobs_order_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_jobs_order_id_idx ON public.orders_jobs USING btree (order_id);


--
-- Name: orders_path_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_path_idx ON public.orders USING gist (path);


--
-- Name: orders_recieved_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_recieved_date_idx ON public.orders USING btree (recieved_date);


--
-- Name: orders_status_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_status_id_idx ON public.orders USING btree (status_id);


--
-- Name: orders_tag_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_tag_idx ON public.orders USING btree (tag);


--
-- Name: outside_repair_phones_outside_order_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX outside_repair_phones_outside_order_id_idx ON public.outside_repair_phones USING btree (outside_order_id);


--
-- Name: outside_repair_phones_phone_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX outside_repair_phones_phone_id_idx ON public.outside_repair_phones USING btree (phone_id);


--
-- Name: outside_repairs_company_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX outside_repairs_company_id_idx ON public.outside_repairs USING btree (company_id);


--
-- Name: outside_repairs_status_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX outside_repairs_status_id_idx ON public.outside_repairs USING btree (status_id);


--
-- Name: parts_inventory_models_model_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parts_inventory_models_model_id_idx ON public.parts_inventory_models USING btree (model_id);


--
-- Name: parts_inventory_models_part_serial_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parts_inventory_models_part_serial_idx ON public.parts_inventory_models USING btree (part_serial);


--
-- Name: parts_queue_part_serial_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parts_queue_part_serial_idx ON public.parts_queue USING btree (part_serial);


--
-- Name: parts_queue_phone_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parts_queue_phone_id_idx ON public.parts_queue USING btree (phone_id);


--
-- Name: parts_queue_status_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parts_queue_status_id_idx ON public.parts_queue USING btree (status_id);


--
-- Name: parts_queue_technician_requester_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parts_queue_technician_requester_id_idx ON public.parts_queue USING btree (technician_requester_id);


--
-- Name: parts_queue_unique_phone_status_1_2; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX parts_queue_unique_phone_status_1_2 ON public.parts_queue USING btree (phone_id) WHERE (status_id = ANY (ARRAY[(1)::bigint, (2)::bigint]));


--
-- Name: phone_grades_grade_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX phone_grades_grade_id_idx ON public.phone_grades USING btree (grade_id);


--
-- Name: phone_grades_phone_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX phone_grades_phone_id_idx ON public.phone_grades USING btree (phone_id);


--
-- Name: phone_grades_unique_grade_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX phone_grades_unique_grade_phone ON public.phone_grades USING btree (grade_id, phone_id) WHERE ((grade_id IS NOT NULL) AND (phone_id IS NOT NULL));


--
-- Name: phone_update_log_new_order_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX phone_update_log_new_order_id_idx ON public.phone_update_log USING btree (new_order_id);


--
-- Name: phone_update_log_old_order_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX phone_update_log_old_order_id_idx ON public.phone_update_log USING btree (old_order_id);


--
-- Name: phone_update_log_phone_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX phone_update_log_phone_id_idx ON public.phone_update_log USING btree (phone_id);


--
-- Name: phones_date_scanned_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX phones_date_scanned_idx ON public.phones USING btree (date_scanned);


--
-- Name: phones_imei_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX phones_imei_idx ON public.phones USING btree (imei);


--
-- Name: phones_is_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX phones_is_active_idx ON public.phones USING btree (is_active);


--
-- Name: phones_model_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX phones_model_id_idx ON public.phones USING btree (model_id);


--
-- Name: phones_order_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX phones_order_id_idx ON public.phones USING btree (order_id);


--
-- Name: repair_jobs_completed_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX repair_jobs_completed_date_idx ON public.repair_jobs USING btree (completed_date);


--
-- Name: repair_jobs_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX repair_jobs_created_at_idx ON public.repair_jobs USING btree (created_at);


--
-- Name: repair_jobs_order_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX repair_jobs_order_id_idx ON public.repair_jobs USING btree (order_id);


--
-- Name: repair_jobs_status_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX repair_jobs_status_id_idx ON public.repair_jobs USING btree (status_id);


--
-- Name: repairs_phone_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX repairs_phone_id_idx ON public.repairs USING btree (phone_id);


--
-- Name: repairs_repair_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX repairs_repair_job_id_idx ON public.repairs USING btree (repair_job_id);


--
-- Name: reports_causer_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_causer_id_idx ON public.reports USING btree (causer_id);


--
-- Name: reports_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_created_at_idx ON public.reports USING btree (created_at);


--
-- Name: reports_issue_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_issue_id_idx ON public.reports USING btree (issue_id);


--
-- Name: reports_received_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_received_at_idx ON public.reports USING btree (received_at);


--
-- Name: reports_receiver_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_receiver_id_idx ON public.reports USING btree (receiver_id);


--
-- Name: reports_reporter_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_reporter_id_idx ON public.reports USING btree (reporter_id);


--
-- Name: reports_signer_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_signer_id_idx ON public.reports USING btree (signer_id);


--
-- Name: reports_status_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_status_id_idx ON public.reports USING btree (status_id);


--
-- Name: supplies_order_history_status_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX supplies_order_history_status_id_idx ON public.supplies_order_history USING btree (status_id);


--
-- Name: supplies_order_history_supplies_inventory_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX supplies_order_history_supplies_inventory_id_idx ON public.supplies_order_history USING btree (supplies_inventory_id);


--
-- Name: supplies_order_history_who_requested_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX supplies_order_history_who_requested_idx ON public.supplies_order_history USING btree (who_requested);


--
-- Name: technicians_default_job_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX technicians_default_job_id_idx ON public.technicians USING btree (default_job_id);


--
-- Name: technicians_role_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX technicians_role_id_idx ON public.technicians USING btree (role_id);


--
-- Name: unique_active_imei; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_active_imei ON public.phones USING btree (imei) WHERE (is_active IS TRUE);


--
-- Name: unique_daily_device_job_technician; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_daily_device_job_technician ON public.daily_report_new USING btree (device, job_id, technician_id, created_at);


--
-- Name: timesheet normalize_employee_name_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER normalize_employee_name_trigger BEFORE INSERT OR UPDATE ON public.timesheet FOR EACH ROW EXECUTE FUNCTION public.normalize_employee_name();


--
-- Name: paint_details paint_details_color_normalize; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER paint_details_color_normalize BEFORE INSERT OR UPDATE ON public.paint_details FOR EACH ROW EXECUTE FUNCTION public.normalize_paint_color();


--
-- Name: parts_queue parts_queue_approve_date_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER parts_queue_approve_date_trigger BEFORE UPDATE ON public.parts_queue FOR EACH ROW EXECUTE FUNCTION public.set_parts_queue_approve_date();


--
-- Name: phones phone_update_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER phone_update_trigger AFTER UPDATE ON public.phones FOR EACH ROW WHEN (((old.sent_out IS DISTINCT FROM new.sent_out) OR (old.order_id IS DISTINCT FROM new.order_id) OR (old.imei IS DISTINCT FROM new.imei) OR (old.mark IS DISTINCT FROM new.mark) OR (old.is_active IS DISTINCT FROM new.is_active) OR (old.pending IS DISTINCT FROM new.pending))) EXECUTE FUNCTION public.log_phone_updates();


--
-- Name: outside_repair_phones recalc_pending_after_repair_received; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recalc_pending_after_repair_received AFTER UPDATE OF received ON public.outside_repair_phones FOR EACH ROW WHEN ((old.received IS DISTINCT FROM new.received)) EXECUTE FUNCTION public.trg_recalc_pending_on_repair_received();


--
-- Name: repair_jobs repair_jobs_audit_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER repair_jobs_audit_trigger BEFORE INSERT OR UPDATE ON public.repair_jobs FOR EACH ROW EXECUTE FUNCTION public.log_repair_job_changes();


--
-- Name: repair_jobs repair_jobs_status_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER repair_jobs_status_trigger BEFORE INSERT OR UPDATE ON public.repair_jobs FOR EACH ROW EXECUTE FUNCTION public.update_repair_jobs_status();


--
-- Name: parts_queue restore_inventory_stock; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER restore_inventory_stock AFTER DELETE ON public.parts_queue FOR EACH ROW EXECUTE FUNCTION public.increment_stock_on_delete();


--
-- Name: orders trg_a_sync_parent_id_from_tag; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_a_sync_parent_id_from_tag BEFORE INSERT OR UPDATE OF tag ON public.orders FOR EACH ROW EXECUTE FUNCTION public.sync_parent_id_from_tag();


--
-- Name: parts_queue trg_check_part_stock_on_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_check_part_stock_on_insert BEFORE INSERT ON public.parts_queue FOR EACH ROW EXECUTE FUNCTION public.check_part_stock_and_notify();


--
-- Name: phones trg_enforce_pending; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_enforce_pending BEFORE UPDATE OF pending ON public.phones FOR EACH ROW EXECUTE FUNCTION public.enforce_pending_rule();


--
-- Name: phone_jobs_done trg_log_phone_jobs_done; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_log_phone_jobs_done AFTER INSERT OR DELETE OR UPDATE ON public.phone_jobs_done FOR EACH ROW EXECUTE FUNCTION public.log_phone_jobs_done_changes();


--
-- Name: phones trg_maintain_phone_priority; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_maintain_phone_priority BEFORE INSERT OR UPDATE OF current_job ON public.phones FOR EACH ROW EXECUTE FUNCTION public.maintain_phone_priority();


--
-- Name: supplies_order_history trg_notify_supplies_order_history_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_supplies_order_history_insert AFTER INSERT ON public.supplies_order_history FOR EACH ROW EXECUTE FUNCTION public.notify_on_supplies_order_history_insert();


--
-- Name: orders trg_orders_set_path; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_orders_set_path BEFORE INSERT OR UPDATE OF parent_id ON public.orders FOR EACH ROW EXECUTE FUNCTION public.orders_set_path();


--
-- Name: repairs trg_populate_order_id; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_populate_order_id AFTER INSERT ON public.repairs FOR EACH ROW EXECUTE FUNCTION public.populate_order_id_from_phone();


--
-- Name: phones trg_prevent_mark_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_prevent_mark_update BEFORE UPDATE OF mark ON public.phones FOR EACH ROW EXECUTE FUNCTION public.prevent_mark_update_on_pending();


--
-- Name: orders_jobs trg_recalc_on_structure_change; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_recalc_on_structure_change AFTER INSERT OR DELETE OR UPDATE ON public.orders_jobs FOR EACH ROW EXECUTE FUNCTION public.recalc_phones_on_orders_jobs_change();


--
-- Name: phones trg_set_initial_phone_job; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_initial_phone_job BEFORE INSERT ON public.phones FOR EACH ROW EXECUTE FUNCTION public.set_initial_phone_job();


--
-- Name: phones trg_set_model_id; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_model_id BEFORE INSERT ON public.phones FOR EACH ROW EXECUTE FUNCTION public.set_model_id_from_tac();


--
-- Name: outside_repair_phones trg_set_phone_pending; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_phone_pending AFTER INSERT ON public.outside_repair_phones FOR EACH ROW EXECUTE FUNCTION public.set_phone_pending();


--
-- Name: reports trg_set_phone_pending; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_phone_pending BEFORE INSERT ON public.reports FOR EACH ROW EXECUTE FUNCTION public.set_phone_pending_on_report();


--
-- Name: phones trg_set_sent_out_date; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_sent_out_date BEFORE UPDATE OF sent_out ON public.phones FOR EACH ROW EXECUTE FUNCTION public.set_sent_out_date();


--
-- Name: phones trg_sync_order_status_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_order_status_delete AFTER DELETE ON public.phones REFERENCING OLD TABLE AS old_phones_table FOR EACH STATEMENT EXECUTE FUNCTION public.sync_order_status_batch();


--
-- Name: phones trg_sync_order_status_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_order_status_insert AFTER INSERT ON public.phones REFERENCING NEW TABLE AS new_phones_table FOR EACH STATEMENT EXECUTE FUNCTION public.sync_order_status_batch();


--
-- Name: phones trg_sync_order_status_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_order_status_update AFTER UPDATE ON public.phones REFERENCING OLD TABLE AS old_phones_table NEW TABLE AS new_phones_table FOR EACH STATEMENT EXECUTE FUNCTION public.sync_order_status_batch();


--
-- Name: phone_jobs_done trg_update_phone_batch_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_update_phone_batch_delete AFTER DELETE ON public.phone_jobs_done REFERENCING OLD TABLE AS old_table FOR EACH STATEMENT EXECUTE FUNCTION public.calc_phone_current_job_batch();


--
-- Name: phone_jobs_done trg_update_phone_batch_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_update_phone_batch_insert AFTER INSERT ON public.phone_jobs_done REFERENCING NEW TABLE AS new_table FOR EACH STATEMENT EXECUTE FUNCTION public.calc_phone_current_job_batch();


--
-- Name: phone_jobs_done trg_update_phone_batch_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_update_phone_batch_update AFTER UPDATE ON public.phone_jobs_done REFERENCING OLD TABLE AS old_table NEW TABLE AS new_table FOR EACH STATEMENT EXECUTE FUNCTION public.calc_phone_current_job_batch();


--
-- Name: orders trg_update_phones_on_order_complete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_update_phones_on_order_complete AFTER UPDATE OF status_id ON public.orders FOR EACH ROW WHEN ((new.status_id = ANY (ARRAY[(1)::bigint, (2)::bigint]))) EXECUTE FUNCTION public.update_phones_on_order_complete();


--
-- Name: reports trigger_status_logic; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_status_logic AFTER UPDATE OF status_id ON public.reports FOR EACH ROW EXECUTE FUNCTION public.handle_status_update();


--
-- Name: repair_jobs update_completed_date; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_completed_date BEFORE UPDATE ON public.repair_jobs FOR EACH ROW EXECUTE FUNCTION public.set_completed_date();


--
-- Name: parts_queue update_inventory_stock; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_inventory_stock AFTER UPDATE ON public.parts_queue FOR EACH ROW EXECUTE FUNCTION public.decrement_stock_on_approval();


--
-- Name: orders update_lock_old_orders; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_lock_old_orders AFTER INSERT OR UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.lock_old_orders();


--
-- Name: outside_repair_phones update_outside_repair_status_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_outside_repair_status_trigger AFTER UPDATE ON public.outside_repair_phones FOR EACH ROW WHEN ((old.received IS DISTINCT FROM new.received)) EXECUTE FUNCTION public.update_outside_repair_status();


--
-- Name: TAC_database TAC_database_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."TAC_database"
    ADD CONSTRAINT "TAC_database_model_id_fkey" FOREIGN KEY (model_id) REFERENCES public.enum_models(id);


--
-- Name: audit_log audit_log_editor_uid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_editor_uid_fkey FOREIGN KEY (editor_uid) REFERENCES public.technicians(uuid);


--
-- Name: channel_members channel_members_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_members
    ADD CONSTRAINT channel_members_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: channel_members channel_members_technician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_members
    ADD CONSTRAINT channel_members_technician_id_fkey FOREIGN KEY (technician_id) REFERENCES public.technicians(id);


--
-- Name: daily_report_new daily_report2_technician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_new
    ADD CONSTRAINT daily_report2_technician_id_fkey FOREIGN KEY (technician_id) REFERENCES public.technicians(id);


--
-- Name: daily_report_new daily_report_new_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_report_new
    ADD CONSTRAINT daily_report_new_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.enum_jobs(id);


--
-- Name: employee_repairs employee_repairs_bin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_repairs
    ADD CONSTRAINT employee_repairs_bin_id_fkey FOREIGN KEY (bin_id) REFERENCES public.repair_jobs(id);


--
-- Name: employee_repairs employee_repairs_technician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_repairs
    ADD CONSTRAINT employee_repairs_technician_id_fkey FOREIGN KEY (technician_id) REFERENCES public.technicians(id);


--
-- Name: enum_companies enum_companies_uuid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_companies
    ADD CONSTRAINT enum_companies_uuid_fkey FOREIGN KEY (uuid) REFERENCES auth.users(id);


--
-- Name: enum_jobs enum_jobs_role_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_jobs
    ADD CONSTRAINT enum_jobs_role_fkey FOREIGN KEY (role) REFERENCES public.enum_roles(id);


--
-- Name: enum_order_jobs enum_order_jobs_done_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enum_order_jobs
    ADD CONSTRAINT enum_order_jobs_done_id_fkey FOREIGN KEY (done_id) REFERENCES public.enum_phone_done(id);


--
-- Name: events events_status_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_status_id_fkey FOREIGN KEY (status_id) REFERENCES public.enum_status(id);


--
-- Name: events events_technician_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_technician_id_fkey FOREIGN KEY (technician_id) REFERENCES public.technicians(id);


--
-- Name: jobs_assigned jobs_assigned_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs_assigned
    ADD CONSTRAINT jobs_assigned_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.enum_jobs(id);


--
-- Name: jobs_assigned jobs_assigned_repair_jobs_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs_assigned
    ADD CONSTRAINT jobs_assigned_repair_jobs_id_fkey FOREIGN KEY (repair_jobs_id) REFERENCES public.repair_jobs(id) ON DELETE CASCADE;


--
-- Name: logs logs_requester_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.logs
    ADD CONSTRAINT logs_requester_fkey FOREIGN KEY (requester) REFERENCES public.technicians(uuid);


--
-- Name: managers managers_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.managers
    ADD CONSTRAINT managers_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.technicians(id);


--
-- Name: managers managers_manager_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.managers
    ADD CONSTRAINT managers_manager_id_fkey FOREIGN KEY (manager_id) REFERENCES public.technicians(id);


--
-- Name: messages messages_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: messages messages_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES public.technicians(uuid);


--
-- Name: notification_reads notification_reads_notification_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_reads
    ADD CONSTRAINT notification_reads_notification_id_fkey FOREIGN KEY (notification_id) REFERENCES public.notifications(id) ON DELETE CASCADE;


--
-- Name: notification_reads notification_reads_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_reads
    ADD CONSTRAINT notification_reads_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.technicians(uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: notifications notifications_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: notifications notifications_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES auth.users(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: orders_archive orders_archive_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_archive
    ADD CONSTRAINT orders_archive_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: orders orders_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.enum_companies(id);


--
-- Name: orders orders_current_job_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_current_job_fkey FOREIGN KEY (current_job) REFERENCES public.enum_order_jobs(id);


--
-- Name: orders_jobs orders_jobs_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_jobs
    ADD CONSTRAINT orders_jobs_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.enum_order_jobs(id);


--
-- Name: orders_jobs orders_jobs_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders_jobs
    ADD CONSTRAINT orders_jobs_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: orders orders_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.orders(id);


--
-- Name: orders orders_status_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_status_id_fkey FOREIGN KEY (status_id) REFERENCES public.enum_status(id);


--
-- Name: outside_repair_phones outside_repair_phones_outside_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outside_repair_phones
    ADD CONSTRAINT outside_repair_phones_outside_order_id_fkey FOREIGN KEY (outside_order_id) REFERENCES public.outside_repairs(id);


--
-- Name: outside_repair_phones outside_repair_phones_phone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outside_repair_phones
    ADD CONSTRAINT outside_repair_phones_phone_id_fkey FOREIGN KEY (phone_id) REFERENCES public.phones(id);


--
-- Name: outside_repairs outside_repairs_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outside_repairs
    ADD CONSTRAINT outside_repairs_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.enum_companies(id);


--
-- Name: outside_repairs outside_repairs_status_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outside_repairs
    ADD CONSTRAINT outside_repairs_status_id_fkey FOREIGN KEY (status_id) REFERENCES public.enum_status(id);


--
-- Name: paint_details paint_details_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.paint_details
    ADD CONSTRAINT paint_details_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.enum_models(id);


--
-- Name: parts_inventory_models parts_inventory_models_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parts_inventory_models
    ADD CONSTRAINT parts_inventory_models_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.enum_models(id);


--
-- Name: parts_inventory_models parts_inventory_models_part_serial_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parts_inventory_models
    ADD CONSTRAINT parts_inventory_models_part_serial_fkey FOREIGN KEY (part_serial) REFERENCES public.parts_inventory(serial) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: parts_queue parts_queue_part_serial_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parts_queue
    ADD CONSTRAINT parts_queue_part_serial_fkey FOREIGN KEY (part_serial) REFERENCES public.parts_inventory(serial) ON UPDATE CASCADE;


--
-- Name: parts_queue parts_queue_phone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parts_queue
    ADD CONSTRAINT parts_queue_phone_id_fkey FOREIGN KEY (phone_id) REFERENCES public.phones(id);


--
-- Name: parts_queue parts_queue_status_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parts_queue
    ADD CONSTRAINT parts_queue_status_id_fkey FOREIGN KEY (status_id) REFERENCES public.enum_status(id);


--
-- Name: parts_queue parts_queue_technician_requester_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parts_queue
    ADD CONSTRAINT parts_queue_technician_requester_id_fkey FOREIGN KEY (technician_requester_id) REFERENCES public.technicians(id);


--
-- Name: phone_grades phone_grades_grade_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_grades
    ADD CONSTRAINT phone_grades_grade_id_fkey FOREIGN KEY (grade_id) REFERENCES public.enum_grade(id);


--
-- Name: phone_grades phone_grades_phone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_grades
    ADD CONSTRAINT phone_grades_phone_id_fkey FOREIGN KEY (phone_id) REFERENCES public.phones(id);


--
-- Name: phone_jobs_done phone_jobs_done_done_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_jobs_done
    ADD CONSTRAINT phone_jobs_done_done_id_fkey FOREIGN KEY (done_id) REFERENCES public.enum_phone_done(id);


--
-- Name: phone_jobs_done_logs phone_jobs_done_logs_new_done_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_jobs_done_logs
    ADD CONSTRAINT phone_jobs_done_logs_new_done_id_fkey FOREIGN KEY (new_done_id) REFERENCES public.enum_phone_done(id);


--
-- Name: phone_jobs_done_logs phone_jobs_done_logs_old_done_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_jobs_done_logs
    ADD CONSTRAINT phone_jobs_done_logs_old_done_id_fkey FOREIGN KEY (old_done_id) REFERENCES public.enum_phone_done(id);


--
-- Name: phone_jobs_done_logs phone_jobs_done_logs_phone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_jobs_done_logs
    ADD CONSTRAINT phone_jobs_done_logs_phone_id_fkey FOREIGN KEY (phone_id) REFERENCES public.phones(id);


--
-- Name: phone_jobs_done_logs phone_jobs_done_logs_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_jobs_done_logs
    ADD CONSTRAINT phone_jobs_done_logs_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.technicians(uuid);


--
-- Name: phone_jobs_done phone_jobs_done_phone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_jobs_done
    ADD CONSTRAINT phone_jobs_done_phone_id_fkey FOREIGN KEY (phone_id) REFERENCES public.phones(id);


--
-- Name: phone_update_log phone_update_log_phone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_update_log
    ADD CONSTRAINT phone_update_log_phone_id_fkey FOREIGN KEY (phone_id) REFERENCES public.phones(id) ON DELETE CASCADE;


--
-- Name: phone_update_log phone_update_log_who_changed_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phone_update_log
    ADD CONSTRAINT phone_update_log_who_changed_fkey FOREIGN KEY (who_changed) REFERENCES public.technicians(uuid);


--
-- Name: phones phones_current_job_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phones
    ADD CONSTRAINT phones_current_job_fkey FOREIGN KEY (current_job) REFERENCES public.enum_order_jobs(id);


--
-- Name: phones phones_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phones
    ADD CONSTRAINT phones_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.enum_models(id);


--
-- Name: phones phones_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.phones
    ADD CONSTRAINT phones_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: repair_jobs repair_jobs_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repair_jobs
    ADD CONSTRAINT repair_jobs_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: repair_jobs repair_jobs_status_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repair_jobs
    ADD CONSTRAINT repair_jobs_status_id_fkey FOREIGN KEY (status_id) REFERENCES public.enum_status(id);


--
-- Name: repair_jobs repair_jobs_technician_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repair_jobs
    ADD CONSTRAINT repair_jobs_technician_fkey FOREIGN KEY (technician) REFERENCES public.technicians(id);


--
-- Name: repairs repairs_phone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repairs
    ADD CONSTRAINT repairs_phone_id_fkey FOREIGN KEY (phone_id) REFERENCES public.phones(id);


--
-- Name: repairs repairs_repair_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repairs
    ADD CONSTRAINT repairs_repair_job_id_fkey FOREIGN KEY (repair_job_id) REFERENCES public.repair_jobs(id);


--
-- Name: reports reports_causer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_causer_id_fkey FOREIGN KEY (causer_id) REFERENCES public.technicians(id);


--
-- Name: reports reports_issue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_issue_id_fkey FOREIGN KEY (issue_id) REFERENCES public.enum_damages(id);


--
-- Name: reports reports_receiver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_receiver_id_fkey FOREIGN KEY (receiver_id) REFERENCES public.technicians(id);


--
-- Name: reports reports_reported_phone_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_reported_phone_fkey FOREIGN KEY (reported_phone) REFERENCES public.phones(id);


--
-- Name: reports reports_reporter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_reporter_id_fkey FOREIGN KEY (reporter_id) REFERENCES public.technicians(id);


--
-- Name: reports reports_signer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_signer_id_fkey FOREIGN KEY (signer_id) REFERENCES public.technicians(id);


--
-- Name: reports reports_status_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_status_id_fkey FOREIGN KEY (status_id) REFERENCES public.enum_status(id);


--
-- Name: supplies_order_history supplies_order_history_status_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplies_order_history
    ADD CONSTRAINT supplies_order_history_status_id_fkey FOREIGN KEY (status_id) REFERENCES public.enum_status(id);


--
-- Name: supplies_order_history supplies_order_history_supplies_inventory_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplies_order_history
    ADD CONSTRAINT supplies_order_history_supplies_inventory_id_fkey FOREIGN KEY (supplies_inventory_id) REFERENCES public.supplies_inventory(id);


--
-- Name: supplies_order_history supplies_order_history_who_requested_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplies_order_history
    ADD CONSTRAINT supplies_order_history_who_requested_fkey FOREIGN KEY (who_requested) REFERENCES auth.users(id);


--
-- Name: supplies_order_history supplies_order_history_who_requested_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplies_order_history
    ADD CONSTRAINT supplies_order_history_who_requested_fkey1 FOREIGN KEY (who_requested) REFERENCES public.technicians(uuid);


--
-- Name: technicians technicians_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.technicians
    ADD CONSTRAINT technicians_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.enum_companies(id);


--
-- Name: technicians technicians_current_phone_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.technicians
    ADD CONSTRAINT technicians_current_phone_fkey FOREIGN KEY (current_phone) REFERENCES public.phones(id);


--
-- Name: technicians technicians_default_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.technicians
    ADD CONSTRAINT technicians_default_job_id_fkey FOREIGN KEY (default_job_id) REFERENCES public.enum_jobs(id);


--
-- Name: technicians technicians_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.technicians
    ADD CONSTRAINT technicians_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.enum_roles(id);


--
-- Name: technicians technicians_uuid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.technicians
    ADD CONSTRAINT technicians_uuid_fkey FOREIGN KEY (uuid) REFERENCES auth.users(id);


--
-- Name: parts_inventory Allow admin and update role access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow admin and update role access" ON public.parts_inventory TO authenticated USING (true) WITH CHECK (true);


--
-- Name: repair_jobs Allow admin and update role access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow admin and update role access" ON public.repair_jobs TO authenticated USING (true) WITH CHECK (true);


--
-- Name: repairs Allow admin and update role access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow admin and update role access" ON public.repairs TO authenticated USING (true) WITH CHECK (true);


--
-- Name: manual_summary_polish_plus Enable delete for users based on user_id; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable delete for users based on user_id" ON public.manual_summary_polish_plus USING (true);


--
-- Name: audit_log Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.audit_log TO authenticated USING (true);


--
-- Name: channels Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.channels FOR INSERT TO authenticated WITH CHECK (public.has_order_access('all'::text));


--
-- Name: jobs_assigned Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.jobs_assigned TO authenticated USING (true);


--
-- Name: orders Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.orders TO authenticated USING (true);


--
-- Name: orders_jobs Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.orders_jobs TO authenticated USING (true);


--
-- Name: phone_grades Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.phone_grades TO authenticated USING (true);


--
-- Name: phone_jobs_done Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.phone_jobs_done TO authenticated USING (true);


--
-- Name: phone_jobs_done_logs Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.phone_jobs_done_logs TO authenticated USING (true);


--
-- Name: timesheet Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public.timesheet TO authenticated USING (true);


--
-- Name: employee_repairs Enable insert for users based on user_id; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for users based on user_id" ON public.employee_repairs USING (true);


--
-- Name: paint_details Enable insert for users based on user_id; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for users based on user_id" ON public.paint_details TO authenticated USING (true);


--
-- Name: supplies_order_history Enable opfor authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable opfor authenticated users only" ON public.supplies_order_history TO authenticated USING (true);


--
-- Name: supplies_inventory Enable opperations for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable opperations for authenticated users only" ON public.supplies_inventory TO authenticated USING (true);


--
-- Name: managers Enable read access for all logged; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all logged" ON public.managers FOR SELECT TO authenticated USING (true);


--
-- Name: channels Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.channels FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.technicians t
  WHERE (t.uuid = ( SELECT auth.uid() AS uid)))));


--
-- Name: enum_companies Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.enum_companies FOR SELECT TO authenticated USING (true);


--
-- Name: enum_damages Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.enum_damages FOR SELECT TO authenticated USING (true);


--
-- Name: enum_jobs Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.enum_jobs FOR SELECT TO authenticated USING (true);


--
-- Name: enum_models Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.enum_models FOR SELECT TO authenticated USING (true);


--
-- Name: enum_order_jobs Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.enum_order_jobs FOR SELECT TO authenticated USING (true);


--
-- Name: enum_phone_done Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.enum_phone_done FOR SELECT TO authenticated USING (true);


--
-- Name: enum_roles Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.enum_roles FOR SELECT TO authenticated USING (true);


--
-- Name: enum_status Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.enum_status FOR SELECT TO authenticated USING (true);


--
-- Name: logs Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.logs TO authenticated USING (true);


--
-- Name: logs_metric Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.logs_metric TO authenticated USING (true);


--
-- Name: notifications Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.notifications TO authenticated USING (true);


--
-- Name: parts_queue Enable read access for all users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users" ON public.parts_queue TO authenticated USING (true);


--
-- Name: enum_grade Enable read access for all users2; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable read access for all users2" ON public.enum_grade FOR SELECT TO authenticated USING (true);


--
-- Name: technicians Policy with security definer; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Policy with security definer" ON public.technicians TO authenticated USING (true);


--
-- Name: daily_report_new Policy with security definer functions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Policy with security definer functions" ON public.daily_report_new TO authenticated USING (true);


--
-- Name: parts_inventory_models Policy with security definer functions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Policy with security definer functions" ON public.parts_inventory_models TO authenticated USING (true);


--
-- Name: TAC_database; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."TAC_database" ENABLE ROW LEVEL SECURITY;

--
-- Name: TAC_database User Admin Access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "User Admin Access" ON public."TAC_database" TO authenticated USING (true);


--
-- Name: orders_archive User Admin Access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "User Admin Access" ON public.orders_archive TO authenticated USING (true);


--
-- Name: phone_update_log User Admin Access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "User Admin Access" ON public.phone_update_log TO authenticated USING (true);


--
-- Name: phones User Admin Access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "User Admin Access" ON public.phones TO authenticated USING (true);


--
-- Name: reports User Admin Access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "User Admin Access" ON public.reports TO authenticated USING (true);


--
-- Name: messages Users can delete their own messages; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete their own messages" ON public.messages FOR DELETE TO authenticated USING ((sender_id = ( SELECT auth.uid() AS uid)));


--
-- Name: messages Users can insert messages in their channels; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert messages in their channels" ON public.messages FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM (public.channel_members cm
     JOIN public.technicians t ON ((t.id = cm.technician_id)))
  WHERE ((cm.channel_id = messages.channel_id) AND (t.uuid = ( SELECT auth.uid() AS uid))))));


--
-- Name: channel_members Users can view memberships for their channels; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view memberships for their channels" ON public.channel_members FOR SELECT TO authenticated USING (public.user_in_channel(channel_id));


--
-- Name: messages Users can view messages in their channels; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view messages in their channels" ON public.messages FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM (public.channel_members cm
     JOIN public.technicians t ON ((t.id = cm.technician_id)))
  WHERE ((cm.channel_id = messages.channel_id) AND (t.uuid = ( SELECT auth.uid() AS uid))))));


--
-- Name: events all control; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "all control" ON public.events TO authenticated USING (true);


--
-- Name: outside_repair_phones allow access to authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "allow access to authenticated" ON public.outside_repair_phones TO authenticated USING (true);


--
-- Name: outside_repairs allow access to authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "allow access to authenticated" ON public.outside_repairs TO authenticated USING (true);


--
-- Name: audit_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: channel_members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.channel_members ENABLE ROW LEVEL SECURITY;

--
-- Name: channels; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.channels ENABLE ROW LEVEL SECURITY;

--
-- Name: daily_report_new; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.daily_report_new ENABLE ROW LEVEL SECURITY;

--
-- Name: employee_repairs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.employee_repairs ENABLE ROW LEVEL SECURITY;

--
-- Name: enum_companies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.enum_companies ENABLE ROW LEVEL SECURITY;

--
-- Name: enum_damages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.enum_damages ENABLE ROW LEVEL SECURITY;

--
-- Name: enum_grade; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.enum_grade ENABLE ROW LEVEL SECURITY;

--
-- Name: enum_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.enum_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: enum_models; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.enum_models ENABLE ROW LEVEL SECURITY;

--
-- Name: enum_order_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.enum_order_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: enum_phone_done; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.enum_phone_done ENABLE ROW LEVEL SECURITY;

--
-- Name: enum_roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.enum_roles ENABLE ROW LEVEL SECURITY;

--
-- Name: enum_status; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.enum_status ENABLE ROW LEVEL SECURITY;

--
-- Name: events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;

--
-- Name: jobs_assigned; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.jobs_assigned ENABLE ROW LEVEL SECURITY;

--
-- Name: logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.logs ENABLE ROW LEVEL SECURITY;

--
-- Name: logs_metric; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.logs_metric ENABLE ROW LEVEL SECURITY;

--
-- Name: managers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.managers ENABLE ROW LEVEL SECURITY;

--
-- Name: manual_summary_polish_plus; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.manual_summary_polish_plus ENABLE ROW LEVEL SECURITY;

--
-- Name: messages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

--
-- Name: notification_reads; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notification_reads ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: orders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;

--
-- Name: orders_archive; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.orders_archive ENABLE ROW LEVEL SECURITY;

--
-- Name: orders_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.orders_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: outside_repair_phones; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.outside_repair_phones ENABLE ROW LEVEL SECURITY;

--
-- Name: outside_repairs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.outside_repairs ENABLE ROW LEVEL SECURITY;

--
-- Name: paint_details; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.paint_details ENABLE ROW LEVEL SECURITY;

--
-- Name: parts_inventory; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.parts_inventory ENABLE ROW LEVEL SECURITY;

--
-- Name: parts_inventory_models; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.parts_inventory_models ENABLE ROW LEVEL SECURITY;

--
-- Name: parts_queue; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.parts_queue ENABLE ROW LEVEL SECURITY;

--
-- Name: notification_reads perms; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY perms ON public.notification_reads TO authenticated USING (true);


--
-- Name: phone_grades; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.phone_grades ENABLE ROW LEVEL SECURITY;

--
-- Name: phone_jobs_done; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.phone_jobs_done ENABLE ROW LEVEL SECURITY;

--
-- Name: phone_jobs_done_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.phone_jobs_done_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: phone_update_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.phone_update_log ENABLE ROW LEVEL SECURITY;

--
-- Name: phones; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.phones ENABLE ROW LEVEL SECURITY;

--
-- Name: repair_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.repair_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: repairs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.repairs ENABLE ROW LEVEL SECURITY;

--
-- Name: reports; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

--
-- Name: supplies_inventory; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.supplies_inventory ENABLE ROW LEVEL SECURITY;

--
-- Name: supplies_order_history; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.supplies_order_history ENABLE ROW LEVEL SECURITY;

--
-- Name: technicians; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.technicians ENABLE ROW LEVEL SECURITY;

--
-- Name: timesheet; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.timesheet ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

