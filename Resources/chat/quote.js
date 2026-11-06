/* 引用格式解析獨立於畫面，讓歷史與即時泡泡共用。 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.cdvQuote = factory();
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';
  const marker = '〔codenv 引用〕', endMarker = '〔codenv 引用結束〕';
  const preview = (text) => {
    const value = String(text || '').replace(/〔codenv/g, '〔 codenv');
    const segmented = typeof Intl.Segmenter === 'function';
    const chars = segmented ? new Intl.Segmenter('zh-Hant', { granularity: 'grapheme' }).segment(value) : value;
    let out = '', count = 0;
    for (const c of chars) {
      if (count++ === 20) break;
      out += segmented ? c.segment : c;
    }
    return out;
  };
  function parse(value) {
    const text = String(value || '');
    const boundary = /(?:\n\n|^)〔codenv (?:引用|換模型|聊天室名稱|程式碼區)〕/.exec(text);
    const clean = boundary ? text.slice(0, boundary.index) : text;
    const items = [];
    // 只接受第一個附加區塊；引用內的內容必須逐行有 > 前綴。
    if (boundary && boundary[0].endsWith(marker)) {
      const start = boundary.index + boundary[0].length;
      const rest = text.slice(start).split('\n');
      let current = null, ended = false, valid = true;
      for (const line of rest.slice(1)) {
        if (line === endMarker) { ended = true; break; }
        const h = /^#(\d+) (我說|你（AI）說)（ref:([\p{L}\p{N}_:.\-]+)）：$/u.exec(line);
        if (h) {
          if (+h[1] !== items.length + 1) { valid = false; break; }
          current = { qid: h[3], role: h[2] === '我說' ? 'user' : 'assistant', lines: [] };
          items.push(current);
        } else if (current && line.startsWith('> ') && !line.includes('〔codenv')) current.lines.push(line.slice(2));
        else { valid = false; break; }
      }
      if (!ended || !valid || items.some((q) => !q.lines.length)) items.length = 0;
    }
    return { text: clean, quotes: items.map((q) => ({ qid: q.qid, role: q.role, preview: preview(q.lines.join('\n')) })) };
  }
  function fallbackID(role, value) {
    let hash = 2166136261;
    for (const c of String(value)) { hash ^= c.codePointAt(0); hash = Math.imul(hash, 16777619); }
    return 'q-' + role + '-' + (hash >>> 0).toString(16);
  }
  function ordered(items, qids) {
    const ranks = new Map(qids.map((qid, i) => [qid, i]));
    return [...items].sort((a, b) => (ranks.get(a.qid) ?? Infinity) - (ranks.get(b.qid) ?? Infinity));
  }
  return { parse, preview, fallbackID, ordered };
});
