import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/*
 * 概念參考：earendil-works/pi 的 eval 報告旗標，
 * packages/evals/src/report.ts（MIT；包含 flaky 等旗標）。
 * 這裡獨立整理單題穩定度與執行時間，沒有移植原始碼。
 */

export function historyPath() {
  // EXAM_HISTORY_FILE 可供測試與 CI 指到暫存位置；預設紀錄留在使用者資料夾。
  return path.resolve(process.env.EXAM_HISTORY_FILE || path.join(
    homedir(), 'Library', 'Application Support', 'AI 工作台', 'exam-history.jsonl'));
}

export async function readHistory(file = historyPath()) {
  let content;
  try { content = await readFile(file, 'utf8'); }
  catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  const records = [];
  for (const line of content.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const row = JSON.parse(line);
      if (row && typeof row.runId === 'string' && typeof row.caseId === 'string' &&
          ['pass', 'fail', 'skip'].includes(row.status)) records.push(row);
    } catch { /* 忽略損毀或未寫完的單行，讓舊紀錄仍可讀。 */ }
  }
  return records;
}

function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function hasPassAndFail(rows) {
  const statuses = new Set(rows.map(row => row.status).filter(status => status === 'pass' || status === 'fail'));
  return statuses.has('pass') && statuses.has('fail');
}

function programVersion(row) {
  if (typeof row.testAppHash === 'string' && row.testAppHash) return `app:${row.testAppHash}`;
  if (typeof row.gitCommit === 'string' && row.gitCommit) return `commit:${row.gitCommit}`;
  return null;
}

export function analyzeHistory(records, recentRuns = 20) {
  const byRun = new Map();
  for (const row of records) {
    if (!byRun.has(row.runId)) byRun.set(row.runId, new Map());
    byRun.get(row.runId).set(row.caseId, row);
  }
  const rounds = [...byRun].slice(-recentRuns).map(([runId, cases]) => ({ runId, cases }));
  if (!rounds.length) return [];

  const caseIds = new Set(rounds.flatMap(round => [...round.cases.keys()]));
  const attention = [];
  for (const caseId of caseIds) {
    const caseRows = rounds.flatMap((round, roundIndex) => {
      const row = round.cases.get(caseId);
      return row ? [{ ...row, roundIndex }] : [];
    });
    const latest = caseRows.at(-1);
    const flags = [], details = [];

    const sameVersion = programVersion(latest);
    const sameVersionRows = sameVersion ? caseRows.filter(row => programVersion(row) === sameVersion) : [];
    const recentFiveRows = caseRows.filter(row => row.roundIndex >= Math.max(0, rounds.length - 5));
    if (hasPassAndFail(sameVersionRows) || hasPassAndFail(recentFiveRows)) {
      flags.push('flaky');
      details.push('同一程式版本或最近 5 輪同時有通過與失敗');
    }

    const previousTimes = caseRows.slice(0, -1)
      .filter(row => row.status !== 'skip' && Number.isFinite(row.seconds) && row.seconds >= 0)
      .map(row => row.seconds);
    const baseline = median(previousTimes);
    if (latest.status !== 'skip' && baseline > 0 && Number.isFinite(latest.seconds) && latest.seconds >= baseline * 2) {
      flags.push('slow');
      details.push(`${latest.seconds.toFixed(2)} 秒；先前中位數 ${baseline.toFixed(2)} 秒`);
    }

    if (rounds.length >= 2) {
      const current = rounds.at(-1).cases.get(caseId);
      const previous = rounds.at(-2).cases.get(caseId);
      if (current && previous?.status === 'pass' && current.status !== 'pass') {
        flags.push('newly-failing');
        details.push(`上一輪通過、本輪${current.status === 'skip' ? '略過' : '失敗'}`);
      }
    }

    const lastTenRounds = rounds.slice(-10);
    const lastTen = lastTenRounds.map(round => round.cases.get(caseId));
    if (lastTen.length === 10 && lastTen.every(row => row?.status === 'skip')) {
      flags.push('always-skipped');
      details.push('連續 10 輪略過，請評估是否實作或移除這題');
    }

    if (flags.length) attention.push({ caseId, caseName: latest.caseName || caseId, flags, details });
  }
  return attention;
}

export function formatAttention(records, recentRuns = 20) {
  const items = analyzeHistory(records, recentRuns);
  if (!items.length) return '';
  return `需要注意的題：\n${items.map(item =>
    `- ${item.caseId} ${item.caseName}：${item.flags.join('、')}（${item.details.join('；')}）`
  ).join('\n')}`;
}

export function parseRecentRuns(value = process.env.EXAM_REPORT_RUNS || '20') {
  value = String(value);
  if (!/^[1-9]\d*$/.test(value) || !Number.isSafeInteger(Number(value))) throw new Error('N 必須是正整數');
  return Number(value);
}

function parseRunCount(argv) {
  let value = process.env.EXAM_REPORT_RUNS || '20';
  if (argv.length) {
    if (argv.length !== 2 || argv[0] !== '--runs') throw new Error('用法：node scripts/exam/report.mjs [--runs N]');
    value = argv[1];
  }
  return parseRecentRuns(value);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const recentRuns = parseRunCount(process.argv.slice(2));
    const output = formatAttention(await readHistory(), recentRuns);
    if (output) console.log(output);
  } catch (error) {
    console.error(`考卷摘要失敗：${error.message}`);
    process.exitCode = 2;
  }
}
