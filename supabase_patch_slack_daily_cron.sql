-- ============================================================
--  Slack 毎日自動通知（pg_cron / JST 9:00）
--  前提: http 拡張有効、supabase_patch_slack_http_sync.sql 実行済み
--  Dashboard → Database → Extensions で pg_cron も有効化
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

CREATE OR REPLACE FUNCTION _slack_item_json(
  p_type text, p_company_id uuid, p_company_name text, p_app_id uuid,
  p_target text, p_kind text, p_deadline date, p_cal_days int, p_days_phase text,
  p_base_url text
) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_deadline IS NULL OR p_cal_days IS NULL OR p_cal_days < 0 OR p_days_phase = 'until_start' THEN NULL
    ELSE jsonb_build_object(
      'subsidy_type', p_type,
      'company_id', p_company_id::text,
      'company_name', p_company_name,
      'application_id', p_app_id::text,
      'target', p_target,
      'kind', p_kind,
      'deadline_date', to_char(p_deadline, 'YYYY-MM-DD'),
      'business_days', _biz_days_until(p_deadline, _jst_today()),
      'link', rtrim(p_base_url, '/') || '#company/' || p_company_id::text || '/status?section=' || p_type || '&app=' || p_app_id::text
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

-- 送信コア（管理者 RPC / cron 共通）
CREATE OR REPLACE FUNCTION _slack_dispatch_items(p_items jsonb, p_dry_run boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_settings slack_settings%ROWTYPE;
  v_threshold int;
  v_item jsonb;
  v_dedupe text;
  v_exists uuid;
  v_sent jsonb := '[]'::jsonb;
  v_skipped int := 0;
  v_candidates int := 0;
  v_type_label text;
  v_target text;
  v_text text;
  v_payload jsonb;
  v_body text;
  v_bd int;
  v_use_bot boolean;
  v_http_status int;
  v_slack jsonb;
BEGIN
  SELECT * INTO v_settings FROM slack_settings WHERE id = 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Slack 設定がありません'; END IF;
  IF NOT v_settings.enabled THEN RETURN jsonb_build_object('ok', true, 'skipped', 'notifications disabled'); END IF;
  IF v_settings.app_base_url IS NULL OR trim(v_settings.app_base_url) = '' THEN
    RAISE EXCEPTION 'システムURL（app_base_url）が未設定です';
  END IF;
  v_use_bot := v_settings.bot_token IS NOT NULL AND trim(v_settings.bot_token) <> ''
    AND v_settings.channel_id IS NOT NULL AND trim(v_settings.channel_id) <> '';
  IF NOT v_use_bot AND (v_settings.webhook_url IS NULL OR trim(v_settings.webhook_url) = '') THEN
    RAISE EXCEPTION 'Bot トークン+チャンネルID、または Webhook URL を設定してください';
  END IF;
  v_threshold := coalesce(v_settings.notify_business_days, 10);

  FOR v_item IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  LOOP
    v_bd := (v_item->>'business_days')::int;
    IF v_bd IS NULL OR v_bd > v_threshold THEN CONTINUE; END IF;
    v_candidates := v_candidates + 1;
    v_dedupe := format('%s:%s:%s:%s:%s', v_item->>'subsidy_type', v_item->>'application_id', v_item->>'kind', v_item->>'deadline_date', v_threshold);
    SELECT id INTO v_exists FROM slack_notification_log WHERE dedupe_key = v_dedupe LIMIT 1;
    IF v_exists IS NOT NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    v_type_label := CASE v_item->>'subsidy_type'
      WHEN 'career_up' THEN 'キャリアアップ' WHEN 'biz' THEN '業務改善' WHEN 'work' THEN '働き方改革'
      WHEN 'dual' THEN '両立支援' WHEN 'reskill' THEN 'リスキリング' WHEN 'over65' THEN '65歳超'
      ELSE coalesce(v_item->>'subsidy_type', '') END;
    v_target := nullif(trim(v_item->>'target'), '');
    v_text := format(E'*🟡 残り%s営業日*（%s営業日以内で通知）\n%s | %s%s\n%s: %s', v_bd, v_threshold, v_type_label, v_item->>'company_name',
      CASE WHEN v_target IS NOT NULL THEN E'\n対象: ' || v_target ELSE '' END, v_item->>'kind', replace(v_item->>'deadline_date', '-', '/'));
    v_payload := jsonb_build_object('text', format('【助成金期限】%s — 残り%s営業日', v_item->>'company_name', v_bd),
      'blocks', jsonb_build_array(
        jsonb_build_object('type', 'section', 'text', jsonb_build_object('type', 'mrkdwn', 'text', v_text)),
        jsonb_build_object('type', 'actions', 'elements', jsonb_build_array(
          jsonb_build_object('type', 'button', 'text', jsonb_build_object('type', 'plain_text', 'text', '📋 案件を開く', 'emoji', true),
            'url', coalesce(v_item->>'link', v_settings.app_base_url), 'style', 'primary')))));

    IF NOT coalesce(p_dry_run, false) THEN
      IF v_use_bot THEN
        v_body := (v_payload || jsonb_build_object('channel', trim(v_settings.channel_id)))::text;
        SELECT r.status, r.content::jsonb INTO v_http_status, v_slack
        FROM extensions.http(('POST', 'https://slack.com/api/chat.postMessage',
          ARRAY[extensions.http_header('Authorization', 'Bearer ' || trim(v_settings.bot_token))],
          'application/json', v_body)::extensions.http_request) AS r;
      ELSE
        SELECT r.status, r.content::jsonb INTO v_http_status, v_slack
        FROM extensions.http(('POST', v_settings.webhook_url, ARRAY[]::extensions.http_header[],
          'application/json', v_payload::text)::extensions.http_request) AS r;
      END IF;
      IF v_use_bot AND NOT coalesce((v_slack->>'ok')::boolean, false) THEN
        RAISE EXCEPTION 'Slack エラー: %', coalesce(v_slack->>'error', v_slack::text);
      END IF;
      INSERT INTO slack_notification_log (dedupe_key, subsidy_type, application_id, company_id, company_name, kind, deadline_date)
      VALUES (v_dedupe, v_item->>'subsidy_type', nullif(v_item->>'application_id', '')::uuid, nullif(v_item->>'company_id', '')::uuid,
        v_item->>'company_name', v_item->>'kind', (v_item->>'deadline_date')::date);
    END IF;
    v_sent := v_sent || jsonb_build_array(format('%s %s %s', v_type_label, v_item->>'company_name', v_item->>'kind'));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'dry_run', coalesce(p_dry_run, false), 'threshold', v_threshold,
    'candidates', v_candidates, 'sent_count', jsonb_array_length(v_sent), 'skipped_count', v_skipped, 'sent', v_sent);
END;
$$;

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

-- staff_run_slack_notify を共通送信に接続
CREATE OR REPLACE FUNCTION staff_run_slack_notify(
  p_admin_login_id text,
  p_admin_password text,
  p_dry_run boolean DEFAULT true,
  p_items jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT _verify_admin(p_admin_login_id, p_admin_password) THEN
    RAISE EXCEPTION '権限がありません';
  END IF;
  RETURN _slack_dispatch_items(p_items, coalesce(p_dry_run, true));
END;
$$;

GRANT EXECUTE ON FUNCTION staff_run_slack_notify(text, text, boolean, jsonb) TO anon, authenticated;

-- 設定 RPC 更新（cron 項目）
DROP FUNCTION IF EXISTS staff_get_slack_settings(text, text);
CREATE FUNCTION staff_get_slack_settings(p_admin_login_id text, p_admin_password text)
RETURNS TABLE(
  enabled boolean,
  webhook_url_masked text,
  bot_token_masked text,
  channel_id text,
  app_base_url text,
  notify_business_days int,
  cron_enabled boolean,
  last_cron_run_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions
AS $$
BEGIN
  IF NOT _verify_admin(p_admin_login_id, p_admin_password) THEN RAISE EXCEPTION '権限がありません'; END IF;
  RETURN QUERY
  SELECT s.enabled,
    CASE WHEN s.webhook_url IS NULL OR length(s.webhook_url) < 8 THEN NULL ELSE '****' || right(s.webhook_url, 4) END,
    CASE WHEN s.bot_token IS NULL OR length(s.bot_token) < 8 THEN NULL ELSE 'xoxb-****' || right(s.bot_token, 4) END,
    s.channel_id, s.app_base_url, s.notify_business_days,
    coalesce(s.cron_enabled, true), s.last_cron_run_at, s.updated_at
  FROM slack_settings s WHERE s.id = 1;
END;
$$;
GRANT EXECUTE ON FUNCTION staff_get_slack_settings(text, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_save_slack_settings(text, text, boolean, text, text, int, text, text);
CREATE FUNCTION staff_save_slack_settings(
  p_admin_login_id text, p_admin_password text, p_enabled boolean,
  p_webhook_url text, p_app_base_url text, p_notify_business_days int DEFAULT 10,
  p_bot_token text DEFAULT NULL, p_channel_id text DEFAULT NULL, p_cron_enabled boolean DEFAULT true
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE cur_webhook text; cur_bot text; v_in text;
BEGIN
  IF NOT _verify_admin(p_admin_login_id, p_admin_password) THEN RAISE EXCEPTION '権限がありません'; END IF;
  v_in := _normalize_slack_bot_token(p_bot_token);
  SELECT webhook_url, bot_token INTO cur_webhook, cur_bot FROM slack_settings WHERE id = 1;
  UPDATE slack_settings SET
    enabled = coalesce(p_enabled, false),
    webhook_url = CASE WHEN p_webhook_url IS NULL OR trim(p_webhook_url) = '' OR p_webhook_url LIKE '****%' THEN cur_webhook ELSE trim(p_webhook_url) END,
    bot_token = CASE WHEN v_in IS NULL OR p_bot_token LIKE 'xoxb-****%' THEN cur_bot ELSE v_in END,
    channel_id = nullif(trim(p_channel_id), ''),
    app_base_url = nullif(trim(p_app_base_url), ''),
    notify_business_days = p_notify_business_days,
    cron_enabled = coalesce(p_cron_enabled, true),
    updated_at = now()
  WHERE id = 1;
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION staff_save_slack_settings(text, text, boolean, text, text, int, text, text, boolean) TO anon, authenticated;

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
