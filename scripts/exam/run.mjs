import { cases, command, run, root } from './common.mjs';
import { createHash } from 'node:crypto';
import { createReadStream, readFileSync } from 'node:fs';
import { appendFile, lstat, mkdir, readlink, readdir, realpath } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { formatAttention, historyPath, parseRecentRuns, readHistory } from './report.mjs';
const usage = '用法：scripts/exam.sh [dev|holdout|all] [--require <清單檔或 all>] [--ids <案例 ID 清單>] [--only <案例 ID>]（清單每行一個案例 ID，可用 # 註解；必跑案例會自動加入；--ids 不可和 --only 同用）';
let mode = 'dev', modeGiven = false, requiredSource, idsSource, onlyId;
const regressions = [
  ['R01', '既有數學測試', process.execPath, 'test-math.mjs'],
  ['R02', '既有繪圖測試', process.execPath, 'test-plot.mjs'],
  ['R03', '既有引用測試', process.execPath, 'quote-test.js'],
  ['R04', '既有離線續跑測試（僅暫存 fixture repo）', '/bin/bash', 'test-resume.sh'],
  ['R05', '記憶容量檢查（唯讀、暫存假資料）', '/usr/bin/python3', 'test-memory-check.py'],
  ['R06', '對話全文搜尋（暫存資料夾與假紀錄）', '/usr/bin/python3', 'test-search.py'],
  ['R07', 'Pre-commit hook（獨立暫存 Git repo）', '/bin/bash', 'test-precommit.sh'],
].map(([id, name, bin, file]) => ({ id, name, args: [bin, path.join(root, 'scripts', file)] }));
let selected, required, jobs;
try {
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--require' && requiredSource === undefined) {
      requiredSource = args[++i];
      if (!requiredSource || requiredSource.startsWith('--')) throw Error('--require 缺少清單檔或 all');
    } else if (args[i] === '--ids' && idsSource === undefined) {
      idsSource = args[++i];
      if (!idsSource || idsSource.startsWith('--')) throw Error('--ids 缺少案例 ID 清單檔');
    } else if (args[i] === '--only' && onlyId === undefined) {
      onlyId = args[++i];
      if (!onlyId || onlyId.startsWith('--')) throw Error('--only 缺少案例 ID');
    } else if (['dev', 'holdout', 'all'].includes(args[i]) && !modeGiven) {
      mode = args[i]; modeGiven = true;
    } else throw Error(`無效或重複的參數：${args[i]}`);
  }
  const catalog = [...cases('all'), ...regressions];
  required = new Set(requiredSource === 'all' ? catalog.map(c => c.id) :
    requiredSource === undefined ? [] : readFileSync(requiredSource, 'utf8').split(/\r?\n/)
      .map(line => line.split('#')[0].trim()).filter(Boolean));
  if (requiredSource !== undefined && !required.size) throw Error('必跑清單不可為空');
  const known = new Set(catalog.map(c => c.id));
  const unknown = [...required].filter(id => !known.has(id));
  if (unknown.length) throw Error(`必跑清單有未知案例：${unknown.join('、')}`);
  if (onlyId && !known.has(onlyId)) throw Error(`單題執行有未知案例：${onlyId}`);
  if (onlyId && requiredSource !== undefined) throw Error('--only 不可和 --require 同時使用');
  const ids = new Set(idsSource === undefined ? [] : readFileSync(idsSource, 'utf8').split(/\r?\n/)
    .map(line => line.split('#')[0].trim()).filter(Boolean));
  const unknownIds = [...ids].filter(id => !known.has(id));
  if (unknownIds.length) throw Error(`指定題目清單有未知案例：${unknownIds.join('、')}`);
  if (idsSource !== undefined && !ids.size) throw Error('指定題目清單不可為空');
  if (onlyId && idsSource !== undefined) throw Error('--only 不可和 --ids 同時使用');
  selected = onlyId ? catalog.filter(c => c.id === onlyId) : idsSource !== undefined ?
    catalog.filter(c => ids.has(c.id) || required.has(c.id)) :
    catalog.filter(c => mode === 'all' || c.group === mode || required.has(c.id));
  const rawJobs = process.env.EXAM_JOBS ?? '4';
  if (!/^[1-9]\d*$/.test(rawJobs) || Number(rawJobs) > 64) throw Error('EXAM_JOBS 要是 1 到 64 的整數');
  jobs = Number(rawJobs);
} catch (error) {
  console.error(`錯誤：${error.message}\n${usage}`); process.exit(2);
}
function compareId(a, b) {
  const ma = /^([A-Za-z]+)(\d+)$/.exec(a), mb = /^([A-Za-z]+)(\d+)$/.exec(b);
  if (ma && mb) return ma[1].localeCompare(mb[1]) || Number(ma[2]) - Number(mb[2]) || a.localeCompare(b);
  return a.localeCompare(b);
}
selected.sort((a, b) => compareId(a.id, b.id));
function skipped(c, reason) {
  const mandatory = required.has(c.id);
  return { c, kind: mandatory ? 'fail' : 'skip', seconds: 0, output: `${mandatory ? '失敗' : '略過'} ${c.id} ${c.name}（${mandatory ? '必跑案例被略過：' : ''}${reason}）` };
}
async function check(c, args) {
  const timeout = c.timeout ?? (c.id === 'C17' ? 240000 : c.id === 'R04' || c.runner === 'native.sh' ? 120000 : c.runner === 'export-guard.sh' ? 180000 : 45000);
  const started = process.hrtime.bigint();
  const r = await run(args, timeout);
  const seconds = Number((Number(process.hrtime.bigint() - started) / 1e9).toFixed(3));
  return { c, kind: r.code === 0 ? 'pass' : 'fail', seconds, output: `${r.code === 0 ? '通過' : '失敗'} ${c.id} ${c.name}${r.output.trim() ? '\n' + r.output.trim().split('\n').map(line => '  ' + line).join('\n') : ''}` };
}

