#!/usr/bin/env node

/**
 * src/index.js
 * Syntex MCP Server
 *
 * Loaded automatically by OpenClaw before every task.
 * Structures outbound tasks before they reach Syntex by:
 *
 *   1. Reading SOUL.md  — extracting one sentence relevant to the task
 *   2. Reading MEMORY.md — extracting 2-3 facts relevant to the task
 *   3. Fetching user preferences from Syntex (GET /api/user/preferences)
 *   4. Detecting task type: ROUTINE | INTELLIGENT | SYNTHESIS | ENGINEERING
 *   5. Structuring with labeled fields: [AGENT] [CONTEXT] [TASK] [DELIVERABLE]
 *      [SCOPE] [SUCCESS] [CONSTRAINTS]
 *   6. Injecting user preferences as hard constraints
 *   7. Suppressing chain-of-thought for ROUTINE and INTELLIGENT tasks
 *
 * Required env var:
 *   SX_TOKEN — Syntex bearer token (format: SX-xxxxxxxxxxxxxxxx)
 *
 * Optional env var:
 *   OC_WORKING_DIR — fallback path if MCP roots are unavailable
 */

import { Server }               from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ListRootsResultSchema
} from '@modelcontextprotocol/sdk/types.js';
import { readFileSync, existsSync } from 'fs';
import { join }                  from 'path';
import { fileURLToPath }         from 'url';

// ─── ENV ──────────────────────────────────────────────────────────────────────

const SX_TOKEN        = process.env.SX_TOKEN        || '';
const OC_WORKING_DIR  = process.env.OC_WORKING_DIR  || '';
const SX_GATEWAY_PORT = process.env.SX_GATEWAY_PORT || '';
const SYNTEX_BASE_URL = 'https://syntexprotocol.com';

// ─── RISE TIER DETECTION ──────────────────────────────────────────────────────
//
// Mirrors the isObviousRTier() pre-filter from Syntex classify.js.
// ROUTINE uses the same conservative action+subject pattern gate.
// ENGINEERING and SYNTHESIS are detected by keyword heuristics.
// Everything else defaults to INTELLIGENT.
//
// No LLM call — this is a deterministic pre-processing pass only.

const ACTION_PATTERNS = [
  /\brename\b/, /\breformat\b/, /\bformat\b/, /\bconvert\b/,
  /\bcopy\b/,   /\bpaste\b/,   /\btranslate\b/, /\btranscribe\b/,
  /\bextract\b/, /\bparse\b/,  /\bsort\b/,  /\bfilter\b/,
  /\blist\b/,   /\bcount\b/,   /\bfind and replace\b/, /\bstrip\b/,
  /\bclean up\b/, /\bremove\b/, /\bfill in\b/, /\bfill out\b/
];

const SUBJECT_PATTERNS = [
  /\bfile[s]?\b/, /\bcsv\b/, /\bjson\b/, /\bspreadsheet\b/,
  /\bcolumn[s]?\b/, /\brow[s]?\b/, /\blist\b/, /\btemplate\b/,
  /\btext\b/, /\bstring\b/, /\bdate[s]?\b/, /\bnumber[s]?\b/,
  /\bformat\b/, /\btable\b/
];

const ROUTINE_DISQUALIFIERS = [
  /\banalyse\b/, /\banalyze\b/, /\bresearch\b/, /\bdesign\b/,
  /\bbuild\b/,  /\bcreate\b/,  /\bwrite\b/,    /\bdraft\b/,
  /\bsummar/,   /\bcompare\b/, /\bexplain\b/,  /\breview\b/,
  /\barchitect\b/, /\bmodel\b/, /\bstrateg/, /\boptimis\b/,
  /\boptimiz\b/, /\bwhy\b/, /\bhow\b/, /\bwhat\b/, /\bshould\b/
];

const ENGINEERING_SIGNALS = [
  /\barchitect\b/, /\barchitecture\b/, /\bsecurity\s+review\b/,
  /\bfinancial\s+model/i, /\blegal\s+anal/i, /\baudit\b/,
  /\bsystem\s+design\b/, /\binfrastructure\b/, /\bscalab/,
  /\bcompliance\b/, /\bcryptograph/i, /\bvulnerabilit/i,
  /\bpenetration\b/, /\bperformance\s+profil/i, /\brefactor\b/,
  /\bmigrat/i, /\bdebug(?:ging)?\s+(?:\w+\s+){0,4}(?:no clear|no obvious|unknown)/i
];

