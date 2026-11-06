/* 數學式先避開 Markdown，轉完後再交給 KaTeX；不需要 DOM。 */
(() => {
  'use strict';
  const root = typeof window !== 'undefined' ? window : globalThis;
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const escaped = (s, i) => {
    let n = 0;
    while (i > 0 && s[--i] === '\\') n++;
    return n % 2 === 1;
  };

  // 保留既有的 \text{…}（含巢狀大括號），其餘連續中文字才補上 \text。
  function withCJK(src) {
    let out = '';
    for (let i = 0; i < src.length;) {
      const text = /^\\text\s*\{/.exec(src.slice(i));
      if (text) {
        let j = i + text[0].length, depth = 1;
        for (; j < src.length && depth; j++) {
          if (!escaped(src, j)) {
            if (src[j] === '{') depth++;
            if (src[j] === '}') depth--;
          }
        }
        out += src.slice(i, j); i = j;
      } else {
        // 中文後面的空白一起包進 \text，不然數學模式會把空白吃掉，「若 x」變成「若x」
        const cjk = /^[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]+[ \t]*/u.exec(src.slice(i));
        if (cjk) { out += '\\text{' + cjk[0] + '}'; i += cjk[0].length; }
        else { out += src[i++]; }
      }
    }
    return out;
  }

  function protect(src) {
    const items = [];
    // 只用英數字，marked 不會改寫；原文若剛好有同名文字就換一組。
    let prefix = 'WBMATHPLACEHOLDER';
    while (src.includes(prefix)) prefix += 'X';
    function prose(s) {
      let out = '';
      for (let i = 0; i < s.length;) {
        const open = s.startsWith('$$', i) ? '$$' : s.startsWith('\\[', i) ? '\\[' : s.startsWith('\\(', i) ? '\\(' : s[i] === '$' ? '$' : null;
        if (!open || escaped(s, i)) { out += s[i++]; continue; }
        const display = open === '$$' || open === '\\[';
        const close = open === '\\[' ? '\\]' : open === '\\(' ? '\\)' : open;
        const start = i + open.length;
        if (open === '$' && (!s[start] || /\s/.test(s[start]))) { out += s[i++]; continue; }
        let end = -1;
        for (let j = start; j < s.length; j++) {
          if (!display && /[\r\n]/.test(s[j])) break;
          if (!s.startsWith(close, j) || escaped(s, j)) continue;
          if (open === '$' && (/\s/.test(s[j - 1]) || /[0-9$]/.test(s[j + 1] || '') || s[j - 1] === '$')) continue;
          end = j; break;
        }
        // 串流中的未收尾區塊整段留下，不能再拿第二個 $ 當行內開頭。
        if (end < 0 && display) { out += s.slice(i); break; }
        if (end < 0) { out += s.slice(i, start); i = start; continue; }
        const raw = s.slice(i, end + close.length), tex = s.slice(start, end);
        const token = prefix + items.length + 'END';
        items.push({ token, raw, tex, display });
        out += token;
        i = end + close.length;
      }
      return out;
    }
    // 先切出圍欄與反引號程式碼，分隔符不能跨越這些區域配對。
    const code = /^ {0,3}(`{3,}|~{3,})[^\r\n]*(?:\r?\n|$)|`+/gm;
    let text = '', pos = 0, m;
    while ((m = code.exec(src))) {
      if (escaped(src, m.index)) continue;
      let end;
      if (m[1]) {
        const fence = m[1];
        const closing = new RegExp('^ {0,3}' + fence[0] + '{' + fence.length + ',}[ \\t]*(?:\\r?\\n|$)', 'gm');
        closing.lastIndex = code.lastIndex;
        const hit = closing.exec(src);
        end = hit ? closing.lastIndex : src.length;
      } else {
        const ticks = new RegExp('`+', 'g');
        ticks.lastIndex = code.lastIndex;
        let hit;
        while ((hit = ticks.exec(src)) && hit[0].length !== m[0].length) {}
        if (!hit) continue;
        end = ticks.lastIndex;
      }
      text += prose(src.slice(pos, m.index)) + src.slice(m.index, end);
      pos = end; code.lastIndex = end;
    }
    text += prose(src.slice(pos));
    return { text, items };
  }

  function restore(html, items) {
    if (!items.length) return html;
    const byToken = new Map(items.map((item) => [item.token, item]));
    const tokens = new RegExp(items.map((item) => item.token).join('|'), 'g');
    // 屬性內只還原跳脫後的原文，避免把 KaTeX 標籤塞進連結標題或圖片說明。
    return html.split(/(<(?:[^"'<>]|"[^"]*"|'[^']*')*>)/g).map((part, i) => part.replace(tokens, (token) => {
      const item = byToken.get(token);
      if (i % 2 || !root.katex) return esc(item.raw);
      try {
        return root.katex.renderToString(withCJK(item.tex), {
          displayMode: item.display, throwOnError: false, strict: 'ignore', trust: false, output: 'html',
        });
      } catch (_) { return esc(item.raw); }
    })).join('');
  }

  root.wbMath = { protect, restore };
})();
