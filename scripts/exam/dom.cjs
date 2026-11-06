// 共用既有 quote-test 的最小 DOM；只驗資料與互動，不模擬排版。
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
module.exports = (base) => {
const Q = require(path.join(base, 'quote.js'));
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
const window = { cdvQuote: Q, requestAnimationFrame() {}, addEventListener() {}, innerHeight: 500, matchMedia: () => ({ matches: true }),
  webkit: { messageHandlers: { wb: { postMessage: (m) => messages.push(m) } } }
};
const context = { addEventListener() {}, window, document, console, setTimeout() {}, clearTimeout() {}, setInterval() {}, clearInterval() {},
  IntersectionObserver: class { observe() {} unobserve() {} }, ResizeObserver: class { observe() {} }, NodeFilter: { SHOW_TEXT: 4, FILTER_REJECT: 2, FILTER_ACCEPT: 1 },
  marked: require(path.join(base, 'vendor/marked.umd.js')), performance: { now: () => 0 }, navigator: {} };
vm.runInNewContext(fs.readFileSync(path.join(base, 'chat.js'), 'utf8'), context);

return { wb: window.wb, document, messages, Q };
};
