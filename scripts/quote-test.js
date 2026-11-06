#!/usr/bin/env node
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const base = path.join(__dirname, '..', 'Resources', 'chat');
const Q = require(path.join(base, 'quote.js'));
const sample = `我的問題

〔codenv 引用〕使用者這則訊息是針對下面 2 則先前的訊息（依對話先後）；請針對它們回應。
#1 我說（ref:u-1）：
> 第一行
> 第二行〔 codenv 引用〕
#2 你（AI）說（ref:msg_2）：
> **回答**與更多文字，這裡超過二十個字，用來驗證預覽長度。
〔codenv 引用結束〕

〔codenv 程式碼區〕檔案.swift

〔codenv 聊天室名稱〕測試

〔codenv 換模型〕交接`;
assert.deepEqual(Q.parse(sample), { text: '我的問題', quotes: [
  { qid: 'u-1', role: 'user', preview: '第一行\n第二行〔 codenv 引用〕' },
  { qid: 'msg_2', role: 'assistant', preview: Q.preview('**回答**與更多文字，這裡超過二十個字，用來驗證預覽長度。') }
] });
assert.equal(Array.from(Q.parse(sample).quotes[1].preview).length, 20);
for (const mark of ['換模型', '聊天室名稱', '程式碼區']) {
  assert.deepEqual(Q.parse(`舊文字\n\n〔codenv ${mark}〕附加行`), { text: '舊文字', quotes: [] });
}
assert.deepEqual(Q.parse('舊文字'), { text: '舊文字', quotes: [] });
assert.equal(Q.parse(sample.replace('我的問題', '')).text, '');
assert.equal(Q.parse(sample.trimStart().replace('我的問題\n\n', '')).quotes.length, 2);
for (const bad of [null, '', '亂字串', sample.replace('〔codenv 引用結束〕', ''), sample.replace('ref:u-1', 'u-1'), sample.replace('> 第一行', '〔codenv 引用〕'), sample.replace('> 第一行', '> 〔codenv 引用〕')]) {
  assert.doesNotThrow(() => Q.parse(bad));
}
assert.equal(Q.parse(sample.replace('ref:u-1', 'u-1')).quotes.length, 0);
assert.equal(Q.parse(sample.replace('〔codenv 引用結束〕', '')).quotes.length, 0);
assert.equal(Q.preview('👨‍👩‍👧‍👦'.repeat(21)), '👨‍👩‍👧‍👦'.repeat(20));
assert.equal(Q.fallbackID('user', '文字'), Q.fallbackID('user', '文字'));
assert.deepEqual(Q.ordered([{ qid: 'b' }, { qid: 'a' }], ['a', 'b']).map((q) => q.qid), ['a', 'b']);

