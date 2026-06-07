/* Grocery Operations Intelligence — dashboard client
   Talks only to the same-origin /proxy/* which forwards to the analytics service. */

const API = (p) => `/proxy/${p}`;
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const money = (n) => '$' + Number(n || 0).toLocaleString(undefined, { maximumFractionDigits: 0 });
const pct = (n) => Number(n || 0).toFixed(1) + '%';

const state = { reports: {}, lastWhatIf: null };

/* ---------------- theme ---------------- */
function initTheme() {
  const saved = localStorage.getItem('gsp-theme');
  if (saved === 'dark') document.documentElement.classList.add('dark');
  updateThemeIcon();
  $('#btnTheme').addEventListener('click', () => {
    document.documentElement.classList.toggle('dark');
    localStorage.setItem('gsp-theme',
      document.documentElement.classList.contains('dark') ? 'dark' : 'light');
    updateThemeIcon();
    loadCharts(); // re-render charts so currentColor updates
  });
}
function updateThemeIcon() {
  $('#themeIcon').textContent =
    document.documentElement.classList.contains('dark') ? '☀️' : '🌙';
}

/* ---------------- toast ---------------- */
let toastT;
function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.style.opacity = '1'; t.style.transform = 'none';
  clearTimeout(toastT);
  toastT = setTimeout(() => { t.style.opacity = '0'; t.style.transform = 'translateY(8px)'; }, 2200);
}

/* ---------------- fetch helpers ---------------- */
async function getJSON(path) {
  const r = await fetch(API(path));
  if (!r.ok) throw new Error(`${path} -> ${r.status}`);
  return r.json();
}

/* ---------------- table renderer ---------------- */
function table(container, rows, cols) {
  const el = typeof container === 'string' ? $(container) : container;
  if (!rows || !rows.length) { el.innerHTML = `<p class="text-[12px] text-ibm-gray70 dark:text-ibm-gray20 py-6 text-center">No data yet.</p>`; return; }
  const head = cols.map(c => `<th class="text-left font-medium px-2 py-1.5 text-[11px] uppercase tracking-wide text-ibm-gray70 dark:text-ibm-gray20">${c.label}</th>`).join('');
  const body = rows.map(r => `<tr class="border-t border-ibm-gray20 dark:border-ibm-gray90">${
    cols.map(c => {
      const v = c.fmt ? c.fmt(r[c.key], r) : (r[c.key] ?? '');
      const cls = c.cls ? c.cls(r[c.key], r) : '';
      return `<td class="px-2 py-1.5 text-[12.5px] ${cls}">${v}</td>`;
    }).join('')
  }</tr>`).join('');
  el.innerHTML = `<div class="overflow-x-auto"><table class="w-full border-collapse"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
}

const signCls = (v) => Number(v) < 0 ? 'text-ibm-red font-medium' : 'text-ibm-green font-medium';

/* ---------------- KPI strip ---------------- */
async function loadKPI() {
  const k = await getJSON('metrics/kpi');
  const tiles = [
    { label: 'Revenue', val: money(k.revenue) },
    { label: 'Gross Profit', val: money(k.gross_profit) },
    { label: 'Net Profit', val: money(k.net_profit), accent: k.net_profit < 0 },
    { label: 'Margin', val: pct(k.margin_pct) },
    { label: 'Shrink', val: pct(k.shrink_pct), warn: k.shrink_pct > 3 },
    { label: 'Rev Growth 30d', val: (k.revenue_growth_pct >= 0 ? '+' : '') + pct(k.revenue_growth_pct), good: k.revenue_growth_pct >= 0 },
  ];
  $('#kpiStrip').innerHTML = tiles.map((t, i) => `
    <div class="tile border border-ibm-gray20 dark:border-ibm-gray90 p-3" style="animation-delay:${i * 50}ms">
      <div class="text-[11px] uppercase tracking-wide text-ibm-gray70 dark:text-ibm-gray20">${t.label}</div>
      <div class="text-xl font-semibold mt-1 ${t.warn ? 'text-ibm-amber' : ''} ${t.good ? 'text-ibm-green' : ''} ${t.accent ? 'text-ibm-red' : ''}">${t.val}</div>
    </div>`).join('');

  // investor summary panel
  $('#investorKpi').innerHTML = [
    ['Revenue', money(k.revenue)],
    ['Gross profit', money(k.gross_profit)],
    ['Net profit (after loss)', money(k.net_profit)],
    ['Gross margin', pct(k.margin_pct)],
    ['Shrink % of revenue', pct(k.shrink_pct)],
    ['Revenue growth (30d)', (k.revenue_growth_pct >= 0 ? '+' : '') + pct(k.revenue_growth_pct)],
  ].map(([a, b]) => `<div class="flex justify-between border-b border-ibm-gray20 dark:border-ibm-gray90 pb-1"><span class="text-ibm-gray70 dark:text-ibm-gray20">${a}</span><span class="font-mono font-medium">${b}</span></div>`).join('');
}

/* ---------------- charts (server-rendered SVG injected inline) ---------------- */
const CHARTS = ['revenue_trend', 'loss_by_cause', 'profit_by_category',
  'profit_per_foot', 'profit_projection', 'demand_forecast'];

async function loadCharts() {
  await Promise.all(CHARTS.map(async (name) => {
    const host = $(`#chart_${name}`);
    if (!host) return;
    host.innerHTML = `<div class="skel h-[290px] w-full"></div>`;
    try {
      const r = await fetch(API(`charts/${name}.svg`));
      const body = await r.text();
      // Only inject if we actually got an SVG back — a 5xx returns an HTML/JSON
      // error body that would otherwise be injected as broken markup.
      if (!r.ok || !body.trimStart().startsWith('<svg')) {
        throw new Error(`${name} -> ${r.status}`);
      }
      host.innerHTML = body;
    } catch (e) {
      console.error('chart load failed:', e);
      host.innerHTML = `<p class="text-[12px] text-ibm-red py-6 text-center">chart unavailable — retrying shortly</p>`;
    }
  }));
}

