#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(fileURLToPath(new URL('../..', import.meta.url)));
const compareId = (a, b) => {
  const ma = /^([A-Za-z]+)(\d+)$/.exec(a), mb = /^([A-Za-z]+)(\d+)$/.exec(b);
  return ma && mb ? ma[1].localeCompare(mb[1]) || Number(ma[2]) - Number(mb[2]) || a.localeCompare(b) : a.localeCompare(b);
};
function readIdList(file, label, { required = false } = {}) {
  let source;
  try { source = readFileSync(file, 'utf8'); }
  catch (error) {
    if (required) throw new Error(`${label}不存在或無法讀取：${file}`);
    throw error;
  }
  return [...new Set(source.split(/\r?\n/).map(line => line.split('#')[0].trim()).filter(Boolean))];
}
function readIgnoreList(file) {
  try { return new Set(readIdList(file, '忽略清單')); }
  catch (error) { if (error.code === 'ENOENT') return new Set(); throw error; }
}
function git(args) {
  return execFileSync('git', args, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

try {
  const options = {
    smoke: 'scripts/exam/release-smoke.txt',
    required: 'scripts/exam/release-required.txt',
    ignore: 'scripts/exam/release-select-ignore.txt',
    idsOutput: null,
    summaryOutput: null,
  };
  const args = process.argv.slice(2);
  const seenOptions = new Set();
  for (let i = 0; i < args.length; i++) {
    const key = args[i];
    if (!['--smoke', '--required', '--ignore', '--ids-output', '--summary-output'].includes(key)) {
      throw new Error(`無效的參數：${key}`);
    }
    if (seenOptions.has(key)) throw new Error(`${key} 不可重複`);
    seenOptions.add(key);
    const value = args[++i];
    if (!value || value.startsWith('--')) throw new Error(`${key} 缺少路徑`);
    const property = ({ '--smoke': 'smoke', '--required': 'required', '--ignore': 'ignore', '--ids-output': 'idsOutput', '--summary-output': 'summaryOutput' })[key];
    options[property] = value;
  }
  if (!options.idsOutput || !options.summaryOutput) throw new Error('--ids-output 與 --summary-output 必填');

  const allCases = ['dev', 'holdout'].flatMap(group => JSON.parse(readFileSync(path.join(root, `scripts/exam/${group}/cases.json`), 'utf8'))
    .map(testCase => ({ ...testCase, group })));
  // run.mjs 另列七個 R 類回歸 runner；它們也可列在 --require／冒煙清單。
  const knownIds = new Set([...allCases.map(testCase => testCase.id), ...['R01', 'R02', 'R03', 'R04', 'R05', 'R06', 'R07']]);
  const requiredIds = readIdList(path.resolve(root, options.required), '必跑清單', { required: true });
  const smokeIds = readIdList(path.resolve(root, options.smoke), '冒煙題清單', { required: true });
  for (const [label, ids] of [['必跑清單', requiredIds], ['冒煙題清單', smokeIds]]) {
    const unknown = ids.filter(id => !knownIds.has(id));
    if (unknown.length) throw new Error(`${label}有未知案例：${unknown.join('、')}`);
  }
  if (!requiredIds.length) throw new Error('必跑清單不可為空');
  if (!smokeIds.length) throw new Error('冒煙題清單不可為空');

  const baseTag = git(['describe', '--tags', '--abbrev=0', '--match', 'v*', 'HEAD']);
  const changedFiles = git(['diff', '--name-only', '-z', `${baseTag}..HEAD`]).split('\0').filter(Boolean);
  const ignored = readIgnoreList(path.resolve(root, options.ignore));
  const consideredChanges = changedFiles.filter(file => !ignored.has(file));
  const affectedCases = allCases.map(testCase => ({
    id: testCase.id,
    name: testCase.name,
    matches: (testCase.files ?? []).filter(file => consideredChanges.includes(file)),
  })).filter(testCase => testCase.matches.length);
  const coveredFiles = new Set(allCases.flatMap(testCase => testCase.files ?? []));
  const uncoveredChangedFiles = changedFiles.filter(file => !coveredFiles.has(file));
  const affectedIds = [...new Set(affectedCases.map(testCase => testCase.id))];
  const releaseIds = [...new Set([...affectedIds, ...smokeIds])].sort(compareId);
  const fastUnion = new Set([...requiredIds, ...affectedIds, ...smokeIds]);
  const devIds = JSON.parse(readFileSync(path.join(root, 'scripts/exam/dev/cases.json'), 'utf8')).map(testCase => testCase.id);
  const fullCount = new Set([...devIds, ...requiredIds]).size;
  const summary = {
    baseTag, head: git(['rev-parse', 'HEAD']), changedFiles,
    ignoredChangedFiles: changedFiles.filter(file => ignored.has(file)),
    affectedCases, affectedCount: affectedIds.length,
    smokeIds, smokeCount: smokeIds.length,
    requiredIds, requiredCount: requiredIds.length,
    fastCount: fastUnion.size, fullCount, selectedIds: [...fastUnion].sort(compareId),
    uncoveredChangedFiles,
  };
  writeFileSync(path.resolve(root, options.idsOutput), releaseIds.join('\n') + '\n', { encoding: 'utf8', mode: 0o600 });
  writeFileSync(path.resolve(root, options.summaryOutput), JSON.stringify(summary, null, 2) + '\n', { encoding: 'utf8', mode: 0o600 });

  console.log(`基準 tag：${baseTag}；HEAD：${summary.head.slice(0, 12)}`);
  console.log(`改動檔 ${changedFiles.length} 個；忽略用於選題 ${summary.ignoredChangedFiles.length} 個共用檔。`);
  console.log(`受影響題 ${affectedCases.length} 題：`);
  for (const testCase of affectedCases) console.log(`  ${testCase.id} ${testCase.name}（${testCase.matches.join('、')}）`);
  console.log(`冒煙題 ${smokeIds.length} 題：${smokeIds.join('、')}`);
  if (uncoveredChangedFiles.length) {
    console.log('未被任何題涵蓋的改動檔：');
    for (const file of uncoveredChangedFiles) console.log(`  ${file}`);
  } else console.log('未被任何題涵蓋的改動檔：無');
  console.log(`快速選題：必跑 ${requiredIds.length}、受影響 ${affectedIds.length}、冒煙 ${smokeIds.length}，去重後 ${fastUnion.size} 題；全套 ${fullCount} 題。`);
} catch (error) {
  console.error(`release-select 錯誤：${error.message}`);
  process.exitCode = 2;
}
