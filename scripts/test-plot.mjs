import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const chat = new URL('../Resources/chat/', import.meta.url);
// 關閉字串產生程式碼；解析器即使在這個環境也必須正常運作。
const context = vm.createContext({}, { codeGeneration: { strings: false, wasm: false } });
context.window = context;
const source = readFileSync(new URL('plot.js', chat), 'utf8');
vm.runInContext(source, context, { filename: 'plot.js' });
const { parse, svg } = context.wbPlot;
let passed = 0;
function test(name, run) {
  try { run(); passed++; }
  catch (error) { console.error('失敗：' + name); throw error; }
}
const paths = (html) => [...html.matchAll(/<path class="plot-curve" data-curve="(\d+)" d="([^"]*)"/g)].map((m) => m[2]);
const points = (path) => [...path.matchAll(/[ML]([\d.-]+),([\d.-]+)/g)].map((m) => [Number(m[1]), Number(m[2])]);
const example = 'y = x^2 - 1\ny = -x ; x < 0\ny = x ; x >= 0\ny = sin(x)/x\nx: -5..5\ny: -3..3';

test('範例可解析、四條曲線與 SVG 座標元件', () => {
  const plot = parse(example);
  assert.equal(plot.curves.length, 4);
  assert.deepEqual(Array.from(plot.x), [-5, 5]);
  assert.deepEqual(Array.from(plot.y), [-3, 3]);
  const html = svg(example);
  assert.match(html, /^<svg/);
  assert.equal(paths(html).length, 4);
  assert.ok(paths(html).every((p) => p.includes('L')));
  assert.match(html, /<line/);
  assert.match(html, /<text/);
  assert.match(html, /currentColor/);
  assert.doesNotMatch(html, /NaN|Infinity/);
});
for (const [expr, x, value] of [
  ['-x^2', 3, -9], ['(-x)^2', 3, 9], ['2^3^2', 0, 512],
  ['2^-2', 0, 0.25], ['1 + 2 * 3 - 4 / 2', 0, 5],
  ['.5 + 1e-2 + 2E+1', 0, 20.51], ['pi + e', 0, Math.PI + Math.E],
  ...['sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'sqrt', 'abs', 'exp', 'floor', 'ceil'].map((fn) => [`${fn}(x)`, 0.5, Math[fn](0.5)]),
  ['ln(e)', 0, 1], ['log(100)', 0, 2],
]) {
  test('運算：' + expr, () => assert.ok(Math.abs(parse('y = ' + expr).curves[0].value(x) - value) < 1e-10));
}
test('分段條件與實際路徑的範圍一致', () => {
  const curves = parse(example).curves;
  for (const x of [-3, -0.1, 0, 0.1, 3]) {
    assert.equal(curves[1].condition(x), x < 0);
    assert.equal(curves[2].condition(x), x >= 0);
  }
  // 預設 viewBox 中，x = 0 對應 340；兩條線不能越過各自的半平面。
  const result = paths(svg(example));
  assert.ok(points(result[1]).length > 10);
  // 會細分到條件邊界前一點點，四捨五入後可能剛好落在 340，但不能過界
  assert.ok(points(result[1]).every(([x]) => x <= 340));
  assert.ok(points(result[2]).every(([x]) => x >= 340));
});
test('條件括號、and/or 優先序與所有比較符號', () => {
  const fn = parse('y = x ; (x > -2 and x <= -1) or x >= 2 and x < 3').curves[0].condition;
  for (const x of [-3, -2, -1.5, -1, 0, 2, 2.5, 3]) {
    assert.equal(fn(x), (x > -2 && x <= -1) || (x >= 2 && x < 3));
  }
});
for (const expr of ['1/x', 'tan(x)', 'sin(x)/x', 'floor(x)', '1/(x-0.123)']) {
  test('不連續處斷開：' + expr, () => {
    const html = svg('y = ' + expr + '\nx: -5..5\ny: -5..5');
    const path = paths(html)[0];
    assert.ok((path.match(/M/g) || []).length >= 2);
    assert.doesNotMatch(html, /NaN|Infinity/);
    if (expr === '1/x') {
      const segments = path.split('M').filter(Boolean);
      // x = 0 的位置從 y 軸線讀（版面會因等比例而變）
      const zx = Number(html.match(/<line x1="([\d.]+)" y1="16" x2="\1"[^>]*opacity="0.5"/)[1]);
      assert.ok(segments.every((part) => {
        const xs = points('M' + part).map(([x]) => x);
        return xs.every((x) => x < zx) || xs.every((x) => x > zx);
      }));
    }
  });
}
test('區間中間的條件空隙會斷線', () => {
  const path = paths(svg('y = 1 ; x < 0.001 or x > 0.007\ny: 0..2'))[0];
  assert.ok((path.match(/M/g) || []).length >= 2);
});
test('自動範圍中的倒數仍然分成兩段', () => {
  const path = paths(svg('y = 1/x'))[0];
  assert.ok((path.match(/M/g) || []).length >= 2);
});
test('範圍接受常數式、負數與小數', () => {
  const plot = parse('y = x\nx: -pi..pi\ny: -.5..2^3');
  assert.deepEqual(Array.from(plot.x), [-Math.PI, Math.PI]);
  assert.deepEqual(Array.from(plot.y), [-0.5, 8]);
});
test('條件完全不成立時仍輸出有效的空曲線', () => {
  const html = svg('y = x ; x > 100\nx: -5..5');
  assert.match(html, /^<svg/);
  assert.equal(paths(html)[0], '');
});
for (const expr of ['x^2', '42', 'sqrt(x)', 'ln(-1)', 'exp(1000)']) {
  test('自動 y 範圍：' + expr, () => {
    const html = svg('y = ' + expr);
    assert.match(html, /^<svg/);
    assert.doesNotMatch(html, /NaN|Infinity/);
  });
}
for (const name of ['eval', 'alert', 'constructor', '__proto__', 'window']) {
  for (const src of ['y = ' + name + '(x)', 'y = x ; ' + name + ' < 0']) {
    test('拒絕危險名稱：' + src, () => {
      assert.throws(() => parse(src));
      const html = svg(src);
      assert.match(html, /plot-error/);
      assert.doesNotMatch(html, /<svg/);
    });
  }
}
for (const src of [
  'y = unknown(x)', 'y = Math.sin(x)', 'y = x[0]', 'y = x.constructor',
  'y = sin', 'y = sin()', 'y = sin(x, 2)', 'y = (x', 'y = x)',
  'y = x +', 'y = x ;', 'y = x ; x', 'y = x ; x < 1 < 2',
  'y = x < 1', 'y = x ; x < 0 ; x > 1', 'y = x garbage',
  'y = x\ny: 1..1', 'y = x\nx: 5..-5', 'y = x\nx: x..5',
  'y = x\ny: 0..1e999', 'y = x\nx: 0..1..2', 'x: -5..5', '',
  'y = ' + '('.repeat(300) + 'x' + ')'.repeat(300),
]) {
  test('錯誤區塊整段回退：' + src.slice(0, 60), () => {
    assert.throws(() => parse(src));
    assert.match(svg(src), /plot-error/);
    assert.doesNotMatch(svg(src), /<svg/);
  });
}
test('錯誤訊息與原文都跳脫 HTML', () => {
  const html = svg('y = x\ny = <img src="x" onerror="alert(1)">');
  assert.match(html, /第 2 行/);
  assert.match(html, /&lt;img/);
  assert.doesNotMatch(html, /<img/);
  assert.match(html, /<pre><code>y = x\ny = &lt;img/);
});
test('不使用動態程式碼或外部資源', () => {
  assert.doesNotMatch(source, /\beval\s*\(|new\s+Function\b|setTimeout\s*\(|\bfetch\s*\(|XMLHttpRequest|\bdocument\b/);
});

// 直接載入實際的程式碼區塊入口，驗證接線與模組缺席時的回退。
const chatSource = readFileSync(new URL('chat.js', chat), 'utf8');
const entry = chatSource.slice(chatSource.indexOf('  function codeBlockHtml('), chatSource.indexOf('  const lazyHl ='));
vm.runInContext(`const hlLang = () => null;
const L = (s) => s;
const COPY_ICON = '';
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));
${entry}`, context);
test('聊天入口渲染圖與可展開的原文', () => {
  const html = context.codeBlockHtml(example, 'plot', 'sync');
  assert.match(html, /^<div class="plot"><svg/);
  assert.match(html, /<details><summary>plot<\/summary><pre><code>/);
  assert.match(html, /x &lt; 0/);
});
test('串流模式也可以渲染函數圖', () => assert.match(context.codeBlockHtml(example, 'plot', 'none'), /<svg/));
test('wbPlot 缺席或其他語言時沿用程式碼區塊', () => {
  const plot = context.wbPlot;
  delete context.wbPlot;
  try {
    const html = context.codeBlockHtml('y = x < 0', 'plot', 'sync');
    assert.match(html, /^<div class="code">/);
    assert.match(html, /y = x &lt; 0/);
  } finally { context.wbPlot = plot; }
  assert.match(context.codeBlockHtml('y = x', 'text', 'sync'), /^<div class="code">/);
});
for (const file of ['index.html', 'test.html']) {
  test(file + ' 在 chat.js 前載入繪圖模組', () => {
    const html = readFileSync(new URL(file, chat), 'utf8');
    const plot = html.indexOf('<script src="plot.js">');
    assert.ok(plot >= 0 && plot < html.indexOf('<script src="chat.js">'));
  });
}
// ── 11/5：aspect: equal 與定義域端點細分 ──
const circle = 'y = sqrt(25 - x^2)\ny = -sqrt(25 - x^2)\nx: -6..6\ny: -6..6';
const viewBox = (html) => html.match(/viewBox="0 0 ([\d.]+) ([\d.]+)"/).slice(1).map(Number);
test('aspect 預設 auto、可設 equal、亂寫會報錯', () => {
  assert.equal(parse('y = x').aspect, 'auto');
  assert.equal(parse('y = x\naspect: equal').aspect, 'equal');
  assert.equal(parse('y = x\nAspect: Equal').aspect, 'equal');
  assert.throws(() => parse('y = x\naspect: 2'), /aspect/);
});
test('aspect: equal 時 x、y 一單位一樣長（圓是圓）', () => {
  const html = svg(circle + '\naspect: equal');
  assert.match(html, /class="eq"/);
  const pts = paths(html).flatMap(points);
  const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
  const wpx = Math.max(...xs) - Math.min(...xs), hpx = Math.max(...ys) - Math.min(...ys);
  assert.ok(Math.abs(wpx / hpx - 1) < 0.02, `寬 ${wpx} 高 ${hpx}`);
  const [vw, vh] = viewBox(html);
  assert.ok(vw > 0 && vh > 0 && vh <= 440 + 50);
});
test('aspect: equal 極端比例會放寬短軸，不會變成一條線', () => {
  for (const src of ['y = x\nx: -100..100\ny: -1..1\naspect: equal', 'y = x\nx: -1..1\ny: -100..100\naspect: equal']) {
    const [vw, vh] = viewBox(svg(src));
    assert.ok(vw >= 200 && vh >= 140, `${vw}×${vh}`);
  }
});
test('半圓在 x = ±5 接到 x 軸（上下兩半接起來）', () => {
  const [up, down] = paths(svg(circle + '\naspect: equal')).map(points);
  const endsUp = [up[0], up.at(-1)], endsDown = [down[0], down.at(-1)];
  for (let k = 0; k < 2; k++) {
    const gap = Math.hypot(endsUp[k][0] - endsDown[k][0], endsUp[k][1] - endsDown[k][1]);
    assert.ok(gap < 1.5, `端點差 ${gap} px`);
  }
  // 預設 auto 也一樣接得起來
  const [u2, d2] = paths(svg(circle)).map(points);
  assert.ok(Math.hypot(u2[0][0] - d2[0][0], u2[0][1] - d2[0][1]) < 1.5);
});
test('細分不會讓跳躍或極點連起來', () => {
  const step = points(paths(svg('y = floor(x)\nx: -3..3\ny: -4..4'))[0]);
  const html = paths(svg('y = floor(x)\nx: -3..3\ny: -4..4'))[0];
  assert.ok((html.match(/M/g) || []).length >= 6, '階梯每一階要另起一筆');
  assert.ok(step.length > 10);
  const pole = paths(svg('y = 1/x\nx: -2..2\ny: -10..10'))[0];
  assert.ok((pole.match(/M/g) || []).length >= 2, '1/x 在 0 要斷開');
});
test('病態函數不會卡住（細分有上限）', () => {
  const t0 = Date.now();
  const html = svg('y = sin(1/x)\ny = sin(1/x)*x\nx: -1..1');
  assert.match(html, /^<svg/);
  assert.ok(Date.now() - t0 < 3000, `花了 ${Date.now() - t0} ms`);
});
test('預設 auto：範圍差不多就等比例，差太多就填滿；free 強制填滿', () => {
  assert.match(svg('y = abs(x)\nx: -3..3\ny: -1..3'), /class="eq"/);
  assert.doesNotMatch(svg('y = x^3\nx: -5..5'), /class="eq"/);
  assert.doesNotMatch(svg('y = abs(x)\nx: -3..3\ny: -1..3\naspect: free'), /class="eq"/);
  assert.equal(parse('y = x\naspect: free').aspect, 'free');
});
test('等比例時格子是正方形（兩軸刻度間距一樣）', () => {
  const html = svg('y = abs(x)\nx: -3..3\ny: -1..3');
  const xs = [...html.matchAll(/<line x1="([\d.]+)" y1="16" x2="\1"[^>]*opacity="0.1"/g)].map((m) => Number(m[1]));
  const ys = [...html.matchAll(/<line x1="58" y1="([\d.]+)" x2="[\d.]+" y2="\1"[^>]*opacity="0.1"/g)].map((m) => Number(m[1]));
  const gx = Math.abs(xs[1] - xs[0]), gy = Math.abs(ys[1] - ys[0]);
  assert.ok(xs.length >= 3 && ys.length >= 3 && Math.abs(gx - gy) < 0.05, `格寬 ${gx} 格高 ${gy}`);
});
test('跟取樣週期對齊的震盪也畫得出來（不是一條直線）', () => {
  const pts = points(paths(svg('y = sin(2400*pi*x)\nx: 0..1\ny: -1.2..1.2\naspect: free'))[0]);
  const ys = pts.map((p) => p[1]);
  assert.ok(Math.max(...ys) - Math.min(...ys) > 100, `y 起伏只有 ${Math.max(...ys) - Math.min(...ys)}`);
});
test('第二條曲線不會被第一條病態曲線用光細分額度', () => {
  const [, line] = paths(svg('y = sin(1000*x)\ny = sqrt(1 - x^2)\nx: -1..1\ny: -1.2..1.2\naspect: free')).map(points);
  const right = line.filter(([x]) => x > 340);
  assert.ok(right.length > 20, '右半邊只有 ' + right.length + ' 點');
});
test('寬圖的刻度不會在 20 個時被截掉', () => {
  const html = svg('y = x\nx: 0..22\ny: 0..2\naspect: free', { width: 1600 });
  assert.match(html, />22</);
});
console.log(`函數圖測試通過：${passed} 項`);
