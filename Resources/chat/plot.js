/* 離線函數圖：只解析白名單語法，不執行輸入的 JavaScript，也不存取 DOM。 */
(() => {
  'use strict';
  const root = typeof window !== 'undefined' ? window : globalThis;
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  // ln 為自然對數，log 為常用對數；三角函數使用弧度。
  const functions = new Map([
    ['sin', Math.sin], ['cos', Math.cos], ['tan', Math.tan],
    ['asin', Math.asin], ['acos', Math.acos], ['atan', Math.atan],
    ['sqrt', Math.sqrt], ['abs', Math.abs], ['ln', Math.log], ['log', Math.log10],
    ['exp', Math.exp], ['floor', Math.floor], ['ceil', Math.ceil],
  ]);
  const binary = new Map([
    ['+', (a, b) => a + b], ['-', (a, b) => a - b], ['*', (a, b) => a * b],
    ['/', (a, b) => a / b], ['^', (a, b) => a ** b],
    ['<', (a, b) => a < b], ['<=', (a, b) => a <= b],
    ['>', (a, b) => a > b], ['>=', (a, b) => a >= b],
    ['and', (a, b) => a && b], ['or', (a, b) => a || b],
  ]);

  function expression(src, expected, allowX = true) {
    const tokens = [];
    for (let i = 0; i < src.length;) {
      if (/\s/.test(src[i])) { i++; continue; }
      const m = /^(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|^[a-zA-Z_][a-zA-Z_0-9]*|^(?:<=|>=|[+*/^()<>-])/.exec(src.slice(i));
      if (!m) throw new Error('無法辨識的符號：' + src[i]);
      tokens.push(m[0]); i += m[0].length;
      if (tokens.length > 256) throw new Error('單行式子太長');
    }
    let pos = 0;
    const take = (t) => tokens[pos] === t && (++pos, true);
    const requireType = (n, type) => {
      if (n.type !== type) throw new Error(type === 'number' ? '這裡需要數值式子' : '條件需要比較式');
      return n;
    };
    function primary() {
      const t = tokens[pos++];
      if (t === '(') {
        const n = logicalOr();
        if (!take(')')) throw new Error('缺少右括號');
        return n;
      }
      if (t && /^(?:\d|\.)/.test(t)) {
        const value = Number(t);
        if (!Number.isFinite(value)) throw new Error('數字必須有限');
        return { type: 'number', run: () => value };
      }
      if (t === 'x' && allowX) return { type: 'number', run: (x) => x };
      if (t === 'pi' || t === 'e') return { type: 'number', run: () => t === 'pi' ? Math.PI : Math.E };
      if (functions.has(t)) {
        if (!take('(')) throw new Error('函數需要括號');
        const n = requireType(logicalOr(), 'number');
        if (!take(')')) throw new Error('缺少右括號');
        const fn = functions.get(t);
        return { type: 'number', run: (x) => fn(n.run(x)) };
      }
      throw new Error('不支援的名稱或式子：' + (t || '行尾'));
    }
    function combine(a, op, b) {
      const logical = op === 'and' || op === 'or';
      requireType(a, logical ? 'boolean' : 'number');
      requireType(b, logical ? 'boolean' : 'number');
      const fn = binary.get(op);
      return { type: logical || /^[<>]/.test(op) ? 'boolean' : 'number', run: (x) => fn(a.run(x), b.run(x)) };
    }
    function power() {
      const a = primary();
      return take('^') ? combine(a, '^', unary()) : a;
    }
    function unary() {
      if (take('-') || take('+')) {
        const sign = tokens[pos - 1] === '-' ? -1 : 1;
        const n = requireType(unary(), 'number');
        return { type: 'number', run: (x) => sign * n.run(x) };
      }
      return power();
    }
    function chain(next, ops) {
      let n = next();
      while (ops.includes(tokens[pos])) { const op = tokens[pos++]; n = combine(n, op, next()); }
      return n;
    }
    const product = () => chain(unary, ['*', '/']);
    const sum = () => chain(product, ['+', '-']);
    const comparison = () => chain(sum, ['<', '<=', '>', '>=']);
    const logicalAnd = () => chain(comparison, ['and']);
    const logicalOr = () => chain(logicalAnd, ['or']);
    const n = requireType(logicalOr(), expected);
    if (pos !== tokens.length) throw new Error('多餘的內容：' + tokens[pos]);
    return n.run;
  }

  // parse 成功回傳曲線與範圍；失敗丟出帶行號的錯誤，svg 負責轉成可顯示的訊息。
  function parse(src) {
    if (typeof src !== 'string' || src.length > 16384) throw new Error('區塊太長或不是文字');
    const result = { curves: [], x: [-5, 5], y: null, aspect: 'auto' };
    src.split(/\r?\n/).forEach((raw, index) => {
      const line = raw.trim();
      if (!line) return;
      try {
        const aspect = /^aspect\s*:\s*(\S*)$/i.exec(line);
        const range = /^([xy])\s*:\s*(.*)$/.exec(line);
        if (aspect) {
          const v = aspect[1].toLowerCase();
          if (v !== 'equal' && v !== 'auto' && v !== 'free') throw new Error('aspect 只能是 equal（x、y 一格一樣長）、free（填滿框）或 auto（預設：放得下就等比例）');
          result.aspect = v;
        } else if (range) {
          const parts = range[2].split('..');
          if (parts.length !== 2) throw new Error('範圍格式應為 a..b');
          const values = parts.map((s) => expression(s, 'number', false)(0));
          const span = values[1] - values[0];
          if (!values.every(Number.isFinite) || !Number.isFinite(span) || span <= 0 || !Number.isFinite(1 / span)) throw new Error('範圍必須有限且由小到大');
          result[range[1]] = values;
        } else {
          const curve = /^y\s*=\s*(.*)$/.exec(line);
          if (!curve) throw new Error('每行必須是 y = 式子、座標範圍或 aspect: equal');
          const parts = curve[1].split(';');
          if (parts.length > 2) throw new Error('每行只能有一個條件');
          const value = expression(parts[0], 'number');
          const condition = parts.length === 2 ? expression(parts[1], 'boolean') : () => true;
          result.curves.push({ value, condition });
          if (result.curves.length > 32) throw new Error('最多支援 32 條曲線');
        }
      } catch (error) { throw new Error('第 ' + (index + 1) + ' 行：' + error.message); }
    });
    if (!result.curves.length) throw new Error('至少需要一行 y = 式子');
    return result;
  }

  function svg(src, opts = {}) {
    try {
      const plot = parse(src);
      const baseWidth = Number.isFinite(opts.width) ? Math.max(240, Math.min(1600, opts.width)) : 640;
      const left = 58, top = 16, right = 18, bottom = 34;
      let [xmin, xmax] = plot.x;
      const count = 1200;
      const at = (curve, x) => { const y = curve.condition(x) ? curve.value(x) : NaN; return typeof y === 'number' ? y : NaN; };
      let yrange = plot.y;
      if (!yrange) {
        const samples = plot.curves.map((curve) => Array.from({ length: count + 1 }, (_, i) => at(curve, xmin + (xmax - xmin) * (i / count))));
        // 去掉少量極端值，避免漸近線把主要曲線壓成一條直線。
        const values = samples.flat().filter(Number.isFinite).sort((a, b) => a - b);
        let lo = values.length ? values[Math.floor((values.length - 1) * 0.02)] : -1;
        let hi = values.length ? values[Math.ceil((values.length - 1) * 0.98)] : 1;
        const pad = hi > lo ? (hi - lo) * 0.08 : Math.max(1, Math.abs(lo) * 0.1);
        lo -= pad; hi += pad;
        yrange = [lo, hi];
      }
      let [ymin, ymax] = yrange;
      if (![ymin, ymax, ymax - ymin, 1 / (ymax - ymin)].every(Number.isFinite) || ymax <= ymin) throw new Error('無法自動決定 y 範圍，請指定 y: a..b');
      let w = baseWidth - left - right, h = 260 - top - bottom;
      // x、y 一單位一樣長：在最大框內等比縮放。equal 一定等比例（太扁或太窄就把短軸範圍往兩邊放寬）；
      // auto（預設）只在不用放寬就放得下時等比例，否則像 free 一樣填滿框（例如 y = x^3 的 y 範圍大太多）
      const maxW = baseWidth - left - right, maxH = 440, minW = 200, minH = 140;
      const s = Math.min(maxW / (xmax - xmin), maxH / (ymax - ymin));
      const fits = s * (xmax - xmin) >= minW && s * (ymax - ymin) >= minH;
      const eq = plot.aspect === 'equal' || (plot.aspect === 'auto' && fits);
      if (eq) {
        w = s * (xmax - xmin); h = s * (ymax - ymin);
        if (w < minW) { const c = (xmin + xmax) / 2, half = minW / s / 2; xmin = c - half; xmax = c + half; w = minW; }
        if (h < minH) { const c = (ymin + ymax) / 2, half = minH / s / 2; ymin = c - half; ymax = c + half; h = minH; }
      }
      const dx = xmax - xmin, dy = ymax - ymin;
      const width = left + w + right, height = top + h + bottom;
      const px = (x) => left + (x - xmin) / dx * w;
      const py = (y) => top + (1 - (y - ymin) / dy) * h;
      const num = (n) => Number(n.toFixed(2));
      let out = `<svg xmlns="http://www.w3.org/2000/svg"${eq ? ` class="eq" width="${num(width)}" height="${num(height)}"` : ' width="100%" height="260"'} viewBox="0 0 ${num(width)} ${num(height)}" role="img" aria-label="函數圖">`;
      // 使用等距的漂亮刻度，限制數量，避免極小範圍造成無窮迴圈。
      const niceStep = (min, max, horizontal) => {
        const raw = (max - min) / (horizontal ? Math.max(3, Math.round(w / 70)) : Math.max(3, Math.round(h / 35))), base = 10 ** Math.floor(Math.log10(raw));
        return [1, 2, 5, 10].map((n) => n * base).find((n) => n >= raw);
      };
      // 等比例時兩軸用同一個間距，格子才會是正方形
      const sameStep = eq ? Math.max(niceStep(xmin, xmax, true), niceStep(ymin, ymax, false)) : 0;
      function ticks(min, max, horizontal) {
        const step = sameStep || niceStep(min, max, horizontal);
        for (let i = 0, start = Math.ceil(min / step); i < 40; i++) {
          const value = (start + i) * step;
          if (!Number.isFinite(value) || value > max) break;
          const p = num(horizontal ? px(value) : py(value));
          const label = esc(Number(value.toPrecision(6)));
          out += horizontal
            ? `<line x1="${p}" y1="${top}" x2="${p}" y2="${num(top + h)}" stroke="currentColor" opacity="0.1"/><text x="${p}" y="${num(height - 10)}" text-anchor="middle">${label}</text>`
            : `<line x1="${left}" y1="${p}" x2="${num(left + w)}" y2="${p}" stroke="currentColor" opacity="0.1"/><text x="${left - 7}" y="${p}" text-anchor="end" dominant-baseline="middle">${label}</text>`;
        }
      }
      out += '<g fill="currentColor" font-size="11" font-family="sans-serif">';
      ticks(xmin, xmax, true); ticks(ymin, ymax, false);
      out += '</g>';
      if (xmin <= 0 && xmax >= 0) out += `<line x1="${num(px(0))}" y1="${top}" x2="${num(px(0))}" y2="${num(top + h)}" stroke="currentColor" opacity="0.5"/>`;
      if (ymin <= 0 && ymax >= 0) out += `<line x1="${left}" y1="${num(py(0))}" x2="${num(left + w)}" y2="${num(py(0))}" stroke="currentColor" opacity="0.5"/>`;
      const colors = ['currentColor', '#648de5', '#d47742', '#42a58a', '#ad79ca'];
      // 曲線：先等距取樣，每一小段再自動細分。直的段落直接連；定義域邊界（例如 sqrt(25 - x^2) 在 ±5）
      // 會一路切到邊界附近才收筆，所以半圓能接到 x 軸；跳躍、洞、極點細分到底還是斷開。
      const inside = (y) => Number.isFinite(y) && y >= ymin && y <= ymax;
      const MAX_DEPTH = 14, JUMP_PX = 2, BEND_PX = 0.4;
      plot.curves.forEach((curve, c) => {
        // 細分次數每條曲線各一份（共用的話左邊的病態曲線會把後面的曲線額度用光）
        let budget = Math.floor(400000 / plot.curves.length);
        let path = '', pen = false;
        const to = (x, y) => { path += `${pen ? 'L' : 'M'}${num(px(x))},${num(py(y))}`; pen = true; };
        const walk = (x0, y0, x1, y1, d) => {
          const in0 = inside(y0), in1 = inside(y1);
          const last = d >= MAX_DEPTH || --budget < 0;
          if (in0 && in1) {
            const jump = Math.abs(py(y1) - py(y0));
            if (last) { if (jump > JUMP_PX) pen = false; to(x1, y1); return; }
            const xm = (x0 + x1) / 2, ym = at(curve, xm);
            // 看兩個不對稱的點：只看中點會漏掉剛好跟取樣週期對齊的震盪（例如 sin(2400πx) 的零點都落在取樣點和中點上）
            const straight = (t) => { const y = at(curve, x0 + (x1 - x0) * t); return inside(y) && Math.abs(py(y) - (py(y0) + (py(y1) - py(y0)) * t)) <= BEND_PX; };
            if (inside(ym) && jump < h * 0.25 && straight(0.3) && straight(0.71)) { to(x1, y1); return; }
            walk(x0, y0, xm, ym, d + 1); walk(xm, ym, x1, y1, d + 1);
            return;
          }
          if (!in0 && !in1) { pen = false; return; }
          // 一邊在範圍內、一邊不在：往交界細分
          if (last) { if (in1) { pen = false; to(x1, y1); } else pen = false; return; }
          const xm = (x0 + x1) / 2, ym = at(curve, xm);
          walk(x0, y0, xm, ym, d + 1); walk(xm, ym, x1, y1, d + 1);
        };
        let x0 = xmin, y0 = at(curve, x0);
        if (inside(y0)) to(x0, y0);
        for (let i = 1; i <= count; i++) {
          const x1 = xmin + dx * (i / count), y1 = at(curve, x1);
          walk(x0, y0, x1, y1, 0);
          x0 = x1; y0 = y1;
        }
        out += `<path class="plot-curve" data-curve="${c}" d="${path}" fill="none" stroke="${colors[c % colors.length]}" stroke-width="1.7" stroke-linejoin="round"/>`;
      });
      return out + '</svg>';
    } catch (error) {
      return `<div class="plot-error" role="alert">函數圖錯誤：${esc(error.message)}</div><pre><code>${esc(src)}</code></pre>`;
    }
  }
  root.wbPlot = { parse, svg };
})();
