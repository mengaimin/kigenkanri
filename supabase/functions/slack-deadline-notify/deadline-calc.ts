// 期限計算ロジック（index.html と同期）

export type DeadlineItem = {
  type: string;
  companyId: string;
  companyName: string;
  appId: string;
  target: string | null;
  kind: string;
  deadline: Date;
  days: number | null;
  daysPhase?: string | null;
  status?: string | null;
};

const DEADLINE_DEFAULTS: Record<string, Record<string, string>> = {
  biz: { comp_limit: '2027-01-31', sup_max: '2027-04-10' },
  work: { app_limit: '2026-11-30', comp_limit: '2027-01-31', sup_max: '2027-02-05' },
  reskill: { program_end: '2027-03-31' },
};

const DUAL_MASTER: Record<string, [number, number, number, number]> = {
  '出生時両立支援（第1種）': [0, 1, 2, -1],
  '介護離職防止（休業取得時）': [0, 1, 2, -1],
  '介護離職防止（職場復帰時）': [3, 1, 2, -1],
  '育児休業等支援（育休取得時）': [3, 1, 2, -1],
  '育児休業等支援（職場復帰時）': [6, 1, 2, -1],
  '育休中等業務代替（1ヶ月未満）': [0, 1, 2, -1],
  '育休中等業務代替（1ヶ月以上）': [3, 1, 2, -1],
  '柔軟な働き方選択制度': [6, 1, 2, -1],
  '不妊治療両立支援': [0, 1, 2, -1],
};

export function parseDate(s: string | null | undefined): Date | null {
  if (!s) return null;
  const m = String(s).match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return null;
  return new Date(+m[1], +m[2] - 1, +m[3]);
}

export function todayJST(): Date {
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Tokyo',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
  const [y, m, d] = fmt.format(new Date()).split('-').map(Number);
  return new Date(y, m - 1, d);
}

export function daysFromToday(d: Date | null, today: Date): number | null {
  if (!d) return null;
  const t = new Date(d);
  t.setHours(0, 0, 0, 0);
  const td = new Date(today);
  td.setHours(0, 0, 0, 0);
  return Math.floor((t.getTime() - td.getTime()) / 86400000);
}

/** 今日の翌日〜期限日までの営業日数（土日除外） */
export function businessDaysUntil(deadline: Date | null, today: Date): number | null {
  if (!deadline) return null;
  const t = new Date(today);
  t.setHours(0, 0, 0, 0);
  const e = new Date(deadline);
  e.setHours(0, 0, 0, 0);
  if (e <= t) return null;
  let count = 0;
  const d = new Date(t);
  d.setDate(d.getDate() + 1);
  while (d <= e) {
    const dow = d.getDay();
    if (dow !== 0 && dow !== 6) count++;
    d.setDate(d.getDate() + 1);
  }
  return count;
}

function addMonths(d: Date, m: number): Date {
  const r = new Date(d);
  const day = r.getDate();
  r.setMonth(r.getMonth() + m);
  if (r.getDate() < day) r.setDate(0);
  return r;
}

function addDays(d: Date, n: number): Date {
  const r = new Date(d);
  r.setDate(r.getDate() + n);
  return r;
}

function salaryDateAfter(conv: Date, months: number, pd: number): Date {
  const th = addMonths(conv, months);
  let d = new Date(th.getFullYear(), th.getMonth(), pd);
  if (d < th) d = new Date(th.getFullYear(), th.getMonth() + 1, pd);
  const last = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
  if (pd > last) d = new Date(d.getFullYear(), d.getMonth() + 1, 0);
  return d;
}

type DeadlineRow = { subsidy_type: string; deadline_key: string; deadline_date: string };

function getDeadline(rows: DeadlineRow[], sType: string, key: string): Date | null {
  const row = rows.find(r => r.subsidy_type === sType && r.deadline_key === key);
  return parseDate(row?.deadline_date || DEADLINE_DEFAULTS[sType]?.[key]);
}

function getCuRoundInfo(app: Record<string, unknown>, today: Date) {
  const conv = parseDate(app.conversion_date as string);
  const pd = app.salary_payment_day as number;
  if (!conv || !pd) return null;
  const fp = salaryDateAfter(conv, 6, pd);
  const fs = addDays(fp, 1);
  const fd = addDays(addMonths(fs, 2), -1);
  let sp: Date | null = null, ss: Date | null = null, sd: Date | null = null;
  if (app.is_priority_worker) {
    sp = salaryDateAfter(conv, 12, pd);
    ss = addDays(sp, 1);
    sd = addDays(addMonths(ss, 2), -1);
  }
  const firstComplete = app.status_first === '承認済';
  const round = app.is_priority_worker && firstComplete ? 2 : 1;
  if (round === 1) {
    if (app.status_first === '承認済') return null;
    return { roundLabel: '1回目', deadline: fd, days: daysFromToday(fd, today), status: app.status_first };
  }
  if (app.status_second === '承認済') return null;
  return { roundLabel: '2回目', deadline: sd, days: daysFromToday(sd!, today), status: app.status_second };
}

