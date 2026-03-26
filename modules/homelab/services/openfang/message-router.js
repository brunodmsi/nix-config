#!/usr/bin/env node
import http from 'node:http';
import fs from 'node:fs';
import { execSync } from 'node:child_process';
import { processMedia } from './media-handler.js';

const ROUTER_PORT = parseInt(process.env.ROUTER_PORT || '50052');
const OPENFANG_API = (process.env.OPENFANG_API || 'http://127.0.0.1:50051').replace(/\/+$/, '');
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
    try {
      item.res.writeHead(500);
      item.res.end(JSON.stringify({ error: 'Router error: ' + e.message }));
    } catch {}
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

// --- Proxy ---

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (chunk) => data += chunk);
    req.on('end', () => resolve(data));
  });
}

// Async proxy that optionally captures the response body for logging
function proxyRequestAsync(req, res, targetUrl, body, captureResponse) {
  return new Promise((resolve, reject) => {
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

      if (captureResponse) {
        const chunks = [];
        proxyRes.on('data', chunk => {
          chunks.push(chunk);
          res.write(chunk);
        });
        proxyRes.on('end', () => {
          res.end();
          resolve(Buffer.concat(chunks).toString());
        });
      } else {
        proxyRes.pipe(res);
        proxyRes.on('end', () => resolve(''));
      }
    });
    proxyReq.on('error', (e) => {
      console.error('[router] proxy error:', e.message);
      try {
        res.writeHead(502);
        res.end(JSON.stringify({ error: 'Router proxy error: ' + e.message }));
      } catch {}
      reject(e);
    });
    if (body) proxyReq.write(body);
    proxyReq.end();
  });
}

// Legacy sync proxy for non-message routes
function proxyRequest(req, res, targetUrl, body) {
  proxyRequestAsync(req, res, targetUrl, body, false).catch(() => {});
}

// --- Message handler (called from queue, one at a time per sender) ---

async function handleSenderMessage({ req, res, body, parsed }) {
  const sender = parsed.metadata?.sender;
  const displayName = parsed.metadata?.sender_name;
  const remoteJid = parsed.metadata?.remote_jid;
  let messageContent = parsed.content || parsed.message || '';

  // --- Media processing ---
  let mediaResult = null;
  try {
    mediaResult = await processMedia(parsed);
  } catch (e) {
    console.error('[router] media processing error:', e.message);
  }

  if (mediaResult) {
    // Use transcription as the message content if available
    if (mediaResult.contentOverride) {
      messageContent = mediaResult.contentOverride;
    }

    // Prepend system context about the media
    if (mediaResult.contentPrefix) {
      messageContent = mediaResult.contentPrefix + '\n\n' + (messageContent || '');
    }

    // Strip base64 media data from payload before forwarding to OpenFang
    if (mediaResult.stripMedia) {
      delete parsed.metadata.media_base64;
    }

    // Update the parsed payload with enriched content
    parsed.content = messageContent;
    parsed.message = messageContent;
    body = JSON.stringify(parsed);
  }

  const agentId = getAgentForSender(sender, displayName, remoteJid);
  if (!agentId) {
    console.error('[router] Failed to get agent for sender:', sender);
    res.writeHead(500);
    res.end(JSON.stringify({ error: 'Failed to create agent for sender' }));
    return;
  }

  // Log incoming message (without base64 data)
  logConversation(sender, 'in', messageContent, {
    sender_name: displayName,
    agent_id: agentId,
    media_type: parsed.metadata?.media_type || null,
  });

  const targetUrl = OPENFANG_API + '/api/agents/' + agentId + '/message';
  console.log('[router] ' + sender + ' -> agent ' + agentId + (parsed.metadata?.media_type ? ' [' + parsed.metadata.media_type + ']' : ''));

  // Proxy and capture response for logging
  try {
    const responseBody = await proxyRequestAsync(req, res, targetUrl, body, true);

    // Log outgoing response (best effort)
    if (responseBody) {
      try {
        const respParsed = JSON.parse(responseBody);
        logConversation(sender, 'out', respParsed.response || respParsed.content || responseBody, {
          agent_id: agentId,
        });
      } catch {
        logConversation(sender, 'out', responseBody, { agent_id: agentId });
      }
    }
  } catch (e) {
    logConversation(sender, 'out', 'ERROR: ' + e.message, { agent_id: agentId });
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

  // Enqueue — processed one at a time per sender
  enqueueMessage(sender, { req, res, body, parsed });
});

server.listen(ROUTER_PORT, '127.0.0.1', () => {
  console.log('[router] Message router listening on http://127.0.0.1:' + ROUTER_PORT);
  console.log('[router] Proxying to OpenFang at ' + OPENFANG_API);
});