// 最小 DOM 只驗證互動資料；排版、WebKit 與真實焦點仍需實機驗收。
class Element {
  constructor(tag) {
    this.tagName = tag.toUpperCase(); this.children = []; this.parentElement = null;
    this.dataset = {}; this.attrs = {}; this.listeners = {}; this.style = { setProperty() {}, removeProperty() {} };
    this.className = ''; this._text = ''; this.hidden = false; this.scrollTop = 0; this.scrollHeight = 1000; this.clientHeight = 500;
    this.classList = {
      contains: (c) => this.className.split(/\s+/).includes(c),
      add: (...cs) => { this.className = [...new Set([...this.className.split(/\s+/).filter(Boolean), ...cs])].join(' '); },
      remove: (...cs) => { this.className = this.className.split(/\s+/).filter((c) => !cs.includes(c)).join(' '); },
      toggle: (c, on) => { on = on ?? !this.classList.contains(c); on ? this.classList.add(c) : this.classList.remove(c); return on; }
    };
  }
  appendChild(child) { child.remove(); this.children.push(child); child.parentElement = this; return child; }
  insertBefore(child, before) { child.remove(); const i = this.children.indexOf(before); this.children.splice(i < 0 ? this.children.length : i, 0, child); child.parentElement = this; return child; }
  remove() { if (this.parentElement) this.parentElement.children.splice(this.parentElement.children.indexOf(this), 1); this.parentElement = null; }
  replaceChildren(...children) { for (const c of [...this.children]) c.remove(); this._text = ''; children.forEach((c) => this.appendChild(c)); }
  set textContent(text) { this.replaceChildren(); this._text = String(text); }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  set innerHTML(text) { this.replaceChildren(); this._text = String(text); }
  get innerHTML() { return this._text; }
  get firstChild() { return this.children[0] || null; }
  get lastElementChild() { return this.children.at(-1) || null; }
  get isConnected() { return this === document.body || !!this.parentElement?.isConnected; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return this.attrs[k] ?? null; }
  addEventListener(k, fn) { (this.listeners[k] ||= []).push(fn); }
  click() { for (const fn of this.listeners.click || []) fn({ target: this }); }
  matches(part) {
    if (part === '*') return true;
    const tag = part.match(/^[a-z]+/i);
    if (tag && this.tagName !== tag[0].toUpperCase()) return false;
    for (const c of part.matchAll(/\.([\w-]+)/g)) if (!this.classList.contains(c[1])) return false;
    for (const a of part.matchAll(/\[([\w-]+)\]/g)) if (a[1] === 'data-qid' && !this.dataset.qid) return false;
    return true;
  }
  querySelectorAll(selector) {
    const all = [];
    const visit = (e) => { for (const c of e.children) { all.push(c); visit(c); } };
    visit(this);
    return all.filter((e) => selector.split(',').some((sel) => {
      const parts = sel.trim().split(/\s+/); let cur = e;
      if (!cur.matches(parts.pop())) return false;
      while (parts.length) {
        const p = parts.pop();
        if (p === '>') { cur = cur.parentElement; const parent = parts.pop(); if (parent === ':scope') { if (cur !== this) return false; } else if (!cur?.matches(parent)) return false; }
        else { cur = cur.parentElement; while (cur && !cur.matches(p)) cur = cur.parentElement; if (!cur) return false; }
      }
      return true;
    }));
  }
  querySelector(s) { return this.querySelectorAll(s)[0] || null; }
  contains(e) { return e === this || this.children.some((c) => c.contains(e)); }
  scrollIntoView() { this.scrolled = true; }
}
const document = { body: new Element('body'), documentElement: new Element('html'), readyState: 'complete', addEventListener() {},
  createElement: (tag) => new Element(tag), createTextNode: (t) => { const e = new Element('text'); e.textContent = t; return e; },
  querySelectorAll(s) { return this.body.querySelectorAll(s); }, getElementById() { return null; }, createTreeWalker() { return { nextNode() { return null; } }; }
};
const messages = [];
const rafQueue = [];
const flushRaf = () => { while (rafQueue.length) rafQueue.shift()(); };
const window = { cdvQuote: Q, requestAnimationFrame: (fn) => { rafQueue.push(fn); return rafQueue.length; }, addEventListener() {}, innerHeight: 500, matchMedia: () => ({ matches: true }),
  webkit: { messageHandlers: { wb: { postMessage: (m) => messages.push(m) } } }
};
const context = { addEventListener() {}, window, document, console, setTimeout() {}, clearTimeout() {}, setInterval() {}, clearInterval() {},
  IntersectionObserver: class { observe() {} unobserve() {} }, ResizeObserver: class { observe() {} }, NodeFilter: { SHOW_TEXT: 4, FILTER_REJECT: 2, FILTER_ACCEPT: 1 },
  marked: require(path.join(base, 'vendor/marked.umd.js')), performance: { now: () => 0 }, navigator: {} };