/* ---------------- tables per view ---------------- */
async function loadManager() {
  const cat = await getJSON('metrics/profit/category');
  table('#tbl_cat', cat, [
    { key: 'category', label: 'Category' },
    { key: 'revenue', label: 'Revenue', fmt: money },
    { key: 'gross_profit', label: 'Gross', fmt: money },
    { key: 'net_profit', label: 'Net', fmt: money, cls: signCls },
    { key: 'margin_pct', label: 'Margin', fmt: pct },
  ]);
  const shelf = await getJSON('metrics/profit/shelf');
  table('#tbl_shelf', shelf, [
    { key: 'shelf', label: 'Shelf' },
    { key: 'aisle', label: 'Aisle' },
    { key: 'linear_feet', label: 'Feet' },
    { key: 'gross_profit', label: 'Gross', fmt: money },
    { key: 'profit_per_foot', label: '$/ft', fmt: (v) => '$' + Number(v).toFixed(2), cls: signCls },
  ]);
  const loss = await getJSON('metrics/loss');
  table('#tbl_losscat', loss.by_category, [
    { key: 'category', label: 'Category' },
    { key: 'loss_value', label: 'Loss value', fmt: money, cls: () => 'text-ibm-red' },
  ]);
}

async function loadAdmin() {
  const exp = await getJSON('metrics/expiring');
  table('#tbl_expiring', exp, [
    { key: 'name', label: 'Product' },
    { key: 'category', label: 'Cat' },
    { key: 'on_hand', label: 'Qty' },
    { key: 'days_left', label: 'Days', cls: (v) => Number(v) <= 2 ? 'text-ibm-red font-medium' : Number(v) <= 4 ? 'text-ibm-amber' : '' },
    { key: 'retail_at_risk', label: 'At risk', fmt: money },
  ]);
  const low = await getJSON('metrics/lowstock');
  table('#tbl_lowstock', low, [
    { key: 'name', label: 'Product' },
    { key: 'on_hand', label: 'On hand' },
    { key: 'par_level', label: 'Par' },
    { key: 'vendor', label: 'Vendor' },
    { key: 'lead_time_days', label: 'Lead d' },
  ]);
  const v = await getJSON('metrics/vendors');
  table('#tbl_vendors', v, [
    { key: 'vendor', label: 'Vendor' },
    { key: 'category', label: 'Category' },
    { key: 'deliveries', label: 'Deliveries' },
    { key: 'fill_rate', label: 'Fill %', fmt: pct },
    { key: 'on_time_rate', label: 'On-time %', fmt: pct, cls: (v) => Number(v) < 85 ? 'text-ibm-amber' : 'text-ibm-green' },
  ]);
}

