import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
export const root = path.resolve(fileURLToPath(new URL('../..', import.meta.url)));
export const exam = path.join(root, 'scripts/exam');
export function cases(mode) {
  return (mode === 'all' ? ['dev', 'holdout'] : [mode]).flatMap(group =>
    JSON.parse(readFileSync(path.join(exam, group, 'cases.json'), 'utf8')).map(c => ({ ...c, group })));
}
export function command(c, target = root) {
  const bin = c.runner.endsWith('.py') ? 'python3' : c.runner.endsWith('.sh') ? '/bin/bash' : process.execPath;
  return [bin, path.join(exam, c.runner), c.id, target];
}
export function run(args, timeout = 45000) {
  return new Promise(resolve => {
    const child = spawn(args[0], args.slice(1), {
      cwd: root, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' },
    });
    let output = '', timedOut = false;
    const add = data => { output = (output + data).slice(-60000); };
    child.stdout.on('data', add); child.stderr.on('data', add);
    // 給 browser.mjs 的 finally 時間清理自己的 Edge，超時仍回報失敗。
    const timer = setTimeout(() => { timedOut = true; child.kill('SIGTERM'); }, timeout);
    const hard = setTimeout(() => child.kill('SIGKILL'), timeout + 5000);
    child.once('error', error => { output += error.message; });
    child.once('close', code => { clearTimeout(timer); clearTimeout(hard); resolve({ code: timedOut ? 124 : code ?? 1, output: (timedOut ? '測試逾時\n' : '') + output }); });
  });
}
