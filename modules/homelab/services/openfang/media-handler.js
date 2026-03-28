#!/usr/bin/env node
// Media handler for WhatsApp messages:
// - Documents: auto-upload to Paperless-ngx
// - Images: describe via Gemini vision + offer Paperless upload
// - Audio: transcribe locally via whisper-cpp
// - Video/Sticker: acknowledge receipt

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import https from 'node:https';
import http from 'node:http';

const PAPERLESS_API_URL = (process.env.PAPERLESS_API_URL || 'http://127.0.0.1:28981').replace(/\/+$/, '');
const PAPERLESS_API_TOKEN = process.env.PAPERLESS_API_TOKEN || '';
const GEMINI_API_KEY = process.env.GEMINI_API_KEY || '';
const MEDIA_TMP_DIR = process.env.MEDIA_TMP_DIR || '/persist/openfang/media-tmp';
const FFMPEG_PATH = process.env.FFMPEG_PATH || 'ffmpeg';
const WHISPER_PATH = process.env.WHISPER_PATH || 'whisper-cli';
const WHISPER_MODEL = process.env.WHISPER_MODEL || '/persist/openfang/models/ggml-small.bin';
const LLAMA_MTMD_PATH = process.env.LLAMA_MTMD_PATH || 'llama-mtmd-cli';
const MOONDREAM_REPO = process.env.MOONDREAM_REPO || 'vikhyatk/moondream2-2025-01-09-gguf';
const HF_HOME = process.env.HF_HOME || '/persist/openfang/models/hf-cache';

// Ensure tmp dir exists
try { fs.mkdirSync(MEDIA_TMP_DIR, { recursive: true }); } catch {}

// --- Paperless upload ---

function uploadToPaperless(base64Data, mimetype, filename, sender) {
  return new Promise((resolve, reject) => {
    const buffer = Buffer.from(base64Data, 'base64');

    const ext = mimeToExt(mimetype);
    const safeName = filename || ('whatsapp-' + Date.now() + ext);

    const boundary = '----FormBoundary' + Math.random().toString(36).slice(2);
    const parts = [];

    parts.push(
      '--' + boundary + '\r\n' +
      'Content-Disposition: form-data; name="document"; filename="' + safeName + '"\r\n' +
      'Content-Type: ' + mimetype + '\r\n\r\n'
    );
    parts.push(buffer);
    parts.push('\r\n');

    parts.push(
      '--' + boundary + '\r\n' +
      'Content-Disposition: form-data; name="title"\r\n\r\n' +
      safeName + '\r\n'
    );

    parts.push('--' + boundary + '--\r\n');

    const bodyParts = parts.map(p => typeof p === 'string' ? Buffer.from(p) : p);
    const body = Buffer.concat(bodyParts);

    const url = new URL(PAPERLESS_API_URL + '/api/documents/post_document/');
    const transport = url.protocol === 'https:' ? https : http;

    const req = transport.request({
      hostname: url.hostname,
      port: url.port,
      path: url.pathname,
      method: 'POST',
      headers: {
        'Authorization': 'Token ' + PAPERLESS_API_TOKEN,
        'Content-Type': 'multipart/form-data; boundary=' + boundary,
        'Content-Length': body.length,
      },
      timeout: 30000,
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          console.log('[media] Uploaded to Paperless: ' + safeName + ' (status ' + res.statusCode + ')');
          resolve({ success: true, filename: safeName, response: data });
        } else {
          console.error('[media] Paperless upload failed: ' + res.statusCode + ' ' + data);
          resolve({ success: false, error: 'HTTP ' + res.statusCode, filename: safeName });
        }
      });
    });

    req.on('error', (e) => {
      console.error('[media] Paperless upload error:', e.message);
      resolve({ success: false, error: e.message, filename: safeName });
    });

    req.write(body);
    req.end();
  });
}

// --- Audio transcription via local whisper-cpp ---

