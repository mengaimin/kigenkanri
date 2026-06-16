import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  buildDeadlineItems,
  businessDaysUntil,
  fmtDate,
  toDateKey,
  todayJST,
  TYPE_LABEL,
  type DeadlineItem,
} from "./deadline-calc.ts";

const TYPE_LABEL_PLAIN: Record<string, string> = {
  career_up: "キャリアアップ",
  biz: "業務改善",
  work: "働き方改革",
  dual: "両立支援",
  reskill: "リスキリング",
  over65: "65歳超",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function verifyAdmin(
  supabase: ReturnType<typeof createClient>,
  loginId?: string,
  password?: string,
): Promise<boolean> {
  if (!loginId || !password) return false;
  const { data, error } = await supabase.rpc("staff_login", {
    p_login_id: loginId,
    p_password: password,
  });
  if (error || !data?.length) return false;
  return data[0].role === "admin";
}

function buildCaseUrl(baseUrl: string, item: DeadlineItem): string {
  const base = baseUrl.replace(/\/$/, "");
  const params = new URLSearchParams({
    section: item.type,
    app: item.appId,
  });
  return `${base}#company/${item.companyId}/status?${params.toString()}`;
}

async function postSlack(
  webhookUrl: string,
  item: DeadlineItem,
  link: string,
  businessDays: number,
  threshold: number,
) {
  const target = item.target ? `\n対象: ${item.target}` : "";
  const text =
    `*🟡 残り${businessDays}営業日*（${threshold}営業日以内で通知）\n` +
    `${TYPE_LABEL[item.type] || item.type} | ${item.companyName}${target}\n` +
    `${item.kind}: ${fmtDate(item.deadline)}`;

  const payload = {
    text: `【助成金期限】${item.companyName} — 残り${businessDays}営業日`,
    blocks: [
      {
        type: "section",
        text: { type: "mrkdwn", text },
      },
      {
        type: "actions",
        elements: [
          {
            type: "button",
            text: { type: "plain_text", text: "📋 案件を開く", emoji: true },
            url: link,
            style: "primary",
          },
        ],
      },
    ],
  };

  const res = await fetch(webhookUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Slack webhook failed: ${res.status} ${body}`);
  }
}

function shouldNotify(item: DeadlineItem, threshold: number, today: Date): boolean {
  if (item.days === null || item.days < 0) return false;
  if (item.daysPhase === "until_start") return false;
  const bd = businessDaysUntil(item.deadline, today);
  return bd !== null && bd <= threshold;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, content-type",
      },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, serviceKey);

  let body: { admin_login_id?: string; admin_password?: string; dry_run?: boolean } = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }

  const auth = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
  const isService = auth === serviceKey;
  const isAdmin = isService || await verifyAdmin(supabase, body.admin_login_id, body.admin_password);

  if (!isAdmin) {
    return json({ error: "Unauthorized" }, 401);
  }

  const { data: settings, error: settingsErr } = await supabase
    .from("slack_settings")
    .select("*")
    .eq("id", 1)
    .single();

  if (settingsErr) {
    return json({ error: settingsErr.message }, 500);
  }

  if (!settings?.enabled) {
    return json({ ok: true, skipped: "notifications disabled" });
  }
  if (!settings.webhook_url) {
    return json({ error: "Webhook URL が未設定です" }, 400);
  }
  if (!settings.app_base_url) {
    return json({ error: "システムURL（app_base_url）が未設定です" }, 400);
  }

  const threshold = settings.notify_business_days ?? 10;
  const today = todayJST();

  const [cu, bi, ws, ds, rs, o65, dl] = await Promise.all([
    supabase.from("career_up_applications").select("*,company:companies(id,name)"),
    supabase.from("business_improvement_applications").select("*,company:companies(id,name)"),
    supabase.from("work_style_applications").select("*,company:companies(id,name)"),
    supabase.from("dual_support_applications").select("*,company:companies(id,name)"),
    supabase.from("reskilling_applications").select("*,company:companies(id,name)"),
    supabase.from("over65_applications").select("*,company:companies(id,name)"),
    supabase.from("program_deadlines").select("subsidy_type,deadline_key,deadline_date"),
  ]);

  for (const r of [cu, bi, ws, ds, rs, o65, dl]) {
    if (r.error) return json({ error: r.error.message }, 500);
  }

  const items = buildDeadlineItems({
    careerUp: cu.data || [],
    biz: bi.data || [],
    work: ws.data || [],
    dual: ds.data || [],
    reskill: rs.data || [],
    over65: o65.data || [],
    deadlineRows: dl.data || [],
  }, today);

  const candidates = items.filter((it) => shouldNotify(it, threshold, today));
  const sent: string[] = [];
  const skipped: string[] = [];

  for (const item of candidates) {
    const dateKey = toDateKey(item.deadline);
    const dedupeKey = `${item.type}:${item.appId}:${item.kind}:${dateKey}:${threshold}`;

    const { data: existing } = await supabase
      .from("slack_notification_log")
      .select("id")
      .eq("dedupe_key", dedupeKey)
      .maybeSingle();

    if (existing) {
      skipped.push(dedupeKey);
      continue;
    }

    const link = buildCaseUrl(settings.app_base_url, item);
    const bd = businessDaysUntil(item.deadline, today)!;

    if (!body.dry_run) {
      await postSlack(settings.webhook_url, item, link, bd, threshold);
      await supabase.from("slack_notification_log").insert({
        dedupe_key: dedupeKey,
        subsidy_type: item.type,
        application_id: item.appId,
        company_id: item.companyId,
        company_name: item.companyName,
        kind: item.kind,
        deadline_date: dateKey,
      });
    }
    sent.push(`${TYPE_LABEL_PLAIN[item.type] || item.type} ${item.companyName} ${item.kind}`);
  }

  return json({
    ok: true,
    dry_run: !!body.dry_run,
    threshold,
    candidates: candidates.length,
    sent_count: sent.length,
    skipped_count: skipped.length,
    sent,
  });
});