vm.runInNewContext(fs.readFileSync(path.join(base, 'chat.js'), 'utf8'), context);
const wb = window.wb;
const quotes = () => messages.filter((m) => m.type === 'quotes').at(-1).items;
const turn = (id) => document.querySelectorAll('.turn').find((t) => t.dataset.qid === id);
wb.history([
  { type: 'user', uuid: 'u-1', message: { content: [{ type: 'text', text: '第一則' }] } },
  { type: 'assistant', uuid: 'a-record', message: { id: 'msg_2', content: [{ type: 'text', text: '**回答**' }] } },
  { type: 'user', uuid: 'u-3', message: { content: [{ type: 'text', text: sample }] } }
]);
assert.equal(turn('u-3').querySelector('.bubble-t').textContent, '我的問題');
assert.equal(turn('u-3').querySelectorAll('.quote-label').length, 2);
assert.ok(turn('msg_2').querySelector('.turn-copy'));
turn('msg_2').querySelector('.quote-toggle').click();
turn('u-1').querySelector('.quote-toggle').click();
assert.deepEqual(Array.from(quotes(), (q) => q.qid), ['u-1', 'msg_2']);
assert.equal(quotes()[1].text, '**回答**');
assert.equal(turn('u-1').classList.contains('quoted'), true);
turn('msg_2').querySelector('.quote-toggle').click();
assert.equal(quotes().length, 1);
assert.equal(turn('msg_2').querySelector('.quote-toggle').getAttribute('aria-pressed'), 'false');
wb.localUser({ uuid: 'pending', text: '', queued: true, quotes: Q.parse(sample).quotes });
assert.equal(turn('pending').querySelectorAll('.quote-label').length, 2);
// 送出失敗只撤泡泡，選取集合要保留到成功才清除。
wb.localUser({ uuid: 'failed', text: '失敗' });
wb.unsend('failed');
assert.equal(quotes().length, 1);
wb.clearQuotes();
assert.equal(quotes().length, 0);
assert.equal(document.body.querySelector('.quote-tray').hidden, true);
wb.restoreQuotes([{ qid: 'u-1', role: 'user', text: '第一則' }]);
assert.equal(quotes().length, 1);
wb.localUser({ uuid: 'other', text: '新訊息' });
wb.unsend('pending');
assert.equal(turn('pending'), undefined);
assert.ok(turn('other'));
turn('u-3').querySelector('.quote-label').click();
assert.equal(turn('u-1').scrolled, true);
wb.moreAbove();
wb.localUser({ uuid: 'jump', text: '', quotes: [{ qid: 'missing', role: 'user', preview: '舊訊息' }] });
turn('jump').querySelector('.quote-label').click();
for (let i = 0; i < 7; i++) wb.historyPrepend([], true);
assert.equal(messages.filter((m) => m.type === 'loadOlder').length, 5);
wb.restoreQuotes([{ qid: 'u-1', role: 'user', text: '第一則' }]);
assert.equal(quotes()[0].text, '第一則');
turn('u-1').querySelector('.quote-toggle').click();
turn('u-3').querySelector('.quote-toggle').click();
assert.equal(quotes()[0].text, '我的問題');
assert.equal(quotes()[0].text.includes('codenv'), false);
document.body.querySelector('.quote-chip').click();
assert.equal(quotes().length, 0);
// 重建歷史不能回報空引用洗掉 Swift 保存的選取；載入後再由 Swift 還原。
wb.restoreQuotes([{ qid: 'u-1', role: 'user', text: '第一則' }]);
const beforeReload = messages.filter((m) => m.type === 'quotes').length;
wb.history([{ type: 'user', uuid: 'u-1', message: { content: '第一則' } }]);
assert.equal(messages.filter((m) => m.type === 'quotes').length, beforeReload);
assert.equal(document.body.querySelector('.quote-tray').hidden, true);
wb.restoreQuotes([{ qid: 'u-1', role: 'user', text: '第一則' }]);
assert.equal(turn('u-1').classList.contains('quoted'), true);
assert.equal(document.body.querySelector('.quote-tray').hidden, false);
assert.equal(quotes()[0].qid, 'u-1');
const legacy = { type: 'user', message: { content: '沒有 uuid 的舊文字' } };
wb.history([legacy]);
const legacyID = document.querySelectorAll('.turn.user')[0].dataset.qid;
wb.history([{ ...legacy, timestamp: '2026-10-31T00:00:00Z' }]);
assert.equal(document.querySelectorAll('.turn.user')[0].dataset.qid, legacyID);