function transcribeAudio(base64Data, mimetype) {
  try {
    // Check if whisper model exists
    if (!fs.existsSync(WHISPER_MODEL)) {
      console.error('[media] Whisper model not found at ' + WHISPER_MODEL);
      return { success: false, error: 'Whisper model not available' };
    }

    // Save audio to temp file
    const tmpIn = path.join(MEDIA_TMP_DIR, 'audio-' + Date.now() + '.ogg');
    const tmpWav = path.join(MEDIA_TMP_DIR, 'audio-' + Date.now() + '.wav');
    fs.writeFileSync(tmpIn, Buffer.from(base64Data, 'base64'));

    // Convert to 16kHz mono WAV (required by whisper-cpp)
    execSync(FFMPEG_PATH + ' -i ' + tmpIn + ' -y -ar 16000 -ac 1 -c:a pcm_s16le ' + tmpWav + ' 2>/dev/null', {
      timeout: 30000,
    });
    try { fs.unlinkSync(tmpIn); } catch {}

    // Run whisper-cli
    const output = execSync(
      WHISPER_PATH + ' -m ' + WHISPER_MODEL + ' -l auto -np -nt -f ' + tmpWav,
      { encoding: 'utf8', timeout: 120000 }
    );
    try { fs.unlinkSync(tmpWav); } catch {}

    // Parse output — whisper-cli outputs text lines, strip timestamps if present
    const text = output
      .split('\n')
      .map(l => l.replace(/^\[.*?\]\s*/, '').trim())
      .filter(l => l)
      .join(' ')
      .trim();

    if (text) {
      console.log('[media] Audio transcribed locally (' + text.length + ' chars)');
      return { success: true, transcription: text };
    }
    return { success: false, error: 'Whisper returned empty output' };
  } catch (e) {
    console.error('[media] Whisper transcription error:', e.message);
    return { success: false, error: 'Transcription failed: ' + e.message };
  }
}

// --- Image description via local moondream2 (Gemini fallback) ---

function describeImageLocal(imagePath, prompt) {
  try {
    const output = execSync(
      LLAMA_MTMD_PATH + ' -hf ' + MOONDREAM_REPO +
      ' --image ' + imagePath +
      ' -p "' + prompt.replace(/"/g, '\\"') + '"' +
      ' -n 200 --temp 0.1 2>/dev/null',
      {
        encoding: 'utf8',
        timeout: 120000,
        env: { ...process.env, HF_HOME },
      }
    );
    // llama-mtmd-cli outputs the response after the prompt
    const text = output.trim();
    if (text) {
      console.log('[media] Image described locally (' + text.length + ' chars)');
      return { success: true, description: text };
    }
    return { success: false, error: 'Empty output from moondream2' };
  } catch (e) {
    console.error('[media] Local vision error:', e.message);
    return { success: false, error: e.message };
  }
}

function describeImageGemini(base64Data, mimetype, prompt) {
  return new Promise((resolve) => {
    if (!GEMINI_API_KEY) {
      resolve({ success: false, error: 'No GEMINI_API_KEY configured' });
      return;
    }

    const payload = JSON.stringify({
      contents: [{
        parts: [
          { inline_data: { mime_type: mimetype, data: base64Data } },
          { text: prompt }
        ]
      }],
      generationConfig: { temperature: 0.2, maxOutputTokens: 300 }
    });

    const req = https.request({
      hostname: 'generativelanguage.googleapis.com',
      path: '/v1beta/models/gemini-2.5-flash:generateContent?key=' + GEMINI_API_KEY,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
      },
      timeout: 30000,
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          const text = parsed.candidates?.[0]?.content?.parts?.[0]?.text;
          if (text) {
            console.log('[media] Image described via Gemini (' + text.length + ' chars)');
            resolve({ success: true, description: text.trim() });
          } else {
            resolve({ success: false, error: 'No description in response' });
          }
        } catch (e) {
          resolve({ success: false, error: 'Failed to parse response' });
        }
      });
    });
    req.on('error', (e) => resolve({ success: false, error: e.message }));
    req.write(payload);
    req.end();
  });
}

async function describeImage(base64Data, mimetype, imagePath) {
  const prompt = 'Classify this image into one category: receipt, payment_confirmation, invoice, company_document, screenshot, photo, meme, other. Then briefly describe what you see including any visible text, amounts, dates, or names. Format: CATEGORY: description';

  // Try local moondream2 first
  if (imagePath) {
    const local = describeImageLocal(imagePath, prompt);
    if (local.success) return local;
    console.log('[media] Local vision failed, falling back to Gemini');
  }

  // Fallback to Gemini
  return describeImageGemini(base64Data, mimetype, prompt);
}

// --- Helpers ---

function mimeToExt(mime) {
  const map = {
    'application/pdf': '.pdf',
    'image/jpeg': '.jpg',
    'image/png': '.png',
    'image/webp': '.webp',
    'audio/ogg': '.ogg',
    'audio/mpeg': '.mp3',
    'audio/mp4': '.m4a',
    'video/mp4': '.mp4',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document': '.docx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': '.xlsx',
    'application/msword': '.doc',
    'text/plain': '.txt',
  };
  return map[mime] || '';
}

