#!/usr/bin/env node
/* CREA vault API — the memory + job-store + observability seam the n8n workflows call.
 * Zero dependencies. Reads/writes plain files so the data stays human-editable.
 *
 *   node server.js
 *
 * Env (all optional, sensible defaults):
 *   VAULT_API_PORT      default 5692
 *   VAULT_DIR           where job/lead/inbox notes are written   (default ./data)
 *   KNOWLEDGE_FILE      the markdown the assistant answers from   (default ../knowledge/crea-knowledge.md)
 *   ACUITY_USER_ID / ACUITY_API_KEY / ACUITY_APPT_TYPE_ID    real Acuity availability if set
 *   LLM_CIRCUIT_FAILS / LLM_CIRCUIT_COOLDOWN_S               circuit-breaker thresholds (default 4 / 300)
 *   BACKUP_DIR         where ./go-live.sh --backup writes (for the "last backup age" health metric)
 */
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const VERSION = '3.0.0';
const PORT = Number(process.env.VAULT_API_PORT || 5692);
const VAULT_DIR = path.resolve(process.env.VAULT_DIR || path.join(__dirname, 'data'));
const KB_FILE = path.resolve(process.env.KNOWLEDGE_FILE || path.join(__dirname, '..', 'knowledge', 'crea-knowledge.md'));
const BACKUP_DIR = process.env.BACKUP_DIR ? path.resolve(process.env.BACKUP_DIR) : path.join(__dirname, '..', 'backups');
const ACUITY = { uid: process.env.ACUITY_USER_ID, key: process.env.ACUITY_API_KEY, type: process.env.ACUITY_APPT_TYPE_ID };
const CIRCUIT_FAILS = Number(process.env.LLM_CIRCUIT_FAILS || 4);
const CIRCUIT_COOLDOWN = Number(process.env.LLM_CIRCUIT_COOLDOWN_S || 300) * 1000;
const MAX_BODY = 256 * 1024;

for (const d of ['jobs', 'leads', 'inbox', 'shoots', 'invoices', 'pending', 'state', 'alerts', 'health'])
  fs.mkdirSync(path.join(VAULT_DIR, d), { recursive: true });

// never let a bad request take the process down — Docker would restart it, but a log is better
process.on('uncaughtException', e => logInternal('uncaughtException', e));
process.on('unhandledRejection', e => logInternal('unhandledRejection', e));
function logInternal(kind, e) {
  try { fs.appendFileSync(path.join(VAULT_DIR, 'health', 'vault-api.log'),
    `${new Date().toISOString()} ${kind}: ${(e && e.stack) || e}\n`); } catch {}
}

// ---------- helpers ----------
const jslug = s => String(s || 'x').replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '').slice(0, 80).toLowerCase();
const readJSON = p => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const listFiles = dir => { try { return fs.readdirSync(path.join(VAULT_DIR, dir)).filter(f => f.endsWith('.json')); } catch { return []; } };
const listJSON = dir => listFiles(dir).map(f => readJSON(path.join(VAULT_DIR, dir, f))).filter(Boolean);
const todayStr = () => new Date().toISOString().slice(0, 10);

function writeNote(dir, id, obj) {
  const base = path.join(VAULT_DIR, dir, jslug(id));
  fs.writeFileSync(base + '.json', JSON.stringify(obj, null, 2));
  const md = [`# ${dir.slice(0, -1)}: ${id}`, '', ...Object.entries(obj).map(([k, v]) =>
    `- **${k}**: ${typeof v === 'object' ? '\n' + JSON.stringify(v, null, 2).split('\n').map(l => '  ' + l).join('\n') : v}`)].join('\n');
  fs.writeFileSync(base + '.md', md + '\n');
  return obj;
}
function mergeNote(dir, id, patch) {
  const base = path.join(VAULT_DIR, dir, jslug(id) + '.json');
  return writeNote(dir, id, { ...(readJSON(base) || {}), ...patch, updatedAt: new Date().toISOString() });
}

