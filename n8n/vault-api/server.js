#!/usr/bin/env node
/* CREA vault API — the memory + job-store seam the n8n workflows call.
 * Real service, no dependencies. Reads/writes plain files so the vault stays
 * human-editable and Hermes can read the same data.
 *
 *   node server.js
 *
 * Env (all optional, sensible defaults):
 *   VAULT_API_PORT      default 5692
 *   VAULT_DIR           where job/lead/inbox notes are written   (default ./data)
 *   KNOWLEDGE_FILE      the markdown the assistant answers from   (default ../knowledge/crea-knowledge.md)
 *   ACUITY_USER_ID / ACUITY_API_KEY   if set, /availability calls the real Acuity API
 *   ACUITY_APPT_TYPE_ID              optional, narrows the availability query
 */
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.VAULT_API_PORT || 5692);
const VAULT_DIR = path.resolve(process.env.VAULT_DIR || path.join(__dirname, 'data'));
const KB_FILE = path.resolve(process.env.KNOWLEDGE_FILE || path.join(__dirname, '..', 'knowledge', 'crea-knowledge.md'));
const ACUITY = { uid: process.env.ACUITY_USER_ID, key: process.env.ACUITY_API_KEY, type: process.env.ACUITY_APPT_TYPE_ID };

for (const d of ['jobs', 'leads', 'inbox', 'shoots', 'invoices', 'pending', 'state', 'alerts']) fs.mkdirSync(path.join(VAULT_DIR, d), { recursive: true });

// conversation state — key/value, merged on write. Replaces the separate state-store service.
const STATE_DIR = path.join(VAULT_DIR, 'state');
function stateGet(key) { const p = path.join(STATE_DIR, jslug(key) + '.json'); try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return {}; } }
function stateSet(patch) {
  const key = patch.key; if (!key) throw new Error('state write needs a key');
  const cur = stateGet(key);
  const next = { ...cur, ...patch, updatedAt: new Date().toISOString() };
  fs.writeFileSync(path.join(STATE_DIR, jslug(key) + '.json'), JSON.stringify(next, null, 2));
  return next;
}

// ---------- helpers ----------
const jslug = s => String(s || 'x').replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '').slice(0, 60).toLowerCase();
const readJSON = p => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const listJSON = dir => fs.readdirSync(path.join(VAULT_DIR, dir)).filter(f => f.endsWith('.json')).map(f => readJSON(path.join(VAULT_DIR, dir, f))).filter(Boolean);
function writeNote(dir, id, obj) {
  const base = path.join(VAULT_DIR, dir, jslug(id));
  fs.writeFileSync(base + '.json', JSON.stringify(obj, null, 2));
  // a readable markdown mirror so the vault stays browsable
  const md = [`# ${dir.slice(0, -1)}: ${id}`, '', ...Object.entries(obj).map(([k, v]) =>
    `- **${k}**: ${typeof v === 'object' ? '\n' + JSON.stringify(v, null, 2).split('\n').map(l => '  ' + l).join('\n') : v}`)].join('\n');
  fs.writeFileSync(base + '.md', md + '\n');
  return obj;
}
function mergeNote(dir, id, patch) {
  const base = path.join(VAULT_DIR, dir, jslug(id) + '.json');
  const cur = readJSON(base) || {};
  return writeNote(dir, id, { ...cur, ...patch, updatedAt: new Date().toISOString() });
}

