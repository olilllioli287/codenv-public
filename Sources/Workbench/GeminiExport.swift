import AppKit
import ImageIO
import WebKit

// 瀏覽器格子裡的 Gemini 網頁：匯出對話（他平常用 Chrome 擴充 Voyager 匯出，內嵌瀏覽器沒辦法）
// 還有 ⌘ Enter 送出／Enter 換行。
// 匯出格式比照 Voyager：資料夾裡 chat.md（每輪「使用者」「助理」）＋assets/（圖片），md 用相對路徑引用。
// 做法：在網頁裡讀 DOM（user-query／model-response 元素）轉成 Markdown，圖片在網頁裡 fetch 成 base64 傳回來存檔；
// 網頁 fetch 不到的（跨網域沒開 CORS）改用 codenv 自己的 cookie 向 Google 的圖片網址抓；再抓不到的 md 留原網址、結果裡數出來。
// 只讀網頁，不點、不打字，不送訊息。

enum GeminiExport {
    /// 測試用：CODENV_GEMINI_ANY=1 時任何網頁都當成 Gemini（本機假頁測試）
    /// 測試旗標：任何頁都當 NotebookLM（本機假頁用）
    static let nbAny = ProcessInfo.processInfo.environment["CODENV_NOTEBOOK_ANY"] == "1"
    static func isNotebook(_ url: URL?) -> Bool {
        if nbAny { return url != nil && url?.absoluteString != "about:blank" }
        return url?.host.map { notebookHosts.contains($0) } ?? false
    }
    /// NotebookLM 的網址主機：notebooklm.google.com 現在會轉到 notebook.google.com，兩個都認（跟 Bundles.swift 一致）。腳本裡的主機判斷也用這份
    static let notebookHosts = ["notebook.google.com", "notebooklm.google.com"]
    static let anyHost = ProcessInfo.processInfo.environment["CODENV_GEMINI_ANY"] == "1"

    static func isGemini(_ url: URL?) -> Bool {
        if anyHost { return url != nil && url?.absoluteString != "about:blank" }
        return url?.scheme == "https" && url?.host == "gemini.google.com"
    }

    /// 有對話可以匯的頁面（/app 本身是新對話，沒有東西可匯）
    static func isConversation(_ url: URL?) -> Bool {
        guard isGemini(url), let url else { return false }
        if anyHost { return true }
        let p = url.path
        return p != "" && p != "/" && p != "/app" && p != "/app/"
    }

