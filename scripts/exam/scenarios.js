/* 由 test.html?exam=Bxx 載入；使用實際 wb 介面，不暴露或改寫內部狀態。 */
window.runExamScenario = async function (id) {
  const check = (ok, message) => { if (!ok) throw Error('EXAM_ASSERT: ' + message); };
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const until = async (fn, message) => {
    const end = performance.now() + 8000;
    while (!fn()) { check(performance.now() < end, message); await wait(25); }
  };
  const turn = text => [...document.querySelectorAll('.turn.user')].find(t => t.textContent.includes(text));
  const dist = () => { const s = document.scrollingElement; return s.scrollHeight - s.clientHeight - s.scrollTop; };
  window.__exam = { stage: 'running', details: [] };
  try {
    wb.history([]);
    if (id === 'B01') {
      const mid = 'exam-math';
      const text = String.raw`圓 $$y=\pm\sqrt{25-x^2}$$

$$\frac{d}{dx}[y^2]=2y\frac{dy}{dx}$$

所以 $\frac{dy}{dx}=-\frac{x}{y}$；拋物線 $$y=x^2+1$$。

- 清單 $x^2$
- 價格 $5 和 $10`;
      const event = e => wb.event({ type: 'stream_event', event: e, parent_tool_use_id: null, api_message_id: mid });
      wb.localUser({ uuid: 'math-user', text: '教我微分' });
      wb.setBusy(true);
      event({ type: 'message_start', message: { id: mid } });
      event({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
      for (let i = 0; i < text.length; i += 3) event({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: text.slice(i, i + 3) } });
      await until(() => document.querySelector('main').textContent.includes('$10'), '串流文字未完整呈現');
      check(document.querySelectorAll('.katex').length === 5, '完成前公式數量=' + document.querySelectorAll('.katex').length + '，預期 5');
      check(!document.querySelector('main').textContent.includes('WBMATHPLACEHOLDER'), '佔位字外露');
      check(document.querySelector('main').textContent.includes('$5 和 $10'), '價格被吃掉');
      window.__exam.details.push('final 前 5 個公式，價格保留');
      event({ type: 'content_block_stop', index: 0 });
      wb.event({ type: 'assistant', message: { id: mid, role: 'assistant', content: [{ type: 'text', text }] } });
      wb.event({ type: 'result', subtype: 'success', is_error: false });
      wb.setBusy(false);
      await wait(200);
      check(document.querySelectorAll('.katex').length === 5, '完成後公式重複／遺失');
      check(!document.querySelector('main').textContent.includes('WBMATHPLACEHOLDER'), '完成後佔位字外露');
      check(!document.querySelector('.streaming'), '完成後串流游標殘留');
    } else if (id === 'B12') {
      wb.localUser({ uuid: 'busy-user', text: '測試計時結束' });
      wb.setBusy(true);
      await wait(1100);
      check(!document.querySelector('.typing').hidden, '忙碌時沒有顯示狀態列');
      wb.event({ type: 'result', subtype: 'success', is_error: false });
      wb.setBusy(false);
      check(document.querySelector('.typing').hidden, 'result 後狀態列仍顯示');
      check(document.querySelector('.typing-s').textContent === '', 'result 後計時文字未清除');
      wb.event({ type: 'user', message: { role: 'user', content: '<task-notification><summary>背景工作</summary><status>completed</status></task-notification>' } });
      await wait(1100);
      check(document.querySelector('.typing').hidden, '背景工作通知重新顯示忙碌計時');
      check(document.querySelector('.typing-s').textContent === '', '背景工作通知重新啟動計時');
      window.__exam.details.push('result 清除計時；背景工作完成通知不重啟');
    } else if (id === 'B10') {
      wb.localUser({ uuid: 'other', text: '保留另一則' });
      wb.localUser({ uuid: 'queued-1', text: '排隊一', queued: true });
      wb.flushQueued(); wb.flushQueued();
      const first = turn('排隊一');
      check(first?.classList.contains('lost'), '未讀排隊訊息沒有 lost');
      check(first.querySelectorAll('.queued-note').length === 1 && first.textContent.includes('沒送到'), '提示缺少／重複');
      first.querySelector('button.queued-now').click();
      check(!turn('排隊一') && !!turn('保留另一則'), '刪除影響其他泡泡');
      wb.localUser({ uuid: 'queued-2', text: '已移入未讀', queued: true });
      wb.event({ type: 'result', subtype: 'success', is_error: false });
      wb.flushQueued();
      check(turn('已移入未讀')?.classList.contains('lost'), 'result 後尚未讀取就退出卻未標 lost');
      wb.localUser({ uuid: 'queued-3', text: '已讀取', queued: true });
      wb.event({ type: 'result', subtype: 'success', is_error: false });
      wb.userTaken('queued-3'); wb.flushQueued();
      check(!turn('已讀取')?.classList.contains('lost'), '已讀取被誤標 lost');
    } else if (id === 'B12') {
      // 對應 Codex app-server 的 turn/interrupt → turn/completed(interrupted)。
      // 原生 JSON-RPC 由 C21 的 fake app-server fixture 覆蓋；這裡驗畫面收到結束事件後解除 busy。
      const mid = 'exam-codex-interrupt';
      const event = e => wb.event({ type: 'stream_event', event: e, parent_tool_use_id: null, api_message_id: mid });
      wb.localUser({ uuid: 'codex-interrupt-user', text: 'Codex 中斷考題' });
      wb.setBusy(true);
      event({ type: 'message_start', message: { id: mid } });
      event({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
      event({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '中斷前已收到的部分回覆' } });
      await until(() => document.querySelector('main').textContent.includes('中斷前已收到'), 'Codex 中斷前的部分輸出未呈現');
      event({ type: 'content_block_stop', index: 0 });
      wb.event({ type: 'user', message: { role: 'user', content: '[Request interrupted by user]' } });
      wb.event({ type: 'result', subtype: 'error_during_execution', is_error: true });
      wb.setBusy(false);
      await wait(100);
      check(!document.querySelector('.streaming'), 'interrupted 收尾後仍有串流游標');
      check(document.querySelector('main').textContent.includes('中斷前已收到的部分回覆'), '中斷前已收到的內容被清掉');
      window.__exam.details.push('interrupted 結束生成狀態並保留部分回覆；JSON-RPC 由 C21 覆蓋');
    } else if (id === 'B04') {
      wb.history([{ type: 'user', message: { content: '歷史內容縮短測試' } }]);
      const pad = document.createElement('div');
      pad.style.cssText = 'height:3200px;overflow-anchor:none';
      document.querySelector('main').appendChild(pad);
      await wait(250);
      wb.setBusy(true);
      await wait(300);
      check(dist() <= 2, '前置條件：沒有貼底');
      const s = document.scrollingElement, before = s.scrollTop;
      // 同一個排版週期先縮短再長回：強制讀取 scrollTop 以確認瀏覽器真的夾了位置。
      pad.style.height = '100px';
      const clamped = s.scrollTop;
      pad.style.height = '3200px';
      void s.scrollHeight;
      check(clamped < before - 100, '前置條件：瀏覽器未夾捲動位置');
      await wait(500);
      check(dist() <= 2, '內容長回後未貼底：' + dist());
      check(!(window.__posted || []).some(m => m.type === 'scrollLog' && /不跟了|放開卡扣/.test(m.text)), '無使用者操作卻解除追隨');
      window.__exam.details.push('位置由 ' + before + ' 夾到 ' + clamped + '，長回仍貼底');
      window.__exam.stage = 'wheel';
      await until(() => window.__wheelSent && dist() > 200, 'CDP 真實向上滾輪沒有生效');
      await wait(450);
      const top = s.scrollTop;
      pad.style.height = '3800px';
      await wait(500);
      check(Math.abs(s.scrollTop - top) <= 3 && dist() > 200, '真實向上捲後仍被拉回底');
      wb.scrollEdge(false);
      await wait(900);
      check(dist() <= 2, '回到底後沒有恢復追隨');
      pad.style.height = '4200px';
      await wait(300);
      check(dist() <= 2, '恢復追隨後新增內容未貼底');
      wb.setBusy(false);
    } else if (id === 'C330') {
      const userText = 'C330 使用者引用樣本';
      const assistantText = 'C330 助理引用樣本';
      const userId = 'c330-user';
      const assistantId = 'c330-assistant';
      wb.localUser({ uuid: userId, text: userText });
      wb.setBusy(true);
      const event = e => wb.event({ type: 'stream_event', event: e, parent_tool_use_id: null, api_message_id: assistantId });
      event({ type: 'message_start', message: { id: assistantId } });
      event({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
      event({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: assistantText } });
      event({ type: 'content_block_stop', index: 0 });
      wb.event({ type: 'assistant', message: { id: assistantId, role: 'assistant', content: [{ type: 'text', text: assistantText }] } });
      wb.event({ type: 'result', subtype: 'success', is_error: false });
      wb.setBusy(false);

      const userTurn = () => turn(userText);
      const assistantTurn = () => [...document.querySelectorAll('.turn.assistant')].find(t => t.textContent.includes(assistantText));
      await until(() => userTurn()?.querySelector('.user-actions .quote-toggle') &&
        assistantTurn()?.querySelector('.turn-copy') && assistantTurn()?.querySelector('.quote-toggle'),
      '引用樣本 turn／按鈕未建立');
      await until(() => {
        const row = assistantTurn();
        if (!row) return false;
        const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) if (walker.currentNode.textContent.includes('完成')) return true;
        return false;
      }, 'assistant 完成狀態文字未建立');

      const userQuote = userTurn().querySelector('.user-actions .quote-toggle');
      const assistant = assistantTurn();
      const assistantCopy = assistant.querySelector('.turn-copy');
      const assistantQuote = assistant.querySelector('.quote-toggle');
      const checkSvg = (button, label) => {
        check(button?.tagName === 'BUTTON', label + ' 是 button');
        check(button.getAttribute('aria-label') === '引用' && button.getAttribute('title') === '引用',
          label + ' aria-label／title 為「引用」');
        const svgs = [...button.querySelectorAll('svg')];
        const textWalker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
        let visibleTextOutsideSvg = false;
        while (textWalker.nextNode()) {
          const node = textWalker.currentNode;
          if (node.textContent.trim() && !node.parentElement.closest('svg')) visibleTextOutsideSvg = true;
        }
        check(svgs.length === 1 && !visibleTextOutsideSvg && !button.textContent.includes('❞'),
          label + ' 以單一 SVG 呈現且沒有純文字圖示');
        if (svgs.length !== 1) return;
        const svg = svgs[0];
        check(svg.getAttribute('viewBox') === '0 0 16 16' && svg.getAttribute('aria-hidden') === 'true',
          label + ' SVG viewBox／aria-hidden 正確');
        const shapes = [svg, ...svg.querySelectorAll('*')];
        const hasNoFill = shapes.some(node => node.getAttribute('fill')?.toLowerCase() === 'none' ||
          getComputedStyle(node).fill === 'none');
        const hasStrokeWidth = shapes.some(node => {
          const width = parseFloat(getComputedStyle(node).strokeWidth || node.getAttribute('stroke-width'));
          return Number.isFinite(width) && Math.abs(width - 1.4) < 0.01;
        });
        const iconStyle = getComputedStyle(svg);
        check(hasNoFill && hasStrokeWidth, label + ' SVG 使用 fill:none／stroke-width:1.4');
        check(Math.abs(parseFloat(iconStyle.width) - 15) < 0.01 &&
          Math.abs(parseFloat(iconStyle.height) - 15) < 0.01,
        label + ' SVG 計算尺寸為 15×15px');
      };
      checkSvg(userQuote, '使用者泡泡引用鍵');
      checkSvg(assistantQuote, 'assistant footer 引用鍵');

      const ordered = [];
      const walker = document.createTreeWalker(assistant, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) ordered.push(walker.currentNode);
      const copyIndex = ordered.indexOf(assistantCopy);
      const quoteIndex = ordered.indexOf(assistantQuote);
      const statusIndex = ordered.findIndex(node => node.nodeType === Node.TEXT_NODE && node.textContent.includes('完成'));
      check(copyIndex >= 0 && copyIndex < quoteIndex && quoteIndex < statusIndex,
        'assistant footer DOM 順序為複製鍵、引用鍵、完成狀態文字');

      for (const [button, label] of [[userQuote, '使用者泡泡'], [assistantQuote, 'assistant footer']]) {
        const style = getComputedStyle(button);
        const width = parseFloat(style.width), height = parseFloat(style.height);
        const noBorder = ['Top', 'Right', 'Bottom', 'Left'].every(side => parseFloat(style['border' + side + 'Width']) === 0);
        const transparent = style.backgroundColor === 'transparent' ||
          /rgba\([^)]*,\s*0(?:\.0+)?\s*\)$/.test(style.backgroundColor);
        check(width >= 32 && height >= 32 && noBorder && transparent,
          label + ' 計算樣式為至少 32px、border 0、未引用背景透明');
        check(button.getAttribute('aria-pressed') === 'false' && !button.closest('.turn').classList.contains('quoted'),
          label + ' 初始 aria-pressed 與未引用狀態相符');
      }

      const setPointer = async (id, x, y) => {
        window.__exam.pointerRequest = { id, x, y };
        await until(() => window.__exam.pointerAck === id, '瀏覽器指標事件未完成');
        await wait(40);
      };
      await setPointer(1, 899, 799);
      check(!userTurn().matches(':hover') && !assistant.matches(':hover'), '基準狀態兩個 turn 都未 hover');
      const userIdleOpacity = parseFloat(getComputedStyle(userQuote).opacity);
      const assistantIdleOpacity = parseFloat(getComputedStyle(assistantQuote).opacity);
      check(Number.isFinite(userIdleOpacity) && Number.isFinite(assistantIdleOpacity), '預設 opacity 可計算');

      let box = assistantQuote.getBoundingClientRect();
      await setPointer(2, box.left + box.width / 2, box.top + box.height / 2);
      const assistantHoverOpacity = parseFloat(getComputedStyle(assistantQuote).opacity);
      check(assistant.matches(':hover') && assistantQuote.matches(':hover') &&
        Math.abs(assistantHoverOpacity - 1) < 0.01 &&
        getComputedStyle(assistantQuote).visibility !== 'hidden' && assistantQuote.getClientRects().length > 0,
      '未引用 assistant 引用鍵 hover 時 opacity 為 1 且可見');
      await setPointer(3, 899, 799);
      const assistantIdleStyle = getComputedStyle(assistantQuote);
      check(!assistant.matches(':hover') && Math.abs(parseFloat(assistantIdleStyle.opacity) - 1) < 0.01 &&
        assistantIdleStyle.visibility !== 'hidden' && assistantQuote.getClientRects().length > 0,
        'assistant hover 結束後仍維持 opacity 1 且可見');

      box = userQuote.getBoundingClientRect();
      await setPointer(4, box.left + box.width / 2, box.top + box.height / 2);
      const userHoverOpacity = parseFloat(getComputedStyle(userQuote).opacity);
      check(userTurn().matches(':hover') && userQuote.matches(':hover') && userHoverOpacity >= userIdleOpacity,
        '使用者泡泡沿用 turn hover 顯示');
      await setPointer(5, 899, 799);
      check(!userTurn().matches(':hover') &&
        Math.abs(parseFloat(getComputedStyle(userQuote).opacity) - userIdleOpacity) < 0.01,
      '使用者泡泡 hover 後恢復原預設 opacity');

      const focusables = [...document.querySelectorAll('button, input, textarea, select, [tabindex]:not([tabindex="-1"])')]
        .filter(node => !node.disabled && node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden');
      const focusIndex = focusables.indexOf(assistantQuote);
      check(focusIndex > 0, 'assistant 引用鍵有前一個可聚焦元素，能用鍵盤 Tab 進入');
      focusables[focusIndex - 1].focus();
      window.__exam.keyboardRequest = { id: 1, key: 'Tab', shiftKey: false };
      await until(() => window.__exam.keyboardAck === 1, '瀏覽器 Tab 事件未完成');
      await until(() => document.activeElement === assistantQuote, 'Tab 未移到 assistant 引用鍵');
      const focusStyle = getComputedStyle(assistantQuote);
      check(assistant.matches(':focus-within') && Math.abs(parseFloat(focusStyle.opacity) - 1) < 0.01 &&
        focusStyle.visibility !== 'hidden' && assistantQuote.getClientRects().length > 0,
      'assistant 引用鍵 focus-within 時 opacity 為 1 且可見');
      check(assistantQuote.matches(':focus-visible') && parseFloat(focusStyle.outlineWidth) > 0 &&
        focusStyle.outlineStyle !== 'none' && focusStyle.outlineColor !== 'rgba(0, 0, 0, 0)',
      '鍵盤 focus-visible 保留 outline');

      assistantQuote.click();
      await until(() => assistantQuote.getAttribute('aria-pressed') === 'true' &&
        assistant.classList.contains('quoted') && document.querySelectorAll('.quote-tray .quote-chip').length === 1,
      '引用 assistant 後 aria／狀態／tray 未同步');
      const pressedStyle = getComputedStyle(assistantQuote);
      const variableNames = new Set();
      for (let node = assistantQuote; node; node = node.parentElement) {
        const style = getComputedStyle(node);
        for (let index = 0; index < style.length; index++) {
          const name = style.item(index);
          if (name.startsWith('--') && name.toLowerCase().includes('accent')) variableNames.add(name);
        }
      }
      const tokenValue = (name, property) => {
        const probe = document.createElement('span');
        probe.style.cssText = 'position:absolute;visibility:hidden;pointer-events:none';
        assistantQuote.append(probe);
        probe.style.setProperty(property, `var(${name})`);
        const value = getComputedStyle(probe).getPropertyValue(property).trim();
        probe.remove();
        return value;
      };
      const accentVars = [...variableNames].filter(name => !name.toLowerCase().includes('soft'));
      const softAccentVars = [...variableNames].filter(name => name.toLowerCase().includes('soft'));
      const accentMatch = accentVars.some(name => tokenValue(name, 'color') === pressedStyle.color);
      const softAccentMatch = softAccentVars.some(name => tokenValue(name, 'background-color') === pressedStyle.backgroundColor);
      check(accentMatch && softAccentMatch,
        '已引用計算樣式使用 accent 文字與 accent-soft 背景');
      assistantQuote.blur();
      await setPointer(6, 899, 799);
      const quotedStyle = getComputedStyle(assistantQuote);
      check(!assistant.matches(':focus-within') && assistant.classList.contains('quoted') &&
        Math.abs(parseFloat(quotedStyle.opacity) - 1) < 0.01 &&
        quotedStyle.visibility !== 'hidden' && assistantQuote.getClientRects().length > 0,
      '已引用 .quoted 狀態 opacity 為 1 且可見');

      userQuote.click();
      await until(() => userQuote.getAttribute('aria-pressed') === 'true' &&
        userTurn().classList.contains('quoted') && document.querySelectorAll('.quote-tray .quote-chip').length === 2,
      '引用使用者泡泡後 tray 未增加第二項');
      assistantQuote.click();
      await until(() => assistantQuote.getAttribute('aria-pressed') === 'false' &&
        !assistant.classList.contains('quoted') && userQuote.getAttribute('aria-pressed') === 'true' &&
        document.querySelectorAll('.quote-tray .quote-chip').length === 1,
      '取消 assistant 引用後只移除該 tray 項目');
      userQuote.click();
      await until(() => userQuote.getAttribute('aria-pressed') === 'false' &&
        !userTurn().classList.contains('quoted') && document.querySelectorAll('.quote-tray .quote-chip').length === 0,
      '取消使用者引用後 tray 清空');
      window.__exam.details.push('C330 DOM、SVG、aria／tray、計算樣式、hover／focus-visible／quoted 顯示斷言完成');
    } else if (id === 'C62') {
      check(false, 'C62 是 Node 純邏輯案例，請使用 logic.mjs');
    } else throw Error('未知案例：' + id);
    window.__exam.stage = 'passed';
  } catch (error) {
    window.__exam.error = error.stack || String(error);
    window.__exam.stage = 'failed';
  } finally {
    window.__done = true;
  }
};
