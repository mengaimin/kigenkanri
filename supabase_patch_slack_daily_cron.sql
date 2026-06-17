-- ============================================================
--  Slack 毎日自動通知（pg_cron / JST 9:00）
--  前提: http 拡張有効、supabase_patch_slack_http_sync.sql 実行済み
--  Dashboard → Database → Extensions で pg_cron も有効化
--  適用順: … → supabase_patch_admin_session_auth.sql → 本ファイル
--  （本ファイル実行後、admin_session_auth を再実行して送信表示を最新化）
-- ============================================================

CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;

ALTER TABLE slack_settings
  ADD COLUMN IF NOT EXISTS cron_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS last_cron_run_at timestamptz;

CREATE OR REPLACE FUNCTION _normalize_slack_bot_token(p_token text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_token IS NULL OR trim(p_token) = '' THEN NULL
    ELSE trim(regexp_replace(
      CASE WHEN trim(p_token) ILIKE 'bearer %' THEN trim(substring(trim(p_token) from 8)) ELSE trim(p_token) END,
      E'[\\n\\r\\t ]', '', 'g'))
  END;
$$;

-- ---- 日付ヘルパー ----
CREATE OR REPLACE FUNCTION _jst_today() RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT (timezone('Asia/Tokyo', now()))::date;
$$;

CREATE OR REPLACE FUNCTION _cal_days_until(p_deadline date, p_today date DEFAULT _jst_today())
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_deadline IS NULL THEN NULL ELSE (p_deadline - p_today)::int END;
$$;

CREATE OR REPLACE FUNCTION _biz_days_until(p_deadline date, p_today date DEFAULT _jst_today())
RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d date; c int := 0;
BEGIN
  IF p_deadline IS NULL OR p_deadline <= p_today THEN RETURN NULL; END IF;
  d := p_today + 1;
  WHILE d <= p_deadline LOOP
    IF extract(isodow from d) < 6 THEN c := c + 1; END IF;
    d := d + 1;
  END LOOP;
  RETURN c;
END;
$$;

CREATE OR REPLACE FUNCTION _add_months(p_d date, p_m int) RETURNS date
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE r date; day int := extract(day from p_d);
BEGIN
  IF p_d IS NULL THEN RETURN NULL; END IF;
  r := (date_trunc('month', p_d) + (p_m || ' months')::interval)::date + (day - 1);
  IF extract(day from r) < day THEN
    r := ((date_trunc('month', r) + '1 month'::interval)::date - 1);
  END IF;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION _add_days(p_d date, p_n int) RETURNS date
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_d IS NULL THEN NULL ELSE p_d + p_n END;
$$;

CREATE OR REPLACE FUNCTION _salary_date_after(p_conv date, p_months int, p_pd int) RETURNS date
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE th date; d date; last_day int;
BEGIN
  th := _add_months(p_conv, p_months);
  d := (date_trunc('month', th)::date + (p_pd - 1));
  IF d < th THEN
    d := (date_trunc('month', th + '1 month'::interval)::date + (p_pd - 1));
  END IF;
  last_day := extract(day from ((date_trunc('month', d) + '1 month'::interval)::date - 1));
  IF p_pd > last_day THEN
    d := (date_trunc('month', d) + '1 month'::interval)::date - 1;
  END IF;
  RETURN d;
END;
$$;

CREATE OR REPLACE FUNCTION _prog_deadline(p_type text, p_key text) RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    (SELECT deadline_date FROM program_deadlines WHERE subsidy_type = p_type AND deadline_key = p_key LIMIT 1),
    CASE
      WHEN p_type = 'biz' AND p_key = 'app_limit' THEN '2026-11-30'::date
      WHEN p_type = 'biz' AND p_key = 'comp_limit' THEN '2027-01-31'::date
      WHEN p_type = 'biz' AND p_key = 'sup_max' THEN '2027-04-10'::date
      WHEN p_type = 'work' AND p_key = 'app_limit' THEN '2026-11-30'::date
      WHEN p_type = 'work' AND p_key = 'comp_limit' THEN '2027-01-31'::date
      WHEN p_type = 'work' AND p_key = 'sup_max' THEN '2027-02-05'::date
      WHEN p_type = 'reskill' AND p_key = 'program_end' THEN '2027-03-31'::date
      ELSE NULL
    END
  );
$$;

CREATE OR REPLACE FUNCTION _slack_case_link(
  p_base text, p_company_id uuid, p_type text, p_app_id uuid
) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT rtrim(p_base, '/') || '#company/' || p_company_id::text
    || '/status?section=' || p_type || '&app=' || p_app_id::text;
