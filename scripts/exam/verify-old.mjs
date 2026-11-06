// 離線反證：相同考題先跑目前版本，再以 git show 換入修正前檔案。
import { mkdtemp, mkdir, cp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { root, exam, cases, command, run } from './common.mjs';
const mode = process.argv[2] || 'all';
if (!['dev', 'holdout', 'all'].includes(mode)) throw Error('用法：node scripts/exam/verify-old.mjs [dev|holdout|all]');
const expected = {
  A06: /選項被拆散/, A07: /負責人誤拆/, A08: /HANDOFF 狀態錯誤/,
  A03: /內部附加行外露/, A05: /送失敗泡泡仍存在/,
  A02: /半圓端點差/, A01: /圓寬高比|網格寬高不等/,
  B01: /EXAM_ASSERT: 完成前公式數量=/, B10: /EXAM_ASSERT: 未讀排隊訊息沒有 lost/,
  B04: /EXAM_ASSERT: 內容長回後未貼底|EXAM_ASSERT: 無使用者操作卻解除追隨/,
  A11: /回答文字誤判額度/, A12: /呼叫者 TMPDIR 繞過限制/,
};
const results = [], output = [];
let failed = false;
for (const c of cases(mode).filter(c => !c.pending)) {
  const current = await run(command(c));
  for (const before of [c.before, ...(c.extraBefore || [])]) {
    const temp = await mkdtemp(path.join(tmpdir(), 'codenv-exam-old-'));
    let old, commit;
    try {
      commit = execFileSync('git', ['rev-parse', before], { cwd: root, encoding: 'utf8' }).trim();
      await cp(path.join(root, 'Resources/chat'), path.join(temp, 'Resources/chat'), { recursive: true });
      await mkdir(path.join(temp, 'scripts/exam'), { recursive: true });
      await cp(path.join(exam, 'scenarios.js'), path.join(temp, 'scripts/exam/scenarios.js'));
      for (const file of c.files) {
        // 只讀 object，不 checkout/reset，不變更 index、refs 或工作目錄中的被測程式。
        const bytes = execFileSync('git', ['show', `${before}:${file}`], { cwd: root, maxBuffer: 20 * 1024 * 1024 });
        const target = path.join(temp, file);
        await mkdir(path.dirname(target), { recursive: true });
        await writeFile(target, bytes);
      }
      old = await run(command(c, temp));
    } catch (error) {
      old = { code: 1, output: error.stack || String(error) };
    } finally {
      await rm(temp, { recursive: true, force: true });
    }
    // 基礎設施、缺依賴、語法錯誤或逾時都不能算「抓到歷史 bug」。
    const status = current.code !== 0 ? '無法驗' : old.code === 0 ? '否' : expected[c.id].test(old.output) ? '是' : '無法驗';
    const clean = text => text.replaceAll(temp, '<暫存副本>');
    const row = { id: c.id, name: c.name, before, commit, files: c.files, status,
      currentExit: current.code, oldExit: old.code,
      evidence: clean(old.output.trim()), currentOutput: clean(current.output.trim()) };
    results.push(row);
    output.push(`${c.id} ${c.name}\n修正前：${before} (${commit})\n舊版會失敗：${status}\n目前版 exit=${current.code}\n${row.currentOutput}\n舊版 exit=${old.code}\n${row.evidence}\n`);
    console.log(`${status === '是' ? '通過' : '失敗'} ${c.id} 舊版會失敗：${status}（${before}，exit ${old.code}）`);
    if (status !== '是') failed = true;
  }
}
await writeFile(path.join(exam, `old-results-${mode}.json`), JSON.stringify(results, null, 2) + '\n');
await writeFile(path.join(root, 'docs', `exam-old-output-${mode}.txt`), output.join('\n'));
console.log(`舊版驗證：是 ${results.filter(r => r.status === '是').length}、否 ${results.filter(r => r.status === '否').length}、無法驗 ${results.filter(r => r.status === '無法驗').length}`);
process.exitCode = failed ? 1 : 0;