const SYNTHESIS_SIGNALS = [
  /\bresearch\b/, /\bweb\s+search\b/, /\bsearch\s+(?:the\s+)?(?:web|internet|online)\b/,
  /\bfetch\b/, /\bscrape\b/, /\bcrawl\b/, /\bcross[\s-]document\b/,
  /\bmulti[\s-]file\b/, /\bintegrat\b/, /\bcompare.*across\b/,
  /\bsynthesi[sz]\b/, /\bgather\b/, /\bcollect\s+(?:data|information)\b/,
  /\blook\s+up\b/, /\bexternal\s+(?:api|data|source)/i,
  /\bpull\s+(?:from|in)\b/, /\bcombine.*(?:sources|documents|files)/i
];

/**
 * Detect RISE tier from task text.
 * Returns: 'ROUTINE' | 'INTELLIGENT' | 'SYNTHESIS' | 'ENGINEERING'
 */
function detectTier(task) {
  const t = task.toLowerCase();

  // ROUTINE — deterministic gate (same logic as Syntex classify.js isObviousRTier)
  const hasDisqualifier = ROUTINE_DISQUALIFIERS.some(p => p.test(t));
  if (!hasDisqualifier) {
    const hasAction  = ACTION_PATTERNS.some(p => p.test(t));
    const hasSubject = SUBJECT_PATTERNS.some(p => p.test(t));
    if (hasAction && hasSubject) return 'ROUTINE';
  }

  // ENGINEERING — premium expert signals (check before SYNTHESIS — higher specificity)
  if (ENGINEERING_SIGNALS.some(p => p.test(t))) return 'ENGINEERING';

  // SYNTHESIS — external data or multi-source signals
  if (SYNTHESIS_SIGNALS.some(p => p.test(t))) return 'SYNTHESIS';

  // Default — writing skill, no external data needed
  return 'INTELLIGENT';
}

// ─── RELEVANCE SCORING ────────────────────────────────────────────────────────
//
// Keyword-overlap scoring to extract the most relevant sentence or fact
// without making an LLM call. Stop-words are stripped before scoring.

const STOP_WORDS = new Set([
  'a','an','the','and','or','but','in','on','at','to','for','of','with',
  'by','from','is','it','its','this','that','these','those','was','were',
  'be','been','being','have','has','had','do','does','did','will','would',
  'could','should','may','might','shall','can','not','no','nor','so','yet',
  'both','either','neither','whether','as','if','when','while','because',
  'since','until','unless','although','though','even','just','also','then',
  'than','more','most','very','too','quite','rather','such','some','any',
  'all','each','every','both','few','many','much','other','own','same'
]);

function tokenize(text) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, ' ')
    .split(/\s+/)
    .filter(w => w.length > 2 && !STOP_WORDS.has(w));
}

function scoreRelevance(sentence, taskTokens) {
  const sentTokens = new Set(tokenize(sentence));
  let score = 0;
  for (const t of taskTokens) {
    if (sentTokens.has(t)) score++;
    // Partial match boost (e.g. task has "architect", sentence has "architecture")
    for (const s of sentTokens) {
      if (s !== t && (s.startsWith(t) || t.startsWith(s))) score += 0.5;
    }
  }
  return score;
}

/**
 * Extract the single most relevant sentence from text (SOUL.md).
 * Falls back to first non-empty sentence if no keyword overlap found.
 */
