#!/usr/bin/env node
/* A scripted stand-in for the real model (Groq/OmniRoute), OpenAI-chat-compatible.
   Plays a fixed 5-turn property-intake conversation so CI can drive the FULL
   booking flow (property intake -> readback -> confirm -> hold) without a real
   API key. Point OMNIROUTE_URL / DEMO_LLM_URL at this (see ci-verify.sh).

   Turn number = how many assistant messages are already in the conversation,
   so it's stateless and works for concurrent callers (WhatsApp + voice) without
   needing to key off phone number.

     node mock-llm.js        (listens on :5701)
*/
const http = require('http');

const PORT = process.env.MOCK_LLM_PORT || 5701;

const SCRIPT = [
  { brief: { service: 'video' }, stage: 'gathering',
    reply: "Great, is it a house or apartment, and how many bedrooms?" },
  { brief: { property_type: 'house', bedrooms: 4, bathrooms: 2, car_spaces: 1, levels: 2, floor_sqm: 380, pool: 'yes' }, stage: 'gathering',
    reply: "What's the address?" },
  { brief: { address: '40 Awaba St, Mosman' }, stage: 'gathering',
    reply: "What day and time works?" },
  { brief: { preferred_datetime: '2026-09-19T10:00' }, stage: 'readback',
    reply: "So that's a listing video, 4-bed 2-bath house, 40 Awaba St Mosman, Sat 19 Sep 10am. Is that all correct?" },
  { brief: {}, stage: 'confirmed', confirmed: true, booking_ready: true,
    reply: "Great, the owner will lock in the final details shortly." },
];

function body(req) {
  return new Promise((resolve) => {
    let b = '';
    req.on('data', (c) => (b += c));
    req.on('end', () => { try { resolve(JSON.parse(b || '{}')); } catch { resolve({}); } });
  });
}

http.createServer(async (req, res) => {
  if (req.method !== 'POST') { res.writeHead(404); res.end(); return; }
  const b = await body(req);
  const messages = b.messages || [];
  const turn = Math.min(messages.filter((m) => m.role === 'assistant').length, SCRIPT.length - 1);
  const s = SCRIPT[turn];
  const content = JSON.stringify({
    reply: s.reply, brief: s.brief, stage: s.stage,
    booking_ready: !!s.booking_ready, confirmed: !!s.confirmed, needs_human: false,
  });
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ choices: [{ message: { content } }] }));
}).listen(PORT, () => console.log('mock-llm on :' + PORT));