$$;

CREATE OR REPLACE FUNCTION _slack_item_json(
  p_type text, p_company_id uuid, p_company_name text, p_app_id uuid,
  p_target text, p_kind text, p_deadline date, p_cal_days int, p_days_phase text,
  p_base_url text
) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_deadline IS NULL OR p_cal_days IS NULL OR p_days_phase = 'until_start' THEN NULL
    WHEN p_cal_days < -7 THEN NULL
    ELSE jsonb_build_object(
      'subsidy_type', p_type,
      'company_id', p_company_id::text,
      'company_name', p_company_name,
      'application_id', p_app_id::text,
      'target', p_target,
      'kind', p_kind,
      'deadline_date', to_char(p_deadline, 'YYYY-MM-DD'),
      'cal_days', p_cal_days,
      'business_days', CASE WHEN p_cal_days <= 0 THEN NULL ELSE _biz_days_until(p_deadline, _jst_today()) END,
      'deadline_status', CASE
        WHEN p_cal_days < 0 THEN 'expired'
        WHEN p_cal_days = 0 THEN 'today'
        ELSE 'upcoming'
      END,
      'link', _slack_case_link(p_base_url, p_company_id, p_type, p_app_id)
    )
  END;
$$;

CREATE OR REPLACE FUNCTION _slack_build_notify_items() RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = public
AS $$
DECLARE
  v_today date := _jst_today();
  v_base text;
  v_items jsonb := '[]'::jsonb;
  v_j jsonb;
  r record;
  v_base_date date;
  v_app_start date;
  v_m int[];
  v_deadline date;
  v_days int;
  v_comp date; v_sup date;
