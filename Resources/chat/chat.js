/* AI 工作台：聊天畫面。把 Claude Code 的 stream-json 事件畫成聊天介面。
 * 約定見 docs/chat-protocol.md。全域物件 window.wb 提供給 Swift 呼叫。
 */
(() => {
  'use strict';

  // ───────────────────────── 小工具 ─────────────────────────
  const el = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  };
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const raf = window.requestAnimationFrame.bind(window);
  const stripAnsi = (s) => String(s).replace(/\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]/g, '');
  const firstLine = (s) => String(s || '').split('\n')[0];
  const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
  const lines = (s) => (s ? String(s).replace(/\n$/, '').split('\n').length : 0);

  // ───────────────────────── 介面語言 ─────────────────────────
  // L('中文原文') 或 L`共 ${n} 筆`：查 Swift 傳來的對照表（wb.setLocale，跟 Swift 的 L() 同一份 en.json），查不到就原文。中文介面表是空的，原樣輸出
  let LOCALE = window.__LOCALE || {};      // 英文介面：Swift 在頁面開始前放好（ChatPane 的 WKUserScript）；之後 wb.setLocale 也會再給一次
  const L = (s, ...vals) => {
    const tagged = Array.isArray(s) && s.raw;
    const key = tagged ? s.join('%@') : s;
    const args = tagged ? vals : [];
    let out = (Object.prototype.hasOwnProperty.call(LOCALE, key) && LOCALE[key]) ? LOCALE[key] : key;     // 值是空字串＝還沒翻，顯示中文原文
    if (LOCALE.__pseudo) out = '⟪' + key + '⟫';     // 測試用（--lang pseudo）：標出哪些字有包 L()
    args.forEach((a, i) => { out = out.split('%' + (i + 1) + '$@').join(String(a)); });
    let n = 0;
    return out.replace(/%@/g, () => (n < args.length ? String(args[n++]) : '%@'));
  };

  let followGuard = 0;
  function post(msg) {
    try { window.webkit.messageHandlers.wb.postMessage(msg); }
    catch (_) { console.log('[wb→Swift]', JSON.stringify(msg)); }
  }

  // ───────────────────────── 狀態 ─────────────────────────
  const S = {
    cwd: null,
    home: null,
    busy: false,
    busySince: 0,
    agent: 'Claude',      // 這個聊天室實際在跑的模型（init 事件決定）：權限卡、選擇題上的名字
    following: true,
    jumping: false,
    magnet: false,        // 卡扣：送出訊息（或 Claude 開始做時本來就在底）就扣上，一直貼底；只有使用者自己往上捲（滾輪、觸控、按鍵、按著滑鼠拖）才放開
    pointerDown: false,
    userScrollAt: 0,      // 使用者最近一次滾輪／觸控／捲動按鍵的時間   // 滑鼠按著（拖捲軸、選字往上拉）：這時捲動位置往上才算使用者捲的
    lastScrollTop: 0,
    tools: new Map(),     // tool_use_id → ToolCard
    perms: new Map(),     // request_id → PermCard / AskCard
    animating: new Set(), // 正在打字的 TextBlock
    interrupted: false,
    ctxMain: null,
    bulk: false,          // wb.history 整批載入中
    batch: 0,             // wb.historyAppend 的批次編號
    deferred: new Set(),  // 使用者正在看、現在收會讓畫面被拉動的組：等捲走或回到底部再收
  };

  // DOM 骨架（index.html 與 test.html 共用；這裡自己建，HTML 只要放 script 就好）
  let root, log, queueBox, typing, jumpBtn, lightbox;
  const queued = new Map();   // uuid → 排隊中的使用者泡泡（Claude 還沒讀進去）
  const unconfirmed = new Map();   // 一輪結束時先移進對話、但 Claude 還沒回送讀進的（下一輪結束或回送才算確定）
  function buildSkeleton() {
    root = document.getElementById('wb-root') || document.body.appendChild(el('div'));
    root.id = 'wb-root';
    root.innerHTML = '';
    log = root.appendChild(el('main', 'log'));
    log.setAttribute('aria-live', 'polite');
    typing = root.appendChild(el('div', 'typing'));
    typing.hidden = true;
    typing.innerHTML = `<span class="typing-dots"><i></i><i></i><i></i></span><span class="typing-t">${L('Claude 正在處理')}</span><span class="typing-s"></span>`;
    queueBox = root.appendChild(el('div', 'queue-box'));   // 排隊中的訊息放在「正在處理」下面
    jumpBtn = document.body.appendChild(el('button', 'jump', L('↓ 最新')));
    jumpBtn.type = 'button';
    jumpBtn.hidden = true;
    jumpBtn.addEventListener('click', jumpToBottom);
    lightbox = document.body.appendChild(el('div', 'lightbox'));
    lightbox.hidden = true;
    lightbox.addEventListener('click', () => { lightbox.hidden = true; lightbox.innerHTML = ''; });
    S.ctxMain = new Ctx(log, true);
  }

  // ───────────────────────── 捲動：跟到底／使用者往上捲就停 ─────────────────────────
  const sc = () => document.scrollingElement || document.documentElement;
  const userScrolled = () => Date.now() - S.userScrollAt < 400;
  const distFromBottom = () => { const s = sc(); return s.scrollHeight - s.scrollTop - s.clientHeight; };
  function stick() {
    if (!S.following || S.jumping || userScrolled()) return;   // 使用者剛往上捲：先別拉回去，等捲動事件決定
    const s = sc();
    const target = s.scrollHeight - s.clientHeight;
    if (Math.abs(s.scrollTop - target) > 1) s.scrollTop = target;
    S.lastScrollTop = s.scrollTop;
  }
  // 捲到頂端附近：跟 App 要更早的訊息（一次一批，等它回來才要下一批）
  addEventListener('scroll', () => {
    if (!S.hasOlder || S.loadingOlder) return;
    if (sc().scrollTop < 800) {
      S.loadingOlder = true;
      const n = log.querySelector('.notice.more-top');
      if (n) n.textContent = L('載入更早的訊息…');
      post({ type: 'loadOlder' });
    }
  }, { passive: true });
  // 查「沒貼底」用：跟到底被關掉、或該貼底卻沒貼到時記一筆（App 寫進 drop.log，前面標「捲動」）
  function scrollLog(why) {
    try { post({ type: 'scrollLog', text: `${why} 離底=${Math.round(distFromBottom())} busy=${!!S.busy} jumping=${!!S.jumping}` }); } catch (_) {}
  }
  // 使用者自己往上捲：放開卡扣
  function release(why) {
    if (S.magnet) scrollLog('放開卡扣：' + why);
    S.magnet = false;
  }
  // 滾輪／觸控／按鍵往上：捲動事件不一定馬上來（也可能在剛好在底時被擋掉），過一下直接看離底多遠
  function userUp(why) {
    S.userScrollAt = Date.now();
    release(why);
    unfollow(why);
    clearTimeout(userUp.t);
    userUp.t = setTimeout(() => { if (S.following && distFromBottom() > 6) unfollow(why + '（事後確認）'); }, 120);
  }
  function unfollow(why) {
    if (distFromBottom() < 4) return;
    if (S.following) scrollLog('不跟了：' + (why || '使用者往上'));
    S.following = false;
    S.jumping = false;
    updateJump();
  }
  function jumpToBottom() {
    S.following = true;
    S.jumping = true;
    const s = sc();
    window.scrollTo({ top: s.scrollHeight, behavior: 'smooth' });
    clearTimeout(jumpToBottom.t);
    jumpToBottom.t = setTimeout(() => { S.jumping = false; stick(); updateJump(); }, 700);
    updateJump();
  }
  function updateJump() {
    const show = !S.following && distFromBottom() > 120;
    if (show) {
      const waiting = [...S.perms.values()].some((p) => p.pending);
      jumpBtn.textContent = waiting ? L('↓ 等你回應') : L('↓ 最新');
      jumpBtn.classList.toggle('attn', waiting);
    }
    if (jumpBtn.hidden === show) jumpBtn.hidden = !show;
  }
  function flushDeferred() {
    flushDeferred.q = false;
    for (const g of [...S.deferred]) g.refresh();
  }
  function initScroll() {
    window.addEventListener('wheel', (e) => { if (e.deltaY < 0) userUp('滾輪往上 ' + Math.round(e.deltaY)); }, { passive: true });
    window.addEventListener('touchmove', () => userUp('觸控'), { passive: true });
    window.addEventListener('mousedown', () => { S.pointerDown = true; }, { passive: true, capture: true });
    window.addEventListener('mouseup', () => { S.pointerDown = false; }, { passive: true, capture: true });
    window.addEventListener('mousemove', (e) => { if (!e.buttons) S.pointerDown = false; }, { passive: true });   // 在視窗外放開的
    window.addEventListener('keydown', (e) => {
      // ⌘ ↑／⌘ ↓：跳到對話最上面／最下面（焦點在對話區時；輸入框裡的由 App 處理）
      if (e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
        const t = e.target;
        if (!(t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName)))) { e.preventDefault(); wb.scrollEdge(e.key === 'ArrowUp'); return; }
      }
      if (['PageUp', 'ArrowUp', 'Home'].includes(e.key) || (e.key === ' ' && e.shiftKey)) userUp('按鍵 ' + e.key);
    });
    window.addEventListener('scroll', () => {
      const st = sc().scrollTop;
      const d = distFromBottom();
      if (d < 6) { S.following = true; S.jumping = false; }
      // 捲動位置往上：只有滑鼠按著（拖捲軸）才算使用者捲的。
      // 沒按滑鼠時位置自己往上跑，是內容先縮一下、瀏覽器把位置夾上去（之後又長回來），不是使用者，照樣貼底
      else if (st < S.lastScrollTop - 2 && !S.jumping && (S.pointerDown || userScrolled())) {
        release(S.pointerDown ? '拖捲軸' : '往上捲');
        if (S.following) scrollLog(`不跟了：${S.pointerDown ? '拖捲軸' : '往上捲'} ${Math.round(S.lastScrollTop)}→${Math.round(st)}`);
        S.following = false;
      }
      else if (S.following && !S.jumping && d > 2 && !userScrolled()) { stick(); return; }   // 不是使用者捲的：馬上貼回去
      S.lastScrollTop = st;
      updateJump();
      if (S.deferred.size && !flushDeferred.q) { flushDeferred.q = true; raf(flushDeferred); }
    }, { passive: true });
    // 網頁裡有沒有正在打字的欄位：App 靠這個決定按 / 要不要跳回輸入框
    const editable = (t) => t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));
    document.addEventListener('focusin', (e) => post({ type: 'editing', on: !!editable(e.target) }));
    document.addEventListener('focusout', () => post({ type: 'editing', on: false }));
    const ro = new ResizeObserver(() => { stick(); updateJump(); });
    ro.observe(log);
    ro.observe(typing);
    ro.observe(queueBox);
    window.addEventListener('resize', () => stick());
  }

  // ───────────────────────── 路徑顯示 ─────────────────────────
  function shortPath(p) {
    if (!p) return '';
    p = String(p);
    if (S.cwd && (p === S.cwd || p.startsWith(S.cwd + '/'))) return p.slice(S.cwd.length + 1) || '.';
    const m = p.match(/^\/Users\/[^/]+/);
    if (m) return '~' + p.slice(m[0].length);
    return p;
  }
  function absPath(p) {
    p = String(p).replace(/^file:\/\//, '');
    try { p = decodeURI(p); } catch (_) {}
    p = p.replace(/:\d+(?::\d+)?$/, '');
    if (p.startsWith('~/') && S.home) return S.home + p.slice(1);
    if (p.startsWith('/') || p.startsWith('~')) return p;
    if (S.cwd) return S.cwd + '/' + p.replace(/^\.\//, '');
    return p;
  }
  function pathEl(p, cls) {
    const a = el('span', 'path' + (cls ? ' ' + cls : ''), shortPath(p));
    a.dataset.path = p;
    a.title = p;
    return a;
  }
  // 完整路徑（/…、~/…）：沒有空格直接可點；有空格的（`~/My Files/a.md`）要問 Swift 存在才算
  const looksAbsPath = (t) => /^(~\/|\/)[^`'"<>\n]*[^\s`'"<>.,:;)]$/.test(t) && t.length > 2 && !/^\/\//.test(t);
  // 相對路徑或只有檔名（可以是中文）：一律問 Swift 在工作目錄找不找得到，找不到不做成連結
  const looksRelPath = (t) => !!S.cwd && /^(\.\/)?[\p{L}\p{N}_.\-@\[\]]+(\/[\p{L}\p{N}_.\-@\[\] ]+)*\.[A-Za-z0-9]{1,8}(:\d+(:\d+)?|#L\d+(-L?\d+)?)?$/u.test(t)
    && !/^\d+(\.\d+)+$/.test(t);
  // 直接可點的：沒有空格、至少兩層（/loop 這種斜線指令只有一層，要問 Swift）
  const looksLikePath = (t) => looksAbsPath(t) && !/\s/.test(t) && (t.startsWith('~/') || /^\/[^/]+\//.test(t));

  // 一般文字裡沒包反引號的完整路徑：~/… 或常見的根目錄開頭；遇到空白、引號、全形標點就停
  // 路徑可能緊接中文（「~/Desktop/a.pdf也能點」），斷在哪由 Swift 找「最長的存在前綴」決定
  const BARE_PATH = /(?<![\w/.~])(?:~\/|\/(?:Users|Volumes|Applications|Library|System|private|tmp|opt|usr|var|etc)\/)[^\s`'"<>，。、；：！？（）「」『』【】《》…]+/gu;

  // 問 Swift「這些路徑在不在」：同一段文字重畫（串流中會一直重畫）時用快取，不重問
  // 找不到的只記 5 秒：Claude 常先說「我建了 foo.md」才真的寫檔，之後重畫要再問一次
  const pathCache = new Map();   // key → { hit: 找到的那段文字（'' ＝找不到）, at }
  const pathWait = new Map();    // key → [拿到結果後要做的事]
  let pathBatch = null;
  function askPath(key, item, apply) {
    const c = pathCache.get(key);
    if (c && (c.hit || Date.now() - c.at < 5000)) { apply(c.hit); return; }
    const w = pathWait.get(key);
    if (w) { w.push(apply); return; }
    pathWait.set(key, [apply]);
    if (!pathBatch) { pathBatch = []; queueMicrotask(() => { const b = pathBatch; pathBatch = null; post({ type: 'pathCheck', items: b }); }); }
    pathBatch.push({ key, ...item });
  }
  /// Swift 查完：[{key, hit}]，hit 是存在的那段文字（找不到為 null）
  function pathsChecked(list) {
    for (const r of list || []) {
      const hit = r.hit || '';
      pathCache.set(r.key, { hit, at: Date.now() });
      const w = pathWait.get(r.key) || [];
      pathWait.delete(r.key);
      for (const f of w) f(hit);
    }
  }
  function markCodePath(c, t) { c.classList.add('path'); c.dataset.path = t; }
  // 候選路徑先包成一般文字樣子的 span，Swift 回覆後換成「可點的那段＋剩下的字」
  function linkBareText(tn) {
    const s = tn.nodeValue;
    const m = [...s.matchAll(BARE_PATH)];
    if (!m.length) return;
    const frag = document.createDocumentFragment();
    let at = 0;
    for (const x of m) {
      frag.append(s.slice(at, x.index));
      const cand = x[0], span = el('span', 'path-wait', cand);
      frag.append(span);
      at = x.index + cand.length;
      askPath('p:' + cand, { path: cand, prefix: true }, (hit) => {
        if (!hit || !cand.startsWith(hit)) { span.replaceWith(cand); return; }
        const a = el('span', 'path md-path', hit);
        a.dataset.path = hit;
        a.title = absPath(hit);
        span.replaceWith(a, cand.slice(hit.length));
      });
    }
    frag.append(s.slice(at));
    tn.replaceWith(frag);
  }

  /// Markdown 圖片網址 → 本機路徑（file:// 解開成路徑；不是本機的回 null）
  function localImgPath(href) {
    if (/^file:/i.test(href)) { try { return decodeURIComponent(new URL(href).pathname); } catch (_) { return null; } }
    if (href.startsWith('/') && !href.startsWith('//')) { try { return decodeURI(href); } catch (_) { return href; } }
    if (href.startsWith('~/')) { try { return decodeURI(href); } catch (_) { return href; } }
    return null;
  }
  /// 每一段分開做百分比編碼（中文、空格、#、? 都不會弄壞網址）；~ 開頭留給 App 換成家目錄
  const localImgURL = (p) => 'codenv-img://local/' + p.replace(/^\/+/, '').split('/').map(encodeURIComponent).join('/');
  // 本機圖片載不到（不存在、不是圖片）：換成「🖼 說明 + 路徑」，不要出現破圖問號
  document.addEventListener('error', (e) => {
    const img = e.target;
    if (!(img instanceof HTMLImageElement) || !img.classList.contains('md-img') || !img.dataset.path) return;
    const span = el('span', 'md-img-missing');
    span.append('🖼 ' + (img.alt || L('圖片')) + L('（載不到：'));
    span.appendChild(pathEl(img.dataset.path));
    span.append('）');
    img.replaceWith(span);
  }, true);

  // ───────────────────────── Markdown ─────────────────────────
  const INLINE_TAG_OK = /^<\/?(br|kbd|sub|sup|b|i|em|strong|u|s|del|ins|mark|small)\s*\/?>$/i;
  const safeHref = (h) => /^(https?:|mailto:|file:|\/|~\/|\.{0,2}\/|#)/i.test(h) || /^[\w.\-]+(\/[\w.\-]+)*$/.test(h);
  const md = new marked.Marked({ gfm: true, breaks: true }); // 單一換行就換行（中文詩、條列常這樣寫）
  md.use({
    // 單一個 ~ 不當刪除線（GFM 預設會），不然沒包反引號的 ~/路徑 兩個之間的字全被劃掉；~~ 照舊
    tokenizer: {
      del(src) { return /^~(?!~)/.test(src) ? { type: 'text', raw: '~', text: '~' } : false; },
    },
    renderer: {
      html({ text }) { return INLINE_TAG_OK.test(text.trim()) ? text.trim() : esc(text); },
      code({ text, lang }) { return codeBlockHtml(text, (lang || '').trim().split(/\s+/)[0], md._hl); },
      link({ href, title, tokens }) {
        const inner = this.parser.parseInline(tokens);
        if (!href || !safeHref(href)) return inner;
        return `<a href="${esc(href)}"${title ? ` title="${esc(title)}"` : ''}>${inner}</a>`;
      },
      image({ href, text }) {
        if (!href || !/^(https?:|file:|data:image\/|\/|~\/)/i.test(href)) return esc(text || '');
        // 網路上的圖不自動載入：被網頁誘導的 Claude 可以把資料藏在圖片網址裡送出去。改成連結，點了才用瀏覽器開
        if (/^https?:/i.test(href)) {
          let host = ''; try { host = new URL(href).host; } catch (_) {}
          return `<a href="${esc(href)}" class="md-img-remote" title="${esc(href)}">🖼 ${esc(text || L('網路圖片'))}${L('（')}${esc(host)}${L('，點了才開）')}</a>`;
        }
        if (/^data:/i.test(href)) return `<img class="md-img" src="${esc(href)}" alt="${esc(text || '')}" loading="lazy">`;
        // 本機路徑（/…、~/…、file://…）：網頁只能讀 chat 資料夾，改走 codenv-img://（LocalImages.swift 讀檔，只回圖片）
        const p = localImgPath(href);
        if (!p) return esc(text || '');
        return `<img class="md-img" src="${esc(localImgURL(p))}" alt="${esc(text || '')}" data-path="${esc(p)}" loading="lazy">`;
      },
      table(token) {
        // 外面包一層可以左右捲的框
        let h = '<div class="tbl"><table><thead><tr>';
        for (const c of token.header) h += this.tablecell(c);
        h += '</tr></thead><tbody>';
        for (const row of token.rows) { h += '<tr>'; for (const c of row) h += this.tablecell(c); h += '</tr>'; }
        return h + '</tbody></table></div>';
      },
    },
  });
  md._hl = 'sync';

  const LANG_ALIAS = { sh: 'bash', zsh: 'bash', shell: 'bash', console: 'bash', js: 'javascript', jsx: 'javascript', ts: 'typescript', tsx: 'typescript', py: 'python', rb: 'ruby', yml: 'yaml', md: 'markdown', objc: 'objectivec', 'objective-c': 'objectivec', html: 'xml', plist: 'xml', svg: 'xml', kt: 'kotlin', rs: 'rust', 'c++': 'cpp', h: 'c', hpp: 'cpp', m: 'objectivec', cs: 'csharp', jsonc: 'json', diff: 'diff', patch: 'diff', toml: 'ini', conf: 'ini', text: 'plaintext', txt: 'plaintext' };
  function hlLang(lang) {
    if (!lang || !window.hljs) return null;
    lang = lang.toLowerCase();
    lang = LANG_ALIAS[lang] || lang;
    return hljs.getLanguage(lang) ? lang : null;
  }
  const EXT_LANG = { swift: 'swift', py: 'python', js: 'javascript', mjs: 'javascript', cjs: 'javascript', ts: 'typescript', tsx: 'typescript', jsx: 'javascript', json: 'json', md: 'markdown', sh: 'bash', zsh: 'bash', bash: 'bash', rb: 'ruby', go: 'go', rs: 'rust', c: 'c', h: 'c', m: 'objectivec', mm: 'objectivec', cpp: 'cpp', cc: 'cpp', hpp: 'cpp', java: 'java', kt: 'kotlin', css: 'css', scss: 'scss', less: 'less', html: 'xml', xml: 'xml', plist: 'xml', svg: 'xml', yml: 'yaml', yaml: 'yaml', toml: 'ini', ini: 'ini', sql: 'sql', lua: 'lua', php: 'php', pl: 'perl', r: 'r', cs: 'csharp', diff: 'diff', mk: 'makefile', makefile: 'makefile' };
  const langFromPath = (p) => { const m = String(p || '').toLowerCase().match(/(?:\.([a-z0-9]+)|\/(makefile))$/); return m ? EXT_LANG[m[1] || m[2]] || null : null; };

  function highlightTo(code, text, lang) {
    const l = hlLang(lang);
    if (l && text.length < 200000) {
      try { code.innerHTML = hljs.highlight(text, { language: l, ignoreIllegals: true }).value; code.classList.add('hljs'); return; } catch (_) {}
    }
    code.textContent = text;
  }
  // 'sync'：馬上上色；'lazy'：捲到看得到才上色（接回舊對話時用）；'none'：不上色（串流中的大段程式碼）
  // 複製鈕的圖示（兩張卡；按了換成打勾一下）：程式碼區右上角、每輪回覆最下面共用
  const COPY_ICON = '<svg class="ic-copy" viewBox="0 0 16 16" aria-hidden="true"><rect x="5.5" y="5.5" width="8.5" height="8.5" rx="1.6"/><path d="M10.5 3.2V3A1.5 1.5 0 0 0 9 1.5H3A1.5 1.5 0 0 0 1.5 3v6A1.5 1.5 0 0 0 3 10.5h.2"/></svg><svg class="ic-done" viewBox="0 0 16 16" aria-hidden="true"><path d="M3 8.5l3.2 3.2L13 4.8"/></svg>';
  function codeBlockHtml(text, lang, mode) {
    const l = hlLang(lang);
    const label = lang ? esc(lang) : '';
    let body;
    if (l && mode === 'sync' && text.length < 60000) {
      try { body = hljs.highlight(text, { language: l, ignoreIllegals: true }).value; } catch (_) { body = esc(text); }
      return `<div class="code"><div class="code-h"><span class="code-l">${label}</span><button class="copy icon-btn" type="button" title="${L('複製')}" aria-label="${L('複製')}">${COPY_ICON}</button></div><pre><code class="hljs">${body}</code></pre></div>`;
    }
    const lazy = l && mode === 'lazy' ? ` data-hl="${l}"` : '';
    return `<div class="code"><div class="code-h"><span class="code-l">${label}</span><button class="copy icon-btn" type="button" title="${L('複製')}" aria-label="${L('複製')}">${COPY_ICON}</button></div><pre><code${lazy}>${esc(text)}</code></pre></div>`;
  }
  const lazyHl = new IntersectionObserver((entries) => {
    for (const en of entries) {
      if (!en.isIntersecting) continue;
      const c = en.target;
      lazyHl.unobserve(c);
      const lang = c.dataset.hl;
      delete c.dataset.hl;
      highlightTo(c, c.textContent, lang);
    }
  }, { rootMargin: '600px 0px' });

  // 插入 DOM 後的小處理：路徑可點、延後上色
  function decorate(node) {
    if (node.nodeType !== 1) return;
    for (const c of node.querySelectorAll('code[data-hl]')) lazyHl.observe(c);
    for (const c of node.querySelectorAll('code')) {
      if (c.parentElement.tagName === 'PRE' || c.closest('a')) continue;
      const t = c.textContent.trim();
      if (looksLikePath(t)) markCodePath(c, t);
      else if (looksAbsPath(t) || looksRelPath(t)) askPath('e:' + (looksAbsPath(t) ? '' : S.cwd) + '|' + t, { path: t }, (hit) => { if (hit) markCodePath(c, t); });
    }
    // 沒包反引號的完整路徑（不碰程式碼、連結、已經是路徑的地方）
    const tw = document.createTreeWalker(node, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => !/[~/]/.test(n.nodeValue) || n.parentElement.closest('code, pre, a, .path, .path-wait, kbd')
        ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
    });
    const texts = [];
    while (tw.nextNode()) texts.push(tw.currentNode);
    texts.forEach(linkBareText);
  }

  function renderMarkdownHtml(src, hlMode) {
    md._hl = hlMode;
    try { return md.parse(src); } catch (e) { return `<p>${esc(src)}</p>`; } finally { md._hl = 'sync'; }
  }
  function setMarkdown(container, src, hlMode = 'sync') {
    container.innerHTML = renderMarkdownHtml(src, hlMode);
    decorate(container);
  }

  // ───────────────────────── 對話脈絡（主對話／子代理） ─────────────────────────
  class Ctx {
    constructor(container, main) {
      this.container = container;
      this.main = main;
      this.turn = null;
      this.msgs = new Map();   // message.id → {blocks:[], byIndex: Map}
      this.curMsg = null;
      this.onStep = null;      // 子代理：有新工具時通知 Task 卡片
    }
    getTurn() {
      if (!this.main) return this.container;
      if (!this.turn || !this.turn.isConnected) {
        this.turn = el('section', 'turn assistant');
        this.container.appendChild(this.turn);
      }
      return this.turn;
    }
    // 工具卡片、思考列放進「步驟組」；子代理裡不分組
    stepParent() {
      if (!this.main) return this.container;
      const turn = this.getTurn();
      if (!this.group || this.group.ended || this.group.el.parentElement !== turn) this.group = new StepGroup(turn);
      return this.group.list;
    }
    addStep(item) { if (this.main && this.group) { item.group = this.group; this.group.add(item); } }
    // 文字段落、選擇題、提示：把目前的步驟組切斷（結束的組會自動收起）
    breakParent() { this.closeGroup(false); return this.getTurn(); }
    closeGroup(forced) {
      const g = this.group;
      if (!g) return;
      this.group = null;
      g.end(forced);
    }
    endTurn() { this.closeGroup(false); if (this.main && this.turn) addTurnCopy(this.turn); this.turn = null; }
    msg(id) {
      id = id || this.curMsg || '_';
      let m = this.msgs.get(id);
      if (!m) { m = { blocks: [], byIndex: new Map() }; this.msgs.set(id, m); }
      return m;
    }
  }
  function ctxFor(o) {
    const pid = o && o.parent_tool_use_id;
    if (!pid) return S.ctxMain;
    const card = S.tools.get(pid);
    if (card && card.sub) return card.sub;
    return S.ctxMain;
  }

  // ───────────────────────── 步驟組：連續的工具卡片＋思考列，結束後收成一行 ─────────────────────────
  const reducedMotion = () => { try { return window.matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (_) { return false; } };
  // 改變某個元素的高度時，別讓使用者正在看的位置跑掉：
  // 跟到底 → 改完再貼底；元素頂端在畫面上方（使用者在看它下面的東西）→ 補回高度差
  function keepAnchor(node, change) {
    if (S.bulk) { change(); return; }
    if (S.following && !S.jumping) { change(); stick(); return; }
    const r0 = node.getBoundingClientRect();
    if (r0.top >= 0) { change(); return; }
    change();
    const d = node.getBoundingClientRect().bottom - r0.bottom;
    if (Math.abs(d) > 0.5) { const s = sc(); s.scrollTop += d; S.lastScrollTop = s.scrollTop; }
  }
  const STEP_KIND = { Bash: 'bash', Read: 'read', Write: 'write', Edit: 'edit', MultiEdit: 'edit', NotebookEdit: 'edit', Grep: 'search', Glob: 'search', WebFetch: 'web', WebSearch: 'web', Task: 'agent', Agent: 'agent', TodoWrite: 'todo' };
  class StepGroup {
    constructor(turn) {
      this.tools = [];
      this.ended = false;
      this.forced = false;
      this.manual = null;     // 使用者點過：true＝展開、false＝收起
      this.collapsed = false;
      this.mode = '';
      this.born = S.historyMode ? S.batch : -1;
      this.el = turn.appendChild(el('div', 'grp'));
      this.head = null;       // 摘要列：有兩步以上、要收起時才建
      this.list = this.el.appendChild(el('div', 'grp-list'));
    }
    buildHead() {
      this.head = this.el.insertBefore(el('div', 'grp-h'), this.list);
      this.head.tabIndex = 0;
      this.head.setAttribute('role', 'button');
      this.head.appendChild(el('span', 'ti'));
      this.sum = this.head.appendChild(el('span', 'grp-sum'));
      this.meta = this.head.appendChild(el('span', 'grp-meta'));
      this.head.appendChild(el('span', 'chev'));
      this.head.addEventListener('click', () => this.toggle());
      this.head.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); this.toggle(); } });
    }
    add(item) { if (item instanceof ToolCard) this.tools.push(item); if (this.ended) this.refresh(); }
    end(forced) {
      if (forced) this.forced = true;
      this.ended = true;
      this.refresh();
    }
    changed() { if (this.ended) this.refresh(); }   // 組裡的工具狀態變了
    refresh() {
      const n = this.tools.length;
      const mode = n >= 2 ? 'multi' : n === 1 ? 'single' : 'none';
      if (mode !== this.mode) {
        if (this.mode) this.el.classList.remove(this.mode);
        this.el.classList.add(mode);
        this.mode = mode;
      }
      if (!this.ended || mode === 'none') return;
      // 有工具在等允許就一定展開；一輪還沒結束時，還在跑的工具也讓它展開
      const active = this.tools.some((t) => t.state === 'waiting' || (!this.forced && t.state === 'running'));
      const want = active ? false : this.manual != null ? !this.manual : true;
      // 會改變高度的 class 都放進 pre，讓 keepAnchor 先量到改變前的位置
      const pre = () => {
        this.el.classList.add('ended');
        this.el.classList.toggle('active', active);   // 還在跑：照進行中的樣子逐條顯示，不出摘要列
        if (mode === 'multi') this.renderHead();
      };
      const fresh = S.historyMode && this.born === S.batch;   // 同一批裡才長出來的：還沒畫到畫面上
      S.deferred.delete(this);
      if (want && !this.collapsed && this.manual == null && mode === 'multi' && !fresh && !S.bulk && !(S.following && !S.jumping)) {
        // 使用者往上捲、這組就在眼前，而且收起後頁面會短到捲動位置被往下拉 → 先別收
        const r = this.el.getBoundingClientRect();
        const pull = Math.min(sc().scrollTop, this.list.offsetHeight - 32 - distFromBottom());   // 收起後會被往下拉多少
        if (r.top >= 0 && r.top < window.innerHeight && pull > 2) {
          keepAnchor(this.el, pre);
          S.deferred.add(this);
          return;
        }
      }
      const b = S.bulk;
      if (fresh) S.bulk = true;
      if (want !== this.collapsed) this.setCollapsed(want, !S.bulk, pre);
      else keepAnchor(this.el, pre);
      S.bulk = b;
    }
    renderHead() {
      if (!this.head) this.buildHead();
      const c = { bash: 0, read: new Set(), write: new Set(), edit: new Set(), search: 0, web: 0, agent: 0, todo: 0, other: 0 };
      let fail = 0, denied = 0, stopped = 0, running = 0;
      for (const t of this.tools) {
        const k = STEP_KIND[t.name] || 'other';
        const key = t.input.file_path || t.input.notebook_path || t.id;
        if (c[k] instanceof Set) c[k].add(key); else c[k]++;
        if (t.state === 'error') fail++;
        else if (t.state === 'denied') denied++;
        else if (t.state === 'stopped') stopped++;
        else if (t.state === 'running' || t.state === 'waiting') running++;
      }
      const sz = (v) => (v instanceof Set ? v.size : v);
      // 跟 Claude Code 一樣用英文：Ran 1 shell command, read 2 files
      const parts = [];
      const n = (k, one, many) => `${k} ${k === 1 ? one : many}`;
      if (c.bash) parts.push(`Ran ${n(c.bash, 'shell command', 'shell commands')}`);
      if (sz(c.read)) parts.push(`Read ${n(sz(c.read), 'file', 'files')}`);
      if (sz(c.edit)) parts.push(`Edited ${n(sz(c.edit), 'file', 'files')}`);
      if (sz(c.write)) parts.push(`Wrote ${n(sz(c.write), 'file', 'files')}`);
      if (c.search) parts.push(`Searched for ${n(c.search, 'pattern', 'patterns')}`);
      if (c.web) parts.push(`Fetched ${n(c.web, 'web page', 'web pages')}`);
      if (c.agent) parts.push(`Ran ${n(c.agent, 'agent', 'agents')}`);
      if (c.todo) parts.push('Updated todos');
      if (c.other) parts.push(`Used ${n(c.other, 'tool', 'tools')}`);
      this.sum.textContent = parts.map((p, i) => (i ? p[0].toLowerCase() + p.slice(1) : p)).join(', ');
      const bad = [];
      if (fail) bad.push(`${fail} failed`);
      if (denied) bad.push(`${denied} denied`);
      let meta = bad.join(', ');
      if (!meta && stopped) meta = 'stopped';
      if (!meta && running) meta = `${running} running`;
      this.meta.textContent = meta;
      const st = bad.length ? 'bad' : stopped ? 'stop' : running ? 'run' : 'ok';
      if (st !== this.st) { if (this.st) this.el.classList.remove(this.st); this.el.classList.add(st); this.st = st; }
    }
    toggle() {
      if (this.mode !== 'multi' || !this.ended || this.el.classList.contains('active')) return;
      const expanding = this.collapsed;
      this.manual = expanding;   // 收著就展開，反之亦然
      // 使用者自己點開：摘要列留在原地，不要被「跟到底」帶走
      if (expanding && S.following && !S.magnet) { S.following = false; S.jumping = false; }
      this.setCollapsed(!this.collapsed, true);
      updateJump();
    }
    setCollapsed(c, anim, pre) {
      this.collapsed = c;
      const L = this.list;
      clearTimeout(this._animT);
      if (this._animEnd) this._animEnd();
      const apply = () => {
        if (pre) pre();
        this.el.classList.toggle('collapsed', c);
        if (this.head) this.head.setAttribute('aria-expanded', String(!c));
      };
      // 只在看得到的地方、而且是整組收合時才做動畫；畫面外的直接切換（並補回捲動位置）
      let doAnim = anim && this.mode === 'multi' && !reducedMotion();
      if (doAnim && !(S.following && !S.jumping)) {
        const r = this.el.getBoundingClientRect();
        doAnim = r.top >= 0 && r.top < window.innerHeight;
      }
      if (!doAnim) { keepAnchor(this.el, apply); return; }
      this.el.classList.add('anim');      // 動畫期間清單保持顯示
      const from = c ? L.offsetHeight : 0;
      apply();
      L.style.height = '';
      const to = c ? 0 : L.offsetHeight;
      L.style.overflow = 'hidden';
      L.style.height = from + 'px';
      L.style.opacity = c ? '1' : '0';
      void L.offsetHeight;
      L.style.transition = 'height .2s ease, opacity .16s ease';
      L.style.height = to + 'px';
      L.style.opacity = c ? '0' : '1';
      const done = () => {
        this._animEnd = null;
        clearTimeout(this._animT);
        L.removeEventListener('transitionend', onEnd);
        L.style.transition = L.style.height = L.style.opacity = L.style.overflow = '';
        this.el.classList.remove('anim');
        stick();
      };
      const onEnd = (e) => { if (e.target === L && e.propertyName === 'height') done(); };
      L.addEventListener('transitionend', onEnd);
      this._animEnd = done;
      this._animT = setTimeout(done, 320);
    }
  }

  // ───────────────────────── 文字區塊（逐字出現、只重畫最後一段） ─────────────────────────
  class TextBlock {
    constructor(parent, animate) {
      this.type = 'text';
      this.el = parent.appendChild(el('div', 'md'));
      this.el._tb = this;    // 「複製」整段回覆時拿原文（Markdown）
      this.raw = '';
      this.shown = 0;
      this.final = false;
      this.done = false;
      this.animate = animate;
      this.parts = [];       // [{key, nodes}]
    }
    append(t) { this.raw += t; this.kick(); }
    setFull(t, isFinal) {
      if (typeof t === 'string' && t.length >= this.raw.length) this.raw = t;
      else if (typeof t === 'string' && !t.startsWith(this.raw)) this.raw = t;
      if (isFinal) this.final = true;
      if (!this.animate) { this.shown = this.raw.length; this.renderNow(); return; }
      this.kick();
    }
    finish() { this.final = true; if (!this.animate) this.renderNow(); else this.kick(); }
    kick() { if (!this.done) { S.animating.add(this); scheduleTick(); } }
    renderNow() {
      // 一次畫完（歷史記錄、或打字追上之後）
      this.parts = [];
      setMarkdown(this.el, this.raw, this.lazy ? 'lazy' : 'sync');
      this.el.classList.remove('streaming');
      if (this.final) { this.done = true; S.animating.delete(this); }
    }
    tick() {
      const backlog = this.raw.length - this.shown;
      if (backlog > 0) {
        // 很長的回覆：每畫一次都要整段重新解析，一秒畫 8 次就好，不然越後面越卡
        const now = performance.now();
        if (this.shown > 8000 && now - (this._lastR || 0) < 120) return true;
        this._lastR = now;
        let step = Math.max(1, Math.ceil(backlog * 0.14));
        if (backlog > 4000) step = backlog; // 太落後就直接追上
        let n = this.shown + step;
        const c = this.raw.charCodeAt(n - 1);
        if (c >= 0xd800 && c <= 0xdbff) n++;
        this.shown = Math.min(n, this.raw.length);
        this.renderPartial(this.raw.slice(0, this.shown), false);
      }
      if (this.shown >= this.raw.length && this.final) {
        this.renderPartial(this.raw, true);
        this.el.classList.remove('streaming');
        this.done = true;
        return false;
      }
      this.el.classList.add('streaming');
      return this.shown < this.raw.length; // 還有字要出
    }
    renderPartial(src, isFinal) {
      let tokens;
      try { tokens = md.lexer(src); } catch (_) { tokens = [{ type: 'paragraph', raw: src, text: src, tokens: [{ type: 'text', raw: src, text: src }] }]; }
      const links = tokens.links;
      const toks = tokens.filter((t) => t.type !== 'space' && t.type !== 'def');
      const keys = toks.map((t, i) => (i === toks.length - 1 && !isFinal ? '~' : '') + t.raw);
      let i = 0;
      while (i < this.parts.length && i < keys.length && this.parts[i].key === keys[i]) i++;
      // 移除變動的部分
      for (let j = this.parts.length - 1; j >= i; j--) for (const n of this.parts[j].nodes) n.remove();
      this.parts.length = i;
      const tpl = document.createElement('template');
      for (let j = i; j < toks.length; j++) {
        const t = toks[j];
        const isTail = keys[j].startsWith('~');
        const list = [t]; list.links = links;
        let mode = 'sync';
        if (isTail && t.type === 'code' && t.text.length > 6000) mode = 'none';
        md._hl = mode;
        let h;
        try { h = md.parser(list); } catch (_) { h = `<p>${esc(t.raw)}</p>`; }
        md._hl = 'sync';
        tpl.innerHTML = h;
        const nodes = [...tpl.content.childNodes].filter((n) => n.nodeType === 1 || n.textContent.trim());
        for (const n of nodes) { this.el.appendChild(n); decorate(n); }
        this.parts.push({ key: keys[j], nodes });
      }
      // 打字中的小圓點放在最後一段文字的尾巴
      const old = this.el.querySelector('.caret');
      if (old) old.classList.remove('caret');
      if (!isFinal) {
        let n = this.el.lastElementChild;
        while (n && n.lastElementChild && /^(OL|UL|LI|BLOCKQUOTE|P|H[1-6]|TABLE|TBODY|THEAD|TR|TD|TH|DIV)$/.test(n.lastElementChild.tagName) && !n.lastElementChild.classList.contains('code')) n = n.lastElementChild;
        if (n && !n.classList.contains('code') && !n.classList.contains('tbl')) n.classList.add('caret');
      }
    }
  }

  let tickScheduled = false;
  function scheduleTick() {
    if (tickScheduled) return;
    tickScheduled = true;
    raf(runTick);
  }
  function runTick() {
    tickScheduled = false;
    let more = false;
    for (const b of S.animating) {
      if (b.done || !b.el.isConnected) { S.animating.delete(b); continue; }
      const keep = b.tick();
      if (b.done) S.animating.delete(b);
      else if (keep) more = true;
    }
    if (more) scheduleTick();
    stick();
  }

  // ───────────────────────── 思考 ─────────────────────────
  class ThinkBlock {
    constructor(parent, live) {
      this.type = 'thinking';
      this.el = parent.appendChild(el('div', 'think' + (live ? ' live' : '')));
      this.head = this.el.appendChild(el('button', 'think-h'));
      this.head.type = 'button';
      this.label = this.head.appendChild(el('span', 'think-l', live ? 'Thinking…' : 'Thought'));
      this.extra = this.head.appendChild(el('span', 'think-x'));
      this.body = null;
      this.text = '';
      this.start = Date.now();
      this.final = false;
      this.head.addEventListener('click', () => { this.userToggled = true; this.toggle(); });
      // 還在想的時候展開（字邊來邊顯示），想完自動收起（使用者 10/23 要的）
      if (live) { this.autoOpened = true; this.body = this.el.appendChild(el('div', 'think-b')); this.el.classList.add('open'); }
      this.refresh();
    }
    // 一個字一個字來的時候不要每次都整段重畫：合併到下一個畫面更新
    append(t) {
      this.text += t;
      if (!this._raf) this._raf = requestAnimationFrame(() => { this._raf = 0; this.refresh(); });
    }
    tokens() {}   // 思考中不顯示進度，想完才顯示花了多久
    setFull(t, durMs, stopped) {
      if (typeof t === 'string' && t.length >= this.text.length) this.text = t;
      this.finish(durMs, stopped);
    }
    finish(durMs, stopped) {
      if (this.final) return;
      this.final = true;
      this.el.classList.remove('live');
      const ms = durMs != null ? durMs : Date.now() - this.start;
      const sec = Math.max(1, Math.round(ms / 1000));
      this.label.textContent = stopped ? `Thought for ${sec}s (interrupted)` : `Thought for ${sec}s`;
      this.extra.textContent = '';
      if (this.autoOpened && !this.userToggled && this.body) { this.body.hidden = true; this.el.classList.remove('open'); }
      this.refresh();
    }
    refresh() {
      if (!this._has) this._has = /\S/.test(this.text);
      const has = this._has;
      this.el.classList.toggle('has', has);
      this.head.disabled = !has;
      if (this.body) this.body.textContent = this.text;
      if (this.autoOpened && !this.final && S.following) stick();   // 思考一邊長、畫面一邊往上（使用者沒往上捲時）
    }
    toggle() {
      if (!this.text.trim()) return;
      if (!this.body) { this.body = this.el.appendChild(el('div', 'think-b')); this.body.textContent = this.text; }
      else this.body.hidden = !this.body.hidden;
      this.el.classList.toggle('open', !this.body.hidden);
    }
  }

  // ───────────────────────── 差異（diff） ─────────────────────────
  function lineDiff(a, b) {
    // 回傳 [{t:' '|'-'|'+', s}]；小檔用 LCS，大檔退化成全刪全加
    const A = a === '' ? [] : a.split('\n'), B = b === '' ? [] : b.split('\n');
    let pre = 0;
    while (pre < A.length && pre < B.length && A[pre] === B[pre]) pre++;
    let suf = 0;
    while (suf < A.length - pre && suf < B.length - pre && A[A.length - 1 - suf] === B[B.length - 1 - suf]) suf++;
    const a2 = A.slice(pre, A.length - suf), b2 = B.slice(pre, B.length - suf);
    const out = A.slice(0, pre).map((s) => ({ t: ' ', s }));
    if (a2.length * b2.length <= 250000) {
      const n = a2.length, m = b2.length;
      const dp = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
      for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) dp[i][j] = a2[i] === b2[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
      let i = 0, j = 0;
      while (i < n && j < m) {
        if (a2[i] === b2[j]) { out.push({ t: ' ', s: a2[i] }); i++; j++; }
        else if (dp[i + 1][j] >= dp[i][j + 1]) out.push({ t: '-', s: a2[i++] });
        else out.push({ t: '+', s: b2[j++] });
      }
      while (i < n) out.push({ t: '-', s: a2[i++] });
      while (j < m) out.push({ t: '+', s: b2[j++] });
    } else {
      for (const s of a2) out.push({ t: '-', s });
      for (const s of b2) out.push({ t: '+', s });
    }
    for (const s of A.slice(A.length - suf)) out.push({ t: ' ', s });
    return out;
  }
  // hunks: [{oldStart,newStart,lines:[...]}]
  function hunksFromPatch(patch) {
    return (patch || []).map((h) => ({ oldStart: h.oldStart, newStart: h.newStart, lines: h.lines.map((l) => ({ t: l[0] === '+' || l[0] === '-' ? l[0] : ' ', s: l.slice(1) })) }));
  }
  function hunksFromStrings(a, b) {
    const d = lineDiff(a || '', b || '');
    // 只留變動附近 3 行
    const keep = new Array(d.length).fill(false);
    d.forEach((x, i) => { if (x.t !== ' ') for (let k = Math.max(0, i - 3); k <= Math.min(d.length - 1, i + 3); k++) keep[k] = true; });
    const hunks = [];
    let cur = null, o = 1, n = 1;
    d.forEach((x, i) => {
      if (keep[i]) {
        if (!cur) { cur = { oldStart: o, newStart: n, lines: [], gap: false }; hunks.push(cur); }
        cur.lines.push(x);
      } else cur = null;
      if (x.t !== '+') o++;
      if (x.t !== '-') n++;
    });
    return hunks;
  }
  const countHunks = (hunks) => {
    let add = 0, del = 0;
    for (const h of hunks) for (const l of h.lines) { if (l.t === '+') add++; else if (l.t === '-') del++; }
    return { add, del };
  };
  function diffEl(hunks, lang, absoluteLines) {
    const box = el('div', 'diff');
    let count = 0;
    hunks.forEach((h, hi) => {
      if (hi > 0) box.appendChild(el('div', 'diff-gap', '⋯'));
      let o = h.oldStart, n = h.newStart;
      for (const l of h.lines) {
        if (++count > 800) { if (count === 801) box.appendChild(el('div', 'diff-gap', L('（差異太長，只顯示前 800 行）'))); continue; }
        const row = el('div', 'dl ' + (l.t === '+' ? 'add' : l.t === '-' ? 'del' : 'ctx'));
        const on = el('span', 'ln', l.t === '+' ? '' : String(o));
        const nn = el('span', 'ln', l.t === '-' ? '' : String(n));
        const sg = el('span', 'sg', l.t === ' ' ? '' : l.t === '-' ? '−' : '+');
        const tx = el('span', 'tx');
        const hl = hlLang(lang);
        if (hl && l.s.length < 2000) { try { tx.innerHTML = hljs.highlight(l.s, { language: hl, ignoreIllegals: true }).value; } catch (_) { tx.textContent = l.s; } }
        else tx.textContent = l.s;
        if (!l.s) tx.textContent = ' ';
        row.append(on, nn, sg, tx);
        box.appendChild(row);
        if (l.t !== '+') o++;
        if (l.t !== '-') n++;
      }
    });
    if (!absoluteLines) box.classList.add('rel');
    return box;
  }

  // ───────────────────────── 工具結果整理 ─────────────────────────
  function normResult(content) {
    // tool_result.content 可能是字串或 [{type:text|image}]
    const out = { text: '', images: [] };
    if (typeof content === 'string') out.text = content;
    else if (Array.isArray(content)) {
      for (const b of content) {
        if (!b) continue;
        if (b.type === 'text') out.text += (out.text ? '\n' : '') + b.text;
        else if (b.type === 'image' && b.source) {
          if (b.source.type === 'base64') out.images.push(`data:${b.source.media_type || 'image/png'};base64,${b.source.data}`);
          else if (b.source.url) out.images.push(b.source.url);
        }
      }
    }
    return out;
  }
  function stripLineNumbers(t) {
    // Read 的輸出每行開頭是「   12→」或「12\t」
    const ls = t.split('\n');
    const re = /^\s*\d+(?:→|\t)/;
    let hits = 0;
    for (const l of ls.slice(0, 20)) if (re.test(l)) hits++;
    if (hits < Math.min(3, ls.length)) return null;
    return ls.map((l) => l.replace(re, '')).join('\n');
  }

  // 整段是 JSON（物件或陣列）就排成多行；不是就回 null
  function jsonPretty(text) {
    const t = String(text || '').trim();
    if (!/^[\[{]/.test(t) || t.length > 200000) return null;
    try { return JSON.stringify(JSON.parse(t), null, 2); } catch (_) { return null; }
  }
  function preEl(text, cls, maxLines = 400) {
    const wrap = el('div', 'out' + (cls ? ' ' + cls : ''));
    const pre = wrap.appendChild(el('pre'));
    const t = stripAnsi(text || '');
    const ls = t.split('\n');
    if (ls.length > maxLines) {
      pre.textContent = ls.slice(0, maxLines).join('\n');
      const more = wrap.appendChild(el('button', 'more', L`顯示全部（共 ${ls.length} 行）`));
      more.type = 'button';
      more.addEventListener('click', () => { pre.textContent = t; more.remove(); });
    } else pre.textContent = t;
    return wrap;
  }
  function codeEl(text, lang, maxLines = 400) {
    const wrap = el('div', 'out code-out');
    const pre = wrap.appendChild(el('pre'));
    const code = pre.appendChild(el('code'));
    const ls = String(text).split('\n');
    const show = ls.length > maxLines ? ls.slice(0, maxLines).join('\n') : String(text);
    highlightTo(code, show, lang);
    if (ls.length > maxLines) {
      const more = wrap.appendChild(el('button', 'more', L`顯示全部（共 ${ls.length} 行）`));
      more.type = 'button';
      more.addEventListener('click', () => { highlightTo(code, String(text), lang); more.remove(); });
    }
    return wrap;
  }
  function imagesEl(urls) {
    const box = el('div', 'imgs');
    for (const u of urls) {
      const img = box.appendChild(el('img'));
      img.src = u;
      img.loading = 'lazy';
      img.alt = L('圖片');
    }
    return box;
  }

  // ───────────────────────── 工具卡片 ─────────────────────────
  const TASK_TOOLS = new Set(['Task', 'Agent']);
  function toolKind(name) {
    if (TASK_TOOLS.has(name)) return 'task';
    if (name === 'AskUserQuestion') return 'ask';
    if (name === 'TodoWrite') return 'todo';
    if (name === 'ExitPlanMode') return 'plan';
    return 'tool';
  }

  class ToolCard {
    constructor(ctx, id, name, input) {
      this.ctx = ctx;
      this.id = id;
      this.name = name || L('工具');
      this.input = input || {};
      this.partial = '';
      this.result = null;     // {text, images}
      this.tur = null;        // tool_use_result
      this.isError = false;
      this.state = 'running';
      this.kind = toolKind(this.name);
      // 計畫（ExitPlanMode）要讓人看得到，不收進步驟組
      const parent = this.kind === 'plan' ? ctx.breakParent() : ctx.stepParent();
      this.el = parent.appendChild(el('div', 'tool k-' + this.kind));
      if (this.kind !== 'plan') ctx.addStep(this);
      this.head = this.el.appendChild(el('div', 'tool-h'));
      this.head.tabIndex = 0;
      this.head.setAttribute('role', 'button');
      this.icon = this.head.appendChild(el('span', 'ti'));
      this.sum = this.head.appendChild(el('span', 'tool-sum'));
      this.meta = this.head.appendChild(el('span', 'tool-meta'));
      this.chev = this.head.appendChild(el('span', 'chev'));
      this.body = null;
      this.open = false;
      this.head.addEventListener('click', (e) => { if (e.target.closest('.path')) return; this.toggle(); });
      this.head.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); this.toggle(); } });
      if (this.kind === 'task') {
        this.body = this.el.appendChild(el('div', 'tool-b'));
        this.body.hidden = true;
        this.promptEl = this.body.appendChild(el('div', 'task-prompt'));
        this.subEl = this.body.appendChild(el('div', 'sub'));
        this.finalEl = this.body.appendChild(el('div', 'task-final md'));
        this.sub = new Ctx(this.subEl, false);
        this.steps = 0;
        this.sub.onStep = (card) => { this.steps++; this.lastStep = card; this.refreshHead(); };
      }
      if (this.kind === 'todo' || this.kind === 'plan') this.open = true;
      this.setState('running');
      this.refreshHead();
      // 還沒跑完的展開（內容邊來邊顯示），跑完自動收起；舊對話載入時不展開（使用者 10/23 要的）
      if (!S.historyMode && !this.open) {
        this.autoOpened = true;
        this.open = true;
        if (this.kind === 'task') { this.body.hidden = false; this.el.classList.add('open'); } else this.buildBody(false);
      }
      if (ctx.onStep) ctx.onStep(this);
    }
    get hasBody() { return true; }
    setPartialJson(chunk) {
      this.partial += chunk;
      if (!this._pq) { this._pq = true; raf(() => { this._pq = false; this.refreshHead(); if (this.open && !this.inputDone && this.kind !== 'task') { this.buildBody(true); this.followInner(); } }); }
    }
    partialField(k) {
      const m = this.partial.slice(0, 4000).match(new RegExp('"' + k + '"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)'));
      if (!m) return undefined;
      try { return JSON.parse('"' + m[1].replace(/\\$/, '') + '"'); } catch (_) { return m[1]; }
    }
    setInput(input) {
      this.input = input || {};
      this.partial = '';
      this.inputDone = true;
      this.refreshHead();
      if (this.open) { this.buildBody(true); if (this.autoOpened && !this.result) this.followInner(); }
    }
    setResult(content, tur, isError) {
      this.result = normResult(content);
      this.tur = tur;
      // Bash 指令有跑完、只是結束碼不是 0（結果開頭「Exit code N」）：跟 CLI 一樣當一般結果顯示，不畫紅 ✕；
      // 結束碼只在展開後用灰字標出。被拒絕、中斷、逾時這類照舊算錯誤
      const ec = isError && this.name === 'Bash' && !this.denied ? this.result.text.match(/^(?:Error: )?Exit code (\d+)\n?/) : null;
      this.exitCode = ec ? Number(ec[1]) : null;
      if (ec) {
        this.result = { ...this.result, text: this.result.text.slice(ec[0].length) };
        if (typeof tur === 'string') this.tur = null;
        isError = false;
      }
      this.isError = !!isError;
      if (this.kind === 'task') this.refreshTask();
      this.autoClose();
      this.setState(this.isError ? (this.denied ? 'denied' : 'error') : 'done');
      this.refreshHead();
      if (this.open || this.kind === 'todo' || this.kind === 'plan') this.buildBody(true);
      else if (this.body && this.kind !== 'task') { this.body.remove(); this.body = null; }
    }
    // 自動展開、還在長的時候：框裡的內容捲到最新一行，整頁也貼底（使用者往上捲了就不動）
    followInner() {
      if (!S.following || S.jumping || !this.body) return;
      for (const p of this.body.querySelectorAll('.out pre, .diff')) p.scrollTop = p.scrollHeight;
      stick();
    }
    // 自動展開的跑完了：收起來（使用者自己點過的不動）
    autoClose() {
      if (!this.autoOpened || this.userToggled || !this.open) return;
      this.open = false;
      if (this.body) this.body.hidden = true;
      this.el.classList.remove('open');
    }
    setState(s) {
      this.state = s;
      if (s === 'stopped') this.autoClose();
      this.el.classList.remove('running', 'done', 'error', 'waiting', 'denied', 'stopped');
      this.el.classList.add(s);
      if (this.group) this.group.changed();
    }
    // 標題列
    field(k) { const v = this.input[k]; return v !== undefined ? v : this.partialField(k); }
    refreshHead() {
      const { verb, target, meta } = this.summary();
      this.sum.innerHTML = '';
      this.sum.appendChild(el('span', 'verb', verb));
      if (target) {
        if (target.nodeType) this.sum.appendChild(target); else this.sum.appendChild(el('span', 'tgt', target));
      }
      let m = meta || '';
      if (this.state === 'waiting') m = L('等你允許');
      else if (this.state === 'denied') m = L('已拒絕');
      else if (this.state === 'stopped') m = L('已停止');
      this.meta.innerHTML = '';
      if (m && typeof m === 'object') this.meta.appendChild(m); else this.meta.textContent = m;
    }
    summary() {
      const n = this.name, f = (k) => this.field(k);
      const codeT = (s) => { const c = el('code', 'tgt', clip(firstLine(s), 120)); c.title = s; return c; };
      const p = (k) => { const v = f(k); return v ? pathEl(v) : null; };
      switch (n) {
        case 'Bash': {
          const cmd = f('command');
          return { verb: L('執行'), target: cmd ? codeT(cmd) : L('指令…'), meta: this.tur && this.tur.interrupted ? L('已中斷') : '' };
        }
        case 'BashOutput': return { verb: L('查看背景指令輸出'), target: '' };
        case 'KillShell': case 'KillBash': return { verb: L('停止背景指令'), target: '' };
        case 'Read': {
          const off = this.input.offset, lim = this.input.limit;
          let meta = '';
          if (lim) meta = L`第 ${off || 1}–${(off || 1) + lim - 1} 行`;
          else if (off) meta = L`第 ${off} 行起`;
          if (this.tur && this.tur.type === 'image') meta = L('圖片');
          return { verb: L('讀取'), target: p('file_path') || L('檔案…'), meta };
        }
        case 'Write': {
          const c = f('content');
          const isNew = this.tur ? this.tur.type === 'create' : null;
          const ln = this.inputDone ? lines(c) : (this.partial.match(/\\n/g) || []).length;
          return { verb: isNew === false ? L('覆寫') : isNew ? L('建立') : L('寫入'), target: p('file_path') || L('檔案…'), meta: ln ? L`${ln} 行${this.inputDone ? '' : '…'}` : '' };
        }
        case 'Edit': case 'MultiEdit': {
          let meta = '';
          if (this.inputDone || this.tur) {
            const { add, del } = countHunks(this.hunks());
            meta = this.diffMeta(add, del);
          }
          return { verb: L('編輯'), target: p('file_path') || L('檔案…'), meta };
        }
        case 'NotebookEdit': return { verb: L('編輯筆記本'), target: p('notebook_path') };
        case 'Glob': return { verb: L('找檔案'), target: f('pattern') ? codeT(f('pattern')) : '', meta: this.countMeta(L('個檔案')) };
        case 'Grep': return { verb: L('搜尋'), target: f('pattern') ? codeT(f('pattern')) : '', meta: f('path') ? L('於 ') + shortPath(f('path')) : this.countMeta(L('筆')) };
        case 'LS': return { verb: L('列出'), target: p('path') };
        case 'WebFetch': { const u = f('url') || ''; return { verb: L('讀取網頁'), target: el('span', 'tgt', clip(u.replace(/^https?:\/\//, ''), 80)) }; }
        case 'WebSearch': return { verb: L('搜尋網路'), target: f('query') ? L`「${clip(f('query'), 80)}」` : '' };
        case 'TodoWrite': {
          const t = this.input.todos || [];
          const done = t.filter((x) => x.status === 'completed').length;
          return { verb: L('待辦清單'), target: '', meta: t.length ? L`完成 ${done}/${t.length}` : '' };
        }
        case 'Task': case 'Agent': return this.taskSummary();
        case 'AskUserQuestion': return { verb: L('提問'), target: '' };
        case 'ExitPlanMode': return { verb: L('計畫'), target: '', meta: '' };
        case 'EnterPlanMode': return { verb: L('進入規劃模式'), target: '' };
        case 'Skill': return { verb: L('使用技能'), target: f('skill') ? codeT(f('skill')) : '' };
        case 'ToolSearch': return { verb: L('載入工具'), target: f('query') ? codeT(f('query')) : '' };
        case 'SendMessage': return { verb: L('傳訊息給'), target: f('to') || f('recipient') || '' };
        case 'TaskStop': return { verb: L('停止子代理'), target: '' };
        default: {
          const mm = n.match(/^mcp__(.+?)__(.+)$/);
          const firstStr = Object.values(this.input).find((v) => typeof v === 'string' && v.length < 200);
          if (mm) return { verb: mm[2].replace(/_/g, ' '), target: firstStr ? el('span', 'tgt muted', clip(firstStr, 80)) : '', meta: mm[1].replace(/^claude_ai_/, '').replace(/_/g, ' ') };
          return { verb: n, target: firstStr ? el('span', 'tgt muted', clip(firstLine(firstStr), 80)) : '' };
        }
      }
    }
    diffMeta(add, del) {
      const m = el('span', 'dm');
      m.append(el('span', 'dm-add', '+' + add), el('span', 'dm-del', '−' + del));
      return m;
    }
    countMeta(unit) {
      if (!this.result || this.isError) return '';
      if (this.tur && typeof this.tur.numFiles === 'number') return `${this.tur.numFiles} ${unit}`;     // unit 由呼叫端用 L('…') 包好
      return '';
    }
    taskSummary() {
      const d = this.field('description') || '';
      const type = this.field('subagent_type');
      let meta = '';
      if (this.state === 'running' && this.lastStep) {
        const s = this.lastStep.summary();
        const t = s.target && s.target.nodeType ? s.target.textContent : (s.target || '');
        meta = clip(`${s.verb} ${t}`.trim(), 60);
      } else if (this.tur && this.tur.totalToolUseCount != null) {
        meta = L`${this.tur.totalToolUseCount} 個步驟 · ${(this.tur.totalDurationMs / 1000).toFixed(1)} 秒`;
      } else if (this.steps) meta = L`${this.steps} 個步驟`;
      return { verb: type && type !== 'general-purpose' ? L`子代理（${type}）` : L('子代理'), target: d ? el('span', 'tgt', d) : '', meta };
    }
    hunks() {
      if (this._hunks && this._hunksFrom === this.tur) return this._hunks;
      let h;
      if (this.tur && Array.isArray(this.tur.structuredPatch) && this.tur.structuredPatch.length) h = hunksFromPatch(this.tur.structuredPatch);
      else if (this.name === 'MultiEdit' && Array.isArray(this.input.edits)) h = this.input.edits.flatMap((e) => hunksFromStrings(e.old_string, e.new_string));
      else h = hunksFromStrings(this.input.old_string, this.input.new_string);
      this._hunks = h; this._hunksFrom = this.tur;
      this._absLines = !!(this.tur && this.tur.structuredPatch && this.tur.structuredPatch.length);
      return h;
    }
    toggle() {
      this.userToggled = true;
      if (this.kind === 'task') {
        this.open = !this.open;
        this.body.hidden = !this.open;
        this.el.classList.toggle('open', this.open);
        return;
      }
      this.open = !this.open;
      if (this.open) this.buildBody(false);
      else if (this.body) this.body.hidden = true;
      this.el.classList.toggle('open', this.open);
    }
    buildBody(force) {
      if (this.kind === 'task') return;
      if (this.body && !force) { this.body.hidden = false; return; }
      const b = el('div', 'tool-b');
      this.fillBody(b);
      if (this.body) this.body.replaceWith(b); else this.el.appendChild(b);
      this.body = b;
      b.hidden = !this.open;
      this.el.classList.toggle('open', this.open);
    }
    fillBody(b) {
      const r = this.result;
      // 參數還在串流：先用已經收到的部分畫（指令、檔名、內容）
      const inp = this.inputDone ? this.input : Object.fromEntries(['command', 'file_path', 'content', 'description', 'pattern', 'path'].map((k) => [k, this.field(k)]).filter(([, v]) => v !== undefined));
      const errBox = () => { if (r && this.isError) b.appendChild(preEl(r.text, 'err')); };
      switch (this.name) {
        case 'Bash': {
          const cmd = el('div', 'cmd');
          cmd.appendChild(el('span', 'prompt', '$'));
          const ct = cmd.appendChild(el('span', 'cmd-t'));
          highlightTo(ct, inp.command || '', 'bash');
          b.appendChild(cmd);
          if (inp.description) b.appendChild(el('div', 'note', inp.description));
          if (r) {
            if (this.isError) errBox();
            else {
              const out = this.tur && typeof this.tur === 'object' ? (this.tur.stdout || '') : r.text;
              const er = this.tur && typeof this.tur === 'object' ? (this.tur.stderr || '') : '';
              if (out) b.appendChild(preEl(out));
              if (er) b.appendChild(preEl(er, 'stderr'));
              if (!out && !er) b.appendChild(el('div', 'note', L('（沒有輸出）')));
              if (r.images.length) b.appendChild(imagesEl(r.images));
              if (this.exitCode !== null && this.exitCode !== undefined) b.appendChild(el('div', 'note', L`結束碼 ${this.exitCode}`));
            }
          }
          return;
        }
        case 'Read': {
          if (!r) return;
          if (this.isError) return errBox();
          if (r.images.length) { b.appendChild(imagesEl(r.images)); return; }
          if (this.tur && this.tur.type === 'image' && this.tur.file && this.tur.file.base64) {
            b.appendChild(imagesEl([`data:${this.tur.file.type || 'image/png'};base64,${this.tur.file.base64}`])); return;
          }
          const content = this.tur && this.tur.file && typeof this.tur.file.content === 'string' ? this.tur.file.content : (stripLineNumbers(r.text) ?? r.text);
          b.appendChild(codeEl(content, langFromPath(inp.file_path)));
          return;
        }
        case 'Write': {
          if (r && this.isError) errBox();
          if (this.tur && this.tur.type === 'update' && this.tur.structuredPatch && this.tur.structuredPatch.length) {
            b.appendChild(diffEl(hunksFromPatch(this.tur.structuredPatch), langFromPath(inp.file_path), true));
          } else if (inp.content != null) b.appendChild(codeEl(inp.content, langFromPath(inp.file_path), 300));
          return;
        }
        case 'Edit': case 'MultiEdit': {
          if (r && this.isError) errBox();
          const h = this.hunks();
          b.appendChild(diffEl(h, langFromPath(inp.file_path), this._absLines));
          return;
        }
        case 'TodoWrite': {
          const ul = b.appendChild(el('ul', 'todos'));
          for (const t of inp.todos || []) {
            const li = ul.appendChild(el('li', 'todo ' + (t.status || 'pending')));
            li.appendChild(el('span', 'tb'));
            li.appendChild(el('span', 'tt', t.status === 'in_progress' && t.activeForm ? t.activeForm : t.content));
          }
          return;
        }
        case 'ExitPlanMode': {
          const d = b.appendChild(el('div', 'md plan'));
          setMarkdown(d, inp.plan || '');
          if (r && this.isError) errBox();
          return;
        }
        default: {
          const keys = Object.keys(inp);
          if (keys.length) {
            const det = b.appendChild(el('details', 'args'));
            det.appendChild(el('summary', '', L('參數')));
            det.appendChild(codeEl(JSON.stringify(inp, null, 2), 'json', 200));
            if (keys.length <= 3 && JSON.stringify(inp).length < 300) det.open = true;
          }
          if (r) {
            if (this.isError) errBox();
            else {
              const js = jsonPretty(r.text);
              if (js) b.appendChild(codeEl(js, 'json'));
              else if (r.text) b.appendChild(preEl(r.text));
              if (r.images.length) b.appendChild(imagesEl(r.images));
              if (!r.text && !r.images.length) b.appendChild(el('div', 'note', L('（沒有輸出）')));
            }
          }
        }
      }
    }
    // Task 卡片內容
    refreshTask() {
      const prompt = this.input.prompt;
      if (prompt && !this.promptEl.childNodes.length) {
        this.promptEl.appendChild(el('div', 'task-pl', L('交代的工作')));
        const t = this.promptEl.appendChild(el('div', 'task-pt'));
        t.textContent = prompt;
        t.addEventListener('click', () => t.classList.toggle('full'));
      }
      if (this.result) {
        let txt = '';
        if (this.tur && Array.isArray(this.tur.content)) txt = this.tur.content.filter((x) => x.type === 'text').map((x) => x.text).join('\n\n');
        if (!txt) txt = this.result.text.replace(/^\[Subagent hand-back\][\s\S]*?\n\n/, '');
        if (this.isError) { this.finalEl.innerHTML = ''; this.finalEl.appendChild(preEl(txt, 'err')); }
        else if (txt) { this.finalEl.classList.add('has'); setMarkdown(this.finalEl, txt); }
      }
    }
  }

  // ───────────────────────── 選擇題（AskUserQuestion） ─────────────────────────
  class AskCard {
    constructor(ctx, toolId, input) {
      this.toolId = toolId;
      this.input = input || {};
      this.reqId = null;
      this.pending = false;
      this.answers = null;
      this.el = ctx.breakParent().appendChild(el('div', 'ask'));   // 選擇題不收進步驟組
      this.render();
    }
    setInput(input) { this.input = input || {}; if (!this.pending) this.render(); }
    activate(reqId, input) {
      this.reqId = reqId;
      if (input) this.input = input;
      this.pending = true;
      S.perms.set(reqId, this);
      this.render();
      updateJump();
    }
    render() {
      const qs = this.input.questions || [];
      this.el.innerHTML = '';
      this.el.classList.toggle('pending', this.pending);
      this.el.classList.toggle('answered', !!this.answers);
      const head = this.el.appendChild(el('div', 'ask-t', this.answers ? L`${S.agent} 問了你` : this.pending ? L`${S.agent} 想問你` : L`${S.agent} 的問題`));
      if (!qs.length) { head.textContent = L('Claude 正在準備問題…'); return; }
      this.qs = qs.map(() => ({ sel: new Set(), other: '' }));
      qs.forEach((q, qi) => {
        const box = this.el.appendChild(el('div', 'q'));
        const qh = box.appendChild(el('div', 'q-h'));
        if (q.header) qh.appendChild(el('span', 'chip', q.header));
        qh.appendChild(el('span', 'q-q', q.question || ''));
        if (q.multiSelect) qh.appendChild(el('span', 'q-hint', L('可複選')));
        const opts = box.appendChild(el('div', 'opts'));
        opts.setAttribute('role', q.multiSelect ? 'group' : 'radiogroup');
        const chosen = this.answers ? String(this.answers[q.question] ?? '') : null;
        const chosenSet = chosen != null ? new Set(chosen.split(/、|, /)) : null;
        const all = [...(q.options || []), { label: L('其他…'), other: true }];
        all.forEach((o, oi) => {
          const btn = opts.appendChild(el('button', 'opt' + (o.other ? ' other' : '')));
          btn.type = 'button';
          btn.setAttribute('role', q.multiSelect ? 'checkbox' : 'radio');
          btn.appendChild(el('span', 'mark' + (q.multiSelect ? ' sq' : '')));
          const tx = btn.appendChild(el('span', 'opt-tx'));
          tx.appendChild(el('span', 'opt-l', o.label));
          if (o.description) tx.appendChild(el('span', 'opt-d', o.description));
          if (chosenSet) {
            const on = o.other ? false : chosenSet.has(o.label);
            btn.classList.toggle('on', on);
            btn.disabled = true;
            if (o.other) {
              const known = new Set((q.options || []).map((x) => x.label));
              const extra = [...chosenSet].filter((x) => x && !known.has(x));
              if (extra.length) { btn.classList.add('on'); tx.querySelector('.opt-l').textContent = L('其他：') + extra.join('、'); } else btn.remove();
            }
            return;
          }
          if (!this.pending) { btn.disabled = true; if (o.other) btn.remove(); return; }
          btn.addEventListener('click', () => this.pick(qi, oi, !!o.other, btn));
        });
        if (this.pending) {
          const inp = box.appendChild(el('input', 'other-in'));
          inp.type = 'text';
          inp.placeholder = L('輸入你的答案（⌘ Enter 送出）');
          inp.hidden = true;
          inp.addEventListener('input', () => { this.qs[qi].other = inp.value; this.validate(); });
          // 只有 ⌘ Enter 送出：中文選字按的 Enter 在 WebKit 常常沒標 isComposing，單按 Enter 會誤送
          inp.addEventListener('keydown', (e) => {
            if (e.key !== 'Enter' || !e.metaKey || e.isComposing) return;
            e.preventDefault();
            if (!this.sendBtn.disabled) this.submit();
          });
        }
      });
      if (this.pending) {
        const f = this.el.appendChild(el('div', 'btns'));
        this.sendBtn = f.appendChild(el('button', 'primary', L('送出答案')));
        this.sendBtn.type = 'button';
        this.sendBtn.disabled = true;
        this.sendBtn.addEventListener('click', () => this.submit());
        const skip = f.appendChild(el('button', 'ghost', L('略過')));
        skip.type = 'button';
        skip.addEventListener('click', () => this.skip());
      } else if (this.resolvedNote) this.el.appendChild(el('div', 'note', this.resolvedNote));
    }
    pick(qi, oi, isOther, btn) {
      const q = this.input.questions[qi];
      const st = this.qs[qi];
      const box = btn.closest('.q');
      const btns = [...box.querySelectorAll('.opt')];
      const inp = box.querySelector('.other-in');
      if (q.multiSelect) {
        if (st.sel.has(oi)) st.sel.delete(oi); else st.sel.add(oi);
      } else st.sel = new Set([oi]);
      btns.forEach((b, i) => { b.classList.toggle('on', st.sel.has(i)); b.setAttribute('aria-checked', st.sel.has(i)); });
      const otherIdx = btns.length - 1;
      inp.hidden = !st.sel.has(otherIdx);
      if (!inp.hidden && isOther) inp.focus();
      this.validate();
    }
    collect() {
      const qs = this.input.questions || [];
      const answers = {};
      for (let i = 0; i < qs.length; i++) {
        const q = qs[i], st = this.qs[i];
        const n = (q.options || []).length;
        const picked = [...st.sel].sort((a, b) => a - b).map((k) => (k === n ? st.other.trim() : q.options[k].label)).filter(Boolean);
        if (!picked.length) return null;
        answers[q.question] = picked.join('、');
      }
      return answers;
    }
    validate() { if (this.sendBtn) this.sendBtn.disabled = !this.collect(); }
    submit() {
      const answers = this.collect();
      if (!answers || !this.pending) return;
      post({ type: 'answer', request_id: this.reqId, updatedInput: { ...this.input, answers } });
      this.pending = false;
      this.answers = answers;
      this.render();
      updateJump();
    }
    skip() {
      if (!this.pending) return;
      post({ type: 'permission', request_id: this.reqId, behavior: 'deny', message: '使用者略過了這個問題，請不要再問，照你的判斷繼續。' });
      this.pending = false;
      this.resolvedNote = L('已略過');
      this.render();
      updateJump();
    }
    resolved(note) {
      if (!this.pending) return;
      this.pending = false;
      this.resolvedNote = note || L('已處理');
      this.render();
      updateJump();
    }
    setResult(content, tur, isError) {
      if (tur && tur.answers) this.answers = tur.answers;
      else if (!isError) {
        const t = normResult(content).text;
        const ans = {};
        for (const m of t.matchAll(/"([^"]+)"="([^"]*)"/g)) ans[m[1]] = m[2];
        if (Object.keys(ans).length) this.answers = ans;
      }
      if (isError && !this.answers) this.resolvedNote = this.resolvedNote || L('沒有回答');
      this.pending = false;
      if (this.reqId) S.perms.delete(this.reqId);
      this.render();
      updateJump();
    }
  }

  // ───────────────────────── 權限卡片 ─────────────────────────
  const PERM_TITLE = {
    Bash: L('執行指令'), Write: L('寫入檔案'), Edit: L('編輯檔案'), MultiEdit: L('編輯檔案'), NotebookEdit: L('編輯筆記本'), Read: L('讀取檔案'),
    WebFetch: L('讀取網頁'), WebSearch: L('搜尋網路'), Glob: L('找檔案'), Grep: L('搜尋檔案內容'), Task: L('開子代理'), Agent: L('開子代理'), ExitPlanMode: L('照這個計畫開始做'),
  };
  function suggestionText(sugs) {
    const parts = [];
    let persistent = false;
    for (const s of sugs || []) {
      if (s.destination && s.destination !== 'session') persistent = true;
      if (s.type === 'setMode') {
        parts.push({ acceptEdits: L('自動接受檔案編輯'), bypassPermissions: L('略過所有權限詢問'), plan: L('規劃模式'), default: L('一般模式') }[s.mode] || s.mode);
      } else if (s.type === 'addRules' || s.type === 'replaceRules') {
        for (const r of s.rules || []) parts.push(r.ruleContent ? `${r.toolName}(${r.ruleContent})` : r.toolName);
      } else if (s.type === 'addDirectories') parts.push(L('存取 ') + (s.directories || []).map(shortPath).join('、'));
    }
    return { text: parts.join('、'), persistent };
  }
  class PermCard {
    constructor(reqId, req) {
      this.reqId = reqId;
      this.req = req;
      this.pending = true;
      this.tool = S.tools.get(req.tool_use_id);
      const turn = S.ctxMain.getTurn();
      this.el = el('div', 'perm pending');
      // 權限卡片不收進步驟組：工具在組裡的話放在組的後面（組不會因此被切斷）
      const host = this.tool && (this.tool.group ? this.tool.group.el : this.tool.el);
      if (host && host.parentElement === turn) host.after(this.el);
      else turn.appendChild(this.el);
      if (this.tool) { this.tool.setState('waiting'); this.tool.refreshHead(); }
      this.render();
    }
    render() {
      const r = this.req, inp = r.input || {};
      this.el.innerHTML = '';
      const t = this.el.appendChild(el('div', 'perm-t'));
      t.appendChild(el('span', 'perm-ic', '!'));
      t.appendChild(el('span', '', L`要允許 ${S.agent} ${PERM_TITLE[r.tool_name] || L('使用 ') + (r.display_name || r.tool_name)}嗎？`));
      const d = this.el.appendChild(el('div', 'perm-d'));
      const lang = langFromPath(inp.file_path);
      switch (r.tool_name) {
        case 'Bash': {
          const c = d.appendChild(el('div', 'cmd'));
          c.append(el('span', 'prompt', '$'), el('span', 'cmd-t', inp.command || ''));
          if (inp.description) d.appendChild(el('div', 'note', inp.description));
          break;
        }
        case 'Edit': case 'MultiEdit': {
          d.appendChild(el('div', 'perm-path')).appendChild(pathEl(inp.file_path));
          const h = r.tool_name === 'MultiEdit' ? (inp.edits || []).flatMap((e) => hunksFromStrings(e.old_string, e.new_string)) : hunksFromStrings(inp.old_string, inp.new_string);
          d.appendChild(diffEl(h, lang, false));
          break;
        }
        case 'Write': {
          d.appendChild(el('div', 'perm-path')).appendChild(pathEl(inp.file_path));
          d.appendChild(codeEl(inp.content || '', lang, 40));
          break;
        }
        case 'Read': case 'NotebookEdit':
          d.appendChild(el('div', 'perm-path')).appendChild(pathEl(inp.file_path || inp.notebook_path));
          break;
        case 'WebFetch':
          d.appendChild(el('div', 'perm-path', inp.url || ''));
          break;
        case 'ExitPlanMode':
          setMarkdown(d.appendChild(el('div', 'md plan')), inp.plan || '');
          break;
        default:
          d.appendChild(preEl(JSON.stringify(inp, null, 2), 'json', 60));
      }
      if (r.description && r.tool_name !== 'Bash' && r.description !== shortPath(inp.file_path) && !String(inp.file_path || '').endsWith(r.description))
        d.appendChild(el('div', 'note', r.description));
      if (r.blocked_path) d.appendChild(el('div', 'note', L('碰到的路徑：') + shortPath(r.blocked_path)));
      if (!this.pending) {
        this.el.classList.remove('pending');
        this.el.classList.add('done', this.decision || 'other');
        const s = el('div', 'perm-res', this.note || L('已處理'));
        this.el.appendChild(s);
        d.hidden = true;
        t.addEventListener('click', () => { d.hidden = !d.hidden; });
        return;
      }
      const btns = this.el.appendChild(el('div', 'btns'));
      const allow = btns.appendChild(el('button', 'primary', L('允許')));
      allow.type = 'button';
      allow.addEventListener('click', () => this.decide('allow'));
      const sugs = r.permission_suggestions || [];
      if (sugs.length) {
        const st = suggestionText(sugs);
        const all = btns.appendChild(el('button', '', st.persistent ? L('以後都允許') : L('這次對話都允許')));
        all.type = 'button';
        all.title = st.text;
        all.addEventListener('click', () => this.decide('always'));
        if (st.text) this.el.insertBefore(el('div', 'perm-sug', (st.persistent ? L('「以後都允許」會記住：') : L('「這次對話都允許」會開啟：')) + st.text), btns);
      }
      const deny = btns.appendChild(el('button', 'danger', L('拒絕')));
      deny.type = 'button';
      deny.addEventListener('click', () => this.decide('deny'));
    }
    decide(kind) {
      if (!this.pending) return;
      const r = this.req;
      if (kind === 'deny') {
        post({ type: 'permission', request_id: this.reqId, behavior: 'deny', message: '使用者拒絕了這個操作。' });
        this.finish('deny', L('已拒絕'));
        if (this.tool) { this.tool.denied = true; this.tool.setState('denied'); this.tool.refreshHead(); }
      } else {
        const m = { type: 'permission', request_id: this.reqId, behavior: 'allow', updatedInput: r.input || {} };
        if (kind === 'always') m.updatedPermissions = r.permission_suggestions || [];
        post(m);
        this.finish('allow', kind === 'always' ? (suggestionText(r.permission_suggestions).persistent ? L('已允許，以後都允許') : L('已允許，這次對話都允許')) : L('已允許'));
        if (this.tool && this.tool.state === 'waiting') { this.tool.setState('running'); this.tool.refreshHead(); }
      }
    }
    finish(decision, note) {
      // 處理完就收掉卡片；結果（允許後的執行結果／已拒絕）留在工具卡片上
      this.pending = false;
      this.decision = decision;
      this.note = note;
      this.el.remove();
      S.perms.delete(this.reqId);
      updateJump();
    }
    resolved(note) {
      if (!this.pending) return;
      if (this.tool && this.tool.state === 'waiting') { this.tool.setState(this.tool.result ? (this.tool.isError ? 'error' : 'done') : 'running'); this.tool.refreshHead(); }
      this.finish('other', note || L('已處理'));
    }
  }

  // ───────────────────────── 其他畫面元素 ─────────────────────────
  let petW = 0, petH = 0;
  function applyPet() {
    const st = document.documentElement.style;
    // 使用者：不要因為桌寵改變文字排版。所以底部不留空白，只讓「↓ 最新」按鈕往左讓開
    st.setProperty('--wb-pet-w', petW + 'px');
    st.setProperty('--wb-pet-h', '0px');
    if (S.following) stick();
  }
  addEventListener('resize', () => { if (petW) applyPet(); });
  function notice(text, cls) {
    const n = el('div', 'notice' + (cls ? ' ' + cls : ''), text);
    log.appendChild(n);
    S.ctxMain.endTurn();
    return n;
  }
  function smallNote(ctx, text, cls) {
    return ctx.breakParent().appendChild(el('div', 'line-note' + (cls ? ' ' + cls : ''), text));
  }
  function userBubble(text, images, opts = {}) {
    if (!opts.queued) S.ctxMain.endTurn();
    const t = el('section', 'turn user' + (opts.queued ? ' queued' : ''));
    const b = t.appendChild(el('div', 'bubble' + (opts.cmd ? ' cmd' : '')));
    if (images && images.length) b.appendChild(imagesEl(images));
    // 換模型時程式附的那行（前面對話的紀錄檔）是給模型看的，重開時從紀錄讀回來也不顯示
    if (text) text = text.replace(/\n\n〔codenv 換模型〕[\s\S]*$/, '');   // 換模型的交接（可能好幾行）一路藏到最後
    if (text) {
      const tx = b.appendChild(el('div', 'bubble-t'));
      tx.textContent = text;
      if (text.length > 900 || lines(text) > 14) {
        tx.classList.add('clamp');
        const more = b.appendChild(el('button', 'more', L('展開全部')));
        more.type = 'button';
        more.addEventListener('click', () => { const c = tx.classList.toggle('clamp'); more.textContent = c ? L('展開全部') : L('收起'); });
      }
    }
    (opts.queued ? queueBox : log).appendChild(t);
    return t;
  }
  // 排隊中的泡泡：放在對話最下面（Claude 目前的回答下方），等它真的讀進去才移進對話
  function queueNote(t, uuid, now) {
    let n = t.querySelector('.queued-note');
    if (!n) n = t.appendChild(el('div', 'queued-note'));
    n.innerHTML = '';
    if (now) { n.textContent = L('插話中…（Claude 停下目前這一步就讀）'); return; }
    n.appendChild(document.createTextNode(L('排隊中：Claude 做完這一步就會讀到 · ')));
    const a = n.appendChild(el('button', 'queued-now', L('馬上插話（⌃ Enter）')));
    a.type = 'button';
    a.addEventListener('click', () => { queueNote(t, uuid, true); post({ type: 'sendNow', uuid }); });
  }
  function takeQueued(t) {
    S.ctxMain.endTurn();
    t.classList.remove('queued');
    const n = t.querySelector('.queued-note');
    if (n) n.remove();
    log.appendChild(t);
  }
  function turnFooter(o) {
    const turn = S.ctxMain.turn;
    const stopped = S.interrupted;
    const isErr = o.is_error && !(stopped && (o.subtype === 'error_during_execution' || !o.subtype));
    const parts = [];
    if (!stopped && !isErr) parts.push(L('完成'));
    if (o.duration_ms) parts.push(fmtDur(o.duration_ms));
    // 不顯示 total_cost_usd：訂閱登入時那只是「換算成 API 價格」的估計，不會真的收費，顯示出來容易誤會
    if (isErr) {
      const msg = o.result || (Array.isArray(o.errors) && o.errors.join('；')) || ({ error_max_turns: L('達到回合上限'), error_during_execution: L('執行中發生錯誤'), error_max_budget_usd: L('達到花費上限') }[o.subtype]) || L('發生錯誤');
      const n = (turn || log).appendChild(el('div', 'turn-foot err'));
      n.textContent = msg + (parts.length ? ' · ' + parts.join(' · ') : '');
    } else if (turn) {
      turn.appendChild(el('div', 'turn-foot', parts.join(' · ')));
    }
  }
  // 一輪回覆結束：最下面放「複製」，複製這輪 Claude 說的所有文字（原文 Markdown，不含工具和思考）
  function turnTexts(turn) {
    return [...turn.querySelectorAll(':scope > .md')].map((m) => (m._tb ? m._tb.raw : m.textContent).trim()).filter(Boolean);
  }
  function addTurnCopy(turn) {
    if (turn.querySelector(':scope > .turn-foot .turn-copy') || !turnTexts(turn).length) return;
    let foot = [...turn.querySelectorAll(':scope > .turn-foot')].pop();
    if (!foot) foot = turn.appendChild(el('div', 'turn-foot'));
    const b = el('button', 'turn-copy icon-btn');
    b.type = 'button';
    b.innerHTML = COPY_ICON;
    b.setAttribute('aria-label', L('複製'));
    b.title = L('複製這段回覆的全部文字');
    foot.insertBefore(b, foot.firstChild);
  }
  const fmtDur = (ms) => {
    const s = ms / 1000;
    if (s < 60) return L`${s.toFixed(s < 10 ? 1 : 0)} 秒`;
    const m = Math.floor(s / 60);
    return L`${m} 分 ${Math.round(s % 60)} 秒`;
  };

  // ───────────────────────── 事件處理 ─────────────────────────
  function blockForStart(ctx, msgId, index, cb, live) {
    const m = ctx.msg(msgId);
    let b;
    if (cb.type === 'text') b = new TextBlock(ctx.breakParent(), live);
    else if (cb.type === 'thinking' || cb.type === 'redacted_thinking') { b = new ThinkBlock(ctx.stepParent(), true); ctx.addStep(b); }
    else if (cb.type === 'tool_use' || cb.type === 'server_tool_use' || cb.type === 'mcp_tool_use') b = makeTool(ctx, cb.id, cb.name, cb.input && Object.keys(cb.input).length ? cb.input : null);
    else return null;
    m.blocks.push(b);
    m.byIndex.set(index, b);
    return b;
  }
  function makeTool(ctx, id, name, input) {
    if (id && S.tools.has(id)) return S.tools.get(id);
    let card;
    if (name === 'AskUserQuestion') { card = new AskCard(ctx, id, input); card.type = 'tool_use'; card.id = id; }
    else { card = new ToolCard(ctx, id, name, input); card.type = 'tool_use'; if (input) card.setInput(input); }
    if (id) S.tools.set(id, card);
    return card;
  }

  // assistant 事件：一個（或多個）完整區塊 → 取代串流中暫畫的內容
  function onAssistant(o, live) {
    const ctx = ctxFor(o);
    const msg = o.message || {};
    const m = ctx.msg(msg.id);
    for (const blk of msg.content || []) {
      if (!blk) continue;
      if (blk.type === 'tool_use' || blk.type === 'server_tool_use' || blk.type === 'mcp_tool_use') {
        const existing = S.tools.get(blk.id);
        if (existing) { existing.setInput(blk.input); if (!m.blocks.includes(existing)) m.blocks.push(existing); continue; }
        const card = makeTool(ctx, blk.id, blk.name, blk.input);
        m.blocks.push(card);
        continue;
      }
      if (blk.type === 'text') {
        let b = m.blocks.find((x) => x.type === 'text' && !x.final);
        if (!b) {
          if (m.blocks.some((x) => x.type === 'text' && x.raw === blk.text)) continue; // 重複送來
          if (!blk.text || !blk.text.trim()) continue;
          b = new TextBlock(ctx.breakParent(), false);
          b.lazy = !live;
          m.blocks.push(b);
        }
        b.setFull(blk.text, true);
        continue;
      }
      if (blk.type === 'thinking' || blk.type === 'redacted_thinking') {
        let b = m.blocks.find((x) => x.type === 'thinking' && !x.final);
        if (!b) {
          if (!live && !(blk.thinking || '').trim()) continue; // 舊對話裡空白的思考就不畫
          b = new ThinkBlock(ctx.stepParent(), false);
          ctx.addStep(b);
          m.blocks.push(b);
        }
        b.setFull(blk.thinking || '', o.thinking_duration_ms);
        continue;
      }
      if (/_tool_result$/.test(blk.type) && blk.tool_use_id) {
        const card = S.tools.get(blk.tool_use_id);
        if (card) card.setResult(blk.content && blk.content.type ? JSON.stringify(blk.content) : blk.content, null, !!(blk.content && blk.content.error_code));
      }
    }
  }

  function onStream(o) {
    const e = o.event || {};
    const ctx = ctxFor(o);
    const msgId = o.api_message_id || (e.message && e.message.id) || ctx.curMsg;
    switch (e.type) {
      case 'message_start':
        ctx.curMsg = (e.message && e.message.id) || msgId;
        break;
      case 'content_block_start':
        blockForStart(ctx, msgId, e.index, e.content_block || {}, true);
        break;
      case 'content_block_delta': {
        const b = ctx.msg(msgId).byIndex.get(e.index);
        const d = e.delta || {};
        if (!b) {
          if (d.type === 'text_delta') { const nb = blockForStart(ctx, msgId, e.index, { type: 'text' }, true); nb.append(d.text || ''); }
          break;
        }
        if (d.type === 'text_delta' && b.type === 'text') b.append(d.text || '');
        else if (d.type === 'thinking_delta' && b.type === 'thinking') b.append(d.thinking || '');
        else if (d.type === 'input_json_delta' && b.setPartialJson) b.setPartialJson(d.partial_json || '');
        break;
      }
      case 'content_block_stop': {
        const b = ctx.msg(msgId).byIndex.get(e.index);
        if (b && b.type === 'text') b.finish();
        else if (b && b.type === 'thinking') b.finish(null, S.interrupted);
        break;
      }
      case 'message_stop': {
        const m = ctx.msg(msgId);
        for (const b of m.blocks) { if (b.type === 'text') b.finish(); else if (b.type === 'thinking') b.finish(null, S.interrupted); }
        break;
      }
    }
  }

  const INTERRUPT_RE = /^\[Request interrupted by user(?: for tool use)?\]/;
  function onUser(o, live) {
    const ctx = ctxFor(o);
    const c = o.message && o.message.content;
    const tur = o.tool_use_result !== undefined ? o.tool_use_result : o.toolUseResult;
    if (typeof c === 'string') { if (!live) userText(c, []); else if (INTERRUPT_RE.test(c)) stoppedNote(); return; }
    if (!Array.isArray(c)) return;
    const texts = [], images = [];
    const results = c.filter((b) => b && b.type === 'tool_result');
    for (const b of c) {
      if (!b) continue;
      if (b.type === 'text') texts.push(b.text || '');
      else if (b.type === 'image' && b.source) images.push(b.source.type === 'base64' ? `data:${b.source.media_type};base64,${b.source.data}` : b.source.url);
    }
    for (const r of results) {
      const card = S.tools.get(r.tool_use_id);
      const myTur = results.length === 1 ? tur : null;
      if (card) {
        card.setResult(r.content, myTur, r.is_error);
        for (const p of S.perms.values()) if (p.pending && p.req && p.req.tool_use_id === r.tool_use_id) p.resolved(r.is_error ? L('已處理') : L('已允許'));
      }
    }
    if (o.parent_tool_use_id) return; // 子代理收到的交代內容，Task 卡片已經有了
    if (live) {
      if (texts.some((t) => INTERRUPT_RE.test(t))) stoppedNote();
      return;
    }
    if (!results.length && (texts.length || images.length)) userText(texts.join('\n'), images);
    else if (texts.some((t) => INTERRUPT_RE.test(t))) stoppedNote();
  }
  function stoppedNote() {
    S.interrupted = true;
    for (const card of S.tools.values()) if (card.setState && (card.state === 'running' || card.state === 'waiting')) { card.setState('stopped'); card.refreshHead(); }
    for (const p of S.perms.values()) if (p.pending) p.resolved(L('已停止'));
    smallNote(S.ctxMain, L('已停止'), 'stopped');
  }
  // 舊對話裡的使用者文字：過濾系統插入的東西
  function userText(text, images) {
    let t = String(text || '');
    if (INTERRUPT_RE.test(t.trim())) { stoppedNote(); return; }
    if (/^<(local-command-caveat|system-reminder)>/.test(t.trim())) return;
    const cmd = t.match(/<command-name>([^<]*)<\/command-name>/);
    if (cmd) {
      const args = (t.match(/<command-args>([\s\S]*?)<\/command-args>/) || [])[1] || '';
      userBubble(`${cmd[1].startsWith('/') ? '' : '/'}${cmd[1]} ${args}`.trim(), images, { cmd: true });
      return;
    }
    const out = t.match(/<local-command-stdout>([\s\S]*?)<\/local-command-stdout>/);
    if (out) { const s = stripAnsi(out[1]).trim(); if (s) notice(clip(s, 300)); return; }
    const bash = t.match(/<bash-input>([\s\S]*?)<\/bash-input>/);
    if (bash) { userBubble('! ' + bash[1], images, { cmd: true }); return; }
    if (/<bash-(stdout|stderr)>/.test(t)) return;
    t = t.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '').trim();
    if (!t && !(images && images.length)) return;
    userBubble(t, images);
  }

  function onSystem(o) {
    switch (o.subtype) {
      case 'init':
        if (o.cwd) { S.cwd = o.cwd; guessHome(o.cwd); }
        // 權限卡、選擇題寫「Claude」的地方換成實際在跑的模型（Gemini 經 agy、ChatGPT 經 codex）
        if (o.model) { const m = String(o.model).toLowerCase(); S.agent = m.startsWith('gemini') ? 'Gemini' : /^(gpt|o\d)/.test(m) ? 'ChatGPT' : m.startsWith('copilot') ? 'Copilot' : m.startsWith('local-') ? '本機模型' : m.startsWith('apple') ? 'Apple 模型' : 'Claude'; }
        break;
      case 'permission_denied': {
        const card = S.tools.get(o.tool_use_id);
        if (card && card.setState) { card.denied = true; card.setState('denied'); card.refreshHead(); }
        else smallNote(ctxFor(o), L`沒有權限：${o.tool_name || ''}`, 'warn');
        break;
      }
      case 'thinking_tokens': {
        const m = S.ctxMain.msg();
        const b = [...m.blocks].reverse().find((x) => x.type === 'thinking' && !x.final);
        if (b) b.tokens(o.estimated_tokens);
        break;
      }
      case 'compact_boundary':
        if (S.compactingEl) { S.compactingEl.remove(); S.compactingEl = null; }
        notice(L('對話已壓縮（較早的內容整理成摘要）')); break;
      // 壓縮中（Claude 自己壓、或本機模型請 Claude 整理）／本機模型的自動壓縮沒成功
      // 「整理中」那行做完就收掉（status 換成別的、或 compact_boundary 到了）
      case 'status':
        if (S.compactingEl) { S.compactingEl.remove(); S.compactingEl = null; }
        if (o.status === 'compacting') S.compactingEl = notice(L('整理前面的對話…（上下文太長，先壓縮成摘要）'));
        else if (o.status === 'compact_failed') notice(o.message || L('自動壓縮沒成功，照原樣繼續'), 'warn');
        break;
      case 'api_retry': notice(L`連線不穩，重試中（第 ${o.attempt || '?'} 次）…`, 'warn'); break;
      case 'task_notification': {
        const card = S.tools.get(o.tool_use_id);
        if (card && card.kind === 'task' && !card.result && o.summary) {
          card.finalEl.classList.add('has');
          setMarkdown(card.finalEl, o.summary);
          card.setState(o.status === 'completed' ? 'done' : o.status === 'failed' ? 'error' : card.state);
          card.refreshHead();
        }
        break;
      }
    }
  }
  function guessHome(p) { const m = String(p).match(/^\/Users\/[^/]+/); if (m) S.home = m[0]; }

  function handle(o, live) {
    if (!o || typeof o !== 'object') return;
    switch (o.type) {
      case 'stream_event': onStream(o); break;
      case 'assistant': onAssistant(o, live); break;
      case 'user': onUser(o, live); break;
      case 'system': onSystem(o); break;
      case 'control_request': onControl(o); break;
      case 'result': onResult(o); break;
      default: break;
    }
  }
  function onControl(o) {
    const req = o.request || {};
    if (req.subtype !== 'can_use_tool') return;
    if (S.perms.has(o.request_id)) return;
    if (req.tool_name === 'AskUserQuestion') {
      let card = S.tools.get(req.tool_use_id);
      if (!(card instanceof AskCard)) { card = new AskCard(S.ctxMain, req.tool_use_id, req.input); if (req.tool_use_id) S.tools.set(req.tool_use_id, card); }
      card.activate(o.request_id, req.input);
    } else {
      S.perms.set(o.request_id, new PermCard(o.request_id, req));
      updateJump();
    }
  }
  function onResult(o) {
    for (const ctx of [S.ctxMain]) for (const m of ctx.msgs.values()) for (const b of m.blocks) { if (b.type === 'text' && !b.final) b.finish(); else if (b.type === 'thinking' && !b.final) b.finish(null, S.interrupted); }
    S.ctxMain.closeGroup(true);   // 這一輪結束：最後一組也收起
    turnFooter(o);
    S.ctxMain.endTurn();
    S.interrupted = false;
    // 還在排隊的：這一輪結束後 Claude 接著就讀，照順序移進對話。
    // 上一輪移進來的到這裡已經跑完一輪＝確定讀到了；這輪移進來的先記著，程序在讀之前就結束的話標「沒送到」
    unconfirmed.clear();
    for (const [u, t] of queued) { takeQueued(t); unconfirmed.set(u, t); }
    queued.clear();
  }
  // 使用者 10/24：排隊的訊息還沒被讀，程序就結束了 → 原本當成已送出、刪不掉；改成標「沒送到」＋刪除
  function markLost(t) {
    t.classList.add('lost');
    const n = t.appendChild(el('div', 'queued-note'));
    n.appendChild(document.createTextNode(L('沒送到：結束前沒有讀到這則 · ')));
    const b = n.appendChild(el('button', 'queued-now', L('刪除')));
    b.type = 'button';
    b.addEventListener('click', () => t.remove());
  }

  // ───────────────────────── 對外介面（Swift 呼叫） ─────────────────────────
  function hexToRgb(h) {
    const m = String(h || '').trim().match(/^#?([0-9a-f]{6})$/i);
    if (!m) return null;
    const n = parseInt(m[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  const lum = (rgb) => { const f = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }; return 0.2126 * f(rgb[0]) + 0.7152 * f(rgb[1]) + 0.0722 * f(rgb[2]); };

  let busyTimer = null;
  const wb = {
    pathsChecked,
    setLocale(table) {
      LOCALE = table || {};
      document.title = L('對話');
    },
    setTheme(t) {
      t = t || {};
      const st = document.documentElement.style;
      if (t.bg) st.setProperty('--bg', t.bg);
      if (t.fg) st.setProperty('--fg', t.fg);
      const ansi = Array.isArray(t.ansi) ? t.ansi : [];
      const names = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white'];
      ansi.forEach((c, i) => { if (c) st.setProperty('--ansi-' + (i < 8 ? names[i] : 'br-' + names[i - 8]), c); });
      const accent = ansi[4] || ansi[12];
      if (accent) {
        st.setProperty('--accent', accent);
        const rgb = hexToRgb(accent);
        if (rgb) st.setProperty('--on-accent', lum(rgb) > 0.28 ? '#0b0d10' : '#ffffff');
      }
      if (t.monoFont) st.setProperty('--mono', `"${String(t.monoFont).replace(/"/g, '')}", ui-monospace, "SF Mono", Menlo, monospace`);
      if (t.monoSize) st.setProperty('--mono-size', Math.max(10, Math.min(20, +t.monoSize)) + 'px');
      // 對話文字跟終端機一樣（設定頁可以改回系統字型）
      if (t.bodyFont) {
        st.setProperty('--sans', `"${String(t.bodyFont).replace(/"/g, '')}", "PingFang TC", -apple-system, sans-serif`);
        st.setProperty('--body-size', (+t.bodySize || 15).toFixed(2) + 'px');
        st.setProperty('--body-weight', String(t.bodyWeight || 400));
        st.setProperty('--mono-size', ((+t.bodySize || 15) * 0.9).toFixed(2) + 'px');
      } else {
        for (const k of ['--sans', '--body-size', '--body-weight']) st.removeProperty(k);
      }
      let dark = t.dark;
      if (dark == null && t.bg) { const rgb = hexToRgb(t.bg); dark = rgb ? lum(rgb) < 0.3 : true; }
      document.documentElement.dataset.theme = dark ? 'dark' : 'light';
      st.colorScheme = dark ? 'dark' : 'light';
    },
    history(records) {
      resetState();
      const prevHl = S.historyMode;
      S.historyMode = true;
      S.bulk = true;   // 整批載入：組直接收起，不做動畫、不量位置
      for (const r of records || []) {
        if (r && r.type === 'wbDivider') { S.ctxMain.endTurn(); notice(r.text, 'divider'); continue; }   // 換過模型：各家紀錄接起來的分隔線
        if (!r || (r.type !== 'user' && r.type !== 'assistant')) continue;
        if (r.isMeta || r.isSidechain || r.isVisibleInTranscriptOnly) continue;
        if (r.cwd && !S.cwd) { S.cwd = r.cwd; guessHome(r.cwd); }
        if (r.isCompactSummary) { notice(L('（較早的對話已壓縮成摘要）')); continue; }
        try { handle(r, false); } catch (e) { console.error('history', e); }
      }
      // 舊對話沒結果的工具：不要一直轉圈
      for (const c of S.tools.values()) if (c.state === 'running' && c.setState) { c.setState('stopped'); c.refreshHead(); }
      S.ctxMain.endTurn();
      S.historyMode = prevHl;
      S.bulk = false;
      S.following = true;
      stick();
      raf(stick);
    },
    // 同步顯示（對話在別處進行）：把紀錄檔新長出來的記錄接在後面，不清空畫面
    historyAppend(records) {
      const prevHl = S.historyMode;
      S.historyMode = true;
      S.batch++;   // 這一批新長出來的組直接收起；之前就在畫面上的組照常（可動畫、補捲動位置）
      for (const r of records || []) {
        if (!r || (r.type !== 'user' && r.type !== 'assistant')) continue;
        if (r.isMeta || r.isSidechain || r.isVisibleInTranscriptOnly) continue;
        if (r.cwd && !S.cwd) { S.cwd = r.cwd; guessHome(r.cwd); }
        if (r.isCompactSummary) { notice(L('（較早的對話已壓縮成摘要）')); continue; }
        try { handle(r, false); } catch (e) { console.error('historyAppend', e); }
      }
      S.batch++;
      S.historyMode = prevHl;
      stick();
    },
    event(o) {
      if (typeof o === 'string') { try { o = JSON.parse(o); } catch (_) { return; } }
      try { handle(o, true); } catch (e) { console.error('wb.event', e, o); }
    },
    localUser(m) {
      m = m || {};
      if (m.queued && m.uuid) {
        const t = userBubble(m.text || '', m.images || [], { queued: true });
        queued.set(m.uuid, t);
        queueNote(t, m.uuid, !!m.now);
      } else {
        S.interrupted = false;
        userBubble(m.text || '', m.images || []);
      }
      // 送出＝扣上卡扣：之後 Claude 的思考、回覆一直貼在最新一行，直到使用者自己往上捲
      S.magnet = true;
      S.following = true;
      S.jumping = false;
      S.userScrollAt = 0;
      stick();
      updateJump();
    },
    // Claude 讀進了這則（回送）：從排隊區移進對話
    userTaken(uuid) {
      S.interrupted = false;   // 讀進了新的訊息：新的一輪開始
      unconfirmed.delete(uuid);
      const t = queued.get(uuid);
      if (!t) return;
      queued.delete(uuid);
      takeQueued(t);
      stick();
    },
    // 這一輪結束：還在排隊的照順序移進對話（Claude 接著就會讀）
    // 輸入框是空的按 ⌃ Enter：排隊中的訊息全部馬上插話（跟按每則的「馬上插話」一樣）
    sendQueuedNow() {
      for (const [uuid, t] of queued) { queueNote(t, uuid, true); post({ type: 'sendNow', uuid }); }
      return queued.size;
    },
    // 程序結束：還沒被讀進去的（排隊中的、剛移進對話還沒確認的）都沒送到
    flushQueued() {
      if (!queued.size && !unconfirmed.size) return;
      for (const t of queued.values()) { takeQueued(t); markLost(t); }
      for (const t of unconfirmed.values()) markLost(t);
      queued.clear();
      unconfirmed.clear();
      stick();
    },
    permissionResolved(id, note) {
      const p = S.perms.get(id);
      if (p) p.resolved(note);
    },
    resolveAllPermissions(note) {
      for (const p of S.perms.values()) if (p.resolved) p.resolved(note);
    },
    setBusy(b) {
      S.busy = !!b;
      typing.hidden = !S.busy;
      clearInterval(busyTimer);
      clearInterval(followGuard);
      if (S.busy) {
        if (S.following && !S.jumping) S.magnet = true;   // 不管這輪是誰開始的（別處傳來的訊息也算），本來在底就扣上
        let logged = false;
        followGuard = setInterval(() => {
          if (!S.following || S.jumping || distFromBottom() <= 2) return;
          if (!logged) { logged = true; scrollLog('補貼底（照理該在底卻不在）'); }
          stick();
        }, 200);
        S.busySince = Date.now();
        const s = typing.querySelector('.typing-s');
        s.textContent = '';
        busyTimer = setInterval(() => {
          const sec = Math.floor((Date.now() - S.busySince) / 1000);
          s.textContent = sec >= 3 ? fmtDur(sec * 1000).replace(/\.0 /, ' ') : '';
        }, 1000);
      } else {
        // 停下來時還在轉圈的思考收起來
        for (const m of S.ctxMain.msgs.values()) for (const b of m.blocks) if (b.type === 'thinking' && !b.final) b.finish(null, true);
        S.ctxMain.closeGroup(true);
      }
      stick();
    },
    notice(text) { notice(String(text || '')); stick(); },
    // 右下角桌寵空位：最底下留高度、「↓ 最新」讓開寬度（0 0＝沒有空位）
    // 程式碼顏色（設定頁）：{keyword, type, function, string, number, attr, comment} → #RRGGBB；null＝照 iTerm 的 ANSI 顏色
    setCodeColors(map) {
      const st = document.documentElement.style;
      for (const k of ['keyword', 'type', 'function', 'string', 'number', 'attr', 'comment']) {
        if (map && map[k]) st.setProperty('--code-' + k, map[k]); else st.removeProperty('--code-' + k);
      }
      if (map) document.documentElement.dataset.codeCustom = '1'; else delete document.documentElement.dataset.codeCustom;
    },
    // 右下角桌寵空位的大小（只用來讓「↓ 最新」按鈕讓開）
    setPetInset(w, h) {
      petW = Math.max(0, w | 0); petH = Math.max(0, h | 0);
      applyPet();
    },
    // 放在最上面的提示（例如「前面還有 N 則沒載入」）
    noticeTop(text) { const n = el('div', 'notice', String(text || '')); log.insertBefore(n, log.firstChild); },
    // 往上捲載入更早的：先排在看不見的暫存區，排好整塊插到最上面，捲動位置補回同樣的高度（畫面不跳）
    // more＝再更早還有沒有；沒有了就把頂端的提示拿掉
    historyPrepend(records, more) {
      const box = el('div');
      const saveLog = log, saveCtx = S.ctxMain, prevHl = S.historyMode, prevFollow = S.following;
      log = box; S.ctxMain = new Ctx(box, true); S.historyMode = true; S.following = false;
      try {
        for (const r of records || []) {
          if (r && r.type === 'wbDivider') { S.ctxMain.endTurn(); notice(r.text, 'divider'); continue; }
          if (!r || (r.type !== 'user' && r.type !== 'assistant')) continue;
          if (r.isMeta || r.isSidechain || r.isVisibleInTranscriptOnly) continue;
          if (r.isCompactSummary) { notice(L('（較早的對話已壓縮成摘要）')); continue; }
          try { handle(r, false); } catch (e) { console.error('historyPrepend', e); }
        }
        S.ctxMain.endTurn();
        // 結果在比較新的那頁（已經載過、當時還沒有這張卡）：不要一直轉圈
        for (const c of S.tools.values()) if (c.state === 'running' && c.setState && c.el && box.contains(c.el)) { c.setState('stopped'); c.refreshHead(); }
      } finally {
        log = saveLog; S.ctxMain = saveCtx; S.historyMode = prevHl; S.following = prevFollow;
      }
      const s = sc(), before = s.scrollHeight, top = s.scrollTop;
      const old = log.querySelector('.notice.more-top');
      if (old) old.remove();
      const first = log.firstChild;
      while (box.firstChild) log.insertBefore(box.firstChild, first);
      if (more) wb.moreAbove();
      s.scrollTop = top + (s.scrollHeight - before);
      S.loadingOlder = false;
    },
    // 最上面放「往上捲載入更早的訊息」，捲到頂端附近就跟 App 要
    scrollEdge(top) {
      if (!top) { jumpToBottom(); return; }
      release('⌘ ↑');
      S.following = false;
      S.jumping = false;
      const s = sc();
      if (s.scrollTop <= 2 && S.hasOlder && !S.loadingOlder) {
        S.loadingOlder = true;
        const n = log.querySelector('.notice.more-top');
        if (n) n.textContent = L('載入更早的訊息…');
        post({ type: 'loadOlder' });
      } else s.scrollTop = 0;
      S.lastScrollTop = s.scrollTop;
      updateJump();
    },
    moreAbove() {
      if (log.querySelector('.notice.more-top')) return;
      const n = el('div', 'notice more-top', L('往上捲可以載入更早的訊息'));
      log.insertBefore(n, log.firstChild);
      S.hasOlder = true;
    },
    noMoreAbove() { const n = log.querySelector('.notice.more-top'); if (n) n.remove(); S.hasOlder = false; S.loadingOlder = false; },
    // 網頁端補充：清空畫面（換對話時用）
    clear() { resetState(); },
  };
  function resetState() {
    log.innerHTML = '';
    S.tools.clear();
    S.perms.clear();
    S.animating.clear();
    S.deferred.clear();
    S.ctxMain = new Ctx(log, true);
    S.interrupted = false;
    updateJump();
  }

  // ───────────────────────── 點擊：連結、路徑、複製、圖片 ─────────────────────────
  function copyText(text, btn) {
    const done = () => {
      if (!btn) return;
      // 圖示鈕：換成打勾一下；文字鈕：換成「已複製」
      if (btn.classList.contains('icon-btn')) { btn.classList.add('done'); setTimeout(() => btn.classList.remove('done'), 1200); return; }
      btn.textContent = L('已複製'); setTimeout(() => { btn.textContent = L('複製'); }, 1200);
    };
    if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(text).then(done, () => fallback()); return; }
    fallback();
    function fallback() {
      const ta = document.body.appendChild(el('textarea'));
      ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
      ta.select();
      try { document.execCommand('copy'); done(); } catch (_) {}
      ta.remove();
    }
  }
  document.addEventListener('click', (e) => {
    const tc = e.target.closest('.turn-copy');
    if (tc) { const t = tc.closest('.turn'); if (t) copyText(turnTexts(t).join('\n\n'), tc); return; }
    const copy = e.target.closest('.copy');
    if (copy) { const c = copy.closest('.code').querySelector('pre'); copyText(c.textContent, copy); return; }
    const a = e.target.closest('a[href]');
    if (a) {
      e.preventDefault();
      const href = a.getAttribute('href');
      if (/^(https?|mailto):/i.test(href)) post({ type: 'openURL', url: href });
      else if (/^#/.test(href)) return;
      else post({ type: 'open', path: absPath(href) });
      return;
    }
    const p = e.target.closest('.path[data-path]');
    if (p) { e.preventDefault(); e.stopPropagation(); post({ type: 'open', path: absPath(p.dataset.path) }); return; }
    const img = e.target.closest('.imgs img, .md img');
    if (img) {
      lightbox.innerHTML = '';
      lightbox.appendChild(el('img')).src = img.src;
      lightbox.hidden = false;
    }
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !lightbox.hidden) { lightbox.hidden = true; lightbox.innerHTML = ''; } });

  // ───────────────────────── 啟動 ─────────────────────────
  function boot() {
    buildSkeleton();
    initScroll();
    window.wb = wb;
    post({ type: 'ready' });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