function calcBiz(app: Record<string, unknown>, rows: DeadlineRow[], today: Date) {
  const compLimit = getDeadline(rows, 'biz', 'comp_limit')!;
  const supMax = getDeadline(rows, 'biz', 'sup_max')!;
  const comp = parseDate(app.completion_date_actual as string);
  const isDone = ['支給申請済', '承認済（助成金受領）'].includes(app.status as string);
  const compDays = comp || isDone ? null : daysFromToday(compLimit, today);
  let supLimit: Date | null = null, supDays: number | null = null;
  if (comp) {
    const om = addMonths(comp, 1);
    supLimit = om < supMax ? om : supMax;
    supDays = isDone ? null : daysFromToday(supLimit, today);
  }
  return { compLimit, compDays, supLimit, supDays };
}

function calcWork(app: Record<string, unknown>, rows: DeadlineRow[], today: Date) {
  const appLimit = getDeadline(rows, 'work', 'app_limit')!;
  const compLimit = getDeadline(rows, 'work', 'comp_limit')!;
  const supMax = getDeadline(rows, 'work', 'sup_max')!;
  const ad = parseDate(app.application_date as string);
  const cd = parseDate(app.completion_date as string);
  const isDone = ['支給申請済', '承認済'].includes(app.status as string);
  const notApp = ['未申請', '交付申請済'].includes(app.status as string);
  const appDays = notApp ? daysFromToday(appLimit, today) : null;
  const compDays = !cd && !isDone ? daysFromToday(compLimit, today) : null;
  let supLimit: Date | null = null, supDays: number | null = null;
  if (cd) {
    const td = addDays(cd, 30);
    supLimit = td < supMax ? td : supMax;
    supDays = isDone ? null : daysFromToday(supLimit, today);
  } else if (ad) {
    supLimit = supMax;
    supDays = isDone ? null : daysFromToday(supLimit, today);
  }
  return { appLimit, appDays, compLimit, compDays, supLimit, supDays };
}

function calcDual(app: Record<string, unknown>, today: Date) {
  const m = DUAL_MASTER[app.support_course as string];
  if (!m) return {};
  const [sm, sd, lm, ld] = m;
  const base = parseDate(app.date2 as string) || parseDate(app.date1 as string);
  if (!base) return {};
  const appStart = addDays(addMonths(base, sm), sd);
  const deadline = addDays(addMonths(appStart, lm), ld);
  const isDone = ['支給申請済', '承認済'].includes(app.status as string);
  if (isDone) return { deadline, days: null, daysPhase: null };
  const untilStart = daysFromToday(appStart, today);
  if (untilStart !== null && untilStart > 0) {
    return { deadline, days: untilStart, daysPhase: 'until_start' };
  }
  return { deadline, days: daysFromToday(deadline, today), daysPhase: 'until_deadline' };
}

function calcReskill(app: Record<string, unknown>, rows: DeadlineRow[], today: Date) {
  const programEnd = getDeadline(rows, 'reskill', 'program_end')!;
  const start = parseDate(app.training_start_date as string);
  const end = parseDate(app.training_end_date as string);
  const exam = parseDate(app.exam_date as string);
  const planSubmitted = !!parseDate(app.plan_submit_date as string);
  const isDone = ['支給申請済', '承認済', '不承認'].includes(app.status as string);
  const planPending = !planSubmitted && app.status === '未申請';
  let planLimit: Date | null = null, planDays: number | null = null;
  if (start && planPending && !isDone) {
    planLimit = addMonths(start, -1);
    planDays = daysFromToday(planLimit, today);
  }
  let supLimit: Date | null = null, supDays: number | null = null;
  const payBase = exam || end;
  if (payBase && !isDone) {
    const supStart = addDays(payBase, 1);
    supLimit = addDays(addMonths(supStart, 2), -1);
    supDays = daysFromToday(supLimit, today);
  }
  const programDays = (!isDone && !end && ['未申請', '計画届提出済'].includes(app.status as string))
    ? daysFromToday(programEnd, today) : null;
  return { planLimit, planDays, supLimit, supDays, programEnd, programDays };
}

function calcOver65(app: Record<string, unknown>, today: Date) {
  const impl = parseDate(app.implementation_date as string);
  const isDone = ['支給申請済', '承認済', '不承認'].includes(app.status as string);
  if (!impl) return { deadline: null, days: null };
  const firstWindow = addMonths(new Date(impl.getFullYear(), impl.getMonth(), 1), 1);
  const lastWindow = addMonths(firstWindow, 3);
  const deadline = new Date(lastWindow.getFullYear(), lastWindow.getMonth(), 15);
  return { deadline, days: isDone ? null : daysFromToday(deadline, today) };
}

function pushItem(
  items: DeadlineItem[],
  partial: Omit<DeadlineItem, 'deadline'> & { deadline: Date | null },
) {
  if (!partial.deadline || partial.days === null || partial.days === undefined) return;
  items.push({ ...partial, deadline: partial.deadline });
}