async function loadGrowth() {
  const promo = await getJSON('metrics/promotions');
  table('#tbl_promo', promo, [
    { key: 'program', label: 'Program' },
    { key: 'category', label: 'Cat' },
    { key: 'discount_pct', label: 'Disc', fmt: (v) => v + '%' },
    { key: 'incremental_margin', label: 'Incr. margin', fmt: money, cls: signCls },
  ]);
  const ads = await getJSON('metrics/ads');
  table('#tbl_ads', ads, [
    { key: 'program', label: 'Program' },
    { key: 'channel', label: 'Channel' },
    { key: 'spend', label: 'Spend', fmt: money },
    { key: 'attributable_margin', label: 'Attr. margin', fmt: money },
    { key: 'roi_x', label: 'ROI x', fmt: (v) => Number(v).toFixed(2) + '×', cls: (v) => Number(v) < 1 ? 'text-ibm-red' : 'text-ibm-green' },
  ]);
  const fb = await getJSON('metrics/feedback');
  table('#tbl_feedback', fb.themes, [
    { key: 'theme', label: 'Theme' },
    { key: 'n', label: 'Mentions' },
    { key: 'sentiment', label: 'Sentiment', fmt: (v) => Number(v).toFixed(2), cls: (v) => Number(v) < 0 ? 'text-ibm-red' : 'text-ibm-green' },
  ]);
}

async function loadInvestor() {
  const proj = await getJSON('forecast/profit?horizon=30');
  const a = proj.assumptions || {};
  $('#projAssume').textContent =
    `Model: ${a.model} · trend ${a.trend_slope_per_day}/day · hist avg daily GP ${money(a.historical_avg_daily_gross_profit)} · projected 30d total ${money(proj.summary?.projected_total_gross_profit)}`;
}

/* ---------------- exports ---------------- */
function download(filename, content, type) {
  const blob = new Blob([content], { type });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = filename; a.click();
  URL.revokeObjectURL(url);
}

function wireExports() {
  // JSON per-panel
  $$('.json-export').forEach(b => b.addEventListener('click', async () => {
    const data = await getJSON(b.dataset.endpoint);
    download(`${b.dataset.name}.json`, JSON.stringify(data, null, 2), 'application/json');
    toast('JSON exported');
  }));
  // SVG charts
  $$('.svg-export').forEach(b => b.addEventListener('click', async () => {
    const r = await fetch(API(`charts/${b.dataset.chart}.svg`));
    download(`${b.dataset.chart}.svg`, await r.text(), 'image/svg+xml');
    toast('SVG exported');
  }));
  // full reports
  $$('.report-export').forEach(b => b.addEventListener('click', async () => {
    const data = await getJSON(`reports/${b.dataset.report}`);
    download(`report_${b.dataset.report}.json`, JSON.stringify(data, null, 2), 'application/json');
    toast('Report downloaded');
  }));
  // whole dashboard
  $('#btnExportAll').addEventListener('click', async () => {
    toast('Building dashboard export…');
    const names = ['daily_operations', 'profit_margin', 'promotion_marketing', 'forecast_plan', 'investor_summary'];
    const out = { generated_at: new Date().toISOString(), reports: {} };
    for (const n of names) { try { out.reports[n] = await getJSON(`reports/${n}`); } catch (e) { out.reports[n] = { error: String(e) }; } }
    download('grocery_dashboard_export.json', JSON.stringify(out, null, 2), 'application/json');
    toast('Dashboard JSON exported');
  });
}

