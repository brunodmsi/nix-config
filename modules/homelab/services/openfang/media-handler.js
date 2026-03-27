#!/usr/bin/env node
// Media handler for WhatsApp messages:
// - Documents: auto-upload to Paperless-ngx
// - Images: pass through for Fluzy to ask user
// - Audio: transcribe via Gemini API
// - Video/Sticker: acknowledge receipt

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import https from 'node:https';
import http from 'node:http';

const PAPERLESS_API_URL = (process.env.PAPERLESS_API_URL || 'http://127.0.0.1:28981').replace(/\/+$/, '');
const PAPERLESS_API_TOKEN = process.env.PAPERLESS_API_TOKEN || '';
const GEMINI_API_KEY = process.env.GEMINI_API_KEY || '';
const MEDIA_TMP_DIR = process.env.MEDIA_TMP_DIR || '/tmp/openfang-media';
const FFMPEG_PATH = process.env.FFMPEG_PATH || 'ffmpeg';

// Ensure tmp dir exists
try { fs.mkdirSync(MEDIA_TMP_DIR, { recursive: true }); } catch {}

// --- Paperless upload ---

function uploadToPaperless(base64Data, mimetype, filename, sender) {
  return new Promise((resolve, reject) => {
    const buffer = Buffer.from(base64Data, 'base64');

    // Determine filename
    const ext = mimeToExt(mimetype);
    const safeName = filename || ('whatsapp-' + Date.now() + ext);

    // Build multipart form data
    const boundary = '----FormBoundary' + Math.random().toString(36).slice(2);
    const parts = [];

    // Document file
    parts.push(
      '--' + boundary + '\r\n' +
      'Content-Disposition: form-data; name="document"; filename="' + safeName + '"\r\n' +
      'Content-Type: ' + mimetype + '\r\n\r\n'
    );
    parts.push(buffer);
    parts.push('\r\n');

    // Title
    parts.push(
      '--' + boundary + '\r\n' +
      'Content-Disposition: form-data; name="title"\r\n\r\n' +
      safeName + '\r\n'
    );

    parts.push('--' + boundary + '--\r\n');

    // Combine parts
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

// --- Audio transcription via Gemini ---

function transcribeAudio(base64Data, mimetype) {
  return new Promise((resolve, reject) => {
    if (!GEMINI_API_KEY) {
      resolve({ success: false, error: 'No GEMINI_API_KEY configured' });
      return;
    }

    // Convert ogg/opus to mp3 via ffmpeg for better compatibility
    let audioBase64 = base64Data;
    let audioMime = mimetype;

    if (mimetype.includes('ogg') || mimetype.includes('opus')) {
      try {
        const tmpIn = path.join(MEDIA_TMP_DIR, 'audio-' + Date.now() + '.ogg');
        const tmpOut = path.join(MEDIA_TMP_DIR, 'audio-' + Date.now() + '.mp3');
        fs.writeFileSync(tmpIn, Buffer.from(base64Data, 'base64'));
        execSync(FFMPEG_PATH + ' -i ' + tmpIn + ' -y -q:a 2 ' + tmpOut + ' 2>/dev/null', { timeout: 15000 });
        audioBase64 = fs.readFileSync(tmpOut).toString('base64');
        audioMime = 'audio/mp3';
        try { fs.unlinkSync(tmpIn); } catch {}
        try { fs.unlinkSync(tmpOut); } catch {}
      } catch (e) {
        console.error('[media] ffmpeg conversion failed:', e.message);
        // Fall back to original format
      }
    }

    const payload = JSON.stringify({
      contents: [{
        parts: [
          {
            inline_data: {
              mime_type: audioMime,
              data: audioBase64,
            }
          },
          {
            text: "Transcribe this audio message exactly as spoken. If the language is not English, transcribe in the original language. Return ONLY the transcription, nothing else."
          }
        ]
      }],
      generationConfig: {
        temperature: 0.1,
        maxOutputTokens: 2048,
      }
    });

    const req = https.request({
      hostname: 'generativelanguage.googleapis.com',
      path: '/v1beta/models/gemini-2.5-flash:generateContent?key=' + GEMINI_API_KEY,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
      },
      timeout: 60000,
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          const text = parsed.candidates?.[0]?.content?.parts?.[0]?.text;
          if (text) {
            console.log('[media] Audio transcribed (' + text.length + ' chars)');
            resolve({ success: true, transcription: text.trim() });
          } else {
            console.error('[media] Gemini response missing text:', data.slice(0, 200));
            resolve({ success: false, error: 'No transcription in response' });
          }
        } catch (e) {
          console.error('[media] Gemini parse error:', e.message);
          resolve({ success: false, error: 'Failed to parse Gemini response' });
        }
      });
    });

    req.on('error', (e) => {
      console.error('[media] Gemini request error:', e.message);
      resolve({ success: false, error: e.message });
    });

    req.write(payload);
    req.end();
  });
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
        contentPrefix: '[System: User sent a document "' + result.filename + '". It was automatically uploaded to Paperless-ngx for OCR and storage. Let the user know it was uploaded successfully. They can search for it later using the paperless-tool.]',
        stripMedia: true,
      };
    } else {
      return {
        contentPrefix: '[System: User sent a document "' + (mediaFilename || 'unknown') + '" but upload to Paperless failed: ' + result.error + '. Let the user know.]',
        stripMedia: true,
      };
    }
  }

  // --- IMAGE: pass info to Fluzy, let it ask the user ---
  if (mediaType === 'image') {
    // Save temporarily so Fluzy could reference it if needed
    const ext = mimeToExt(mediaMime) || '.jpg';
    const tmpFile = path.join(MEDIA_TMP_DIR, 'img-' + Date.now() + ext);
    try {
      fs.writeFileSync(tmpFile, Buffer.from(mediaBase64, 'base64'));
    } catch {}

    return {
      contentPrefix: '[System: User sent an image (' + mediaMime + ', ' + sizeKB + ' KB). The image is saved at ' + tmpFile + '. Ask the user if they want to upload it to Paperless-ngx for storage. If they say yes, use shell_exec to run: /persist/openfang/scripts/paperless-upload.sh "' + tmpFile + '" "' + (sender || '') + '"]',
      stripMedia: true,
    };
  }

  // --- AUDIO: transcribe via Gemini ---
  if (mediaType === 'audio') {
    const result = await transcribeAudio(mediaBase64, mediaMime);

    if (result.success) {
      // Transcription is user-controlled content — use as contentOverride only,
      // not embedded in [System:] context to avoid prompt injection
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
