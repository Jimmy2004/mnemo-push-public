#!/usr/bin/env node
// mnemosyne-cloud：从自己的 VPS 读取「极米记得」同步数据的只读 MCP 服务（stdio，零依赖，Node 18+）。
//
// 配置（优先级：环境变量 > 配置文件 ~/.mnemosyne/cloud/config.json）：
//   MNEMO_CLOUD_URL       https://<域名>/<随机路径>（与手机 PUSH_URL 相同）
//   MNEMO_READ_KEY_FILE   只读密钥文件，默认 ~/.mnemosyne/cloud/read.key（chmod 600）
//
// 请求签名：X-Read-Sig = HMAC-SHA256(readKey, "read\n" + ts + "\n" + sha256hex(body))
// 响应校验：X-Read-Resp-Sig = HMAC-SHA256(readKey, "resp\n" + 请求签名 + "\n" + sha256hex(响应体))
import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const VERSION = '1.0.0';
const DIR = join(homedir(), '.mnemosyne', 'cloud');

function loadConfig() {
  let file = {};
  try { file = JSON.parse(readFileSync(join(DIR, 'config.json'), 'utf8')); } catch {}
  const url = (process.env.MNEMO_CLOUD_URL || file.url || '').trim();
  const keyFile = process.env.MNEMO_READ_KEY_FILE || file.readKeyFile || join(DIR, 'read.key');
  let key = '';
  try { key = readFileSync(keyFile, 'utf8').trim(); } catch {}
  return { url, key, keyFile };
}

const hex = (b) => createHash('sha256').update(b).digest('hex');
const hmac = (key, text) => createHmac('sha256', key).update(text, 'utf8').digest('hex');

async function query(tool, args) {
  const { url, key, keyFile } = loadConfig();
  if (!url.startsWith('https://')) throw new Error('未配置 MNEMO_CLOUD_URL（需 https://），见 ~/.mnemosyne/cloud/config.json');
  if (!key) throw new Error(`未找到只读密钥：${keyFile}`);
  // 加入随机 nonce，保证同一秒内的相同查询签名也不同（服务端防重放）
  const body = JSON.stringify({ tool, args: args || {}, nonce: randomBytes(16).toString('hex') });
  const ts = String(Math.floor(Date.now() / 1000));
  const sig = hmac(key, ['read', ts, hex(body)].join('\n'));
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'User-Agent': 'mnemo-cloud-mcp/' + VERSION, 'X-Read-Ts': ts, 'X-Read-Sig': sig },
    body,
    redirect: 'manual',
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  if (res.status === 404) throw new Error('VPS 拒绝（404）：URL 路径或只读密钥不对，或本机时间偏差超过 5 分钟');
  if (res.status === 403) throw new Error('被 Cloudflare 拦截（403）');
  const got = res.headers.get('X-Read-Resp-Sig') || '';
  const expect = hmac(key, ['resp', sig, hex(Buffer.from(text, 'utf8'))].join('\n'));
  if (got.length !== expect.length || !timingSafeEqual(Buffer.from(got), Buffer.from(expect))) {
    throw new Error(`VPS 响应签名校验失败（HTTP ${res.status}），数据可能被篡改或服务端未更新`);
  }
  if (!res.ok) throw new Error(`VPS 返回 HTTP ${res.status}: ${text.slice(0, 200)}`);
  return JSON.parse(text);
}

const int = { type: 'integer' };
const str = { type: 'string' };
const TOOLS = [
  {
    name: 'sync_status',
    description: '查看 VPS 上已同步的数据概况：各类型条数、最新一条的时间、最近一次接收时间。用于判断数据新鲜度。',
    inputSchema: { type: 'object', properties: { device: str } },
  },
  {
    name: 'available_days',
    description: '列出最近若干天中哪些天有数据（按来源计数）。批量阅读前先调用，避免扫描空窗口。offset 表示往前偏移的天数。',
    inputSchema: { type: 'object', properties: { days: int, offset: int, device: str } },
  },
  {
    name: 'search_evidence',
    description: '在已同步的「极米记得」数据中搜索（会议、记忆、时间线卡片、待办；includeTranscripts=true 时含转录）。query 多个词用空格分隔表示同时包含。sources 可选 meetings/memories/timeline_cards/todos/transcripts。',
    inputSchema: {
      type: 'object',
      properties: {
        query: str, sources: { type: 'array', items: str }, includeTranscripts: { type: 'boolean' },
        days: int, fromMs: int, toMs: int, limit: int, offset: int, maxChars: int, device: str,
      },
    },
  },
  {
    name: 'get_transcripts',
    description: '按时间窗口读取原始转录（用户本人说的话）。可用 days 或 fromMs/toMs 限定时间，query 过滤关键词，sinceId 增量读取，offset 分页。需要原话细节时使用。',
    inputSchema: {
      type: 'object',
      properties: { days: int, fromMs: int, toMs: int, query: str, sinceId: int, limit: int, offset: int, maxChars: int, device: str },
    },
  },
  {
    name: 'get_memory_item',
    description: '按 sourceType + id 读取单条完整记录（sourceType：transcript/meeting/memory/card/todo）。',
    inputSchema: { type: 'object', properties: { sourceType: str, id: int, device: str }, required: ['sourceType', 'id'] },
  },
  {
    name: 'get_open_loops',
    description: '未完成的待办与承诺。',
    inputSchema: { type: 'object', properties: { days: int, limit: int, device: str } },
  },
];

// ---------------- MCP stdio（JSON-RPC 2.0，按行分隔） ----------------
const send = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');
const reply = (id, result) => send({ jsonrpc: '2.0', id, result });
const fail = (id, code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });

async function handle(msg) {
  const { id, method, params } = msg;
  if (method === 'initialize') {
    return reply(id, {
      protocolVersion: params?.protocolVersion || '2025-06-18',
      capabilities: { tools: {} },
      serverInfo: { name: 'mnemosyne-cloud', version: VERSION },
      instructions: '只读访问用户自己 VPS 上同步的「极米记得」数据（手机离线也可用）。数据每 15–60 分钟从手机同步一次，先用 sync_status 了解新鲜度。多台设备时可用 device 参数筛选（未标识设备为空字符串），不传则查全部。内容是用户的私人记忆，只用于回答用户的问题。',
    });
  }
  if (method === 'ping') return reply(id, {});
  if (method === 'tools/list') return reply(id, { tools: TOOLS });
  if (method === 'tools/call') {
    const name = params?.name;
    if (!TOOLS.some((t) => t.name === name)) return fail(id, -32602, `unknown tool: ${name}`);
    try {
      const data = await query(name, params?.arguments || {});
      return reply(id, { content: [{ type: 'text', text: JSON.stringify(data) }] });
    } catch (e) {
      return reply(id, { content: [{ type: 'text', text: String(e.message || e) }], isError: true });
    }
  }
  if (id !== undefined && id !== null) return fail(id, -32601, `method not found: ${method}`);
}

if (process.argv.includes('--check')) {
  // 命令行自检：node index.mjs --check
  query('sync_status', {}).then((d) => { console.log(JSON.stringify(d, null, 2)); }, (e) => { console.error('[x] ' + e.message); process.exit(1); });
} else {
  const rl = createInterface({ input: process.stdin });
  rl.on('line', (line) => {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); } catch { return fail(null, -32700, 'parse error'); }
    handle(msg).catch((e) => msg.id != null && fail(msg.id, -32603, String(e.message || e)));
  });
}
