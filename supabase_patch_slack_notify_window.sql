-- 通知条件を「ちょうどN営業日」→「N営業日以内（未送信）」に修正
-- 既に staff_run_slack_notify を作成済みの場合、このファイルだけ SQL Editor で Run

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
  v_bd int;
BEGIN
  IF NOT _verify_admin(p_admin_login_id, p_admin_password) THEN
    RAISE EXCEPTION '権限がありません';
  END IF;

  SELECT * INTO v_settings FROM slack_settings WHERE id = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Slack 設定がありません';
  END IF;

  IF NOT v_settings.enabled THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'notifications disabled');
  END IF;
  IF v_settings.webhook_url IS NULL OR trim(v_settings.webhook_url) = '' THEN
    RAISE EXCEPTION 'Webhook URL が未設定です';
  END IF;
  IF v_settings.app_base_url IS NULL OR trim(v_settings.app_base_url) = '' THEN
    RAISE EXCEPTION 'システムURL（app_base_url）が未設定です';
  END IF;

  v_threshold := coalesce(v_settings.notify_business_days, 10);

  FOR v_item IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  LOOP
    v_bd := (v_item->>'business_days')::int;
    IF v_bd IS NULL OR v_bd > v_threshold THEN
      CONTINUE;
    END IF;

    v_candidates := v_candidates + 1;
    v_dedupe := format(
      '%s:%s:%s:%s:%s',
      v_item->>'subsidy_type',
      v_item->>'application_id',
      v_item->>'kind',
      v_item->>'deadline_date',
      v_threshold
    );

    SELECT id INTO v_exists FROM slack_notification_log WHERE dedupe_key = v_dedupe LIMIT 1;
    IF v_exists IS NOT NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_type_label := CASE v_item->>'subsidy_type'
      WHEN 'career_up' THEN 'キャリアアップ'
      WHEN 'biz' THEN '業務改善'
      WHEN 'work' THEN '働き方改革'
      WHEN 'dual' THEN '両立支援'
      WHEN 'reskill' THEN 'リスキリング'
      WHEN 'over65' THEN '65歳超'
      ELSE coalesce(v_item->>'subsidy_type', '')
    END;

    v_target := nullif(trim(v_item->>'target'), '');
    v_text := format(
      E'*🟡 残り%s営業日*（%s営業日以内で通知）\n%s | %s%s\n%s: %s',
      v_bd,
      v_threshold,
      v_type_label,
      v_item->>'company_name',
      CASE WHEN v_target IS NOT NULL THEN E'\n対象: ' || v_target ELSE '' END,
      v_item->>'kind',
      replace(v_item->>'deadline_date', '-', '/')
    );

    v_payload := jsonb_build_object(
      'text', format('【助成金期限】%s — 残り%s営業日', v_item->>'company_name', v_bd),
      'blocks', jsonb_build_array(
        jsonb_build_object('type', 'section', 'text', jsonb_build_object('type', 'mrkdwn', 'text', v_text)),
        jsonb_build_object(
          'type', 'actions',
          'elements', jsonb_build_array(
            jsonb_build_object(
              'type', 'button',
              'text', jsonb_build_object('type', 'plain_text', 'text', '📋 案件を開く', 'emoji', true),
              'url', coalesce(v_item->>'link', v_settings.app_base_url),
              'style', 'primary'
            )
          )
        )
      )
    );

    IF NOT coalesce(p_dry_run, true) THEN
      PERFORM net.http_post(
        url := v_settings.webhook_url,
        headers := jsonb_build_object('Content-Type', 'application/json'),
        body := v_payload
      );
      INSERT INTO slack_notification_log (
        dedupe_key, subsidy_type, application_id, company_id, company_name, kind, deadline_date
      ) VALUES (
        v_dedupe,
        v_item->>'subsidy_type',
        nullif(v_item->>'application_id', '')::uuid,
        nullif(v_item->>'company_id', '')::uuid,
        v_item->>'company_name',
        v_item->>'kind',
        (v_item->>'deadline_date')::date
      );
    END IF;

    v_sent := v_sent || jsonb_build_array(format('%s %s %s', v_type_label, v_item->>'company_name', v_item->>'kind'));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', coalesce(p_dry_run, true),
    'threshold', v_threshold,
    'candidates', v_candidates,
    'sent_count', jsonb_array_length(v_sent),
    'skipped_count', v_skipped,
    'sent', v_sent
  );
END;
$$;

GRANT EXECUTE ON FUNCTION staff_run_slack_notify(text, text, boolean, jsonb) TO anon, authenticated;