/* ---------------- what-if ---------------- */
function wireWhatIf() {
  const ask = async () => {
    const q = $('#whatifInput').value.trim();
    if (!q) { toast('Type a scenario first'); return; }
    const out = $('#whatifOut'), ans = $('#whatifAnswer');
    out.classList.remove('hidden');
    ans.innerHTML = `<span class="skel inline-block h-4 w-3/4"></span>`;
    $('#whatifAsk').disabled = true; $('#whatifAsk').textContent = 'Thinking…';
    try {
      const r = await fetch(API('whatif'), {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ question: q }),
      });
      if (!r.ok) throw new Error(`analytics returned ${r.status}`);
      const data = await r.json();
      state.lastWhatIf = data;
      ans.textContent = data.answer || '(no answer)';
      $('#whatifFacts').innerHTML = (data.facts_used || []).map(f => `<li>${f}</li>`).join('') || '<li>none</li>';
    } catch (e) {
      ans.textContent = 'Scenario failed: ' + e + '. Is the analytics service up?';
    } finally {
      $('#whatifAsk').disabled = false; $('#whatifAsk').textContent = 'Run scenario';
    }
  };
  $('#whatifAsk').addEventListener('click', ask);
  $$('.whatif-chip').forEach(c => c.addEventListener('click', () => {
    $('#whatifInput').value = c.textContent.trim(); ask();
  }));
  $('#whatifExport').addEventListener('click', () => {
    if (!state.lastWhatIf) return;
    download('whatif_scenario.json', JSON.stringify(state.lastWhatIf, null, 2), 'application/json');
    toast('Scenario exported');
  });
}

/* ---------------- view switching ---------------- */
function wireViews() {
  $$('.view-tab').forEach(tab => tab.addEventListener('click', () => {
    const v = tab.dataset.view;
    $$('.view-tab').forEach(t => { t.classList.remove('tab-active'); t.classList.add('text-ibm-gray70', 'dark:text-ibm-gray20'); });
    tab.classList.add('tab-active'); tab.classList.remove('text-ibm-gray70', 'dark:text-ibm-gray20');
    $$('.view-panel').forEach(p => p.classList.toggle('hidden', p.dataset.panel !== v));
  }));
}

/* ---------------- boot ---------------- */
// Run a loader, and if it throws (e.g. analytics not ready yet), retry once
// after a short delay so the dashboard self-heals on a slow cold start.
async function withRetry(fn, label) {
  try {
    await fn();
  } catch (e) {
    console.warn(`${label} failed, retrying once…`, e);
    await new Promise(res => setTimeout(res, 2500));
    try { await fn(); }
    catch (e2) { console.error(`${label} failed after retry`, e2); throw e2; }
  }
}

async function boot() {
  initTheme(); wireViews(); wireExports(); wireWhatIf();
  $('#updated').textContent = 'loaded ' + new Date().toLocaleString();

  // Each section loads independently so one slow/failed call can't blank the
  // whole dashboard. Settle all of them and report only if everything failed.
  const sections = [
    withRetry(loadKPI, 'KPIs'),
    withRetry(loadCharts, 'charts'),
    withRetry(loadManager, 'manager'),
    withRetry(loadAdmin, 'admin'),
    withRetry(loadGrowth, 'growth'),
    withRetry(loadInvestor, 'investor'),
  ];
  const results = await Promise.allSettled(sections);
  if (results.every(r => r.status === 'rejected')) {
    toast('Could not reach the analytics service — is the stack up?');
  } else if (results.some(r => r.status === 'rejected')) {
    toast('Some panels are still loading…');
  }

  // warm the what-if index in the background (best-effort)
  fetch(API('whatif/reindex'), { method: 'POST' }).catch(() => {});
}
document.addEventListener('DOMContentLoaded', boot);
