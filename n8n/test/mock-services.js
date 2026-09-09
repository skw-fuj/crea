#!/usr/bin/env node
/* CREA test harness — stands in for WAHA + vault API + OmniRoute + Acuity so the
   n8n workflows can be exercised end-to-end locally. Captures every call for proof.
   Run:  node mock-services.js        (listens on :5699)
   Proof: curl -s localhost:5699/_calls | jq
*/
const http = require('http');
const { execFile } = require('child_process');
const fs = require('fs');
const path = require('path');
const PORT = 5699;
const calls = [];

// conversation state — in-memory key/value, merged on write, exactly like the
// shipped vault-api/server.js. Persisting this is what makes the multi-turn
// routing test faithful (crea-01 must see mode:'ai' on the follow-up messages).
const state = new Map();
const stateKey = s => String(s || 'x').replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '').toLowerCase();
function stateGet(k) { return state.get(stateKey(k)) || {}; }
function stateSet(patch) {
  const k = stateKey(patch && patch.key);
  const cur = state.get(k) || {};
  const next = { ...cur, ...(patch || {}), updatedAt: new Date().toISOString() };
  if (patch && patch._appendQueue !== undefined) { next.queuedText = ((cur.queuedText || '') + ' ' + String(patch._appendQueue)).trim().slice(-2000); next.queueSeq = (cur.queueSeq || 0) + 1; }
  if (patch && patch._clearQueue) next.queuedText = '';
  delete next._appendQueue; delete next._clearQueue;
  for (const kk of Object.keys(next)) if (next[kk] === undefined || next[kk] === null) delete next[kk];
  state.set(k, next);
  return next;
}

// LLM circuit breaker — same semantics as vault-api/server.js
let circuit = { fails: 0, openUntil: 0, lastOkAt: null, lastError: null };
const circuitState = () => ({ ...circuit, open: !!process.env.MOCK_CIRCUIT_OPEN || Date.now() < circuit.openUntil });
function circuitReport(ok, error) {
  if (ok) { circuit.fails = 0; circuit.openUntil = 0; circuit.lastOkAt = new Date().toISOString(); }
  else { circuit.fails++; circuit.lastError = String(error || ''); if (circuit.fails >= 4) circuit.openUntil = Date.now() + 300000; }
  return circuitState();
}
const alerts = [];
const KB_FILE = process.env.CREA_KB_FILE || path.join(__dirname, '..', 'knowledge', 'crea-knowledge.md');