// ---------- knowledge retrieval ----------
function knowledge(q) {
  let md = '';
  try { md = fs.readFileSync(KB_FILE, 'utf8'); } catch { return { chunks: ['(knowledge base file missing at ' + KB_FILE + ')'] }; }
  const secs = md.split(/\n(?=##\s)/).filter(s => s.trim());
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
  const anchors = secs.filter(s => /^##\s+(Packages|Coverage|Booking process)/i.test(s.trim())).map(s => s.trim());
  return { chunks: [...new Set([...hits, ...anchors])].slice(0, 4) };
}

// ---------- availability (real Acuity, or a sane default) ----------
async function availability() {
  const note = 'Shoots run Mon–Sat 08:00–16:00. Anything not listed is likely open, pending confirmation.';
  if (!ACUITY.uid || !ACUITY.key) return { busy: [], note: note + ' (Acuity not connected — treat all as tentative.)' };
  const from = new Date().toISOString().slice(0, 10);
  const to = new Date(Date.now() + 14 * 864e5).toISOString().slice(0, 10);
  const auth = 'Basic ' + Buffer.from(`${ACUITY.uid}:${ACUITY.key}`).toString('base64');
  try {
    const r = await fetch(`https://acuityscheduling.com/api/v1/appointments?minDate=${from}&maxDate=${to}&max=200`, { headers: { Authorization: auth } });
    const appts = await r.json();
    const busy = (Array.isArray(appts) ? appts : []).map(a => ({
      date: (a.datetime || '').slice(0, 10),
      from: (a.datetime || '').slice(11, 16),
      to: (a.endTime || '').slice(11, 16),
      what: a.type || 'booked',
    })).filter(b => b.date);
    return { busy, note };
  } catch (e) {
    return { busy: [], note: note + ' (Acuity lookup failed: ' + e.message + ')' };
  }
}

// ---------- job selectors ----------
function jobs(filter) {
  const all = listJSON('jobs');
  if (filter === 'billable') return all.filter(j => String(j.status).toLowerCase() === 'completed' && String(j.invoiced).toLowerCase() !== 'true' && String(j.invoiced).toLowerCase() !== 'draft');
  if (filter === 'tomorrow') { const d = new Date(Date.now() + 864e5).toISOString().slice(0, 10); return all.filter(j => (j.datetime || '').slice(0, 10) === d); }
  return all;
}

// ---------- router ----------
const send = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
const body = req => new Promise(r => { let b = ''; req.on('data', c => b += c); req.on('end', () => { try { r(JSON.parse(b || '{}')); } catch { r({}); } }); });

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const p = u.pathname.replace(/\/+$/, '') || '/';
  const q = u.searchParams;
  const isPost = ['POST', 'PUT', 'PATCH'].includes(req.method);
  const data = isPost ? await body(req) : null;
  try {
    if (p === '/' || p === '/health') return send(res, 200, { ok: true, vault: VAULT_DIR, knowledge: fs.existsSync(KB_FILE), acuity: !!ACUITY.key });

    if (p === '/knowledge') return send(res, 200, knowledge(q.get('q')));
    if (p === '/availability') return send(res, 200, await availability());

    // conversation state (was a separate service)
    if (p === '/state' && !isPost) return send(res, 200, stateGet(q.get('key')));
    if (p === '/state' && isPost) return send(res, 200, stateSet(data));

    // failure alerts from the error handler
    if (p === '/alert' && isPost) { writeNote('alerts', 'alert-' + Date.now(), data); return send(res, 200, { ok: true }); }

    if (p === '/job' && isPost) return send(res, 200, writeNote('jobs', data.jobId || 'job-' + Date.now(), data));
    if (p === '/job/invoiced' && isPost) return send(res, 200, mergeNote('jobs', data.jobId, { invoiced: data.invoiced || 'draft' }));
    if (p === '/jobs') return send(res, 200, jobs(q.get('filter')));

    if (p === '/lead' && isPost) return send(res, 200, writeNote('leads', (data.from || 'lead') + '-' + Date.now(), data));
    if (p === '/leads' && isPost) return send(res, 200, writeNote('leads', (data.key || 'lead') + '-' + Date.now(), data));
    if (p === '/leads') return send(res, 200, listJSON('leads'));

    if (p === '/inbox' && isPost) return send(res, 200, writeNote('inbox', (data.from || 'msg') + '-' + Date.now(), data));

    if (p === '/pending' && isPost) return send(res, 200, writeNote('pending', data.jobId || data.phone || 'p-' + Date.now(), { ...data, confirmed: false, chases: 0 }));
    if (p === '/pending') return send(res, 200, listJSON('pending').filter(r => String(r.confirmed).toLowerCase() !== 'true'));
    if (p === '/pending/update' && isPost) return send(res, 200, mergeNote('pending', data.jobId, data));
    if (p === '/pending/confirm' && isPost) return send(res, 200, mergeNote('pending', data.jobId || data.from, { confirmed: true }));

    if (p === '/shoots' && isPost) return send(res, 200, writeNote('shoots', (data.cardId || 'card') + '-' + (data.shootIndex || Date.now()), data));
    if (p === '/invoice-draft' && isPost) return send(res, 200, writeNote('invoices', data.jobId || 'inv-' + Date.now(), { ...data, status: 'draft' }));

    return send(res, 404, { error: 'no route', path: p });
  } catch (e) {
    return send(res, 500, { error: e.message });
  }
});

server.listen(PORT, () => console.log(`CREA vault API on http://127.0.0.1:${PORT}  vault=${VAULT_DIR}  kb=${fs.existsSync(KB_FILE) ? 'ok' : 'MISSING'}  acuity=${ACUITY.key ? 'connected' : 'not set'}`));
