#!/usr/bin/env node
import http from 'node:http';
import fs from 'node:fs';
import { execSync } from 'node:child_process';
import { processMedia } from './media-handler.js';

const ROUTER_PORT = parseInt(process.env.ROUTER_PORT || '50052');
const OPENFANG_API = (process.env.OPENFANG_API || 'http://127.0.0.1:50051').replace(/\/+$/, '');
const GATEWAY_URL = (process.env.GATEWAY_URL || 'http://127.0.0.1:3010').replace(/\/+$/, '');
const DB_URL = process.env.DB_URL || 'postgresql://openfang@127.0.0.1:5432/openfang';
const MANIFEST_PATH = process.env.MANIFEST_PATH || '/etc/openfang/agent-manifest.toml';
const OPENFANG_BIN = process.env.OPENFANG_BIN || '/persist/openfang/.openfang/bin/openfang';
const OPENFANG_CONFIG = process.env.OPENFANG_CONFIG || '/persist/openfang/.openfang/config.toml';
const HOME_DIR = process.env.HOME || '/persist/openfang';
const ALLOWED_SENDERS_FILE = process.env.ALLOWED_SENDERS_FILE || '';

// --- Per-sender message queue ---
// Serializes message processing per sender to prevent race conditions
// when multiple messages arrive while an agent is still processing.
const senderQueues = new Map();

function enqueueMessage(sender, item) {
  if (!senderQueues.has(sender)) {
    senderQueues.set(sender, { processing: false, queue: [] });
  }
  const sq = senderQueues.get(sender);
  sq.queue.push(item);
  if (!sq.processing) {
    processQueue(sender);
  }
}

async function processQueue(sender) {
  const sq = senderQueues.get(sender);
  if (!sq || sq.queue.length === 0) {
    if (sq) sq.processing = false;
    return;
  }
  sq.processing = true;
  const item = sq.queue.shift();
  const queueDepth = sq.queue.length;
  if (queueDepth > 0) {
    console.log('[router] ' + sender + ' queue depth: ' + queueDepth + ' waiting');
  }
  try {
    await handleSenderMessage(item);
  } catch (e) {
    console.error('[router] queue processing error for ' + sender + ':', e.message);
  }
  // Process next message in queue
  processQueue(sender);
}

// --- Helpers ---

function loadAllowedSenders() {
  if (!ALLOWED_SENDERS_FILE) {
    console.error('[router] ALLOWED_SENDERS_FILE not configured — denying all');
    return null;
  }
  try {
    return fs.readFileSync(ALLOWED_SENDERS_FILE, 'utf8')
      .split('\n')
      .map(l => l.trim())
      .filter(l => l && !l.startsWith('#'));
  } catch (e) {
    console.error('[router] Could not read allowed senders file — denying all:', e.message);
    return null;
  }
}

function isSenderAllowed(sender) {
  const allowed = loadAllowedSenders();
  if (!allowed) return false; // fail closed: no file = deny all
  const stripped = sender.replace(/[^0-9]/g, '');
  return allowed.some(num => stripped === num.replace(/[^0-9]/g, ''));
}

function psql(query) {
  try {
    return execSync('psql -t -A -c "$SQL" "$DB"', {
      encoding: 'utf8',
      timeout: 5000,
      env: { ...process.env, SQL: query, DB: DB_URL },
    }).trim();
  } catch (e) {
    console.error('[router] psql error:', e.message);
    return '';
  }
}

function sqlEscape(str) {
  return (str || '').replace(/'/g, "''");
}

// --- Conversation logging ---

function logConversation(channelUserId, direction, content, metadata) {
  try {
    const safeId = sqlEscape(channelUserId);
    const safeContent = sqlEscape(typeof content === 'string' ? content : JSON.stringify(content));
    const safeMeta = sqlEscape(JSON.stringify(metadata || {}));
    psql(
      "INSERT INTO conversation_log (channel_user_id, direction, content, metadata) " +
      "VALUES ('" + safeId + "', '" + direction + "', '" + safeContent + "', '" + safeMeta + "'::jsonb)"
    );
  } catch (e) {
    console.error('[router] conversation log error:', e.message);
  }
}

// --- Agent management ---

function spawnAgent(senderPhone) {
  try {
    const manifest = fs.readFileSync(MANIFEST_PATH, 'utf8');
    const stripped = senderPhone.replace(/[^0-9]/g, '');
    const uniqueName = 'fluzy-' + stripped;
    const tmpManifest = '/tmp/openfang-manifest-' + stripped + '.toml';
    fs.writeFileSync(tmpManifest, manifest.replace(/^name = ".*"$/m, 'name = "' + uniqueName + '"'));

    const out = execSync(
      `HOME=${HOME_DIR} ${OPENFANG_BIN} agent spawn --config "${OPENFANG_CONFIG}" "${tmpManifest}"`,
      { encoding: 'utf8', timeout: 30000, env: { ...process.env, HOME: HOME_DIR } }
    );

    try { fs.unlinkSync(tmpManifest); } catch {}

    const match = out.match(/ID:\s+([a-f0-9-]+)/);
    if (match) {
      console.log('[router] Spawned agent ' + uniqueName + ':', match[1]);
      return match[1];
    }
    console.error('[router] Could not parse agent ID from spawn output:', out);
    return null;
  } catch (e) {
    console.error('[router] spawn error:', e.message);
    return null;
  }
}

// Safe because message queue serializes per-sender — no concurrent calls for same sender
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
  const agentId = spawnAgent(sender);
  if (agentId) {
    psql(
      "UPDATE channel_users SET agent_id = '" + agentId + "' " +
      "WHERE channel = 'whatsapp' AND channel_user_id = '" + safeSender + "'"
    );
  }
  return agentId;
}