BEGIN
  SELECT app_base_url INTO v_base FROM slack_settings WHERE id = 1;
  IF v_base IS NULL OR trim(v_base) = '' THEN RETURN '[]'::jsonb; END IF;

  -- キャリアアップ
  FOR r IN
    SELECT cu.*, c.name AS company_name
    FROM career_up_applications cu
    JOIN companies c ON c.id = cu.company_id
  LOOP
    IF r.conversion_date IS NULL OR r.salary_payment_day IS NULL THEN CONTINUE; END IF;
    v_deadline := NULL; v_days := NULL;
    IF r.is_priority_worker AND r.status_first = '承認済' THEN
      IF r.status_second <> '承認済' THEN
        v_deadline := _add_days(_add_months(_add_days(_salary_date_after(r.conversion_date, 12, r.salary_payment_day), 1), 2), -1);
        v_days := _cal_days_until(v_deadline, v_today);
        v_j := _slack_item_json('career_up', r.company_id, r.company_name, r.id, r.employee_name, '2回目 申請期限', v_deadline, v_days, NULL, v_base);
      END IF;
    ELSIF r.status_first <> '承認済' THEN
      v_deadline := _add_days(_add_months(_add_days(_salary_date_after(r.conversion_date, 6, r.salary_payment_day), 1), 2), -1);
      v_days := _cal_days_until(v_deadline, v_today);
      v_j := _slack_item_json('career_up', r.company_id, r.company_name, r.id, r.employee_name, '1回目 申請期限', v_deadline, v_days, NULL, v_base);
    END IF;
    IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
  END LOOP;

  -- 業務改善
  FOR r IN
    SELECT bi.*, c.name AS company_name FROM business_improvement_applications bi JOIN companies c ON c.id = bi.company_id
  LOOP
    IF r.status = '未申請' AND r.application_date IS NULL
       AND NOT r.status = ANY(ARRAY['支給申請済','承認済（助成金受領）']) THEN
      v_deadline := _prog_deadline('biz', 'app_limit');
      v_j := _slack_item_json('biz', r.company_id, r.company_name, r.id, NULL, '交付申請期限（年度）', v_deadline, _cal_days_until(v_deadline, v_today), NULL, v_base);
      IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
    END IF;
    IF r.wage_raise_date IS NOT NULL
       AND NOT r.status = ANY(ARRAY['支給申請済','承認済（助成金受領）']) THEN
      v_deadline := _add_months(r.wage_raise_date, 6);
      v_days := _cal_days_until(v_deadline, v_today);
      IF v_days IS NOT NULL AND v_days >= -7 THEN
        v_j := _slack_item_json('biz', r.company_id, r.company_name, r.id, NULL, '賃金6か月維持期限', v_deadline, v_days, NULL, v_base);
        IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
      END IF;
    END IF;
    v_comp := _prog_deadline('biz', 'comp_limit');
    IF r.completion_date_actual IS NULL AND NOT r.status = ANY(ARRAY['支給申請済','承認済（助成金受領）']) THEN
      v_j := _slack_item_json('biz', r.company_id, r.company_name, r.id, NULL, '事業完了期限（年度）', v_comp, _cal_days_until(v_comp, v_today), NULL, v_base);
      IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
    END IF;
    IF r.completion_date_actual IS NOT NULL AND NOT r.status = ANY(ARRAY['支給申請済','承認済（助成金受領）']) THEN
      v_sup := least(_add_months(r.completion_date_actual, 1), _prog_deadline('biz', 'sup_max'));
      v_j := _slack_item_json('biz', r.company_id, r.company_name, r.id, NULL, '支給申請期限', v_sup, _cal_days_until(v_sup, v_today), NULL, v_base);
      IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
    END IF;
  END LOOP;

  -- 働き方改革
  FOR r IN
    SELECT ws.*, c.name AS company_name FROM work_style_applications ws JOIN companies c ON c.id = ws.company_id
  LOOP
    IF r.status = ANY(ARRAY['未申請','交付申請済']) THEN
      v_deadline := _prog_deadline('work', 'app_limit');
      v_j := _slack_item_json('work', r.company_id, r.company_name, r.id, NULL, '交付申請期限（年度）', v_deadline, _cal_days_until(v_deadline, v_today), NULL, v_base);
      IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
    END IF;
    IF r.completion_date IS NULL AND NOT r.status = ANY(ARRAY['支給申請済','承認済']) THEN
      v_deadline := _prog_deadline('work', 'comp_limit');
      v_j := _slack_item_json('work', r.company_id, r.company_name, r.id, NULL, '事業完了期限（年度）', v_deadline, _cal_days_until(v_deadline, v_today), NULL, v_base);
      IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
    END IF;
    IF NOT r.status = ANY(ARRAY['支給申請済','承認済']) THEN
      IF r.completion_date IS NOT NULL THEN
        v_sup := least(_add_days(r.completion_date, 30), _prog_deadline('work', 'sup_max'));
      ELSIF r.application_date IS NOT NULL THEN
        v_sup := _prog_deadline('work', 'sup_max');
      ELSE v_sup := NULL; END IF;
      IF v_sup IS NOT NULL THEN
        v_j := _slack_item_json('work', r.company_id, r.company_name, r.id, NULL, '支給申請期限', v_sup, _cal_days_until(v_sup, v_today), NULL, v_base);
        IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
      END IF;
    END IF;
  END LOOP;

  -- 両立支援（主要コース）
  FOR r IN
    SELECT ds.*, c.name AS company_name,
      CASE ds.support_course
        WHEN '出生時両立支援（第1種）' THEN ARRAY[0,1,2,-1]
        WHEN '介護離職防止（休業取得時）' THEN ARRAY[0,1,2,-1]
        WHEN '介護離職防止（職場復帰時）' THEN ARRAY[3,1,2,-1]
        WHEN '育児休業等支援（育休取得時）' THEN ARRAY[3,1,2,-1]
        WHEN '育児休業等支援（職場復帰時）' THEN ARRAY[6,1,2,-1]
        WHEN '育休中等業務代替（1ヶ月未満）' THEN ARRAY[0,1,2,-1]
        WHEN '育休中等業務代替（1ヶ月以上）' THEN ARRAY[3,1,2,-1]
        WHEN '柔軟な働き方選択制度' THEN ARRAY[6,1,2,-1]
        WHEN '不妊治療両立支援' THEN ARRAY[0,1,2,-1]
        ELSE NULL::int[] END AS m
    FROM dual_support_applications ds JOIN companies c ON c.id = ds.company_id
  LOOP
    IF r.m IS NULL THEN CONTINUE; END IF;
    IF r.status = ANY(ARRAY['支給申請済','承認済']) THEN CONTINUE; END IF;
    v_base_date := coalesce(r.date2, r.date1);
    IF v_base_date IS NULL THEN CONTINUE; END IF;
    v_app_start := _add_days(_add_months(v_base_date, r.m[1]), r.m[2]);
    v_deadline := _add_days(_add_months(v_app_start, r.m[3]), r.m[4]);
    v_days := _cal_days_until(v_app_start, v_today);
    IF v_days > 0 THEN
      v_j := _slack_item_json('dual', r.company_id, r.company_name, r.id, r.employee_name,
        format('申請可能まで (%s)', r.support_course), v_deadline, v_days, 'until_start', v_base);
    ELSE
      v_j := _slack_item_json('dual', r.company_id, r.company_name, r.id, r.employee_name,
        format('支給申請期限 (%s)', r.support_course), v_deadline, _cal_days_until(v_deadline, v_today), 'until_deadline', v_base);
    END IF;
    IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
  END LOOP;

  -- リスキリング
  FOR r IN
    SELECT rs.*, c.name AS company_name FROM reskilling_applications rs JOIN companies c ON c.id = rs.company_id
  LOOP
    IF r.training_start_date IS NOT NULL AND r.plan_submit_date IS NULL AND r.status = '未申請'
       AND NOT r.status = ANY(ARRAY['支給申請済','承認済','不承認']) THEN
      v_deadline := _add_months(r.training_start_date, -1);
      v_j := _slack_item_json('reskill', r.company_id, r.company_name, r.id, r.training_name, '計画届提出期限', v_deadline, _cal_days_until(v_deadline, v_today), NULL, v_base);
      IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
    END IF;
    IF coalesce(r.exam_date, r.training_end_date) IS NOT NULL AND NOT r.status = ANY(ARRAY['支給申請済','承認済','不承認']) THEN
      v_sup := _add_days(_add_months(_add_days(coalesce(r.exam_date, r.training_end_date), 1), 2), -1);
      v_j := _slack_item_json('reskill', r.company_id, r.company_name, r.id, r.training_name,
        CASE WHEN r.exam_date IS NOT NULL THEN '支給申請期限（受験日起算）' ELSE '支給申請期限（訓練終了日起算）' END,
        v_sup, _cal_days_until(v_sup, v_today), NULL, v_base);
      IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
    END IF;
    IF r.training_end_date IS NULL AND r.status = ANY(ARRAY['未申請','計画届提出済']) AND NOT r.status = ANY(ARRAY['支給申請済','承認済','不承認']) THEN
      v_deadline := _prog_deadline('reskill', 'program_end');
      v_j := _slack_item_json('reskill', r.company_id, r.company_name, r.id, r.training_name, '制度終了（令和8年度末）', v_deadline, _cal_days_until(v_deadline, v_today), NULL, v_base);
      IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
    END IF;
  END LOOP;

  -- 65歳超
  FOR r IN
    SELECT o.*, c.name AS company_name FROM over65_applications o JOIN companies c ON c.id = o.company_id
  LOOP
    IF r.implementation_date IS NULL OR r.status = ANY(ARRAY['支給申請済','承認済','不承認']) THEN CONTINUE; END IF;
    v_deadline := make_date(extract(year from _add_months(date_trunc('month', r.implementation_date)::date, 4))::int,
      extract(month from _add_months(date_trunc('month', r.implementation_date)::date, 4))::int, 15);
    v_j := _slack_item_json('over65', r.company_id, r.company_name, r.id, r.target_name,
      format('支給申請期限（%s）', r.course_type), v_deadline, _cal_days_until(v_deadline, v_today), NULL, v_base);
    IF v_j IS NOT NULL THEN v_items := v_items || jsonb_build_array(v_j); END IF;
  END LOOP;

  RETURN v_items;