// ---------- conversation state ----------
const STATE_DIR = path.join(VAULT_DIR, 'state');
function stateGet(key) { try { return JSON.parse(fs.readFileSync(path.join(STATE_DIR, jslug(key) + '.json'), 'utf8')); } catch { return {}; } }
function stateSet(patch) {
  const key = patch.key; if (!key) throw new Error('state write needs a key');
  // read-modify-write is atomic here: Node's event loop runs this handler body to completion
  // (all fs calls are sync, no await) before the next request — so concurrent queue appends
  // and clears can't interleave.
  const cur = stateGet(key);
  const next = { ...cur, ...patch, updatedAt: new Date().toISOString() };
  if (patch._appendQueue !== undefined) {
    next.queuedText = ((cur.queuedText || '') + ' ' + String(patch._appendQueue)).trim().slice(-2000);
    next.queueSeq = (cur.queueSeq || 0) + 1;
  }
  if (patch._clearQueue) {
    next.queuedText = '';
  }
  delete next._appendQueue; delete next._clearQueue;
  for (const k of Object.keys(next)) if (next[k] === undefined || next[k] === null) delete next[k];
  fs.writeFileSync(path.join(STATE_DIR, jslug(key) + '.json'), JSON.stringify(next, null, 2));
  return next;
}

// ---------- LLM circuit breaker (shared across all conversations) ----------
// crea-02b POSTs /llm/report {ok:true|false}; before calling the model it GETs /llm/state.
// After CIRCUIT_FAILS consecutive failures the circuit is "open" for CIRCUIT_COOLDOWN —
// the assistant then skips the model entirely and uses the deterministic qualifier.
const CIRCUIT_FILE = path.join(VAULT_DIR, 'state', '_llm-circuit.json');
function circuitGet() {
  const c = readJSON(CIRCUIT_FILE) || { fails: 0, openUntil: 0, lastOkAt: null, lastFailAt: null, lastError: null };
  c.open = Date.now() < c.openUntil;
  return c;
}
function circuitReport(ok, error) {
  const c = circuitGet();
  if (ok) { c.fails = 0; c.openUntil = 0; c.lastOkAt = new Date().toISOString(); }
  else {
    c.fails = (c.fails || 0) + 1; c.lastFailAt = new Date().toISOString(); c.lastError = String(error || '').slice(0, 300);
    if (c.fails >= CIRCUIT_FAILS) c.openUntil = Date.now() + CIRCUIT_COOLDOWN;
  }
  delete c.open;
  fs.writeFileSync(CIRCUIT_FILE, JSON.stringify(c, null, 2));
  return circuitGet();
}

// ---------- incident log with dedup (1 identical alert per hour) ----------
function recordAlert(data) {
  const key = jslug((data.workflow || 'x') + '-' + (data.node || '') + '-' + String(data.message || data.error || '').slice(0, 60));
  const seenFile = path.join(VAULT_DIR, 'health', 'alert-seen.json');
  const seen = readJSON(seenFile) || {};
  const now = Date.now();
  const suppressed = seen[key] && (now - seen[key] < 3600e3);
  seen[key] = now;
  // prune old
  for (const k of Object.keys(seen)) if (now - seen[k] > 24 * 3600e3) delete seen[k];
  fs.writeFileSync(seenFile, JSON.stringify(seen));
  if (!suppressed) {
    writeNote('alerts', 'alert-' + new Date().toISOString().replace(/[:.]/g, '-'),
      { ...data, severity: data.severity || 'error', recordedAt: new Date().toISOString() });
  }
  return { ok: true, suppressed };
}