function extractRelevantSentence(text, task) {
  if (!text || !text.trim()) return '';

  const taskTokens = tokenize(task);
  const sentences = text
    .split(/(?<=[.!?])\s+|[\n]+/)
    .map(s => s.trim())
    .filter(s => s.length > 20 && !/^[#*\-_>|`]/.test(s)); // skip markdown headings/code

  if (sentences.length === 0) return text.split('\n').find(l => l.trim().length > 10) || '';

  let best = sentences[0];
  let bestScore = -1;

  for (const s of sentences) {
    const score = scoreRelevance(s, taskTokens);
    if (score > bestScore) {
      bestScore = score;
      best = s;
    }
  }

  return best;
}

/**
 * Extract the N most relevant facts from MEMORY.md.
 * Splits on blank lines and bullet/numbered list items.
 */
function extractRelevantFacts(text, task, count = 3) {
  if (!text || !text.trim()) return [];

  const taskTokens = tokenize(task);

  // Split into candidate facts: paragraphs and list items
  const facts = text
    .split(/\n{2,}|\n(?=[-*•]|\d+\.)/)
    .flatMap(block => block.split(/\n/).map(l => l.replace(/^[-*•]\s*|\d+\.\s*/, '').trim()))
    .filter(f => f.length > 15 && !/^#+\s/.test(f));

  if (facts.length === 0) return [];

  const scored = facts.map(f => ({ f, score: scoreRelevance(f, taskTokens) }));
  scored.sort((a, b) => b.score - a.score);

  // Return top N, de-duplicated
  const seen = new Set();
  const results = [];
  for (const { f } of scored) {
    const key = f.slice(0, 40);
    if (!seen.has(key) && results.length < count) {
      seen.add(key);
      results.push(f);
    }
  }
  return results;
}

// ─── FETCH USER PREFERENCES ───────────────────────────────────────────────────
//
// GET https://syntexprotocol.com/api/user/preferences
// Authorization: Bearer SX-xxxxxxxxxxxxxxxx
//
// NOTE: This endpoint needs to be added to the Syntex server (api/user.js).
// It should return: { lengthPreference, formatPreference, tonePreference, tierProfile }
//
// Falls back to safe defaults if the endpoint is unavailable or the token is
// missing — so the MCP server degrades gracefully during initial rollout.

const PREF_DEFAULTS = {
  lengthPreference: 'balanced',
  formatPreference: 'task_appropriate',
  tonePreference:   'direct',
  tierProfile:      'smart'
};

async function fetchPreferences() {
  if (!SX_TOKEN) {
    console.error('[syntex-mcp] SX_TOKEN not set — using preference defaults');
    return PREF_DEFAULTS;
  }

  try {
    const res = await fetch(`${SYNTEX_BASE_URL}/api/user/preferences`, {
      method:  'GET',
      headers: { 'Authorization': `Bearer ${SX_TOKEN}` },
      signal:  AbortSignal.timeout(8000)
    });

    if (!res.ok) {
      console.error(`[syntex-mcp] Preferences fetch returned ${res.status} — using defaults`);
      return PREF_DEFAULTS;
    }

    const data = await res.json();
    return {
      lengthPreference: data.lengthPreference || data.length_preference || PREF_DEFAULTS.lengthPreference,
      formatPreference: data.formatPreference || data.format_preference || PREF_DEFAULTS.formatPreference,
      tonePreference:   data.tonePreference   || data.tone_preference   || PREF_DEFAULTS.tonePreference,
      tierProfile:      data.tierProfile      || data.tier_profile      || PREF_DEFAULTS.tierProfile
    };

  } catch (err) {
    console.error(`[syntex-mcp] Preferences fetch failed: ${err.message} — using defaults`);
    return PREF_DEFAULTS;
  }
}

// ─── TASK STRUCTURING ─────────────────────────────────────────────────────────
//
// Builds the labeled field template for the detected RISE tier.
// Chain-of-thought is suppressed for ROUTINE and INTELLIGENT.

const TIER_META = {
  ROUTINE: {
    deliverable: 'Execute exactly as specified. Return only the result — nothing extra.',
    scope:       'Deterministic execution only. No interpretation, no elaboration, no caveats.',
    success:     'Output matches the transformation described in the task precisely.',
    allowCot:    false
  },
  INTELLIGENT: {
    deliverable: 'Complete response using only the information contained in this prompt.',
    scope:       'No external research. No tool use. Everything needed is in the prompt.',
    success:     'Addresses the task fully within the provided context. Nothing unsupported added.',
    allowCot:    false
  },
  SYNTHESIS: {
    deliverable: 'Synthesised output integrating external information, tool results, or cross-document analysis as required.',
    scope:       'External research and tool use permitted. Multi-step execution expected.',
    success:     'Output is complete, accurate, and references sources where external data was used.',
    allowCot:    true
  },
  ENGINEERING: {
    deliverable: 'Expert-level output. Architecture, analysis, or implementation reflecting senior engineering judgment.',
    scope:       'Full reasoning permitted. Complex multi-step execution expected. Edge cases must be addressed.',
    success:     'Output would satisfy a senior expert review. Trade-offs acknowledged. No hand-waving.',
    allowCot:    true
  }
};

/**
 * Map user preference values to concise constraint strings.
 */
function formatPrefsAsConstraints(prefs) {
  const length = {
    concise:       'Length: concise — shortest complete answer, tight word count.',
    balanced:      'Length: balanced — enough detail to act on, no padding.',
    comprehensive: 'Length: comprehensive — full depth, thorough coverage.'
  }[prefs.lengthPreference] || 'Length: balanced.';

  const format = {
    prose:            'Format: prose — flowing paragraphs, no bullets or headers.',
    structured:       'Format: structured — headers, bullets, and numbered lists as needed.',
    task_appropriate: 'Format: task-appropriate — choose the best fit for the output type.'
  }[prefs.formatPreference] || 'Format: task-appropriate.';

  const tone = {
    direct:        'Tone: direct — no preamble, no filler, no sign-off.',
    conversational:'Tone: conversational — clear and approachable.',
    formal:        'Tone: formal — professional register throughout.'
  }[prefs.tonePreference] || 'Tone: direct.';

  return [length, format, tone];
}

/**
 * Assemble the final structured task string using labeled fields.
 */
function buildStructuredTask(soulLine, memoryFacts, task, prefs, tier) {
  const meta         = TIER_META[tier];
  const prefLines    = formatPrefsAsConstraints(prefs);
  const cotSuppressor = '- No chain-of-thought. Do not narrate your reasoning. Answer directly.';

  const agentBlock = soulLine
    ? soulLine
    : 'No SOUL.md found — agent identity not available.';

  const contextBlock = memoryFacts.length > 0
    ? memoryFacts.map((f, i) => `${i + 1}. ${f}`).join('\n')
    : 'No MEMORY.md found — no prior context available.';

  const constraintLines = [
    ...prefLines,
    ...(meta.allowCot ? [] : [cotSuppressor])
  ];

  return [
    `[AGENT]`,
    agentBlock,
    '',
    `[CONTEXT]`,
    contextBlock,
    '',
    `[TASK]`,
    task.trim(),
    '',
    `[DELIVERABLE]`,
    meta.deliverable,
    '',
    `[SCOPE]`,
    meta.scope,
    '',
    `[SUCCESS]`,
    meta.success,
    '',
    `[CONSTRAINTS]`,
    ...constraintLines
  ].join('\n');
}

// ─── STARTUP REGISTRATION HEARTBEAT ──────────────────────────────────────────
//
// OC's built-in heartbeat to Syntex fires on its own schedule (up to 30 min).
// That's too long to wait during onboarding — the modal channel won't work until
// Syntex has the gateway URL stored for this server.
//
// This fires immediately when the MCP server starts (i.e. when OC starts), then
// retries every 60s until Syntex acknowledges the registration with a 200.
// Once registered, polling stops — OC's normal task traffic keeps the URL fresh.
//
// Requires SX_GATEWAY_PORT in env (written by install.sh into the OC MCP config).

async function sendRegistrationHeartbeat() {
  if (!SX_TOKEN || !SX_GATEWAY_PORT) return false;
  try {
    const res = await fetch(`${SYNTEX_BASE_URL}/v1/chat/completions`, {
      method:  'POST',
      headers: {
        'Authorization':     `Bearer ${SX_TOKEN}`,
        'Content-Type':      'application/json',
        'X-OC-Gateway-Port': SX_GATEWAY_PORT
      },
      body:   JSON.stringify({
        model:    'syntex/auto',
        messages: [{ role: 'user', content: 'ping' }],
        stream:   false
      }),
      signal: AbortSignal.timeout(15000)
    });
    return res.ok;
  } catch {
    return false;
  }
}

function startRegistrationHeartbeat() {
  if (!SX_TOKEN || !SX_GATEWAY_PORT) return;

  (async () => {
    // Immediate attempt on startup
    if (await sendRegistrationHeartbeat()) {
      console.error('[syntex-mcp] Gateway registered with Syntex');
      return;
    }

    // Retry every 60s until acknowledged
    console.error('[syntex-mcp] Registration heartbeat failed — retrying every 60s');
    const interval = setInterval(async () => {
      if (await sendRegistrationHeartbeat()) {
        console.error('[syntex-mcp] Gateway registration confirmed');
        clearInterval(interval);
      }
    }, 60_000);

    // Don't hold the event loop open if OC shuts down the MCP process
    interval.unref();
  })().catch(err => console.error('[syntex-mcp] Registration heartbeat error:', err.message));
}

// ─── MCP SERVER ───────────────────────────────────────────────────────────────

const server = new Server(
  { name: 'syntex-mcp', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

// ── List tools ────────────────────────────────────────────────────────────────

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'structure_task',
      description:
        'Structures an outbound task before it reaches Syntex. ' +
        'Reads SOUL.md and MEMORY.md from the OC working directory, fetches ' +
        'user preferences from Syntex, detects the RISE tier, and returns a ' +
        'fully labeled task block ready to send to a model.',
      inputSchema: {
        type: 'object',
        properties: {
          task: {
            type:        'string',
            description: 'The raw task text to structure.'
          }
        },
        required: ['task']
      }
    }
  ]
}));