END;
$$;

-- ---- 送信処理 ----
-- _slack_deadline_label / _slack_deadline_summary / _slack_dispatch_items は
-- supabase_patch_admin_session_auth.sql で定義（申請期間まで / 期間切れ 表示）。
-- このパッチ適用後、必ず admin_session_auth を再実行してください。

-- 毎日自動実行（pg_cron）
CREATE OR REPLACE FUNCTION slack_daily_notify_cron()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_settings slack_settings%ROWTYPE;
  v_items jsonb;
  v_result jsonb;
BEGIN
  SELECT * INTO v_settings FROM slack_settings WHERE id = 1;
  IF NOT FOUND OR NOT v_settings.enabled OR NOT coalesce(v_settings.cron_enabled, true) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'disabled');
  END IF;
  v_items := _slack_build_notify_items();
  v_result := _slack_dispatch_items(v_items, false);
  UPDATE slack_settings SET last_cron_run_at = now(), updated_at = now() WHERE id = 1;
  RETURN v_result || jsonb_build_object('source', 'cron');
END;
$$;

-- pg_cron 登録（JST 9:00 = UTC 0:00）
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'slack-daily-notify') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'slack-daily-notify' LIMIT 1));
  END IF;
END $$;

SELECT cron.schedule(
  'slack-daily-notify',
  '0 0 * * *',
  $$SELECT public.slack_daily_notify_cron();$$
);
