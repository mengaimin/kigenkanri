-- 管理者操作: パスワード再入力なし（ログイン中の管理者 login_id で権限確認）
-- アカウント管理・Slack 通知設定用 RPC を更新（何度実行しても OK）
-- Supabase SQL Editor で Run

CREATE OR REPLACE FUNCTION _is_admin(p_login_id text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM staff_members sm
    WHERE sm.login_id = lower(trim(p_login_id))
      AND sm.role = 'admin'
      AND sm.is_active = true
  );
$$;

CREATE OR REPLACE FUNCTION _require_admin(p_login_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT _is_admin(p_login_id) THEN
    RAISE EXCEPTION '権限がありません（管理者でログインしてください）';
  END IF;
END;
$$;

-- === アカウント管理 ===

DROP FUNCTION IF EXISTS staff_list_accounts(text, text);
DROP FUNCTION IF EXISTS staff_list_accounts(text);
CREATE OR REPLACE FUNCTION staff_list_accounts(p_admin_login_id text)
RETURNS TABLE(id uuid, name text, login_id text, role text, is_active boolean, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public, extensions
AS $$
BEGIN
  PERFORM _require_admin(p_admin_login_id);
  RETURN QUERY
    SELECT sm.id, sm.name, sm.login_id, sm.role, sm.is_active, sm.created_at
    FROM staff_members sm
    ORDER BY sm.role DESC, sm.login_id;
END;
$$;
GRANT EXECUTE ON FUNCTION staff_list_accounts(text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_create_account(text, text, text, text, text);
DROP FUNCTION IF EXISTS staff_create_account(text, text, text, text, text, text);
DROP FUNCTION IF EXISTS staff_create_account(text, text, text, text, text);
CREATE OR REPLACE FUNCTION staff_create_account(
  p_admin_login_id text,
  p_name text,
  p_new_login_id text,
  p_new_password text,
  p_role text DEFAULT 'staff'
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  new_id uuid;
  lid text := lower(trim(p_new_login_id));
  r text := lower(trim(coalesce(p_role, 'staff')));
BEGIN
  PERFORM _require_admin(p_admin_login_id);
  IF r NOT IN ('admin', 'staff') THEN RAISE EXCEPTION '権限の種別が不正です'; END IF;
  IF length(lid) < 3 THEN RAISE EXCEPTION 'ログインIDは3文字以上にしてください'; END IF;
  IF length(p_new_password) < 8 THEN RAISE EXCEPTION 'パスワードは8文字以上にしてください'; END IF;
  IF lid = 'admin' THEN RAISE EXCEPTION 'このログインIDは使用できません'; END IF;
  INSERT INTO staff_members (name, login_id, password_hash, role)
  VALUES (trim(p_name), lid, extensions.crypt(p_new_password, extensions.gen_salt('bf')), r)
  RETURNING staff_members.id INTO new_id;
  RETURN new_id;
END;
$$;
GRANT EXECUTE ON FUNCTION staff_create_account(text, text, text, text, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_set_account_role(text, text, text, text);
DROP FUNCTION IF EXISTS staff_set_account_role(text, text, text);
CREATE OR REPLACE FUNCTION staff_set_account_role(
  p_admin_login_id text,
  p_target_login_id text,
  p_role text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  lid text := lower(trim(p_target_login_id));
  r text := lower(trim(p_role));
BEGIN
  PERFORM _require_admin(p_admin_login_id);
  IF r NOT IN ('admin', 'staff') THEN RAISE EXCEPTION '権限の種別が不正です'; END IF;
  IF lid = 'admin' THEN RAISE EXCEPTION '初期管理者の権限は変更できません'; END IF;
  UPDATE staff_members SET role = r WHERE login_id = lid;
  RETURN FOUND;
END;
$$;
GRANT EXECUTE ON FUNCTION staff_set_account_role(text, text, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_delete_account(text, text, text);
DROP FUNCTION IF EXISTS staff_delete_account(text, text);
CREATE OR REPLACE FUNCTION staff_delete_account(
  p_admin_login_id text,
  p_target_login_id text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
BEGIN
  PERFORM _require_admin(p_admin_login_id);
  IF lower(trim(p_target_login_id)) = 'admin' THEN
    RAISE EXCEPTION '初期管理者（admin）は削除できません';
  END IF;
  DELETE FROM staff_members WHERE login_id = lower(trim(p_target_login_id));
  RETURN FOUND;
END;
$$;
GRANT EXECUTE ON FUNCTION staff_delete_account(text, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_admin_reset_password(text, text, text, text);
DROP FUNCTION IF EXISTS staff_admin_reset_password(text, text, text);
CREATE OR REPLACE FUNCTION staff_admin_reset_password(
  p_admin_login_id text,
  p_target_login_id text,
  p_new_password text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  lid text := lower(trim(p_target_login_id));
BEGIN
  PERFORM _require_admin(p_admin_login_id);
  IF length(p_new_password) < 8 THEN RAISE EXCEPTION '新しいパスワードは8文字以上にしてください'; END IF;
  IF NOT EXISTS (SELECT 1 FROM staff_members WHERE login_id = lid AND is_active = true) THEN
    RAISE EXCEPTION '対象アカウントが見つかりません';
  END IF;
  UPDATE staff_members
  SET password_hash = extensions.crypt(p_new_password, extensions.gen_salt('bf'))
  WHERE login_id = lid AND is_active = true;
  RETURN FOUND;
END;
$$;
GRANT EXECUTE ON FUNCTION staff_admin_reset_password(text, text, text) TO anon, authenticated;

-- === Slack 通知 ===

CREATE OR REPLACE FUNCTION _slack_case_link(
  p_base text, p_company_id uuid, p_type text, p_app_id uuid
) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT rtrim(p_base, '/') || '#company/' || p_company_id::text
    || '/status?section=' || p_type || '&app=' || p_app_id::text;
$$;

CREATE OR REPLACE FUNCTION _slack_escape_mrkdwn(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_text IS NULL OR p_text = '' THEN ''
    ELSE replace(replace(replace(replace(p_text, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '|', '｜')
  END;
$$;

CREATE OR REPLACE FUNCTION _slack_deadline_label(p_cal_days int, p_biz_days int)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_cal_days IS NULL THEN '⚪ 期限'
    WHEN p_cal_days < 0 THEN format('🔴 *期間切れ*（%s日超過）', abs(p_cal_days))
    WHEN p_cal_days = 0 THEN '🔴 *本日期限*'
    WHEN p_biz_days IS NOT NULL THEN format('🟡 *申請期間まで* 残り%s営業日', p_biz_days)
    ELSE format('🟡 *申請期間まで* 残り%s日', p_cal_days)
  END;
$$;

CREATE OR REPLACE FUNCTION _slack_deadline_summary(p_cal_days int, p_biz_days int)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_cal_days IS NULL THEN '期限'
    WHEN p_cal_days < 0 THEN format('期間切れ（%s日超過）', abs(p_cal_days))
    WHEN p_cal_days = 0 THEN '本日期限'
    WHEN p_biz_days IS NOT NULL THEN format('申請期間まで 残り%s営業日', p_biz_days)
    ELSE format('申請期間まで 残り%s日', p_cal_days)
  END;
$$;

-- 2引数版（daily_cron）→ 4引数版へ更新（サンプル通知・skip_log 対応）
DROP FUNCTION IF EXISTS public._slack_dispatch_items(jsonb, boolean);
DROP FUNCTION IF EXISTS public._slack_dispatch_items(jsonb, boolean, boolean, boolean);

CREATE OR REPLACE FUNCTION _slack_dispatch_items(
  p_items jsonb,
  p_dry_run boolean DEFAULT false,
  p_skip_log boolean DEFAULT false,
  p_test_label boolean DEFAULT false
)
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
  v_cal int;
  v_use_bot boolean;
  v_http_status int;
  v_slack jsonb;
  v_prefix text;
  v_link text;
  v_summary text;
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
  v_prefix := CASE WHEN p_test_label THEN '【テスト】' ELSE '【助成金期限】' END;

  FOR v_item IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  LOOP
    v_cal := (v_item->>'cal_days')::int;
    IF v_cal IS NULL AND v_item->>'deadline_date' ~ '^\d{4}-\d{2}-\d{2}$' THEN
      v_cal := ((v_item->>'deadline_date')::date - _jst_today());
    END IF;
    v_bd := (v_item->>'business_days')::int;
    IF v_bd IS NULL AND v_cal IS NOT NULL AND v_cal > 0 AND v_item->>'deadline_date' ~ '^\d{4}-\d{2}-\d{2}$' THEN
      v_bd := _biz_days_until((v_item->>'deadline_date')::date, _jst_today());
    END IF;
    IF NOT p_test_label THEN
      IF v_cal IS NULL THEN CONTINUE; END IF;
      IF v_cal < -7 THEN CONTINUE; END IF;
      IF v_cal < 0 THEN
        NULL;
      ELSIF v_cal = 0 THEN
        NULL;
      ELSIF v_bd IS NOT NULL AND v_bd <= v_threshold THEN
        NULL;
      ELSIF v_bd IS NULL AND v_cal <= v_threshold THEN
        NULL;
      ELSE
        CONTINUE;
      END IF;
    END IF;
    IF p_test_label AND v_cal IS NULL AND v_bd IS NULL THEN
      v_cal := v_threshold;
      v_bd := v_threshold;
    END IF;
    v_candidates := v_candidates + 1;
    v_dedupe := format('%s:%s:%s:%s:%s', v_item->>'subsidy_type', v_item->>'application_id', v_item->>'kind', v_item->>'deadline_date', v_threshold);
    IF NOT p_skip_log AND NOT coalesce(p_dry_run, false) THEN
      SELECT id INTO v_exists FROM slack_notification_log WHERE dedupe_key = v_dedupe LIMIT 1;
      IF v_exists IS NOT NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;
    END IF;

    v_type_label := CASE v_item->>'subsidy_type'
      WHEN 'career_up' THEN 'キャリアアップ' WHEN 'biz' THEN '業務改善' WHEN 'work' THEN '働き方改革'
      WHEN 'dual' THEN '両立支援' WHEN 'reskill' THEN 'リスキリング' WHEN 'over65' THEN '65歳超'
      ELSE coalesce(v_item->>'subsidy_type', '') END;
    v_target := nullif(trim(v_item->>'target'), '');
    v_summary := _slack_deadline_summary(v_cal, v_bd);
    v_text := format(E'%s\n%s | %s%s\n%s: %s', _slack_deadline_label(v_cal, v_bd), v_type_label,
      _slack_escape_mrkdwn(v_item->>'company_name'),
      CASE WHEN v_target IS NOT NULL THEN E'\n対象: ' || _slack_escape_mrkdwn(v_target) ELSE '' END,
      _slack_escape_mrkdwn(v_item->>'kind'), replace(v_item->>'deadline_date', '-', '/'));
    IF v_cal IS NOT NULL AND v_cal >= 0 AND v_bd IS NOT NULL THEN
      v_text := v_text || format(E'\n_暦日: あと%s日_', v_cal);
    END IF;
    IF p_test_label THEN
      v_text := E'*📋 通知サンプル（テスト送信）*\n' || v_text;
    END IF;
    v_link := coalesce(nullif(trim(v_item->>'link'), ''), nullif(trim(v_settings.app_base_url), ''));
    IF v_link IS NOT NULL AND v_link !~* '^https?://' THEN
      v_link := 'https://' || ltrim(v_link, '/');
    END IF;
    IF v_link IS NOT NULL AND v_link ~* '^(https?://)(localhost|127\.0\.0\.1|\[::1\])([:/]|$)' THEN
      v_link := NULL;
    END IF;
    IF v_link IS NOT NULL THEN
      v_payload := jsonb_build_object('text', format('%s%s — %s', v_prefix, v_item->>'company_name', v_summary),
        'blocks', jsonb_build_array(
          jsonb_build_object('type', 'section', 'text', jsonb_build_object('type', 'mrkdwn', 'text', v_text)),
          jsonb_build_object('type', 'actions', 'elements', jsonb_build_array(
            jsonb_build_object('type', 'button',
              'text', jsonb_build_object('type', 'plain_text', 'text', '📋 案件を開く', 'emoji', true),
              'url', v_link
            )
          ))
        ));
    ELSE
      v_text := v_text || E'\n_（システムURLが未設定のためリンクなし）_';
      v_payload := jsonb_build_object('text', format('%s%s — %s', v_prefix, v_item->>'company_name', v_summary),
        'blocks', jsonb_build_array(
          jsonb_build_object('type', 'section', 'text', jsonb_build_object('type', 'mrkdwn', 'text', v_text))));
    END IF;

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
      IF NOT p_skip_log THEN
        INSERT INTO slack_notification_log (dedupe_key, subsidy_type, application_id, company_id, company_name, kind, deadline_date)
        VALUES (v_dedupe, v_item->>'subsidy_type', nullif(v_item->>'application_id', '')::uuid, nullif(v_item->>'company_id', '')::uuid,
          v_item->>'company_name', v_item->>'kind', (v_item->>'deadline_date')::date);
      END IF;
    END IF;
    v_sent := v_sent || jsonb_build_array(format('%s %s %s', v_type_label, v_item->>'company_name', v_item->>'kind'));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'dry_run', coalesce(p_dry_run, false), 'test', p_test_label,
    'threshold', v_threshold, 'candidates', v_candidates,
    'sent_count', jsonb_array_length(v_sent), 'skipped_count', v_skipped, 'sent', v_sent);
END;
$$;

DROP FUNCTION IF EXISTS staff_get_slack_settings(text, text);
DROP FUNCTION IF EXISTS staff_get_slack_settings(text);
CREATE OR REPLACE FUNCTION staff_get_slack_settings(p_admin_login_id text)
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
  PERFORM _require_admin(p_admin_login_id);
  RETURN QUERY
  SELECT s.enabled,
    CASE WHEN s.webhook_url IS NULL OR length(s.webhook_url) < 8 THEN NULL ELSE '****' || right(s.webhook_url, 4) END,
    CASE WHEN s.bot_token IS NULL OR length(s.bot_token) < 8 THEN NULL ELSE 'xoxb-****' || right(s.bot_token, 4) END,
    s.channel_id, s.app_base_url, s.notify_business_days,
    coalesce(s.cron_enabled, true), s.last_cron_run_at, s.updated_at
  FROM slack_settings s WHERE s.id = 1;
END;
$$;
GRANT EXECUTE ON FUNCTION staff_get_slack_settings(text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_save_slack_settings(text, text, boolean, text, text, int, text, text);
DROP FUNCTION IF EXISTS staff_save_slack_settings(text, text, boolean, text, text, int, text, text, boolean);
DROP FUNCTION IF EXISTS staff_save_slack_settings(text, boolean, text, text, int, text, text, boolean);
CREATE OR REPLACE FUNCTION staff_save_slack_settings(
  p_admin_login_id text,
  p_enabled boolean,
  p_webhook_url text,
  p_app_base_url text,
  p_notify_business_days int DEFAULT 10,
  p_bot_token text DEFAULT NULL,
  p_channel_id text DEFAULT NULL,
  p_cron_enabled boolean DEFAULT true
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  cur_webhook text;
  cur_bot text;
  v_new_bot text;
  v_in text;
BEGIN
  PERFORM _require_admin(p_admin_login_id);
  IF p_notify_business_days IS NULL OR p_notify_business_days < 1 OR p_notify_business_days > 60 THEN
    RAISE EXCEPTION '通知営業日数は1〜60の範囲で指定してください';
  END IF;
  v_in := _normalize_slack_bot_token(p_bot_token);
  IF v_in IS NOT NULL AND NOT coalesce(p_bot_token, '') LIKE 'xoxb-****%' THEN
    IF v_in LIKE 'xoxp-%' THEN
      RAISE EXCEPTION 'User OAuth Token（xoxp-）ではなく Bot User OAuth Token（xoxb-）を貼り付けてください';
    END IF;
    IF NOT v_in LIKE 'xoxb-%' THEN
      RAISE EXCEPTION 'Bot トークンは xoxb- で始まる Bot User OAuth Token です';
    END IF;
    IF length(v_in) < 50 THEN
      RAISE EXCEPTION 'Bot トークンが短すぎます。Slack の Bot User OAuth Token を全文コピーしてください';
    END IF;
  END IF;
  SELECT webhook_url, bot_token INTO cur_webhook, cur_bot FROM slack_settings WHERE id = 1;
  v_new_bot := CASE
    WHEN p_bot_token IS NULL OR trim(p_bot_token) = '' THEN cur_bot
    WHEN p_bot_token LIKE 'xoxb-****%' THEN cur_bot
    ELSE v_in END;
  UPDATE slack_settings SET
    enabled = coalesce(p_enabled, false),
    webhook_url = CASE
      WHEN p_webhook_url IS NULL OR trim(p_webhook_url) = '' THEN cur_webhook
      WHEN p_webhook_url LIKE '****%' THEN cur_webhook
      ELSE trim(p_webhook_url) END,
    bot_token = v_new_bot,
    channel_id = nullif(trim(p_channel_id), ''),
    app_base_url = nullif(trim(p_app_base_url), ''),
    notify_business_days = p_notify_business_days,
    cron_enabled = coalesce(p_cron_enabled, true),
    updated_at = now()
  WHERE id = 1;
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION staff_save_slack_settings(text, boolean, text, text, int, text, text, boolean) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_run_slack_notify(text, text, boolean, jsonb);
DROP FUNCTION IF EXISTS staff_run_slack_notify(text, boolean, jsonb);
CREATE OR REPLACE FUNCTION staff_run_slack_notify(
  p_admin_login_id text,
  p_dry_run boolean DEFAULT true,
  p_items jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
BEGIN
  PERFORM _require_admin(p_admin_login_id);
  RETURN _slack_dispatch_items(p_items, coalesce(p_dry_run, true), false, false);
END;
$$;
GRANT EXECUTE ON FUNCTION staff_run_slack_notify(text, boolean, jsonb) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_test_slack_ping(text, text);
DROP FUNCTION IF EXISTS staff_test_slack_ping(text, text, text, text);
DROP FUNCTION IF EXISTS staff_test_slack_ping(text, text, text);
CREATE OR REPLACE FUNCTION staff_test_slack_ping(
  p_admin_login_id text,
  p_bot_token text DEFAULT NULL,
  p_channel_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_settings slack_settings%ROWTYPE;
  v_http_status int;
  v_slack jsonb;
  v_token text;
  v_channel text;
  v_use_bot boolean;
BEGIN
  PERFORM _require_admin(p_admin_login_id);
  SELECT * INTO v_settings FROM slack_settings WHERE id = 1;
  v_token := coalesce(_normalize_slack_bot_token(p_bot_token), _normalize_slack_bot_token(v_settings.bot_token));
  v_channel := coalesce(nullif(trim(p_channel_id), ''), nullif(trim(v_settings.channel_id), ''));
  v_use_bot := v_token IS NOT NULL AND v_token <> '' AND v_channel IS NOT NULL;
  IF NOT v_use_bot AND (v_settings.webhook_url IS NULL OR trim(v_settings.webhook_url) = '') THEN
    RAISE EXCEPTION 'Bot トークン（xoxb-）とチャンネル ID（C...）を入力してください';
  END IF;
  IF v_use_bot THEN
    IF NOT v_token LIKE 'xoxb-%' THEN
      RAISE EXCEPTION 'Bot トークンは xoxb- で始まる必要があります（現在: %）', left(v_token, 12);
    END IF;
    SELECT r.status, r.content::jsonb INTO v_http_status, v_slack
    FROM extensions.http(('POST', 'https://slack.com/api/auth.test',
      ARRAY[extensions.http_header('Authorization', 'Bearer ' || v_token)],
      'application/json', '{}')::extensions.http_request) AS r;
    IF NOT coalesce((v_slack->>'ok')::boolean, false) THEN
      RAISE EXCEPTION 'Slack トークン無効（%）: Bot User OAuth Token（xoxb-）を再コピーしてください',
        coalesce(v_slack->>'error', v_slack::text);
    END IF;
    SELECT r.status, r.content::jsonb INTO v_http_status, v_slack
    FROM extensions.http(('POST', 'https://slack.com/api/chat.postMessage',
      ARRAY[extensions.http_header('Authorization', 'Bearer ' || v_token)],
      'application/json', jsonb_build_object(
        'channel', v_channel,
        'text', '【助成金期限】接続テスト — このメッセージが届けば設定OKです'
      )::text)::extensions.http_request) AS r;
    IF NOT coalesce((v_slack->>'ok')::boolean, false) THEN
      IF v_slack->>'error' = 'not_in_channel' THEN
        RAISE EXCEPTION 'Slack: ボットがチャンネルに参加していません。/invite @アプリ名 を実行してください';
      END IF;
      RAISE EXCEPTION 'Slack エラー: %', coalesce(v_slack->>'error', v_slack::text);
    END IF;
  ELSE
    SELECT r.status, r.content::jsonb INTO v_http_status, v_slack
    FROM extensions.http(('POST', v_settings.webhook_url, ARRAY[]::extensions.http_header[],
      'application/json', '{"text":"【助成金期限】接続テスト — このメッセージが届けば設定OKです"}')::extensions.http_request) AS r;
  END IF;
  RETURN jsonb_build_object('ok', true, 'http_status', v_http_status, 'slack', v_slack);
END;
$$;
GRANT EXECUTE ON FUNCTION staff_test_slack_ping(text, text, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_test_slack_sample_notify(text, text, jsonb);
DROP FUNCTION IF EXISTS staff_test_slack_sample_notify(text, jsonb);
CREATE OR REPLACE FUNCTION staff_test_slack_sample_notify(
  p_admin_login_id text,
  p_items jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
BEGIN
  PERFORM _require_admin(p_admin_login_id);
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION '通知サンプルのデータがありません';
  END IF;
  RETURN _slack_dispatch_items(p_items, false, true, true);
END;
$$;
GRANT EXECUTE ON FUNCTION staff_test_slack_sample_notify(text, jsonb) TO anon, authenticated;

-- 毎日自動通知も 4引数版 dispatch を使う
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
  v_result := _slack_dispatch_items(v_items, false, false, false);
  UPDATE slack_settings SET last_cron_run_at = now(), updated_at = now() WHERE id = 1;
  RETURN v_result || jsonb_build_object('source', 'cron');
END;
$$;
