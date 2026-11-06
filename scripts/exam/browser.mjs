import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir, homedir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
const [id, root] = process.argv.slice(2);
const temp = await mkdtemp(path.join(tmpdir(), 'codenv-exam-edge-'));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let edge, ws, killed = false, stderr = '';
const pending = new Map();
const cleanup = async () => {
  if (killed) return;
  killed = true;
  ws?.close();
  for (const { reject, timer } of pending.values()) { clearTimeout(timer); reject(Error('CDP 已關閉')); }
  pending.clear();
  if (edge?.pid) {
    // detached 群組只包含本測試的 Edge 與它的子程序，不使用 pkill 或共用 profile。
    try { process.kill(-edge.pid, 'SIGTERM'); } catch {}
    for (let i = 0; i < 20 && edge.exitCode === null && edge.signalCode === null; i++) await sleep(50);
    try { process.kill(-edge.pid, 'SIGKILL'); } catch {}
    if (edge.exitCode === null && edge.signalCode === null) await new Promise(resolve => edge.once('exit', resolve));
  }
  await rm(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
};
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { cleanup().finally(() => process.exit(1)); });
try {
  // 直接讓 Edge 以 port=0 向 OS 配發空埠，從自己的 profile 讀回。
  // 避免先用 Node 找空埠再釋放所留下的競爭窗口。
  let port;
  const userData = path.join(temp, 'profile');
  // 不換 HOME、不包 sandbox-exec：假 HOME 會讓 macOS 在使用者畫面跳「找不到鑰匙圈」視窗（11/5 發生過），
  // sandbox-exec 又會擋掉 Edge 啟動要綁的本機 socket。改成：自己的 user-data-dir＋不碰鑰匙圈＋把外部網址都解析失敗
  edge = spawn('/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge', [
    '--headless=new', '--disable-gpu', '--allow-file-access-from-files',
    `--user-data-dir=${userData}`, '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1',
    '--use-mock-keychain', '--password-store=basic',
    '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-component-update',
    '--disable-sync', '--disable-extensions', '--disable-crash-reporter', '--disable-breakpad',
    '--metrics-recording-only', '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost', 'about:blank'],
    { detached: true, stdio: ['ignore', 'ignore', 'pipe'] });
  edge.stderr.on('data', data => { stderr = (stderr + data).slice(-4000); });
  edge.on('error', error => { stderr += String(error); });
  const local = async (suffix, options) => {
    const r = await fetch(`http://127.0.0.1:${port}${suffix}`, { ...options, signal: AbortSignal.timeout(1000) });
    if (!r.ok) throw Error('CDP HTTP ' + r.status);
    return r.json();
  };
  let ready = false;
  for (let i = 0; i < 100; i++) {
    if (edge.exitCode !== null || edge.signalCode !== null) throw Error('Edge 啟動失敗：' + stderr);
    try {
      port = Number((await readFile(path.join(userData, 'DevToolsActivePort'), 'utf8')).split('\n')[0]);
      if (!Number.isInteger(port) || port <= 0) throw Error('Edge 未提供有效 CDP 埠');
      await local('/json/version'); ready = true; break;
    } catch { await sleep(100); }
  }
  assert.ok(ready, 'Edge CDP 啟動逾時：' + stderr);
  const target = await local('/json/new?about:blank', { method: 'PUT' });
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.addEventListener('open', resolve, { once: true }); ws.addEventListener('error', reject, { once: true }); });
  let sequence = 0;
  const errors = [], blocked = [], inflight = new Set();
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const n = ++sequence;
    const timer = setTimeout(() => { pending.delete(n); reject(Error('CDP 逾時：' + method)); }, 5000);
    pending.set(n, { resolve, reject, timer });
    ws.send(JSON.stringify({ id: n, method, params }));
  });
  ws.addEventListener('message', message => {
    const d = JSON.parse(message.data);
    if (d.id && pending.has(d.id)) {
      const p = pending.get(d.id); pending.delete(d.id); clearTimeout(p.timer);
      if (d.error) p.reject(Error(JSON.stringify(d.error))); else p.resolve(d.result);
    }
    if (d.method === 'Runtime.exceptionThrown') errors.push(d.params.exceptionDetails.exception?.description || d.params.exceptionDetails.text);
    if (d.method === 'Runtime.consoleAPICalled' && d.params.type === 'error') errors.push(d.params.args.map(a => a.value ?? a.description).join(' '));
    if (d.method === 'Fetch.requestPaused') {
      const { requestId, request } = d.params;
      const allowed = /^(file:|data:|about:)/.test(request.url);
      if (!allowed) blocked.push(request.url);
      const p = send(allowed ? 'Fetch.continueRequest' : 'Fetch.failRequest', allowed ? { requestId } : { requestId, errorReason: 'BlockedByClient' });
      inflight.add(p); p.catch(e => errors.push(e.message)).finally(() => inflight.delete(p));
    }
  });
  const evaluate = async expression => {
    const r = await send('Runtime.evaluate', { expression, returnByValue: true });
    if (r.exceptionDetails) throw Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    return r.result.value;
  };
  await send('Runtime.enable'); await send('Page.enable');
  await send('Fetch.enable', { patterns: [{ urlPattern: '*' }] });
  await send('Emulation.setDeviceMetricsOverride', { width: 900, height: 800, deviceScaleFactor: 1, mobile: false });
  const url = pathToFileURL(path.join(root, 'Resources/chat/test.html'));
  url.search = new URLSearchParams({ bare: '1', fast: '1', exam: id }).toString();
  await send('Page.navigate', { url: url.href });
  const deadline = Date.now() + 20000;
  let result, wheel = false;
  while (Date.now() < deadline) {
    const state = await evaluate('({done:!!window.__done, exam:window.__exam})');
    if (state.exam?.stage === 'wheel' && !wheel) {
      wheel = true;
      await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: 450, y: 400, deltaX: 0, deltaY: -600 });
      await evaluate('window.__wheelSent=true');
    }
    if (state.done) { result = state.exam; break; }
    if (errors.length) throw Error('頁面錯誤：' + errors.join('\n'));
    await sleep(50);
  }
  await Promise.all(inflight);
  assert.ok(result, '等待 window.__done 逾時');
  assert.equal(errors.length, 0, errors.join('\n'));
  assert.equal(blocked.length, 0, '出現非本機請求：' + blocked.join(', '));
  assert.equal(result.stage, 'passed', result.error);
  console.log('斷言通過 ' + id + ' ' + result.details.join('；'));
} finally {
  await cleanup();
}
