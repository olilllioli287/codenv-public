import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import dom from './dom.cjs';
const [id, root] = process.argv.slice(2);
const base = path.join(root, 'Resources/chat');
const source = readFileSync(path.join(base, 'chat.js'), 'utf8');
const eq = (actual, expected, message) => assert.deepEqual(JSON.parse(JSON.stringify(actual)), expected, message);
if (id === 'A06') {
  // 實際 AskCard.render 的 chosenSet 接線；舊版沒有 splitChosen，仍執行它自己的 split 表達式。
  const fn = source.match(/  function splitChosen\([\s\S]*?\n  }/)?.[0] || '';
  const statement = source.match(/const chosenSet = [^\n]+;/)[0];
  for (const [chosen, labels, expected] of [
    ['紅、綠、藍', ['紅、綠', '藍'], ['紅、綠', '藍']],
    ['A, B, C', ['A, B', 'C'], ['A, B', 'C']],
    ['甲、乙、其他文字', ['甲', '乙'], ['甲', '乙', '其他文字']],
    ['甲乙、甲', ['甲', '甲乙'], ['甲乙', '甲']],
  ]) eq(vm.runInNewContext(`${fn}\n${statement}\n[...chosenSet]`, { chosen, q: { options: labels.map(label => ({ label })) } }), expected, '選項被拆散');
} else if (['A03', 'A05'].includes(id)) {
  const { wb, document, messages, Q } = dom(base);
  const turns = () => document.querySelectorAll('.turn.user');
  if (id === 'A03') {
    for (const mark of ['程式碼區', '聊天室名稱', '換模型']) {
      wb.history([{ type: 'user', uuid: 'u1', message: { content: `問題\n\n〔codenv ${mark}〕內部資料` } }]);
      assert.equal(turns()[0].querySelector('.bubble-t').textContent, '問題', '內部附加行外露');
      eq(Q.parse(`問題\n\n〔codenv ${mark}〕內部資料`), { text: '問題', quotes: [] });
    }
    for (const text of ['〔codenv 引用〕缺結尾', '問題', '']) assert.doesNotThrow(() => Q.parse(text));
    assert.equal(Q.preview('👨‍👩‍👧‍👦'.repeat(21)), '👨‍👩‍👧‍👦'.repeat(20));
  } else {
    wb.history([]);
    wb.restoreQuotes?.([{ qid: 'u1', role: 'user', text: '來源' }]);
    wb.localUser({ uuid: 'failed', text: '送失敗' });
    // 缺少撤送機制的舊版也檢查行為（泡泡仍存在），不以 TypeError 當作 bug 證據。
    wb.unsend?.('failed');
    assert.equal(turns().some(t => t.textContent.includes('送失敗')), false, '送失敗泡泡仍存在');
    wb.localUser({ uuid: 'failed', text: '送失敗' });
    wb.localUser({ uuid: 'other', text: '另一則' });
    wb.unsend('failed'); wb.unsend('failed');
    assert.equal(turns().some(t => t.textContent.includes('送失敗')), false, '非最後一則撤錯 UUID');
    assert.equal(turns().some(t => t.textContent.includes('另一則')), true);
    eq(messages.filter(m => m.type === 'quotes').at(-1).items.map(q => q.qid), ['u1']);
  }
} else if (['A01', 'A02'].includes(id)) {
  const context = vm.createContext({}, { codeGeneration: { strings: false, wasm: false } });
  context.window = context;
  vm.runInContext(readFileSync(path.join(base, 'plot.js'), 'utf8'), context);
  const svg = context.wbPlot.svg;
  const paths = html => [...html.matchAll(/<path class="plot-curve" data-curve="\d+" d="([^"]*)"/g)].map(m => m[1]);
  const points = p => [...p.matchAll(/[ML]([\d.-]+),([\d.-]+)/g)].map(m => [+m[1], +m[2]]);
  const circle = 'y = sqrt(25-x^2)\ny = -sqrt(25-x^2)\nx: -6..6\ny: -6..6';
  if (id === 'A01') {
    const pts = paths(svg(circle)).flatMap(points);
    assert.ok(pts.length > 20, '圓沒有渲染');
    const xs = pts.map(p => p[0]), ys = pts.map(p => p[1]);
    const ratio = (Math.max(...xs) - Math.min(...xs)) / (Math.max(...ys) - Math.min(...ys));
    assert.ok(Math.abs(ratio - 1) < .02, `圓寬高比 ${ratio}`);
    const html = svg('y = abs(x)\nx: -3..3\ny: -1..3');
    const xs2 = [...html.matchAll(/<line x1="([\d.]+)" y1="16" x2="\1"[^>]*opacity="0.1"/g)].map(m => +m[1]);
    const ys2 = [...html.matchAll(/<line x1="58" y1="([\d.]+)" x2="[\d.]+" y2="\1"[^>]*opacity="0.1"/g)].map(m => +m[1]);
    assert.ok(xs2.length >= 3 && ys2.length >= 3);
    assert.ok(Math.abs(Math.abs(xs2[1]-xs2[0])-Math.abs(ys2[1]-ys2[0])) < .05, '網格寬高不等');
    assert.doesNotMatch(svg('y = abs(x)\nx: -3..3\ny: -1..3\naspect: free'), /class="eq"/);
    assert.doesNotMatch(svg('y = x^3\nx: -5..5'), /class="eq"/);
  } else {
    // 加不對齊取樣格點的定義域：原草稿的 ±6 剛好命中 ±5，舊版也會過。
    // 不帶新增的 aspect 語法，確保舊版真的畫圖，失敗來自端點距離。
    for (const input of [circle.replace('x: -6..6', 'x: -6.01..6.02'), circle]) {
      const [up, down] = paths(svg(input)).map(points);
      assert.ok(up.length > 20 && down.length > 20);
      for (const i of [0, -1]) {
        const a = up.at(i), b = down.at(i), gap = Math.hypot(a[0]-b[0], a[1]-b[1]);
        assert.ok(gap < 1.5, `半圓端點差 ${gap}px`);
      }
    }
    for (const expr of ['1/x', 'floor(x)']) {
      const html = svg(`y = ${expr}\nx: -3..3\ny: -4..4`);
      assert.doesNotMatch(html, /NaN|Infinity/);
      assert.ok((paths(html)[0].match(/M/g) || []).length >= 2, '不連續處被接起');
    }
  }
} else throw Error('未知案例：' + id);
console.log('斷言通過 ' + id);
