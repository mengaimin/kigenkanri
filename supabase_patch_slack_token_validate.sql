-- Bot トークン検証（xoxb- 必須）+ 保存時の誤入力防止

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
BEGIN
  IF NOT _verify_admin(p_admin_login_id, p_admin_password) THEN
    RAISE EXCEPTION '権限がありません';
  END IF;
  IF p_notify_business_days IS NULL OR p_notify_business_days < 1 OR p_notify_business_days > 60 THEN
    RAISE EXCEPTION '通知営業日数は1〜60の範囲で指定してください';
  END IF;

  IF p_bot_token IS NOT NULL AND trim(p_bot_token) <> '' AND NOT trim(p_bot_token) LIKE 'xoxb-****%' THEN
    IF trim(p_bot_token) LIKE 'xoxp-%' THEN
      RAISE EXCEPTION 'User OAuth Token（xoxp-）ではなく Bot User OAuth Token（xoxb-）を貼り付けてください';
    END IF;
    IF NOT trim(p_bot_token) LIKE 'xoxb-%' THEN
      RAISE EXCEPTION 'Bot トークンは xoxb- で始まる Bot User OAuth Token です';
    END IF;
    IF length(trim(p_bot_token)) < 50 THEN
      RAISE EXCEPTION 'Bot トークンが短すぎます。Slack の Bot User OAuth Token を全文コピーしてください';
    END IF;
  END IF;

  SELECT webhook_url, bot_token INTO cur_webhook, cur_bot FROM slack_settings WHERE id = 1;
  v_new_bot := CASE
    WHEN p_bot_token IS NULL OR trim(p_bot_token) = '' THEN cur_bot
    WHEN p_bot_token LIKE 'xoxb-****%' THEN cur_bot
    ELSE trim(p_bot_token) END;

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
