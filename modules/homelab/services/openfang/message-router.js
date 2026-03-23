#!/usr/bin/env node
import http from 'node:http';
import fs from 'node:fs';
import { execSync } from 'node:child_process';

const ROUTER_PORT = parseInt(process.env.ROUTER_PORT || '50052');
const OPENFANG_API = (process.env.OPENFANG_API || 'http://127.0.0.1:50051').replace(/\/+$/, '');
const DB_URL = process.env.DB_URL || 'postgresql://openfang@127.0.0.1:5432/openfang';
const MANIFEST_PATH = process.env.MANIFEST_PATH || '/etc/openfang/agent-manifest.toml';
const OPENFANG_BIN = process.env.OPENFANG_BIN || '/persist/openfang/.openfang/bin/openfang';
const OPENFANG_CONFIG = process.env.OPENFANG_CONFIG || '/persist/openfang/.openfang/config.toml';
const HOME_DIR = process.env.HOME || '/persist/openfang';
const ALLOWED_SENDERS_FILE = process.env.ALLOWED_SENDERS_FILE || '';

function loadAllowedSenders() {
  if (!ALLOWED_SENDERS_FILE) return null; // no file = allow all
  try {
    return fs.readFileSync(ALLOWED_SENDERS_FILE, 'utf8')
      .split('\n')
      .map(l => l.trim())
      .filter(l => l && !l.startsWith('#'));
  } catch (e) {
    console.error('[router] Could not read allowed senders file:', e.message);
    return null;
  }
}

function isSenderAllowed(sender) {
  const allowed = loadAllowedSenders();
  if (!allowed) return true; // no file = allow all
  // Check if sender phone (e.g. +559184519877) contains any allowed number
  const stripped = sender.replace(/\+/g, '');
  return allowed.some(num => stripped.includes(num.replace(/\+/g, '')));
}

function psql(query) {
  try {
    return execSync(
      `psql -t -A -c "${query.replace(/"/g, '\\"')}" "${DB_URL}"`,
      { encoding: 'utf8', timeout: 5000 }
    ).trim();
  } catch (e) {
    console.error('[router] psql error:', e.message);
    return '';
  }
}

function sqlEscape(str) {
  return (str || '').replace(/'/g, "''");
}

function spawnAgent() {
  try {
    const out = execSync(
      `HOME=${HOME_DIR} ${OPENFANG_BIN} agent spawn --config "${OPENFANG_CONFIG}" "${MANIFEST_PATH}"`,
      { encoding: 'utf8', timeout: 30000, env: { ...process.env, HOME: HOME_DIR } }
    );
    const match = out.match(/ID:\s+([a-f0-9-]+)/);
    if (match) {
      console.log('[router] Spawned new agent:', match[1]);
      return match[1];
    }
    console.error('[router] Could not parse agent ID from spawn output:', out);
    return null;
  } catch (e) {
    console.error('[router] spawn error:', e.message);
    return null;
  }
}

function getAgentForSender(sender, displayName, remoteJid) {
  const safeSender = sqlEscape(sender);
  const safeDisplay = sqlEscape(displayName || 'Unknown');
  const safeJid = sqlEscape(remoteJid || '');

  // Upsert channel_users row
  psql(
    "INSERT INTO channel_users (channel, channel_user_id, display_name, remote_jid) " +
    "VALUES ('whatsapp', '" + safeSender + "', '" + safeDisplay + "', '" + safeJid + "') " +
    "ON CONFLICT (channel, channel_user_id) DO UPDATE SET " +
    "display_name = '" + safeDisplay + "', " +
    "remote_jid = COALESCE(NULLIF('" + safeJid + "', ''), channel_users.remote_jid)"
  );

  // Check for existing agent_id
  const existingId = psql(
    "SELECT agent_id FROM channel_users WHERE channel = 'whatsapp' AND channel_user_id = '" + safeSender + "'"
  );

  // Valid UUID check
  if (existingId && /^[a-f0-9-]{36}$/.test(existingId)) {
    return existingId;
  }

  // No agent yet — spawn one
  const agentId = spawnAgent();
  if (agentId) {
    psql(
      "UPDATE channel_users SET agent_id = '" + agentId + "' " +
      "WHERE channel = 'whatsapp' AND channel_user_id = '" + safeSender + "'"
    );
  }
  return agentId;
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (chunk) => data += chunk);
    req.on('end', () => resolve(data));
  });
}

function proxyRequest(req, res, targetUrl, body) {
  const url = new URL(targetUrl);
  const proxyReq = http.request({
    hostname: url.hostname,
    port: url.port,
    path: url.pathname + url.search,
    method: req.method,
    headers: { ...req.headers, host: url.host, 'content-length': Buffer.byteLength(body || '') },
    timeout: 180000,
  }, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
  });
  proxyReq.on('error', (e) => {
    console.error('[router] proxy error:', e.message);
    res.writeHead(502);
    res.end(JSON.stringify({ error: 'Router proxy error: ' + e.message }));
  });
  if (body) proxyReq.write(body);
  proxyReq.end();
}

const server = http.createServer(async (req, res) => {
  // Only intercept POST /api/agents/*/message
  const isMessage = req.method === 'POST' && /^\/api\/agents\/[^/]+\/message$/.test(req.url);

  if (!isMessage) {
    const body = await readBody(req);
    proxyRequest(req, res, OPENFANG_API + req.url, body);
    return;
  }

  const body = await readBody(req);
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    proxyRequest(req, res, OPENFANG_API + req.url, body);
    return;
  }

  const sender = parsed.metadata?.sender;
  if (!sender) {
    // No sender metadata (e.g., dashboard chat) — pass through
    proxyRequest(req, res, OPENFANG_API + req.url, body);
    return;
  }

  // Check allowed senders
  if (!isSenderAllowed(sender)) {
    console.log('[router] REJECTED: ' + sender + ' not in allowed senders');
    res.writeHead(403);
    res.end(JSON.stringify({ error: 'Sender not allowed' }));
    return;
  }

  const displayName = parsed.metadata?.sender_name;
  const remoteJid = parsed.metadata?.remote_jid;

  const agentId = getAgentForSender(sender, displayName, remoteJid);
  if (!agentId) {
    console.error('[router] Failed to get agent for sender:', sender);
    res.writeHead(500);
    res.end(JSON.stringify({ error: 'Failed to create agent for sender' }));
    return;
  }

  const targetUrl = OPENFANG_API + '/api/agents/' + agentId + '/message';
  console.log('[router] ' + sender + ' -> agent ' + agentId);
  proxyRequest(req, res, targetUrl, body);
});

server.listen(ROUTER_PORT, '127.0.0.1', () => {
  console.log('[router] Message router listening on http://127.0.0.1:' + ROUTER_PORT);
  console.log('[router] Proxying to OpenFang at ' + OPENFANG_API);
});
