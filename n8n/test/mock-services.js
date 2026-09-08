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

// real LLM for the /omniroute route via the free-tier CLI (per CLAUDE.md)
function llm(messages) {
  return new Promise(resolve => {
    const prompt = messages.map(m => `[${m.role}]\n${m.content}`).join('\n\n') +
      '\n\n[assistant]\n';
    execFile('python3', [path.join(process.env.HOME, '.claude/registry/cheap.py'), prompt],
      { timeout: 60000, maxBuffer: 1 << 20 }, (err, stdout) => {
        if (err) return resolve(null);
        resolve(String(stdout).replace(/^\[cheap-tier:[^\]]*\]\s*/i, '').trim());
      });
  });
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
  if (path === '/_reset') { calls.length = 0; return send(res, 200, { ok: true }); }

  // ---- WAHA ----
  if (path === '/waha/api/sendText')
    return send(res, 201, { id: 'mock_' + Date.now(), to: payload?.chatId, text: payload?.text });
  if (path === '/waha/api/sessions' || path === '/waha/api/version')
    return send(res, 200, { version: 'mock-waha-1.0', status: 'WORKING' });

  // ---- vault API ----
  if (path.startsWith('/vault/')) {
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
    return send(res, 200, { ok: true, stored: path.split('/').slice(2).join('/'), id: 'v_' + Date.now() });
  }

  // ---- OmniRoute (OpenAI-shaped) — proxies to the real free-tier LLM ----
  if (path === '/omniroute') {
    if (process.env.MOCK_LLM_DOWN) return send(res, 503, { error: 'llm down (test)' });
    const msgs = payload?.messages || [];
    const isBriefing = JSON.stringify(msgs).includes('morning briefing');
    if (isBriefing) {
      return send(res, 200, { choices: [{ message: { role: 'assistant', content: 'Morning. 2 shoots today: 9:00 Rose Bay (video), 13:30 Mosman (drone). 1 invoice unpaid. 3 new leads to chase. Leave by 8:20 for Rose Bay parking.' } }] });
    }
    const out = await llm(msgs);
    if (out == null) return send(res, 503, { error: 'llm unavailable' });
    return send(res, 200, { choices: [{ message: { role: 'assistant', content: out } }], model: 'cheap-tier' });
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

  // ---- alert sink ----
  if (path === '/alert') return send(res, 200, { ok: true });

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
