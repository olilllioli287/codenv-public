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