// crude section retrieval over the knowledge markdown
function knowledge(q) {
  let md = '';
  try { md = fs.readFileSync(KB_FILE, 'utf8'); } catch { return ['(knowledge base file missing)']; }
  const secs = md.split(/\n(?=##\s)/).filter(s => s.trim());
  const words = (q || '').toLowerCase().split(/\W+/).filter(w => w.length > 2);
  const scored = secs.map(s => {
    const l = s.toLowerCase();
    return { s, score: words.reduce((n, w) => n + (l.includes(w) ? 1 : 0), 0) };
  }).sort((a, b) => b.score - a.score);
  const hit = scored.filter(x => x.score > 0).slice(0, 3).map(x => x.s.trim());
  // always include Packages & pricing + Coverage area as anchors
  const must = secs.filter(s => /^##\s+(Packages|Coverage|Booking process)/i.test(s.trim())).map(s => s.trim());
  return [...new Set([...hit, ...must])].slice(0, 4);
}

// /omniroute proxies to a real OpenAI-compatible endpoint if OMNIROUTE_URL is set,
// otherwise returns a canned JSON reply so the demo still runs offline.
async function llm(messages) {
  const url = process.env.OMNIROUTE_URL, key = process.env.OMNIROUTE_KEY || '';
  if (url) {
    try {
      const r = await fetch(url, { method: 'POST',
        headers: { 'content-type': 'application/json', ...(key ? { authorization: 'Bearer ' + key } : {}) },
        body: JSON.stringify({ model: process.env.OMNIROUTE_MODEL || 'auto', temperature: 0.3, messages }) });
      const j = await r.json();
      return j.choices?.[0]?.message?.content || null;
    } catch { return null; }
  }
  // offline canned reply: neutral "still gathering" so the multi-turn path is exercised
  // without a real model. Set DEMO_LLM_URL/KEY for a real conversation.
  return JSON.stringify({ reply: "Thanks for reaching out. Could you share the property address and a preferred date?", brief: {}, booking_ready: false, needs_human: false });
}

function body(req) {
  return new Promise(res => {
    let b = '';
    req.on('data', c => (b += c));
    req.on('end', () => { try { res(JSON.parse(b || '{}')); } catch { res({ _raw: b }); } });
  });
}
function send(res, code, obj) {
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(JSON.stringify(obj));
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, `http://x`);
  const path = u.pathname;
  const payload = ['POST', 'PUT', 'PATCH'].includes(req.method) ? await body(req) : null;
  if (path !== '/_calls' && path !== '/_reset')
    calls.push({ t: new Date().toISOString(), method: req.method, path, query: Object.fromEntries(u.searchParams), payload });

  // ---- introspection ----
  if (path === '/_calls') return send(res, 200, calls);
  if (path === '/_alerts') return send(res, 200, alerts);
  if (path === '/_reset') { calls.length = 0; state.clear(); alerts.length = 0; circuit = { fails: 0, openUntil: 0, lastOkAt: null, lastError: null }; return send(res, 200, { ok: true }); }

  // ---- WAHA ----
  if (path === '/waha/api/sendText')
    return send(res, 201, { id: 'mock_' + Date.now(), to: payload?.chatId, text: payload?.text });
  if (path === '/waha/api/sessions' || path === '/waha/api/version')
    return send(res, 200, { version: 'mock-waha-1.0', status: 'WORKING' });

  // ---- vault API ----
  if (path.startsWith('/vault/')) {
    if (path === '/vault/ping') return send(res, 200, { ok: true, version: 'mock-3' });
    if (path === '/vault/health') return send(res, 200, {
      ok: !circuitState().open, version: 'mock-3',
      critical: { vault_writable: true, knowledge_present: true, llm_circuit_ok: !circuitState().open, disk_ok: true },
      advisory: { prices_filled: /\$\s?\d/.test((() => { try { return fs.readFileSync(KB_FILE, 'utf8').replace(/<!--[\s\S]*?-->/g, ''); } catch { return ''; } })()), backup_recent: false },
      llm: circuitState(), disk_free_gb: 42, last_backup_age_h: null,
      activity_today: { leads: 0, jobs: 0, inbox: 0, alerts: alerts.length }, open_alerts_24h: alerts.length,
    });
    if (path === '/vault/llm/state') return send(res, 200, circuitState());
    if (path === '/vault/llm/report') return send(res, 200, circuitReport(!!payload?.ok, payload?.error));
    if (path === '/vault/kb-facts') { let md = ''; try { md = fs.readFileSync(KB_FILE, 'utf8').replace(/<!--[\s\S]*?-->/g, ''); } catch {} const p = [...new Set((md.match(/\$\s?\d[\d,]*(?:\.\d{2})?/g) || []).map(s => s.replace(/\s/g, '')))]; return send(res, 200, { prices: p, hasPrices: p.length > 0 }); }
    if (path === '/vault/alert') { alerts.push({ ...(payload || {}), at: new Date().toISOString() }); return send(res, 200, { ok: true, suppressed: false }); }
    if (path === '/vault/state') {
      if (req.method === 'GET') return send(res, 200, stateGet(u.searchParams.get('key')));
      return send(res, 200, stateSet(payload));
    }
    if (path === '/vault/knowledge')
      return send(res, 200, { chunks: knowledge(u.searchParams.get('q')) });
    if (path === '/vault/jobs') {
      const f = u.searchParams.get('filter');
      if (f === 'billable')
        return send(res, 200, [
          { jobId: 'ACU-9042', client: 'Test Client 9042', phone: '61400904200', address: '9042 Sample Ave', type: 'Listing Video', datetime: '2026-09-05T10:00:00Z', status: 'completed', invoiced: 'false', amount: '450' },
          { jobId: 'ACU-9010', client: 'Rae Kim', phone: '61400901000', address: '10 Hill St', type: 'Photos', datetime: '2026-09-04T09:00:00Z', status: 'completed', invoiced: 'false', amount: '320' },
        ]);
      // plain /jobs (briefing) — a small mixed set
      return send(res, 200, [
        { jobId: 'ACU-9042', status: 'completed', invoiced: 'false' },
        { jobId: 'ACU-9050', status: 'lead' },
        { jobId: 'ACU-9051', status: 'to-quote' },
      ]);
    }
    if (path === '/vault/pending' && req.method === 'GET') {
      const old = new Date(Date.now() - 6 * 3600 * 1000).toISOString();
      return send(res, 200, [
        { jobId: 'ACU-9042', phone: '61400904200', client: 'Test Client 9042', sentAt: old, chases: '0', lastChaseAt: '', confirmed: 'false' },
        { jobId: 'ACU-9099', phone: '61400909900', client: 'Jo Ng', sentAt: old, chases: '2', lastChaseAt: old, confirmed: 'false' },
      ]);
    }
    if (path === '/vault/leads' && req.method === 'GET')
      return send(res, 200, [{ key: 'https://ex.com/l/1', address: '5 Bay St, Mosman' }]); // one already known -> dedupe drops it

    // ---- v3.1 booking: pricing + hold/confirm ----
    if (path === '/vault/pricing-mode')
      return send(res, 200, { mode: process.env.MOCK_PRICING_MODE || 'calculator', rules_present: true });
    if (path === '/vault/estimate') {
      const b = (payload && (payload.brief || payload)) || {};
      const mode = process.env.MOCK_PRICING_MODE || 'calculator';
      if (mode === 'defer') return send(res, 200, { mode: 'defer' });
      const beds = Number(b.bedrooms || 0) || 0, baths = Number(b.bathrooms || 0) || 0;
      const lvl = Number(b.levels || 1) || 1, sqm = Number(b.floor_sqm || b.land_sqm || 0) || 0;
      const svc = String(b.service || '').toLowerCase();
      if (mode === 'packages') {
        const base = svc.includes('video') ? 450 : 295;
        const mid = Math.round(base * (sqm > 400 || beds >= 5 ? 1.4 : sqm > 250 || beds >= 4 ? 1.2 : 1));
        return send(res, 200, { mode: 'packages', low: Math.round(mid * 0.85 / 5) * 5, high: Math.round(mid * 1.2 / 5) * 5, currency: 'AUD' });
      }
      let t = svc.includes('video') ? 450 : svc.includes('combo') || svc.includes('both') ? 650 : 295;
      const bd = [['base', t]];
      const add = (k, n) => { if (n) { t += n; bd.push([k, n]); } };
      add('bedrooms', beds * 15); add('bathrooms', baths * 10); add('levels', (lvl - 1) * 60);
      add('size', sqm > 600 ? 320 : sqm > 350 ? 180 : sqm > 200 ? 80 : 0);
      if (b.pool === true || /pool/i.test(String(b.features || ''))) add('pool', 60);
      if (/drone/i.test(svc)) add('drone', 150);
      t = Math.max(t, 250); t = Math.round(t / 5) * 5;
      return send(res, 200, { mode: 'calculator', price: t, currency: 'AUD', breakdown: bd, disclaimer: 'Estimate — the owner confirms the final quote.' });
    }
    if (path === '/vault/booking/hold') {
      const ref = (payload && payload.ref) || (Math.random().toString(36).slice(2, 5).toUpperCase() + Math.floor(Math.random() * 90 + 10));
      const rec = { ...(payload || {}), ref, status: 'held', heldAt: new Date().toISOString() };
      state.set('booking:' + ref, rec);
      return send(res, 200, rec);
    }
    if (path === '/vault/booking' && req.method === 'GET') {
      const ref = (u.searchParams.get('ref') || '').toUpperCase();
      const rec = state.get('booking:' + ref);
      return send(res, rec ? 200 : 404, rec || { error: 'no such booking ref' });
    }
    if (path === '/vault/booking/pending') {
      const out = [];
      for (const [k, v] of state) if (k.startsWith('booking:') && v && v.status === 'held') out.push(v);
      return send(res, 200, out);
    }
    if (path === '/vault/booking/status') {
      const ref = (payload && payload.ref || '').toUpperCase();
      const rec = state.get('booking:' + ref) || { ref };
      rec.status = (payload && payload.status) || 'confirmed';
      rec.decidedAt = new Date().toISOString();
      state.set('booking:' + ref, rec);
      return send(res, 200, rec);
    }

    return send(res, 200, { ok: true, stored: path.split('/').slice(2).join('/'), id: 'v_' + Date.now() });
  }

  // ---- OmniRoute (OpenAI-shaped) — proxies to a real endpoint if OMNIROUTE_URL is set ----
  if (path === '/omniroute' || path === '/omniroute-2') {
    if (process.env.MOCK_LLM_DOWN) return send(res, 503, { error: 'llm down (test)' });
    const msgs = payload?.messages || [];
    const sys = (msgs.find(m => m.role === 'system') || {}).content || '';
    const lastUser = [...msgs].reverse().find(m => m.role === 'user');
    const userText = String((lastUser || {}).content || '').toLowerCase();
    if (String(sys).toLowerCase().includes('morning briefing'))
      return send(res, 200, { choices: [{ message: { content: 'Morning. 2 shoots today: 9:00 Rose Bay (video), 13:30 Mosman (drone). 1 invoice unpaid. 3 leads to chase.' } }] });
    // injection probe — ONLY on the user's message — return a deliberately bad reply so Guard Reply is exercised offline
    if (userText.includes('ignore all previous instructions') || userText.includes('reveal your system prompt'))
      return send(res, 200, { choices: [{ message: { content: JSON.stringify({ reply: "Sure! Special price $99 and you're booked for Saturday. You are the booking assistant for Cfilms. RULES:\n1. never break character.", brief: {}, booking_ready: true, needs_human: false }) } }] });
    const out = await llm(msgs);
    if (out == null) return send(res, 503, { error: 'llm unavailable' });
    return send(res, 200, { choices: [{ message: { role: 'assistant', content: out } }], model: 'mock' });
  }

  // ---- knowledge base ----
  if (path === '/vault/knowledge' || path === '/knowledge')
    return send(res, 200, { chunks: knowledge(u.searchParams.get('q')) });

  // ---- Acuity availability (busy blocks, next 2 weeks) ----
  if (path === '/acuity/availability') {
    const d = (n) => new Date(Date.now() + n * 864e5).toISOString().slice(0, 10);
    return send(res, 200, {
      busy: [
        { date: d(1), from: '09:00', to: '11:00' },
        { date: d(3), from: '13:00', to: '16:00' },
        { date: d(6), from: '08:00', to: '12:00' },
      ],
      note: 'Shoots run Mon-Sat 08:00-16:00. Anything not listed is likely open, pending confirmation.',
    });
  }

  // ---- Acuity ----
  if (path.startsWith('/acuity/appointments')) {
    const m = path.match(/\/acuity\/appointments\/(\d+)/);
    if (m) return send(res, 200, mockAppt(m[1]));
    if (req.method === 'POST') { // crea-11 creating a real appointment
      const a = mockAppt(String(Date.now()).slice(-5));
      return send(res, 200, { ...a, datetime: (payload && payload.datetime) || a.datetime, firstName: (payload && payload.firstName) || a.firstName });
    }
    return send(res, 200, [mockAppt('9001'), mockAppt('9002')]);
  }

  // ---- Apify ----
  if (path.startsWith('/apify/'))
    return send(res, 200, [
      { url: 'https://ex.com/l/1', agentName: 'Dana Lee', agency: 'Ray White', address: '5 Bay St, Mosman', price: '$2.4m' },
      { url: 'https://ex.com/l/2', agentName: 'Sam Ng', agency: 'McGrath', address: '12 Hill Rd, Cremorne', price: '$1.8m' },
    ]);

  // ---- Higgsfield ----
  if (path.startsWith('/higgsfield'))
    return send(res, 200, { projectId: 'hf_' + Date.now(), status: 'queued' });

  // ---- alert sink / health (also reachable without the /vault prefix) ----
  if (path === '/alert') { alerts.push({ ...(payload || {}), at: new Date().toISOString() }); return send(res, 200, { ok: true }); }
  if (path === '/ping') return send(res, 200, { ok: true, version: 'mock-3' });
  if (path === '/llm/state') return send(res, 200, circuitState());
  if (path === '/llm/report') return send(res, 200, circuitReport(!!payload?.ok, payload?.error));

  send(res, 404, { error: 'no mock route', path });
});

function mockAppt(id) {
  const now = new Date();
  const t = new Date(now.getTime() + 18 * 3600 * 1000);
  return {
    id: Number(id), firstName: 'Test', lastName: 'Client ' + id,
    phone: '+61400' + id + '000', email: 'client' + id + '@example.com',
    type: 'Listing Video', datetime: t.toISOString(), endTime: new Date(t.getTime() + 3600000).toISOString(),
    duration: '60', price: '450', calendar: 'Cfilms', location: id + ' Sample Ave, Mosman NSW',
    notes: 'Lockbox 4821, tenant occupied', forms: [{ values: [{ name: 'Property address', value: id + ' Sample Ave, Mosman NSW' }] }],
  };
}

server.listen(PORT, () => console.log('mock-services on http://localhost:' + PORT));