    struct Output {
        var folder: URL
        var turns: Int
        var images: Int
        var failed: [String]
        /// 有 user-query 但文字、檔名、圖片都沒抓到的輪數（網頁結構跟預期不同、或畫面外的輪沒渲染出來）
        var emptyUsers: Int = 0
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ m: String) { message = m }
    }

    // MARK: ⌘ Enter 送出、Enter 換行

    static var keysOn: Bool { appDefaults.object(forKey: "geminiCmdEnter") as? Bool ?? true }

    /// 注入 gemini.google.com 的腳本：capture 階段攔 keydown。
    /// 單按 Enter（沒有修飾鍵）→ 換行不送出；⌘ Enter → 點送出鈕；⇧ Enter 等其他組合照原樣。輸入法選字中（isComposing、keyCode 229）一律不攔。
    static func keysScript(on: Bool) -> WKUserScript {
        let js = keysJS.replacingOccurrences(of: "__NBANY__", with: nbAny ? "true" : "false").replacingOccurrences(of: "__ANY__", with: anyHost ? "true" : "false").replacingOccurrences(of: "__ON__", with: on ? "true" : "false")
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    static let keysJS = #"""
    (function () {
      var NB = ['notebook.google.com', 'notebooklm.google.com'].indexOf(location.hostname) >= 0 || __NBANY__;
      if (!(location.hostname === 'gemini.google.com' || NB || __ANY__)) return;
      if (window.__codenvKeysInstalled) { window.__codenvKeysOn = __ON__; return; }
      window.__codenvKeysInstalled = true;
      window.__codenvKeysOn = __ON__;
      // 先用不依賴介面語言的（class、data 屬性、send 圖示），aria-label 的字只當後備
      var SEND_SEL = ['button.send-button', 'button[data-test-id="send-button"]', 'button.submit-button',
                      'button:has(mat-icon[fonticon="send"])', 'button:has(mat-icon[data-mat-icon-name="send"])', 'button:has(mat-icon[fonticon="arrow_upward"])',
                      'button[aria-label="傳送訊息"]', 'button[aria-label="Send message"]', 'button[aria-label="傳送"]', 'button[aria-label="Send"]',
                      'button[aria-label="Submit"]', 'button[aria-label="送出"]', 'button[aria-label="提交"]'];
      // 找得到、而且按得下去的送出鍵
      function sendButton() {
        for (var i = 0; i < SEND_SEL.length; i++) {
          var list = document.querySelectorAll(SEND_SEL[i]);
          for (var j = 0; j < list.length; j++) {
            var b = list[j];
            if (b.disabled || b.getAttribute('aria-disabled') === 'true') continue;
            return b;
          }
        }
        return null;
      }
      // 頁面上有沒有送出鍵（不管能不能按）：沒有＝頁面還沒準備好（或 Gemini 改版）。這時不攔 Enter，交還給網頁自己處理
      function hasSendButton() {
        for (var i = 0; i < SEND_SEL.length; i++) if (document.querySelector(SEND_SEL[i])) return true;
        return false;
      }
      // ⌘ Enter：送出鍵可能還沒出現或還沒變成可按（編輯器晚一點才載好）：最多等 1 秒；還是沒有就送一個沒有修飾鍵的 Enter 給網頁自己處理
      function textOf(box) { return box.tagName === 'TEXTAREA' ? box.value : box.innerText; }
      function sendWhenReady(box) {
        var tries = 0, snap = textOf(box);
        (function tick() {
          if (textOf(box) !== snap) return;   // 等的期間內容被改了：放棄，不送出當下的內容
          var b = sendButton();
          if (b) { b.click(); return; }
          if (++tries < 20) { setTimeout(tick, 50); return; }
          window.__codenvPass = true;
          try {
            box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true }));
          } finally { window.__codenvPass = false; }
        })();
      }
      function newline(box) {
        if (box.tagName === 'TEXTAREA') {
          // execCommand 走瀏覽器自己的輸入流程：⌘ Z 還能復原這個換行；不行才退回直接改內容
          if (!document.execCommand('insertText', false, '\n')) {
            var s = box.selectionStart, e = box.selectionEnd;
            box.setRangeText('\n', s, e, 'end');
            box.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertLineBreak' }));
          }
        } else {
          document.execCommand('insertParagraph');
        }
      }
      // Safari 選字確定的那個 Enter：compositionend 先來、keydown 緊接著（isComposing 已經是 false）。確定後 50 毫秒內的 Enter 一律不攔
      var lastCompEnd = -1000;
      window.addEventListener('compositionend', function (e) { lastCompEnd = e.timeStamp; }, true);
      window.addEventListener('keydown', function (e) {
        if (!window.__codenvKeysOn || window.__codenvPass) return;
        if (e.key !== 'Enter' || e.isComposing || e.keyCode === 229) return;
        // 選字確定的那個 Enter：這時組字已經結束，擋掉沒有副作用（不擋的話 Gemini 自己會把它當送出）
        if (e.timeStamp - lastCompEnd < 50) { e.preventDefault(); e.stopImmediatePropagation(); return; }
        var t = e.target;
        if (!t || !t.closest) return;
        // Gemini 是 rich-textarea；NotebookLM 是 query-box 裡的 textarea（選擇器沒對上就不攔，Enter 還給網頁）
        var inRich = t.closest('rich-textarea') || (NB && t.closest('query-box, [class*="query-box"]'));
        if (!inRich) return;
        var box = t.closest('[contenteditable]:not([contenteditable="false"]), textarea');
        if (!box) return;
        if (e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey) {
          e.preventDefault(); e.stopImmediatePropagation();
          sendWhenReady(box);
        } else if (!e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey) {
          if (!hasSendButton()) return;
          e.preventDefault(); e.stopImmediatePropagation();
          newline(box);
        }
      }, true);
    })();
    """#

    // MARK: 版面：隱藏左邊的歷史列表、加寬對話區
    // NotebookLM：來源欄、筆記欄（Studio）各一顆開關

    static var hideHistory: Bool { appDefaults.object(forKey: "geminiHideHistory") as? Bool ?? true }
    /// NotebookLM 的來源欄、筆記欄是不是開著（預設都開）
    static var showSources: Bool { appDefaults.object(forKey: "notebookShowSources") as? Bool ?? true }
    static var showStudio: Bool { appDefaults.object(forKey: "notebookShowStudio") as? Bool ?? true }

    /// 只在 gemini.google.com／notebooklm.google.com 生效的 CSS：只改顯示、不碰功能。選的是元件名稱（語意），抓不到元素時規則就不會套到任何東西
    static func layoutScript(hide: Bool) -> WKUserScript {
        let js = layoutJS.replacingOccurrences(of: "__NBANY__", with: nbAny ? "true" : "false")
            .replacingOccurrences(of: "__ANY__", with: anyHost ? "true" : "false")
            .replacingOccurrences(of: "__HIDE__", with: hide ? "true" : "false")
            .replacingOccurrences(of: "__SRC__", with: showSources ? "true" : "false")
            .replacingOccurrences(of: "__STUDIO__", with: showStudio ? "true" : "false")
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    static let layoutJS = #"""
    (function () {
      var NB = ['notebook.google.com', 'notebooklm.google.com'].indexOf(location.hostname) >= 0 || __NBANY__;
      var GM = location.hostname === 'gemini.google.com' || __ANY__;
      if (!(GM || NB)) return;
      window.__codenvHideHistory = __HIDE__;
      window.__codenvShowSources = __SRC__;
      window.__codenvShowStudio = __STUDIO__;
      if (window.__codenvLayoutInstalled) { if (window.__codenvApplyLayout) window.__codenvApplyLayout(); return; }
      window.__codenvLayoutInstalled = true;
      var RULES = [];
      if (GM) RULES.push({ id: 'codenv-gemini-layout', on: function () { return window.__codenvHideHistory; }, css: [
        // 左邊的歷史導覽欄整個藏起來，內容區的左邊界歸零
        'bard-sidenav { display: none !important; }',
        'bard-sidenav-container bard-sidenav-content, bard-sidenav-container .mat-drawer-content { margin-left: 0 !important; }',
        // 對話區和輸入區放寬
        '.conversation-container, .input-area-container, input-container { max-width: min(1100px, 92%) !important; }'
      ].join('\n') });
      if (NB) {
        RULES.push({ id: 'codenv-nb-sources', on: function () { return !window.__codenvShowSources; },
          css: 'source-panel, .source-panel { display: none !important; }' });
        RULES.push({ id: 'codenv-nb-studio', on: function () { return !window.__codenvShowStudio; },
          css: 'studio-panel, .studio-panel { display: none !important; }' });
      }
      function apply() {
        RULES.forEach(function (r) {
          var st = document.getElementById(r.id);
          if (!r.on()) { if (st) st.remove(); return; }
          if (st) return;
          st = document.createElement('style');
          st.id = r.id;
          st.textContent = r.css;
          (document.head || document.documentElement).appendChild(st);
        });
      }
      window.__codenvApplyLayout = apply;
      apply();
      // 文件還沒有 head、或網頁自己清掉 <style>：載入完成後、以及根節點的子節點變動時再確認一次
      document.addEventListener('DOMContentLoaded', apply);
      new MutationObserver(function () {
        for (var i = 0; i < RULES.length; i++) if (RULES[i].on() && !document.getElementById(RULES[i].id)) { apply(); return; }
      }).observe(document.documentElement, { childList: true });
    })();
    """#

    // MARK: 匯出：讀 DOM

    /// callAsyncJavaScript 的函式本體：先捲到最上面把舊的訊息都載入，再轉成 { title, url, turns, imgs }；抓不到對話回 { error }
    static let collectJS = #"""
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const Q = (s, r) => Array.from((r || document).querySelectorAll(s));
    const TURN = 'user-query, model-response';
    const first = document.querySelector(TURN);
    if (!first) {
      return { error: '這一頁找不到對話內容（沒有 user-query／model-response 元素）。Gemini 網頁改版了，或這頁還沒載入完。',
               diag: { title: document.title, bodyChars: document.body ? document.body.innerText.length : 0 } };
    }
    function scrollParent(el) {
      for (let p = el.parentElement; p; p = p.parentElement) {
        const s = getComputedStyle(p);
        if (/(auto|scroll)/.test(s.overflowY) && p.scrollHeight > p.clientHeight + 4) return p;
      }
      return document.scrollingElement || document.documentElement;
    }
    // 舊的訊息捲到上面才會載入：一直捲到頂，直到數量連三次不變；做完把使用者原本的位置還回去
    const sp = scrollParent(first);
    const fromBottom = sp.scrollHeight - sp.scrollTop;
    let stable = 0, last = -1;
    for (let i = 0; i < 80 && stable < 3; i++) {
      sp.scrollTop = 0;
      await sleep(600);
      const n = Q(TURN).length;
      if (n === last) stable++; else { stable = 0; last = n; }
    }
    // 畫面外的輪是 content-visibility: auto，不會被渲染（innerText 是空的、預覽圖還沒插進來）：逐輪捲進畫面，等它的圖出現再收
    const hasPlaceholder = el => !!el.querySelector('user-query-file-preview, user-query-file-carousel, [class*="file-preview"], [class*="preview-image"]');
    const lazyImgs = el => Q('img', el).filter(i => !(i.currentSrc || i.src) || (!i.complete && i.naturalWidth === 0));
    for (const el of Q(TURN)) {
      el.scrollIntoView({ block: 'center' });
      await sleep(180);
      for (let w = 0; w < 8; w++) {
        const waitImg = (hasPlaceholder(el) && !el.querySelector('img')) || lazyImgs(el).length > 0;
        if (!waitImg) break;
        await sleep(100);
      }
    }
    sp.scrollTop = sp.scrollHeight - fromBottom;

    const imgs = [], imgIndex = new Map();
    // 祖先比對只走到這一輪的元素（user-query／model-response）為止：Gemini 的 <body> class 一長串旗標，含「avatar」字樣，往上爬到 body 會把每張圖都誤判成頭像
    function inTurn(img, sel) {
      for (let p = img; p && p.nodeType === 1; p = p.parentElement) {
        const t = p.tagName.toLowerCase();
        if (t === 'user-query' || t === 'model-response' || t === 'body' || t === 'html') return false;
        if (p.matches(sel)) return true;
      }
      return false;
    }
    function isPreview(img) { return inTurn(img, 'user-query-file-preview, .file-preview-container, .query-file-preview') || /preview-image/.test(img.className || ''); }
    function usable(img) {
      const src = img.currentSrc || img.src;
      if (!src) return false;
      if (inTurn(img, 'bard-avatar, .bard-avatar, .avatar, .user-avatar, mat-icon, .mat-icon, source-footnote, sources-carousel-inline')) return false;
      if (/(^|\s)luminous-file-icon(\s|$)/.test(img.className || '')) return false;   // 檔案類型圖示：只留檔名
      // 檔案類型圖示不收：一般圖 48×48 以下、使用者上傳的預覽圖 32×32 以下
      const small = img.complete && img.naturalWidth > 0 && img.naturalHeight > 0;
      if (small && isPreview(img) && img.naturalWidth <= 32 && img.naturalHeight <= 32) return false;
      if (small && !isPreview(img) && img.naturalWidth <= 48 && img.naturalHeight <= 48) return false;
      return true;
    }
    function reg(img) {
      const src = img.currentSrc || img.src;
      if (!imgIndex.has(src)) { imgIndex.set(src, imgs.length); imgs.push({ src: src, alt: img.alt || '' }); }
      return imgIndex.get(src);
    }

    // ---- HTML → Markdown ----
    const BLOCK = new Set(['p', 'div', 'ul', 'ol', 'li', 'pre', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'table', 'blockquote', 'hr', 'section', 'article', 'code-block', 'table-block', 'message-content']);
    const SKIP = new Set(['script', 'style', 'source-footnote', 'sources-carousel-inline', 'button', 'mat-icon', 'svg', 'noscript']);
    function hasBlockChild(n) { return Array.from(n.children).some(c => isBlock(c)); }
    function isBlock(n) {
      const t = n.tagName.toLowerCase();
      if (BLOCK.has(t)) return true;
      return t.indexOf('-') > 0 && hasBlockChild(n);
    }
    function kids(n, f) { return Array.from(n.childNodes).map(f).join(''); }
    function wrap(m, s) {
      const core = s.trim();
      if (!core) return s;
      return s.slice(0, s.length - s.trimStart().length) + m + core + m + s.slice(s.trimEnd().length);
    }
    function inl(n) {
      if (n.nodeType === 3) return n.textContent.replace(/[ \t\r\n]+/g, ' ');
      if (n.nodeType !== 1) return '';
      const t = n.tagName.toLowerCase();
      if (SKIP.has(t)) return '';
      const dm = n.getAttribute('data-math');
      if (dm !== null) return (n.classList.contains('math-block') || t === 'div') ? '\n\n$$' + dm + '$$\n\n' : '$' + dm + '$';
      switch (t) {
        case 'br': return '  \n';
        case 'strong': case 'b': return wrap('**', kids(n, inl));
        case 'em': case 'i': return wrap('*', kids(n, inl));
        case 's': case 'del': return wrap('~~', kids(n, inl));
        case 'code': return '`' + n.textContent + '`';
        case 'a': { const h = n.getAttribute('href'); const s = kids(n, inl); return h && s.trim() ? '[' + s.trim() + '](' + n.href + ')' : s; }
        case 'img': return usable(n) ? '\n\n![' + (n.alt || '圖片') + '](@@IMG:' + reg(n) + '@@)\n\n' : '';
        default: return kids(n, inl);
      }
    }
    function fence(code, lang) {
      let f = '```';
      while (code.indexOf(f) >= 0) f += '`';
      return f + (lang || '') + '\n' + code.replace(/\n+$/, '') + '\n' + f;
    }
    function table(n) {
      const rows = Q('tr', n).map(tr => Array.from(tr.children).filter(c => /^(td|th)$/i.test(c.tagName))
        .map(c => kids(c, inl).replace(/\|/g, '\\|').replace(/\s*\n\s*/g, ' ').trim()));
      if (!rows.length) return '';
      const w = Math.max.apply(null, rows.map(r => r.length));
      const line = r => '| ' + r.concat(Array(w - r.length).fill('')).join(' | ') + ' |';
      return [line(rows[0]), '|' + Array(w).fill(' --- ').join('|') + '|'].concat(rows.slice(1).map(line)).join('\n');
    }
    function list(n, depth) {
      const ord = n.tagName === 'OL';
      let i = parseInt(n.getAttribute('start') || '1', 10) || 1;
      const out = [];
      for (const li of Array.from(n.children)) {
        if (li.tagName !== 'LI') continue;
        const body = blocks(li, depth + 1, '\n').split('\n');
        const mark = ord ? (i++) + '. ' : '- ';
        out.push(mark + body[0] + (body.length > 1 ? '\n' + body.slice(1).map(l => l ? ' '.repeat(mark.length) + l : l).join('\n') : ''));
      }
      return out.join('\n');
    }
    function block(n, depth) {
      const t = n.tagName.toLowerCase();
      if (SKIP.has(t)) return '';
      if (n.getAttribute('data-math') !== null) return inl(n).trim();
      if (/^h[1-6]$/.test(t)) return '#'.repeat(+t[1]) + ' ' + kids(n, inl).trim();
      if (t === 'p') return kids(n, inl).trim();
      if (t === 'ul' || t === 'ol') return list(n, depth);
      if (t === 'hr') return '---';
      if (t === 'blockquote') return blocks(n, depth, '\n\n').split('\n').map(l => '> ' + l).join('\n');
      if (t === 'table') return table(n);
      if (t === 'table-block') { const tb = n.querySelector('table'); return tb ? table(tb) : blocks(n, depth, '\n\n'); }
      if (t === 'code-block') {
        const lang = ((n.querySelector('.code-block-decoration span') || {}).textContent || '').trim().toLowerCase();
        const c = n.querySelector('code') || n.querySelector('pre') || n;
        return fence(c.textContent, lang);
      }
      if (t === 'pre') {
        const c = n.querySelector('code');
        const m = c && /language-([\w+-]+)/.exec(c.className || '');
        return fence((c || n).textContent, m ? m[1] : '');
      }
      return blocks(n, depth, '\n\n');
    }
    function blocks(n, depth, sep) {
      const out = [];
      let buf = '';
      const flush = () => { const s = buf.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim(); if (s) out.push(s); buf = ''; };
      for (const c of Array.from(n.childNodes)) {
        if (c.nodeType === 1 && isBlock(c)) { flush(); const b = block(c, depth); if (b) out.push(b); }
        else buf += inl(c);
      }
      flush();
      return out.join(sep);
    }

    // ---- 逐輪 ----
    // textContent 轉純文字（<br> 換成換行）；innerText 在畫面外的輪是空的，不能靠它
    function plain(n) {
      if (n.nodeType === 3) return n.textContent;
      if (n.nodeType !== 1) return '';
      if (n.tagName === 'BR') return '\n';
      const t = Array.from(n.childNodes).map(plain).join('');
      return /^(P|DIV|LI)$/.test(n.tagName) && t && !t.endsWith('\n') ? t + '\n' : t;
    }
    function bgUrls(el) {
      const out = [];
      Q('[class*="preview"], [class*="thumbnail"]', el).forEach(e => {
        const m = /url\(["']?([^"')]+)["']?\)/.exec(getComputedStyle(e).backgroundImage || '');
        if (m && out.indexOf(m[1]) < 0) out.push(m[1]);
      });
      return out;
    }
    function userPart(el) {
      const lines = Q('.query-text-line', el);
      let text;
      if (lines.length) text = lines.map(l => plain(l).replace(/\u00a0/g, ' ').replace(/\n+$/, '')).join('\n').trim();
      else {
        const qt = el.querySelector('.query-text');
        text = qt ? plain(qt).replace(/\u00a0/g, ' ').trim() : '';
      }
      const files = [];
      Q('[data-test-id*="file-name"], .file-name, .new-file-name, [class*="file-name"]', el).forEach(f => {
        const s = f.textContent.trim();
        if (s && files.indexOf(s) < 0) files.push(s);
      });
      const ims = [];
      Q('img', el).filter(usable).forEach(i => { const k = reg(i); if (ims.indexOf(k) < 0) ims.push(k); });
      bgUrls(el).forEach(u => {   // 備援：預覽圖有時是 background-image
        if (!imgIndex.has(u)) { imgIndex.set(u, imgs.length); imgs.push({ src: u, alt: '' }); }
        const k = imgIndex.get(u); if (ims.indexOf(k) < 0) ims.push(k);
      });
      return { text: text, files: files, images: ims };
    }
    // 診斷：每個 user-query 的標籤摘要（只有標籤名稱和數量，沒有對話內容）
    function shape(el) {
      const tags = {};
      Q('*', el).forEach(e => { const k = e.tagName.toLowerCase() + (e.className && typeof e.className === 'string' ? '.' + e.className.trim().split(/\s+/)[0] : ''); tags[k] = (tags[k] || 0) + 1; });
      const top = Object.keys(tags).sort((a, b) => tags[b] - tags[a]).slice(0, 14).map(k => k + '×' + tags[k]);
      return { imgs: Q('img', el).length, imgsWithSrc: Q('img', el).filter(i => i.currentSrc || i.src).length, textChars: el.textContent.trim().length,
               queryLines: Q('.query-text-line', el).length, hasPreviewEl: hasPlaceholder(el), top: top };
    }
    function modelPart(el) {
      const body = el.querySelector('message-content .markdown') || el.querySelector('message-content') || el.querySelector('.markdown') || el;
      let md = blocks(body, 0, '\n\n');
      return { md: md };
    }
    const turns = [], diag = [];
    let cur = null;
    for (const el of Q(TURN)) {
      if (el.tagName.toLowerCase() === 'user-query') {
        cur = { user: userPart(el), model: null };
        turns.push(cur);
        diag.push(Object.assign({ turn: turns.length }, shape(el)));
      } else {
        if (!cur) { cur = { user: { text: '', files: [], images: [] }, model: null }; turns.push(cur); }
        const m = modelPart(el);
        if (!cur.model) cur.model = m;
        else if (m.md) cur.model.md = (cur.model.md ? cur.model.md + '\n\n' : '') + m.md;   // 同一輪有第二段回覆（分段、工具呼叫）：接在後面不丟掉
      }
    }
    const raw = (document.querySelector('[data-test-id="conversation-title"]') || {}).textContent || document.title || '';
    const title = raw.replace(/\s*[-–|]\s*Google Gemini\s*$/i, '').replace(/^\s*Google Gemini\s*$/i, '').trim();
    return { title: title, url: location.href, turns: turns, imgs: imgs, diag: diag, ua: navigator.userAgent };
    """#

    /// 在網頁裡抓一張圖：回 { type, data(base64) }；失敗丟錯
    static let fetchJS = #"""
    const abs = new URL(src, location.href).href;
    // 一張圖卡住（伺服器接了連線不回應、回應傳一半不結束）不能讓整次匯出一直等：20 秒到就中止，這張算下載失敗
    const ac = new AbortController();
    const tm = setTimeout(() => ac.abort(), 20000);
    try {
      const r = await fetch(abs, { credentials: 'include', signal: ac.signal });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const b = await r.blob();
      const data = await new Promise((ok, no) => { const f = new FileReader(); f.onload = () => ok(String(f.result).split(',')[1] || ''); f.onerror = () => no(f.error); f.readAsDataURL(b); });
      return { type: b.type, data: data };
    } finally { clearTimeout(tm); }
    """#

    // MARK: 存檔

    /// 帶 cookie 抓圖只限這幾個 Google 自家網域（含根網域本身）
    static func isGoogleHost(_ host: String) -> Bool {
        ["googleusercontent.com", "google.com", "gstatic.com", "ggpht.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 轉址只跟到還是 Google 網域的 https；轉到別處就不跟（cookie 是 session 依主機帶的，不會送到別處）。每張圖用一個新的，順便記轉址次數和被擋下的目標主機（診斷用，只記主機）
    final class SameGoogleRedirect: NSObject, URLSessionTaskDelegate {
        var redirects = 0
        var blockedHost: String?
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            redirects += 1
            if let u = request.url, u.scheme == "https", let h = u.host?.lowercased(), GeminiExport.isGoogleHost(h) { completionHandler(request) }
            else { blockedHost = request.url?.host ?? "?"; completionHandler(nil) }
        }
    }

    /// 一張圖下載的結果和診斷（不含 cookie、不含網址查詢參數）
    struct DownloadInfo {
        var data: Data?
        var mime = ""
        var status: Int?
        var finalHost: String?
        var redirects = 0
        var blockedHost: String?
        var urlErrorCode: Int?
        var reason = ""
    }

    /// WKWebView 的 cookie 裡留下 Google 自家網域的（含 .google.com 與 .googleusercontent.com）；別的網站的 cookie 不碰
    static func googleCookies(_ all: [HTTPCookie]) -> [HTTPCookie] {
        all.filter { c in isGoogleHost((c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain).lowercased()) }
    }

    /// 抓圖專用的 session：ephemeral（cookie 只放在這個 session 自己的記憶體，不碰 HTTPCookieStorage.shared、不寫硬碟），
    /// 把上面篩過的 cookie 放進去，讓 URLSession 依每一跳的主機自己帶對的 cookie（lh3.googleusercontent.com 會轉址到 lh3.google.com）；轉址只跟 Google 的 https
    static func downloadSession(cookies: [HTTPCookie]) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 30
        for c in cookies { cfg.httpCookieStorage?.setCookie(c) }
        return URLSession(configuration: cfg, delegate: SameGoogleRedirect(), delegateQueue: nil)
    }

    /// 向 Google 圖片網址抓一張；不是 200、不是 image/*（例如被導去登入頁的 HTML）都算失敗，原因記在 reason
    static func download(_ src: String, with session: URLSession) async -> DownloadInfo {
        var info = DownloadInfo()
        guard let u = URL(string: src), u.scheme == "https", let h = u.host?.lowercased(), isGoogleHost(h) else { info.reason = "不是 Google 網域的 https 網址，不下載"; return info }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.setValue("https://gemini.google.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let del = SameGoogleRedirect()
        do {
            let (d, resp) = try await session.data(for: req, delegate: del)
            info.redirects = del.redirects; info.blockedHost = del.blockedHost
            guard let http = resp as? HTTPURLResponse else { info.reason = "回應不是 HTTP"; return info }
            info.status = http.statusCode; info.mime = http.mimeType ?? ""; info.finalHost = http.url?.host
            if http.statusCode != 200 { info.reason = "狀態碼 \(http.statusCode)" }
            else if !info.mime.hasPrefix("image/") { info.reason = "不是圖片（\(info.mime.isEmpty ? "沒有 Content-Type" : info.mime)）" }
            else if d.isEmpty { info.reason = "回應是空的" }
            else { info.data = d }
        } catch {
            info.redirects = del.redirects; info.blockedHost = del.blockedHost
            info.urlErrorCode = (error as? URLError)?.code.rawValue ?? (error as NSError).code
            info.reason = del.blockedHost != nil ? "轉址到非 Google 網域被擋下" : "連線錯誤"
        }
        return info
    }

    /// 診斷用：交給下載的 cookie 摘要（網域、數量、__Secure-／__Host- 開頭各幾個），不含名稱本身以外的任何值
    static func cookieSummary(_ cookies: [HTTPCookie]) -> [String: Any] {
        var byDomain: [String: [String: Int]] = [:]
        for c in cookies {
            var e = byDomain[c.domain] ?? ["count": 0, "secure-prefix": 0, "host-prefix": 0]
            e["count", default: 0] += 1
            if c.name.hasPrefix("__Secure-") { e["secure-prefix", default: 0] += 1 }
            if c.name.hasPrefix("__Host-") { e["host-prefix", default: 0] += 1 }
            byDomain[c.domain] = e
        }
        return ["total": cookies.count, "domains": byDomain]
    }

    /// googleusercontent 的原尺寸網址變體：路徑最後一段沒有 =參數就加上去，有（=s512、=w300-h400…）就換掉；查詢字串和片段照留。先 =s0、再 =d
    static func originalVariants(_ src: String) -> [(name: String, url: String)] {
        guard var c = URLComponents(string: src), let host = c.host?.lowercased(), host == "googleusercontent.com" || host.hasSuffix(".googleusercontent.com"),
              let slash = c.percentEncodedPath.lastIndex(of: "/") else { return [] }
        let path = c.percentEncodedPath
        let head = path[...slash], seg = path[path.index(after: slash)...]
        let base = seg.lastIndex(of: "=").map { String(seg[..<$0]) } ?? String(seg)
        guard !base.isEmpty else { return [] }
        return ["s0", "d"].compactMap { name in
            c.percentEncodedPath = String(head) + base + "=" + name
            return c.string.flatMap { $0 == src ? nil : (name, $0) }   // 網址本來就是這個變體就不重抓
        }
    }

    /// 圖片的像素寬高（只讀檔頭，不解碼）
    static func pixels(_ d: Data) -> (w: Int, h: Int)? {
        guard let s = CGImageSourceCreateWithData(d as CFData, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// 先抓網頁給的預覽圖（長邊 512），再試原尺寸的網址變體（=s0、=d），拿到比預覽大的就用它；變體都失敗或不比預覽大就用預覽。
    /// 預覽也失敗時回預覽的失敗診斷（變體有成功就用變體）。variant：preview／s0／d
    static func best(_ src: String, with session: URLSession) async -> (info: DownloadInfo, variant: String) {
        var chosen = await download(src, with: session), variant = "preview"
        var bestPx = chosen.data.flatMap(pixels).map { $0.w * $0.h } ?? 0
        for v in originalVariants(src) {
            let r = await download(v.url, with: session)
            guard let d = r.data, let px = pixels(d), px.w * px.h > bestPx else { continue }
            chosen = r; variant = v.name; bestPx = px.w * px.h
            break
        }
        return (chosen, variant)
    }

    /// 圖片位元組的種類（看檔頭，不信網站給的 type）
    static func imageExt(_ d: Data, type: String) -> String {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if let s = String(data: d.prefix(200), encoding: .utf8)?.lowercased(), s.contains("<svg") { return "svg" }
        switch type { case "image/png": return "png"; case "image/jpeg": return "jpg"; case "image/webp": return "webp"; case "image/gif": return "gif"; case "image/svg+xml": return "svg"; default: return "img" }
    }

    static func safeName(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "[/:\\\\\\x00-\\x1f]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix(".") { t.removeFirst() }
        if t.count > 60 { t = String(t.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return t.isEmpty ? "Gemini 對話" : t
    }

    /// parent 底下建 <標題>-<時間>/，同名不覆蓋（加 -2、-3…）
    static func makeFolder(title: String, parent: URL, now: Date = Date()) throws -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmm"
        let base = "\(safeName(title))-\(f.string(from: now))"
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var n = 1
        while true {
            let u = parent.appendingPathComponent(n == 1 ? base : "\(base)-\(n)", isDirectory: true)
            do { try fm.createDirectory(at: u, withIntermediateDirectories: false); return u }
            catch CocoaError.fileWriteFileExists { n += 1; if n > 99 { throw Failure(L("同名的資料夾太多了")) } }
        }
    }

    /// 把網頁回來的 turns 組成 chat.md；paths[i] 是第 i 張圖存好的相對路徑（沒抓到＝nil，退回原網址）
    static func markdown(title: String, url: String, turns: [[String: Any]], imgs: [[String: Any]], paths: [Int: String], now: Date = Date()) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        func ref(_ i: Int, alt: String) -> String {
            if let p = paths[i] { return "![\(alt)](\(p))" }
            let src = (i < imgs.count ? imgs[i]["src"] as? String : nil) ?? ""
            return src.hasPrefix("http") ? "![\(alt)](\(src))" : "*[\(L("圖片沒有抓到"))]*"
        }
        var out = "# \(title.isEmpty ? "Gemini" : title)\n\n**Date**: \(df.string(from: now))\n**Turns**: \(turns.count)\n**Source**: [Gemini Chat](\(url))\n\n---\n"
        for (n, t) in turns.enumerated() {
            out += "\n## Turn \(n + 1)\n\n### 👤 使用者\n\n"
            let u = t["user"] as? [String: Any] ?? [:]
            let ims = (u["images"] as? [Int]) ?? (u["images"] as? [NSNumber])?.map(\.intValue) ?? []
            if !ims.isEmpty {
                out += "*[This turn includes uploaded images]*\n\n"
                for i in ims { out += ref(i, alt: "上傳圖片預覽") + "\n\n" }
            }
            for f in (u["files"] as? [String]) ?? [] { out += "📎 \(f)\n" }
            if !(((u["files"] as? [String]) ?? []).isEmpty) { out += "\n" }
            if let text = u["text"] as? String, !text.isEmpty { out += text + "\n\n" }
            out += "### 🤖 助理\n\n"
            var md = ((t["model"] as? [String: Any])?["md"] as? String) ?? ""
            // @@IMG:n@@ → 相對路徑或原網址；alt 已經在 ![alt]( 前面，這裡只換括號裡的
            if let re = try? NSRegularExpression(pattern: #"\]\(@@IMG:(\d+)@@\)"#) {
                let ns = md as NSString
                var res = "", last = 0
                for m in re.matches(in: md, range: NSRange(location: 0, length: ns.length)) {
                    res += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                    let i = Int(ns.substring(with: m.range(at: 1))) ?? -1
                    if let p = paths[i] { res += "](\(p))" }
                    else if i >= 0, i < imgs.count, let s = imgs[i]["src"] as? String, s.hasPrefix("http") { res += "](\(s))" }
                    else { res += "](\(L("圖片沒有抓到")))" }
                    last = m.range.location + m.range.length
                }
                res += ns.substring(from: last)
                md = res
            }
            out += (md.isEmpty ? "*（\(L("沒有內容"))）*" : md) + "\n"
        }
        out += "\n---\n\n*Exported from codenv*  \n*Generated on \(df.string(from: now))*\n"
        return out
    }
}

extension BrowserPane {
    /// 匯出這格 Gemini 的整段對話到 parent（預設 ~/Downloads）底下的新資料夾；只讀網頁
    func exportGemini(parent: URL? = nil, done: @escaping (Result<GeminiExport.Output, Error>) -> Void) {
        guard Prefs.shared.webFeaturesEnabled else { return done(.failure(GeminiExport.Failure(L("網頁外掛功能已關閉（設定可打開）")))) }
        guard GeminiExport.isGemini(webView.url) else { return done(.failure(GeminiExport.Failure(L("這一格不是 Gemini 網頁（gemini.google.com）")))) }
        Task { @MainActor in
            do { done(.success(try await self.runGeminiExport(parent: parent))) } catch { done(.failure(error)) }
        }
    }

    @MainActor private func runGeminiExport(parent: URL?) async throws -> GeminiExport.Output {
        func checkEnabled() throws {
            guard Prefs.shared.webFeaturesEnabled else { throw GeminiExport.Failure(L("網頁外掛功能已關閉（設定可打開）")) }
        }
        try checkEnabled()
        let raw: Any?
        do { raw = try await webView.callAsyncJavaScript(GeminiExport.collectJS, arguments: [:], in: nil, contentWorld: .page) }
        catch { throw GeminiExport.Failure(L("讀不到網頁內容：\(error.localizedDescription)")) }
        try checkEnabled()
        guard let r = raw as? [String: Any] else { throw GeminiExport.Failure(L("網頁回了看不懂的東西")) }
        if let e = r["error"] as? String { throw GeminiExport.Failure(e) }
        let turns = r["turns"] as? [[String: Any]] ?? []
        let imgs = r["imgs"] as? [[String: Any]] ?? []
        let title = (r["title"] as? String) ?? ""
        guard !turns.isEmpty else { throw GeminiExport.Failure(L("這一頁沒有對話內容可以匯出")) }

        let folder = try GeminiExport.makeFolder(title: title, parent: parent ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        let assets = folder.appendingPathComponent("assets", isDirectory: true)
        var paths: [Int: String] = [:], failed: [String] = []
        // 先在網頁裡抓（blob:、data:、同網域、有 CORS 的）；抓不到的（Gemini 的圖在 lh3.googleusercontent.com，跨網域沒 CORS）收集起來，
        // 再用 codenv 自己的 session 帶 Google 的 cookie 一批一批（4 張並行）下載
        var blobs: [Int: (Data, String)] = [:], pending: [Int] = []
        var diagImages: [[String: Any]] = []
        var variants: [Int: String] = [:]
        var pageErrors: [Int: String] = [:]
        var cookieInfo: [String: Any] = [:]
        for (i, im) in imgs.enumerated() {
            try checkEnabled()
            let (r, err) = await pageImage((im["src"] as? String) ?? "")
            if let r { blobs[i] = r } else { pending.append(i); pageErrors[i] = err }
        }
        if !pending.isEmpty {
            let cookies = GeminiExport.googleCookies(await webView.configuration.websiteDataStore.httpCookieStore.allCookies())
            try checkEnabled()
            cookieInfo = GeminiExport.cookieSummary(cookies)
            let session = GeminiExport.downloadSession(cookies: cookies)
            // 總開關關掉時連原生圖片下載也取消，不讓已經開始的匯出在背景繼續連網。
            let observer = NotificationCenter.default.addObserver(forName: Prefs.webFeaturesChanged, object: nil, queue: .main) { _ in
                if !Prefs.shared.webFeaturesEnabled { session.invalidateAndCancel() }
            }
            defer { NotificationCenter.default.removeObserver(observer); session.finishTasksAndInvalidate() }
            var at = 0
            while at < pending.count {
                try checkEnabled()
                let chunk = Array(pending[at..<min(at + 4, pending.count)]); at += 4
                let got = await withTaskGroup(of: (Int, GeminiExport.DownloadInfo, String).self) { g -> [(Int, GeminiExport.DownloadInfo, String)] in
                    for i in chunk { let src = (imgs[i]["src"] as? String) ?? ""; g.addTask { let b = await GeminiExport.best(src, with: session); return (i, b.info, b.variant) } }
                    var out: [(Int, GeminiExport.DownloadInfo, String)] = []
                    for await x in g { out.append(x) }
                    return out
                }
                for (i, info, variant) in got {
                    if let d = info.data { blobs[i] = (d, info.mime); variants[i] = variant; continue }
                    var e: [String: Any] = ["index": i + 1, "startHost": URL(string: (imgs[i]["src"] as? String) ?? "")?.host ?? "?", "pageFetchError": pageErrors[i] ?? "",
                                            "reason": info.reason, "mime": info.mime, "redirects": info.redirects]
                    if let v = info.status { e["status"] = v }
                    if let v = info.finalHost { e["finalHost"] = v }
                    if let v = info.blockedHost { e["blockedRedirectHost"] = v }
                    if let v = info.urlErrorCode { e["urlErrorCode"] = v }
                    diagImages.append(e)
                }
            }
        }
        try checkEnabled()
        var savedImages: [[String: Any]] = []
        for (i, im) in imgs.enumerated() {
            guard let (data, type) = blobs[i], !data.isEmpty else { failed.append((im["src"] as? String) ?? ""); continue }
            if paths.isEmpty { try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true) }
            let name = String(format: "img-%03d.%@", i + 1, GeminiExport.imageExt(data, type: type))
            try data.write(to: assets.appendingPathComponent(name))
            paths[i] = "assets/" + name
            var e: [String: Any] = ["index": i + 1, "variant": variants[i] ?? "page", "bytes": data.count]
            if let px = GeminiExport.pixels(data) { e["width"] = px.w; e["height"] = px.h }
            savedImages.append(e)
        }
        // 診斷檔：每輪使用者訊息的標籤摘要（沒有對話內容），下次匯出結果不對時看得出網頁長什麼樣
        let diag = r["diag"] as? [[String: Any]] ?? []
        var emptyUsers = 0
        for d in diag {
            guard let n = d["turn"] as? Int, n >= 1, n <= turns.count, let u = turns[n - 1]["user"] as? [String: Any] else { continue }
            if ((u["text"] as? String) ?? "").isEmpty, ((u["files"] as? [Any]) ?? []).isEmpty, ((u["images"] as? [Any]) ?? []).isEmpty { emptyUsers += 1 }
        }
        let summary: [String: Any] = ["userAgent": (r["ua"] as? String) ?? "", "turns": turns.count, "images": imgs.count, "imagesSaved": paths.count, "emptyUserTurns": emptyUsers, "userQueries": diag, "downloadCookies": cookieInfo, "failedImages": diagImages, "savedImages": savedImages]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: folder.appendingPathComponent("diag.json")) }
        let md = GeminiExport.markdown(title: title, url: (r["url"] as? String) ?? currentURL, turns: turns, imgs: imgs, paths: paths)
        try md.write(to: folder.appendingPathComponent("chat.md"), atomically: true, encoding: .utf8)
        return GeminiExport.Output(folder: folder, turns: turns.count, images: paths.count, failed: failed, emptyUsers: emptyUsers)
    }

    /// 網頁裡抓一張：data: 直接解、其他用網頁的 fetch（blob:、同網域、有開 CORS 的才行）；失敗時回錯誤訊息（診斷用）
    @MainActor private func pageImage(_ src: String) async -> ((Data, String)?, String?) {
        if src.hasPrefix("data:"), let comma = src.firstIndex(of: ",") {
            let head = src[src.startIndex..<comma], body = String(src[src.index(after: comma)...])
            let d = head.hasSuffix(";base64") ? Data(base64Encoded: body) : body.removingPercentEncoding.map { Data($0.utf8) }
            return (d.map { ($0, String(head.dropFirst(5).split(separator: ";").first ?? "")) }, d == nil ? "data: 網址解不開" : nil)
        }
        do {
            if let v = try await webView.callAsyncJavaScript(GeminiExport.fetchJS, arguments: ["src": src], in: nil, contentWorld: .page) as? [String: Any],
               let b64 = v["data"] as? String, let d = Data(base64Encoded: b64), !d.isEmpty {
                return ((d, (v["type"] as? String) ?? ""), nil)
            }
            return (nil, "網頁 fetch 回了空資料")
        } catch {
            return (nil, String((((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription).prefix(160)))
        }
    }
}
