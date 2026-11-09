import { cases, command, run, root } from './common.mjs';
import { readFileSync } from 'node:fs';
import path from 'node:path';
const usage = '用法：scripts/exam.sh [dev|holdout|all] [--require <清單檔或 all>]（清單每行一個案例 ID，可用 # 註解；必跑案例會自動加入）';
let mode = 'dev', modeGiven = false, requiredSource;
const regressions = [
  ['R01', '既有數學測試', process.execPath, 'test-math.mjs'],
  ['R02', '既有繪圖測試', process.execPath, 'test-plot.mjs'],
  ['R03', '既有引用測試', process.execPath, 'quote-test.js'],
  ['R04', '既有離線續跑測試（僅暫存 fixture repo）', '/bin/bash', 'test-resume.sh'],
  ['R05', '記憶容量檢查（唯讀、暫存假資料）', '/usr/bin/python3', 'test-memory-check.py'],
  ['R06', '對話全文搜尋（暫存資料夾與假紀錄）', '/usr/bin/python3', 'test-search.py'],
  ['R07', 'Pre-commit hook（獨立暫存 Git repo）', '/bin/bash', 'test-precommit.sh'],
].map(([id, name, bin, file]) => ({ id, name, args: [bin, path.join(root, 'scripts', file)] }));
let selected, required;
try {
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--require' && requiredSource === undefined) {
      requiredSource = args[++i];
      if (!requiredSource || requiredSource.startsWith('--')) throw Error('--require 缺少清單檔或 all');
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
  selected = catalog.filter(c => mode === 'all' || c.group === mode || required.has(c.id));
} catch (error) {
  console.error(`錯誤：${error.message}\n${usage}`); process.exit(2);
}
let passed = 0, failed = 0, skipped = 0;
function skip(c, reason) {
  const mandatory = required.has(c.id);
  if (mandatory) failed++; else skipped++;
  console.log(`${mandatory ? '失敗' : '略過'} ${c.id} ${c.name}（${mandatory ? '必跑案例被略過：' : ''}${reason}）`);
}
async function check(c, args) {
  const r = await run(args, c.id === 'R04' || c.runner === 'native.sh' ? 120000 : c.runner === 'export-guard.sh' ? 180000 : 45000);
  console.log(`${r.code === 0 ? '通過' : '失敗'} ${c.id} ${c.name}`);
  if (r.code === 0) passed++; else failed++;
  if (r.output.trim()) console.log(r.output.trim().split('\n').map(line => '  ' + line).join('\n'));
}
for (const c of selected) {
  if (c.pending) { skip(c, '需要原生 App，測試尚未實作'); continue; }
  // C 類原生案例：要先做一個測試用 App（EXAM_APP=<路徑>）；會在背景開測試版（open -g、暫存資料夾）
  if (c.runner === 'native.sh' && !process.env.EXAM_APP) { skip(c, '要開原生測試版，設 EXAM_APP=<測試用 codenv.app> 才跑'); continue; }
  // B 類要開無頭 Edge：Edge 每次啟動都會叫它自己的更新程式，11/5 讓使用者畫面跳出「EdgeUpdater.app 已損毀」。
  // 預設不跑，EXAM_BROWSER=1 才跑（之後改成用 WKWebView 跑，跟 codenv 同一個引擎）
  if (c.id.startsWith('B') && process.env.EXAM_BROWSER !== '1') { skip(c, '要開瀏覽器，EXAM_BROWSER=1 才跑'); continue; }
  await check(c, c.args || command(c));
}
console.log(`總結：通過 ${passed}、失敗 ${failed}、略過 ${skipped}（${mode}${requiredSource === undefined ? '' : `；必跑 ${required.size} 題`}）`);
process.exitCode = failed ? 1 : 0;