export function buildDeadlineItems(data: {
  careerUp: Record<string, unknown>[];
  biz: Record<string, unknown>[];
  work: Record<string, unknown>[];
  dual: Record<string, unknown>[];
  reskill: Record<string, unknown>[];
  over65: Record<string, unknown>[];
  deadlineRows: DeadlineRow[];
}, today: Date): DeadlineItem[] {
  const items: DeadlineItem[] = [];
  const rows = data.deadlineRows;

  for (const app of data.careerUp) {
    const co = (app.company as { name?: string })?.name || '';
    const ri = getCuRoundInfo(app, today);
    if (ri?.deadline) {
      pushItem(items, {
        type: 'career_up', companyName: co, companyId: app.company_id as string,
        appId: app.id as string, target: app.employee_name as string,
        kind: `${ri.roundLabel} 申請期限`, deadline: ri.deadline, days: ri.days, status: ri.status as string,
      });
    }
  }

  for (const app of data.biz) {
    const d = calcBiz(app, rows, today);
    const co = (app.company as { name?: string })?.name || '';
    const cid = app.company_id as string;
    pushItem(items, { type: 'biz', companyName: co, companyId: cid, appId: app.id as string, target: null, kind: '事業完了期限（年度）', deadline: d.compLimit, days: d.compDays, status: app.status as string });
    if (d.supLimit) pushItem(items, { type: 'biz', companyName: co, companyId: cid, appId: app.id as string, target: null, kind: '支給申請期限', deadline: d.supLimit, days: d.supDays, status: app.status as string });
  }

  for (const app of data.work) {
    const d = calcWork(app, rows, today);
    const co = (app.company as { name?: string })?.name || '';
    const cid = app.company_id as string;
    pushItem(items, { type: 'work', companyName: co, companyId: cid, appId: app.id as string, target: null, kind: '交付申請期限（年度）', deadline: d.appLimit, days: d.appDays, status: app.status as string });
    pushItem(items, { type: 'work', companyName: co, companyId: cid, appId: app.id as string, target: null, kind: '事業完了期限（年度）', deadline: d.compLimit, days: d.compDays, status: app.status as string });
    if (d.supLimit) pushItem(items, { type: 'work', companyName: co, companyId: cid, appId: app.id as string, target: null, kind: '支給申請期限', deadline: d.supLimit, days: d.supDays, status: app.status as string });
  }

  for (const app of data.dual) {
    const d = calcDual(app, today);
    const co = (app.company as { name?: string })?.name || '';
    if (d.deadline && d.days !== null && d.days !== undefined) {
      pushItem(items, {
        type: 'dual', companyName: co, companyId: app.company_id as string,
        appId: app.id as string, target: app.employee_name as string,
        kind: d.daysPhase === 'until_start' ? `申請可能まで (${app.support_course})` : `支給申請期限 (${app.support_course})`,
        deadline: d.deadline, days: d.days, daysPhase: d.daysPhase, status: app.status as string,
      });
    }
  }

  for (const app of data.reskill) {
    const d = calcReskill(app, rows, today);
    const co = (app.company as { name?: string })?.name || '';
    const cid = app.company_id as string;
    pushItem(items, { type: 'reskill', companyName: co, companyId: cid, appId: app.id as string, target: app.training_name as string, kind: '計画届提出期限', deadline: d.planLimit, days: d.planDays, status: app.status as string });
    if (d.supLimit && d.supDays !== null) pushItem(items, { type: 'reskill', companyName: co, companyId: cid, appId: app.id as string, target: app.training_name as string, kind: app.exam_date ? '支給申請期限（受験日起算）' : '支給申請期限（訓練終了日起算）', deadline: d.supLimit, days: d.supDays, status: app.status as string });
    pushItem(items, { type: 'reskill', companyName: co, companyId: cid, appId: app.id as string, target: app.training_name as string, kind: '制度終了（令和8年度末）', deadline: d.programEnd!, days: d.programDays, status: app.status as string });
  }

  for (const app of data.over65) {
    const d = calcOver65(app, today);
    const co = (app.company as { name?: string })?.name || '';
    if (d.deadline && d.days !== null) {
      pushItem(items, {
        type: 'over65', companyName: co, companyId: app.company_id as string,
        appId: app.id as string, target: app.target_name as string,
        kind: `支給申請期限（${app.course_type}）`, deadline: d.deadline, days: d.days, status: app.status as string,
      });
    }
  }

  return items;
}

export function fmtDate(d: Date): string {
  return `${d.getFullYear()}/${String(d.getMonth() + 1).padStart(2, '0')}/${String(d.getDate()).padStart(2, '0')}`;
}

export function toDateKey(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export const TYPE_LABEL: Record<string, string> = {
  career_up: '👔 キャリアアップ',
  biz: '🏭 業務改善',
  work: '⏰ 働き方改革',
  dual: '👶 両立支援',
  reskill: '📚 リスキリング',
  over65: '👴 65歳超',
};