// --- Async reply via gateway ---

function sendReplyViaGateway(jid, text, quotedId) {
  return new Promise((resolve) => {
    const payload = JSON.stringify({ jid, text, quotedId: quotedId || undefined });
    const url = new URL(GATEWAY_URL + '/api/send');
    const req = http.request({
      hostname: url.hostname,
      port: url.port,
      path: url.pathname,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
      timeout: 10000,
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(true);
        } else {
          console.error('[router] Gateway send failed: ' + res.statusCode + ' ' + data);
          resolve(false);
        }
      });
    });
    req.on('error', (e) => {
      console.error('[router] Gateway send error:', e.message);
      resolve(false);
    });
    req.write(payload);
    req.end();
  });
}

// Fire-and-forget proxy to OpenFang that captures the response
function proxyToOpenfang(targetUrl, body, headers) {
  return new Promise((resolve, reject) => {
    const url = new URL(targetUrl);
    const proxyReq = http.request({
      hostname: url.hostname,
      port: url.port,
      path: url.pathname + url.search,
      method: 'POST',
      headers: { ...headers, host: url.host, 'content-length': Buffer.byteLength(body || '') },
      timeout: 300000, // 5 min — LLM can be slow
    }, (proxyRes) => {
      const chunks = [];
      proxyRes.on('data', chunk => chunks.push(chunk));
      proxyRes.on('end', () => resolve(Buffer.concat(chunks).toString()));
    });
    proxyReq.on('error', reject);
    proxyReq.on('timeout', () => { proxyReq.destroy(); reject(new Error('OpenFang timeout')); });
    if (body) proxyReq.write(body);
    proxyReq.end();
  });
}

// Legacy sync proxy for non-message routes (dashboard, API calls)
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
    try { res.writeHead(502); res.end(JSON.stringify({ error: e.message })); } catch {}
  });
  if (body) proxyReq.write(body);
  proxyReq.end();
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (chunk) => data += chunk);
    req.on('end', () => resolve(data));
  });
}

// --- Message handler (called from queue, one at a time per sender) ---

async function handleSenderMessage({ req, res, body, parsed }) {
  const sender = parsed.metadata?.sender;
  const displayName = parsed.metadata?.sender_name;
  const remoteJid = parsed.metadata?.remote_jid;
  const messageId = parsed.metadata?.message_id;
  let messageContent = parsed.content || parsed.message || '';

  // --- Media processing ---
  let mediaResult = null;
  try {
    mediaResult = await processMedia(parsed);
  } catch (e) {
    console.error('[router] media processing error:', e.message);
  }

  if (mediaResult) {
    if (mediaResult.contentOverride) {
      messageContent = mediaResult.contentOverride;
    }
    if (mediaResult.contentPrefix) {
      messageContent = mediaResult.contentPrefix + '\n\n' + (messageContent || '');
    }
    if (mediaResult.stripMedia) {
      delete parsed.metadata.media_base64;
    }
    parsed.content = messageContent;
    parsed.message = messageContent;
    body = JSON.stringify(parsed);
  }

  const agentId = getAgentForSender(sender, displayName, remoteJid);
  if (!agentId) {
    console.error('[router] Failed to get agent for sender:', sender);
    // Respond to gateway immediately — no reply to send
    res.writeHead(200);
    res.end(JSON.stringify({ status: 'error', error: 'Failed to create agent' }));
    return;
  }

  // Log incoming message
  logConversation(sender, 'in', messageContent, {
    sender_name: displayName,
    agent_id: agentId,
    media_type: parsed.metadata?.media_type || null,
  });

  const targetUrl = OPENFANG_API + '/api/agents/' + agentId + '/message';
  console.log('[router] ' + sender + ' -> agent ' + agentId + (parsed.metadata?.media_type ? ' [' + parsed.metadata.media_type + ']' : ''));

  // Respond to gateway IMMEDIATELY — no timeout possible
  res.writeHead(200);
  res.end(JSON.stringify({ status: 'accepted' }));

  // Proxy to OpenFang async — gateway is already free
  try {
    const responseBody = await proxyToOpenfang(targetUrl, body, req.headers);

    // Extract reply text
    let replyText = '';
    if (responseBody) {
      try {
        const respParsed = JSON.parse(responseBody);
        replyText = respParsed.response || respParsed.content || responseBody;
      } catch {
        replyText = responseBody;
      }
    }

    // Log outgoing response
    logConversation(sender, 'out', replyText, { agent_id: agentId });

    // Send reply to WhatsApp via gateway
    if (replyText && remoteJid) {
      const sent = await sendReplyViaGateway(remoteJid, replyText, messageId);
      if (sent) {
        console.log('[router] Reply sent to ' + sender + ' via gateway');
      } else {
        console.error('[router] Failed to send reply to ' + sender);
      }
    }
  } catch (e) {
    console.error('[router] OpenFang proxy error for ' + sender + ':', e.message);
    logConversation(sender, 'out', 'ERROR: ' + e.message, { agent_id: agentId });

    // Notify user of error via gateway
    if (remoteJid) {
      await sendReplyViaGateway(remoteJid, 'Desculpa, tive um erro processando sua mensagem. Tenta de novo?');
    }
  }
}

// --- Server ---

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
    // No sender metadata (e.g., dashboard chat) — pass through synchronously
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

  // Enqueue — processed one at a time per sender
  enqueueMessage(sender, { req, res, body, parsed });
});

server.listen(ROUTER_PORT, '127.0.0.1', () => {
  console.log('[router] Message router listening on http://127.0.0.1:' + ROUTER_PORT);
  console.log('[router] Proxying to OpenFang at ' + OPENFANG_API);
  console.log('[router] Replies via gateway at ' + GATEWAY_URL);
});