// ── Call tool ─────────────────────────────────────────────────────────────────

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name !== 'structure_task') {
    throw new Error(`Unknown tool: ${request.params.name}`);
  }

  const { task } = request.params.arguments;

  if (!task || typeof task !== 'string' || !task.trim()) {
    return {
      content: [{ type: 'text', text: 'Error: task is required and must be a non-empty string.' }],
      isError: true
    };
  }

  // ── Resolve working directory ──────────────────────────────────────────────
  // Priority: MCP roots from client → OC_WORKING_DIR env → cwd

  let workingDir = process.cwd();

  if (OC_WORKING_DIR) {
    workingDir = OC_WORKING_DIR;
  } else {
    try {
      const rootsResult = await server.request({ method: 'roots/list' }, ListRootsResultSchema);
      const roots = rootsResult.roots || [];

      for (const root of roots) {
        // root.uri is a file:// URL
        let candidate;
        try {
          candidate = fileURLToPath(root.uri);
        } catch {
          candidate = root.uri.replace(/^file:\/\//, '');
        }

        // Use the first root that has either SOUL.md or MEMORY.md
        if (
          existsSync(join(candidate, 'SOUL.md')) ||
          existsSync(join(candidate, 'MEMORY.md'))
        ) {
          workingDir = candidate;
          break;
        }
      }
    } catch {
      // Client does not support roots or roots request failed — stay on cwd
    }
  }

  // ── Read SOUL.md ───────────────────────────────────────────────────────────
  let soulContent = '';
  const soulPath = join(workingDir, 'SOUL.md');
  if (existsSync(soulPath)) {
    try { soulContent = readFileSync(soulPath, 'utf8'); } catch { /* skip */ }
  }

  // ── Read MEMORY.md ─────────────────────────────────────────────────────────
  let memoryContent = '';
  const memoryPath = join(workingDir, 'MEMORY.md');
  if (existsSync(memoryPath)) {
    try { memoryContent = readFileSync(memoryPath, 'utf8'); } catch { /* skip */ }
  }

  // ── Extract relevant content ───────────────────────────────────────────────
  const soulLine    = extractRelevantSentence(soulContent, task);
  const memoryFacts = extractRelevantFacts(memoryContent, task, 3);

  // ── Fetch user preferences ─────────────────────────────────────────────────
  const prefs = await fetchPreferences();

  // ── Detect RISE tier ───────────────────────────────────────────────────────
  const tier = detectTier(task);

  // ── Build structured task ──────────────────────────────────────────────────
  const structured = buildStructuredTask(soulLine, memoryFacts, task, prefs, tier);

  return {
    content: [{ type: 'text', text: structured }]
  };
});

// ─── CONNECT ──────────────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
startRegistrationHeartbeat(); // non-blocking — fires immediately, retries until confirmed
await server.connect(transport);