function isDocument(mimetype) {
  const docTypes = [
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats',
    'text/plain',
    'text/csv',
    'application/vnd.oasis.opendocument',
  ];
  return docTypes.some(t => mimetype.includes(t));
}

// --- Main export: process media in a message ---

function sanitizeFilename(name) {
  if (!name) return 'unknown';
  return name.replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 100);
}

export async function processMedia(parsed) {
  const meta = parsed.metadata || {};
  const mediaType = meta.media_type;
  const mediaBase64 = meta.media_base64;
  const mediaMime = meta.media_mimetype || 'application/octet-stream';
  const mediaFilename = sanitizeFilename(meta.media_filename);
  const sender = meta.sender;

  if (!mediaType || !mediaBase64) {
    return null; // No media to process
  }

  const sizeKB = Math.round(mediaBase64.length * 3 / 4 / 1024);
  console.log('[media] Processing ' + mediaType + ' (' + mediaMime + ', ' + sizeKB + ' KB) from ' + sender);

  // --- DOCUMENT: auto-upload to Paperless ---
  if (mediaType === 'document' || (mediaType === 'image' && isDocument(mediaMime))) {
    if (!PAPERLESS_API_TOKEN) {
      return {
        contentPrefix: '[System: User sent a document (' + (mediaFilename || mediaMime) + ') but Paperless API token is not configured. Tell the user the upload failed.]',
        stripMedia: true,
      };
    }

    const result = await uploadToPaperless(mediaBase64, mediaMime, mediaFilename, sender);

    if (result.success) {
      return {
        contentPrefix: '[System: User sent a document "' + result.filename + '". It was automatically uploaded to Paperless-ngx. Let the user know it was uploaded and they can search for it later using paperless-tool.]',
        stripMedia: true,
      };
    } else {
      return {
        contentPrefix: '[System: User sent a document "' + (mediaFilename || 'unknown') + '" but upload to Paperless failed: ' + result.error + '. Let the user know.]',
        stripMedia: true,
      };
    }
  }

  // --- IMAGE: describe via local moondream2 (Gemini fallback) + offer Paperless upload ---
  if (mediaType === 'image') {
    const ext = mimeToExt(mediaMime) || '.jpg';
    const tmpFile = path.join(MEDIA_TMP_DIR, 'img-' + Date.now() + ext);
    try {
      fs.writeFileSync(tmpFile, Buffer.from(mediaBase64, 'base64'));
    } catch {}

    // Get AI description — local first, Gemini fallback
    const vision = await describeImage(mediaBase64, mediaMime, tmpFile);
    const description = vision.success ? vision.description : 'Could not analyze image';

    // Check if it looks like a document/receipt for auto-upload suggestion
    const isDoc = /receipt|payment|invoice|document|comprovante|recibo|nota fiscal/i.test(description);

    let prefix = '[System: User sent an image (' + mediaMime + ', ' + sizeKB + ' KB). AI analysis: "' + description.replace(/"/g, "'").slice(0, 400) + '". Image saved at ' + tmpFile + '. You can SEE this image via the analysis above — respond based on what it shows.';
    if (isDoc) {
      prefix += ' This appears to be a document/receipt. Offer to store it in Paperless: /persist/openfang/scripts/paperless-upload.sh "' + tmpFile + '" "' + (sender || '') + '"';
    }
    prefix += ']';

    return { contentPrefix: prefix, stripMedia: true };
  }

  // --- AUDIO: transcribe locally via whisper-cpp ---
  if (mediaType === 'audio') {
    const result = transcribeAudio(mediaBase64, mediaMime);

    if (result.success) {
      return {
        contentOverride: result.transcription,
        stripMedia: true,
      };
    } else {
      return {
        contentPrefix: '[System: User sent an audio message but transcription failed: ' + result.error + '. Let the user know you could not understand the audio.]',
        stripMedia: true,
      };
    }
  }

  // --- VIDEO: acknowledge ---
  if (mediaType === 'video') {
    return {
      contentPrefix: '[System: User sent a video (' + mediaMime + ', ' + sizeKB + ' KB). Video processing is not yet supported. Let the user know.]',
      stripMedia: true,
    };
  }

  // --- STICKER: acknowledge ---
  if (mediaType === 'sticker') {
    return {
      contentPrefix: '[System: User sent a sticker. React naturally.]',
      stripMedia: true,
    };
  }

  return null;
}