async function hashTestApp(appPath) {
  if (!appPath) return null;
  const files = [];
  async function collect(absolute, relative) {
    const info = await lstat(absolute);
    if (info.isSymbolicLink()) files.push({ absolute, relative, type: 'link' });
    else if (info.isDirectory()) {
      const children = (await readdir(absolute)).sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
      for (const child of children) await collect(path.join(absolute, child), path.posix.join(relative, child));
    } else if (info.isFile()) files.push({ absolute, relative, type: 'file' });
  }
  try {
    const base = await realpath(path.resolve(appPath));
    await collect(base, '.');
    files.sort((a, b) => a.relative < b.relative ? -1 : a.relative > b.relative ? 1 : 0);
    const hash = createHash('sha256');
    for (const file of files) {
      hash.update(`${file.type}\0${file.relative}\0`);
      if (file.type === 'link') hash.update(await readlink(file.absolute));
      else for await (const chunk of createReadStream(file.absolute)) hash.update(chunk);
      hash.update('\0');
    }
    return hash.digest('hex');
  } catch { return null; }
}

function currentCommit() {
  try { return execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); }
  catch { return null; }
}

function isInside(directory, candidate) {
  const relative = path.relative(directory, candidate);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

async function appendHistory(rows) {
  const file = historyPath();
  if (isInside(root, file)) throw new Error('紀錄路徑不可放在 repo 內');
  await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const canonicalRoot = await realpath(root);
  const canonicalFile = path.join(await realpath(path.dirname(file)), path.basename(file));
  if (isInside(canonicalRoot, canonicalFile)) throw new Error('紀錄路徑解析後位於 repo 內');
  try { if ((await lstat(file)).isSymbolicLink()) throw new Error('紀錄檔不可是 symbolic link'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  await appendFile(file, rows.map(row => JSON.stringify(row)).join('\n') + '\n', { encoding: 'utf8', mode: 0o600 });
  return file;
}

const ready = [], results = new Map();
for (const c of selected) {
  if (c.pending) { results.set(c.id, skipped(c, '需要原生 App，測試尚未實作')); continue; }
  // C 類原生案例：要先做一個測試用 App（EXAM_APP=<路徑>）；會在背景開測試版（open -g、暫存資料夾）
  if (c.runner === 'native.sh' && !process.env.EXAM_APP) { results.set(c.id, skipped(c, '要開原生測試版，設 EXAM_APP=<測試用 codenv.app> 才跑')); continue; }
  // 網頁題要開無頭 Edge：Edge 每次啟動都會叫它自己的更新程式，11/5 讓使用者畫面跳出「EdgeUpdater.app 已損毀」。
  // 預設不跑，EXAM_BROWSER=1 才跑（之後改成用 WKWebView 跑，跟 codenv 同一個引擎）
  if (c.runner === 'browser.mjs' && process.env.EXAM_BROWSER !== '1') { results.set(c.id, skipped(c, '要開瀏覽器，EXAM_BROWSER=1 才跑')); continue; }
  ready.push(c);
}
async function runPool(items) {
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(jobs, items.length) }, async () => {
    while (next < items.length) {
      const c = items[next++];
      results.set(c.id, await check(c, c.args || command(c)));
    }
  }));
}
const runStartedAt = new Date().toISOString();
const runId = `${runStartedAt}-${process.pid}`;
const gitCommit = currentCommit();
const testAppHash = await hashTestApp(process.env.EXAM_APP);

await runPool(ready.filter(c => !c.serial));
for (const c of ready.filter(c => c.serial).sort((a, b) => compareId(a.id, b.id))) {
  results.set(c.id, await check(c, c.args || command(c)));
}
let passed = 0, failed = 0, skippedCount = 0;
for (const c of selected) {
  const result = results.get(c.id);
  console.log(result.output);
  if (result.kind === 'pass') passed++;
  else if (result.kind === 'fail') failed++;
  else skippedCount++;
}
console.log(`總結：通過 ${passed}、失敗 ${failed}、略過 ${skippedCount}（${onlyId ? `單題 ${onlyId}` : mode}${requiredSource === undefined ? '' : `；必跑 ${required.size} 題`}）`);
const historyRows = selected.map(c => {
  const result = results.get(c.id);
  return {
    schemaVersion: 1, runId, runStartedAt, caseId: c.id, caseName: c.name,
    status: result.kind === 'pass' ? 'pass' : result.kind === 'fail' ? 'fail' : 'skip',
    seconds: result.seconds, testAppHash, gitCommit, examJobs: jobs,
  };
});
try {
  const file = await appendHistory(historyRows);
  try {
    const recentRuns = parseRecentRuns();
    const attention = formatAttention(await readHistory(file), recentRuns);
    if (attention) console.log(attention);
  } catch (error) { console.error(`考卷穩定度摘要未完成：${error.message}`); }
} catch (error) { console.error(`考卷歷史紀錄未寫入：${error.message}`); }
process.exitCode = failed ? 1 : 0;