// ---------- knowledge retrieval ----------
function kbText() {
  let md = ''; try { md = fs.readFileSync(KB_FILE, 'utf8'); } catch { return ''; }
  return md.replace(/<!--[\s\S]*?-->/g, '');   // strip HTML comments (they hold "example once filled" text)
}
function kbSections() {
  const md = kbText();
  return md ? md.split(/\n(?=##\s)/).filter(s => s.trim()) : [];
}
function knowledge(q) {
  const secs = kbSections();  // HTML comments already stripped
  if (!secs.length) return { chunks: ['(knowledge base file missing at ' + KB_FILE + ')'], missing: true };
  const ql = String(q || '').toLowerCase();
  const words = ql.split(/\W+/).filter(w => w.length > 2);
  const priceish = /how much|price|pricing|cost|quote|\$|package|rate|fee/.test(ql);
  const scored = secs.map(s => {
    const l = s.toLowerCase();
    let score = words.reduce((n, w) => n + (l.includes(w) ? 1 : 0), 0);
    if (priceish && /^##\s+Packages/i.test(s.trim())) score += 10;
    return { s: s.trim(), score };
  }).sort((a, b) => b.score - a.score);
  const hits = scored.filter(x => x.score > 0).slice(0, 3).map(x => x.s);
  const anchors = secs.filter(s => /^##\s+(Packages|Coverage|Booking process|House rules)/i.test(s.trim())).map(s => s.trim());
  return { chunks: [...new Set([...hits, ...anchors])].slice(0, 5) };
}
// the exact price tokens present in the knowledge file (comments stripped) —
// used by crea-02b's reply guard to catch a price the model invented
function kbFacts() {
  const md = kbText();
  const prices = [...new Set((md.match(/\$\s?\d[\d,]*(?:\.\d{2})?/g) || []).map(s => s.replace(/\s/g, '')))];
  return { prices, hasPrices: prices.length > 0 };
}

// ---------- availability ----------
async function availability() {
  const note = 'Shoots run Mon–Sat 08:00–16:00. Anything not listed is likely open, pending confirmation.';
  if (!ACUITY.uid || !ACUITY.key) return { busy: [], note: note + ' (Acuity not connected — treat all as tentative.)' };
  const from = todayStr();
  const to = new Date(Date.now() + 14 * 864e5).toISOString().slice(0, 10);
  const auth = 'Basic ' + Buffer.from(`${ACUITY.uid}:${ACUITY.key}`).toString('base64');
  try {
    const r = await fetch(`https://acuityscheduling.com/api/v1/appointments?minDate=${from}&maxDate=${to}&max=200`,
      { headers: { Authorization: auth }, signal: AbortSignal.timeout(12000) });
    const appts = await r.json();
    const busy = (Array.isArray(appts) ? appts : []).map(a => ({
      date: (a.datetime || '').slice(0, 10), from: (a.datetime || '').slice(11, 16),
      to: (a.endTime || '').slice(11, 16), what: a.type || 'booked',
    })).filter(b => b.date);
    return { busy, note };
  } catch (e) {
    recordAlert({ workflow: 'vault-api', node: 'availability', message: 'Acuity lookup failed: ' + e.message, severity: 'warn' });
    return { busy: [], note: note + ' (Acuity lookup failed — treat all as tentative.)' };
  }
}

// ---------- job selectors ----------
function jobs(filter) {
  const all = listJSON('jobs');
  if (filter === 'billable') return all.filter(j => String(j.status).toLowerCase() === 'completed' && !['true', 'draft'].includes(String(j.invoiced).toLowerCase()));
  if (filter === 'tomorrow') { const d = new Date(Date.now() + 864e5).toISOString().slice(0, 10); return all.filter(j => (j.datetime || '').slice(0, 10) === d); }
  return all;
}

// ---------- health / observability ----------
function diskFreeGb() {
  try { const out = execSync('df -Pk / 2>/dev/null || df -Pk .', { encoding: 'utf8' }).trim().split('\n').pop().split(/\s+/); return Math.round(Number(out[3]) / 1024 / 1024 * 10) / 10; }
  catch { return null; }
}
function countToday(dir, field) {
  const t = todayStr();
  return listJSON(dir).filter(o => String(o[field] || o.recordedAt || o.capturedAt || o.createdAt || '').slice(0, 10) === t).length;
}
function lastBackupAgeH() {
  try {
    const fns = fs.readdirSync(BACKUP_DIR).filter(f => f.endsWith('.tgz'));
    if (!fns.length) return null;
    const newest = Math.max(...fns.map(f => fs.statSync(path.join(BACKUP_DIR, f)).mtimeMs));
    return Math.round((Date.now() - newest) / 3600e3 * 10) / 10;
  } catch { return null; }
}
function health() {
  const kb = kbFacts();
  const circuit = circuitGet();
  let vaultWritable = false;
  try { const t = path.join(VAULT_DIR, 'health', '.wtest'); fs.writeFileSync(t, '1'); fs.unlinkSync(t); vaultWritable = true; } catch {}
  const disk = diskFreeGb();
  const openAlerts = listJSON('alerts').filter(a => {
    const age = Date.now() - Date.parse(a.recordedAt || a.recordedAt || 0);
    return age < 24 * 3600e3;
  }).length;
  const critical = {
    vault_writable: vaultWritable,
    knowledge_present: kbSections().length > 0,
    llm_circuit_ok: !circuit.open,
    disk_ok: disk == null ? true : disk > 3,
  };
  const advisory = {
    prices_filled: kb.hasPrices,
    backup_recent: (() => { const a = lastBackupAgeH(); return a == null ? false : a < 24 * 30; })(),
  };
  const ok = Object.values(critical).every(Boolean);
  return {
    ok, version: VERSION, checkedAt: new Date().toISOString(),
    checks: { ...critical, ...advisory }, critical, advisory,
    vault: { path: VAULT_DIR, writable: vaultWritable },
    knowledge: { file: KB_FILE, sections: kbSections().length, prices: kb.prices, prices_filled: kb.hasPrices },
    acuity: { connected: !!ACUITY.key },
    llm: circuit,
    disk_free_gb: disk,
    last_backup_age_h: lastBackupAgeH(),
    activity_today: { leads: countToday('leads', 'capturedAt'), jobs: countToday('jobs', 'createdAt'), inbox: countToday('inbox', 'receivedAt'), alerts: countToday('alerts', 'recordedAt') },
    open_alerts_24h: openAlerts,
  };
}

function statusHtml() {
  const h = health();
  const row = (k, v, cls) => `<tr><td>${k}</td><td class="${cls}">${v}</td></tr>`;
  const crit = Object.entries(h.critical).map(([k, v]) => row(k.replace(/_/g, ' '), v ? 'ok' : 'PROBLEM', v ? 'g' : 'b')).join('');
  const adv = Object.entries(h.advisory).map(([k, v]) => row(k.replace(/_/g, ' '), v ? 'ok' : 'to do', v ? 'g' : 'w')).join('');
  return `<!doctype html><meta charset=utf8><title>CREA status</title>
<style>body{font:14px -apple-system,sans-serif;margin:2rem;max-width:640px}h1{font-size:1.2rem}
h2{font-size:1rem;margin-top:1.4rem}
table{border-collapse:collapse;width:100%;margin:.5rem 0}td{padding:.35rem .6rem;border-bottom:1px solid #eee}
.g{color:#137333;font-weight:600}.b{color:#c5221f;font-weight:700}.w{color:#b06000;font-weight:600}.k{color:#666}small{color:#888}</style>
<h1>CREA — ${h.ok ? '🟢 healthy' : '🔴 needs attention'} <small>v${h.version}</small></h1>
<h2>Critical</h2><table>${crit}</table>
<h2>To do</h2><table>${adv}</table>
<h2>Today</h2>
<table>${row('new enquiries', h.activity_today.leads, true)}${row('bookings in', h.activity_today.jobs, true)}${row('inbox messages', h.activity_today.inbox, true)}${row('alerts', h.activity_today.alerts, h.activity_today.alerts === 0)}</table>
<h2>System</h2>
<table>
${row('knowledge sections', h.knowledge.sections, h.knowledge.sections > 0)}
${row('prices in knowledge file', h.knowledge.prices.join(' ') || '(none — assistant defers on price)', h.knowledge.prices_filled)}
${row('LLM circuit', h.llm.open ? 'OPEN (using fallback)' : 'closed (normal)', !h.llm.open)}
${row('Acuity', h.acuity.connected ? 'connected' : 'not connected', true)}
${row('disk free', h.disk_free_gb == null ? 'n/a' : h.disk_free_gb + ' GB', h.disk_free_gb == null || h.disk_free_gb > 5)}
${row('last backup', h.last_backup_age_h == null ? 'never — run ./go-live.sh --backup' : h.last_backup_age_h + ' h ago', h.last_backup_age_h != null && h.last_backup_age_h < 24 * 30)}
</table>
<p class=k>checked ${h.checkedAt}. Auto-refreshes every 30s.</p>
<script>setTimeout(()=>location.reload(),30000)</script>`;
}

// ---------- router ----------
const sendJSON = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
const sendHtml = (res, code, s) => { res.writeHead(code, { 'content-type': 'text/html; charset=utf-8' }); res.end(s); };
const body = req => new Promise(r => {
  let b = '', over = false;
  req.on('data', c => { b += c; if (b.length > MAX_BODY) { over = true; req.destroy(); } });
  req.on('end', () => { if (over) return r({ _error: 'body too large' }); try { r(JSON.parse(b || '{}')); } catch { r({}); } });
  req.on('error', () => r({}));
});

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const p = u.pathname.replace(/\/+$/, '') || '/';
  const q = u.searchParams;
  const isPost = ['POST', 'PUT', 'PATCH'].includes(req.method);
  const data = isPost ? await body(req) : null;
  try {
    if (p === '/' || p === '/health') return sendJSON(res, 200, health());
    if (p === '/status' || p === '/status.html') return sendHtml(res, 200, statusHtml());
    if (p === '/ping') return sendJSON(res, 200, { ok: true, version: VERSION });

    if (p === '/knowledge') return sendJSON(res, 200, knowledge(q.get('q')));
    if (p === '/kb-facts') return sendJSON(res, 200, kbFacts());
    if (p === '/availability') return sendJSON(res, 200, await availability());

    if (p === '/state' && !isPost) return sendJSON(res, 200, stateGet(q.get('key')));
    if (p === '/state' && isPost) return sendJSON(res, 200, stateSet(data));

    if (p === '/llm/state' && !isPost) return sendJSON(res, 200, circuitGet());
    if (p === '/llm/report' && isPost) return sendJSON(res, 200, circuitReport(!!data.ok, data.error));

    if (p === '/alert' && isPost) return sendJSON(res, 200, recordAlert(data));

    if (p === '/job' && isPost) return sendJSON(res, 200, writeNote('jobs', data.jobId || 'job-' + Date.now(), data));
    if (p === '/job/invoiced' && isPost) return sendJSON(res, 200, mergeNote('jobs', data.jobId, { invoiced: data.invoiced || 'draft' }));
    if (p === '/jobs') return sendJSON(res, 200, jobs(q.get('filter')));

    if (p === '/lead' && isPost) return sendJSON(res, 200, writeNote('leads', (data.from || 'lead') + '-' + Date.now(), data));
    if (p === '/leads' && isPost) return sendJSON(res, 200, writeNote('leads', (data.key || 'lead') + '-' + Date.now(), data));
    if (p === '/leads') return sendJSON(res, 200, listJSON('leads'));

    if (p === '/inbox' && isPost) return sendJSON(res, 200, writeNote('inbox', (data.from || 'msg') + '-' + Date.now(), data));

    if (p === '/pending' && isPost) return sendJSON(res, 200, writeNote('pending', data.jobId || data.phone || 'p-' + Date.now(), { ...data, confirmed: false, chases: 0 }));
    if (p === '/pending') return sendJSON(res, 200, listJSON('pending').filter(r => String(r.confirmed).toLowerCase() !== 'true'));
    if (p === '/pending/update' && isPost) return sendJSON(res, 200, mergeNote('pending', data.jobId, data));
    if (p === '/pending/confirm' && isPost) return sendJSON(res, 200, mergeNote('pending', data.jobId || data.from, { confirmed: true }));

    if (p === '/shoots' && isPost) return sendJSON(res, 200, writeNote('shoots', (data.cardId || 'card') + '-' + (data.shootIndex || Date.now()), data));
    if (p === '/invoice-draft' && isPost) return sendJSON(res, 200, writeNote('invoices', data.jobId || 'inv-' + Date.now(), { ...data, status: 'draft' }));

    return sendJSON(res, 404, { error: 'no route', path: p });
  } catch (e) {
    logInternal('request', e);
    return sendJSON(res, 500, { error: e.message });
  }
});

server.requestTimeout = 20000;
server.listen(PORT, () => console.log(`CREA vault API v${VERSION} on http://127.0.0.1:${PORT}  vault=${VAULT_DIR}  kb=${kbSections().length ? 'ok' : 'MISSING'}  acuity=${ACUITY.key ? 'connected' : 'not set'}`));