// 閱讀位置錨點：卸載前抓取、重建後還原，且不被自動貼底搶走。
const anchorRecords = [
  { type: 'user', uuid: 'u-1', message: { content: '第一則' } },
  { type: 'assistant', uuid: 'a-2', message: { id: 'msg_2', content: [{ type: 'text', text: '第二則回答' }] } },
  { type: 'user', uuid: 'u-3', message: { content: '第三則' } }
];
wb.history(anchorRecords);
flushRaf();
assert.equal(document.documentElement.scrollTop, 500);
assert.equal(wb.scrollAnchor().bottom, true);

// 往上捲到第 2 則訊息（index 1，頂端偏移 -35）：重建後應回到同一位置，且 raf(stick) 不搶回最底。
document.documentElement.scrollTop = 135;
const savedAnchor = { ...wb.scrollAnchor() };
assert.deepEqual(savedAnchor, { bottom: false, qid: 'msg_2', index: 1, tail: 1, fromEnd: 0, offset: -35 });
wb.history(anchorRecords);
assert.equal(document.documentElement.scrollTop, 500);
assert.equal(wb.restoreAnchor(savedAnchor), true);
assert.equal(document.documentElement.scrollTop, 135);
flushRaf();
wb.setPetInset(120, 80);
wb.historyAppend([{ type: 'assistant', uuid: 'a-4', message: { id: 'msg_4', content: [{ type: 'text', text: '同步新增' }] } }]);
assert.equal(document.documentElement.scrollTop, 135);
assert.deepEqual({ ...wb.scrollAnchor() }, { ...savedAnchor, fromEnd: 0, tail: 2 });   // 後面多一則：倒數位置跟著變
assert.equal(document.body.querySelector('.jump').hidden, false);

// 原本貼底：重建後照舊貼底。
assert.equal(wb.restoreAnchor({ bottom: true, qid: 'u-1', index: 0, offset: -10 }), true);
flushRaf();
assert.equal(document.documentElement.scrollTop, 500);
assert.equal(wb.scrollAnchor().bottom, true);

// 錨點訊息不在載入範圍內：應貼底，不能誤跳到同 index 的其他訊息。
document.documentElement.scrollTop = 100;
assert.equal(wb.restoreAnchor({ bottom: false, qid: 'older-not-loaded', index: 0, offset: -20 }), false);
flushRaf();
assert.equal(document.documentElement.scrollTop, 500);
assert.equal(wb.scrollAnchor().bottom, true);

// 沒有 qid 時以 log 序號（index）還原。
assert.equal(wb.restoreAnchor({ bottom: false, qid: '', index: 1, offset: -25 }), true);
flushRaf();
assert.equal(document.documentElement.scrollTop, 125);

// 沒有 qid、有 tail（從最後一則倒數）：重建時只載入最後一段也對得上，優先於從頭數的 index（agy Argon 11/6）
assert.equal(wb.restoreAnchor({ bottom: false, qid: '', index: 0, tail: 2, offset: -25 }), true);
flushRaf();
assert.equal(document.documentElement.scrollTop, 125);   // 4 則裡倒數第 3 則＝index 1，不是 index 0
// tail 超出目前載入的範圍（那則在更早、還沒載入的歷史裡）：貼底，不能跳到別則
assert.equal(wb.restoreAnchor({ bottom: false, qid: '', index: 0, tail: 9, offset: -25 }), false);
flushRaf();
assert.equal(document.documentElement.scrollTop, 500);
console.log('quote-test: PASS (parser + minimal DOM; no WebKit/layout)');
