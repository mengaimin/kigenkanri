-- invalid_auth 対策: トークン正規化 + フォーム入力で即テスト + auth.test

CREATE OR REPLACE FUNCTION _normalize_slack_bot_token(p_token text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_token IS NULL OR trim(p_token) = '' THEN NULL
    ELSE trim(regexp_replace(
      CASE WHEN trim(p_token) ILIKE 'bearer %' THEN trim(substring(trim(p_token) from 8)) ELSE trim(p_token) END,
      E'[\\n\\r\\t ]', '', 'g'
    ))
  END;
$$;

CREATE OR REPLACE FUNCTION staff_save_slack_settings(
  p_admin_login_id text,
  p_admin_password text,
  p_enabled boolean,
  p_webhook_url text,
  p_app_base_url text,
  p_notify_business_days int DEFAULT 10,
  p_bot_token text DEFAULT NULL,
  p_channel_id text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  cur_webhook text;
  cur_bot text;
  v_new_bot text;
  v_in text;
BEGIN
  IF NOT _verify_admin(p_admin_login_id, p_admin_password) THEN
    RAISE EXCEPTION '権限がありません';
  END IF;
  IF p_notify_business_days IS NULL OR p_notify_business_days < 1 OR p_notify_business_days > 60 THEN
    RAISE EXCEPTION '通知営業日数は1〜60の範囲で指定してください';
  END IF;

  v_in := _normalize_slack_bot_token(p_bot_token);
  IF v_in IS NOT NULL AND NOT p_bot_token LIKE 'xoxb-****%' THEN
    IF v_in LIKE 'xoxp-%' THEN
      RAISE EXCEPTION 'User OAuth Token（xoxp-）ではなく Bot User OAuth Token（xoxb-）を貼り付けてください';
    END IF;
    IF NOT v_in LIKE 'xoxb-%' THEN
      RAISE EXCEPTION 'Bot トークンは xoxb- で始まる Bot User OAuth Token です（Signing Secret 等は不可）';
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
    updated_at = now()
  WHERE id = 1;
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION staff_save_slack_settings(text, text, boolean, text, text, int, text, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_test_slack_ping(text, text);
DROP FUNCTION IF EXISTS staff_test_slack_ping(text, text, text, text);
CREATE FUNCTION staff_test_slack_ping(
  p_admin_login_id text,
  p_admin_password text,
  p_bot_token text DEFAULT NULL,
  p_channel_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_settings slack_settings%ROWTYPE;
  v_http_status int;
  v_slack jsonb;
  v_token text;
  v_channel text;
  v_use_bot boolean;
BEGIN
  IF NOT _verify_admin(p_admin_login_id, p_admin_password) THEN
    RAISE EXCEPTION '権限がありません';
  END IF;

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

    -- 1) auth.test でトークン自体を検証
    SELECT r.status, r.content::jsonb INTO v_http_status, v_slack
    FROM extensions.http((
      'POST',
      'https://slack.com/api/auth.test',
      ARRAY[extensions.http_header('Authorization', 'Bearer ' || v_token)],
      'application/json',
      '{}'
    )::extensions.http_request) AS r;

    IF NOT coalesce((v_slack->>'ok')::boolean, false) THEN
      RAISE EXCEPTION 'Slack トークン無効（%）: OAuth & Permissions の Bot User OAuth Token（xoxb-）を再コピーしてください。User Token（xoxp-）や Signing Secret は使えません',
        coalesce(v_slack->>'error', v_slack::text);
    END IF;

    -- 2) メッセージ送信
    SELECT r.status, r.content::jsonb INTO v_http_status, v_slack
    FROM extensions.http((
      'POST',
      'https://slack.com/api/chat.postMessage',
      ARRAY[extensions.http_header('Authorization', 'Bearer ' || v_token)],
      'application/json',
      jsonb_build_object(
        'channel', v_channel,
        'text', '【助成金期限】接続テスト — このメッセージが届けば設定OKです'
      )::text
    )::extensions.http_request) AS r;

    IF NOT coalesce((v_slack->>'ok')::boolean, false) THEN
      IF v_slack->>'error' = 'not_in_channel' THEN
        RAISE EXCEPTION 'Slack: ボットがチャンネルに参加していません。期間管理通知チャンネルで /invite @アプリ名 を実行してください';
      END IF;
      IF v_slack->>'error' = 'channel_not_found' THEN
        RAISE EXCEPTION 'Slack: チャンネル ID が見つかりません（%）。C で始まる ID を確認してください', v_channel;
      END IF;
      RAISE EXCEPTION 'Slack エラー: %', coalesce(v_slack->>'error', v_slack::text);
    END IF;
  ELSE
    SELECT r.status, r.content::jsonb INTO v_http_status, v_slack
    FROM extensions.http((
      'POST',
      v_settings.webhook_url,
      ARRAY[]::extensions.http_header[],
      'application/json',
      '{"text":"【助成金期限】接続テスト — このメッセージが届けば設定OKです"}'
    )::extensions.http_request) AS r;
  END IF;

  RETURN jsonb_build_object('ok', true, 'http_status', v_http_status, 'slack', v_slack);
END;
$$;

GRANT EXECUTE ON FUNCTION staff_test_slack_ping(text, text, text, text) TO anon, authenticated;
