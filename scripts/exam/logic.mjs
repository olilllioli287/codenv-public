import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import dom from './dom.cjs';
const [id, root] = process.argv.slice(2);
const base = path.join(root, 'Resources/chat');
const source = readFileSync(path.join(base, 'chat.js'), 'utf8');
const eq = (actual, expected, message) => assert.deepEqual(JSON.parse(JSON.stringify(actual)), expected, message);
if (id === 'C100') {
  const host = readFileSync(path.join(root, 'Sources/Workbench/WindowHost.swift'), 'utf8');
  assert.match(host, /guard !window\.renamed, let root = window\.root/);
  assert.match(host, /ids\.count == 1 \? name : "\\\(name\) ＋\\\(ids\.count - 1\)"/);
  assert.match(host, /store\.conversation\(selected\)\?\.title/);
} else if (id === 'C101') {
  const js = readFileSync(path.join(root, 'Resources/chat/chat.js'), 'utf8');
  const pane = readFileSync(path.join(root, 'Sources/Workbench/ChatPane.swift'), 'utf8');
  assert.match(js, /typing\.querySelector\('\.typing-t'\)/);
  assert.match(js, /`\$\{S\.agent\} 正在處理`/);
  assert.match(js, /m\.startsWith\('gemini'\).*'agy'/);
  assert.match(js, /setAgent\(name\)/);
  assert.match(pane, /session\.codexModel != nil \? "Codex"/);
  assert.match(pane, /session\.agyModel != nil \? "agy"/);
} else if (id === 'C102') {
  const timers = readFileSync(path.join(root, 'Sources/Workbench/PetTimers.swift'), 'utf8');
  assert.match(timers, /let visibleHeight = max\(geo\.size\.height, CGFloat\(items\.count\) \* Self\.rowH\)/);
  assert.doesNotMatch(timers, /Text\(L\("＋/);
  assert.match(timers, /ForEach\(Array\(items\.reversed\(\)\)/);
  const host = readFileSync(path.join(root, 'Sources/Workbench/WindowHost.swift'), 'utf8');
  assert.match(timers, /PetTimers\.shared\.model\.tasks\.count\) \* PetTimersView\.rowH/);
} else if (id === 'C103') {
  const timers = readFileSync(path.join(root, 'Sources/Workbench/PetTimers.swift'), 'utf8');
  assert.match(timers, /struct ProgressHistoryEntry: Codable/);
  assert.match(timers, /static let emaAlpha = 0\.3/);
  assert.match(timers, /done <= 3/);
  assert.match(timers, /historicSecondsPerItem \?\? \(done > 0 \? elapsed \/ Double\(done\) : nil\)/);
  assert.match(timers, /historyURL/);
} else if (id === 'C104') {
  const activity = readFileSync(path.join(root, 'Sources/Workbench/Activity.swift'), 'utf8');
  assert.match(activity, /lastClaudePIDs\[id\] = p/);
  assert.match(activity, /ProcessScan\.scan\(claudePIDs: pids\)/);
  assert.match(activity, /等背景任務/);
} else if (id === 'C105') {
  const usage = readFileSync(path.join(root, 'Sources/Workbench/Usage.swift'), 'utf8');
  assert.match(usage, /s\.contains\("argon"\) \{ return "argonWeek" \}/);
  assert.match(usage, /previous\.remaining <= clamped/);
  const modern = JSON.parse(readFileSync(path.join(root, 'scripts/exam/dev/fixtures-magpie-real-1109.json'), 'utf8'));
  const legacy = JSON.parse(readFileSync(path.join(root, 'scripts/exam/dev/fixtures/magpie-accounts.json'), 'utf8'));
  assert.ok(JSON.stringify(modern).includes('Gemini 4 Argon (High)'));
  assert.ok(JSON.stringify(modern).includes('Gemini 4 Argon · 7 days'));
  assert.ok(JSON.stringify(legacy).includes('"pool":"Argon"'));
} else if (id === 'C106') {
  const usage = readFileSync(path.join(root, 'Sources/Workbench/Usage.swift'), 'utf8');
  const pools = readFileSync(path.join(root, 'Sources/Workbench/ExtraKeyPools.swift'), 'utf8');
  assert.match(usage, /ExtraKeyPools\.pools\(sources\)/);
  assert.match(usage, /KeyVault\.service\(\$0\)/);
  assert.match(pools, /api\/v1\/key/);
  assert.match(pools, /free_model_daily_requests/);
  assert.match(pools, /chat\/completions/);
  assert.match(pools, /"max_tokens": 1/);
  assert.match(pools, /ttl: TimeInterval = 30 \* 60/);
  assert.match(pools, /failureTTL: TimeInterval = 10 \* 60/);
  assert.match(pools, /NSCondition\(\)/);
  assert.match(pools, /groq-probe-cache\.json/);
  assert.match(pools, /Edition\.support\("groq-probe-cache\.json"\)/);
  assert.match(pools, /firstIndex\(of: "--state-dir"\)/, '測試實例快取放在 --state-dir');
  assert.match(pools, /rateHeadersOnly/);
  assert.match(pools, /task\.cancel\(\)/, '探測逾時會取消 URLSessionTask');
  assert.match(pools, /pattern: "\^\(\?:/, '重置時間正規表示式使用起訖錨點');
  assert.match(pools, /1_000_000_000_000/, '轉 Int 前限制標頭數值範圍');
  assert.match(pools, /groqProbeModels = \["openai\/gpt-oss-20b", "qwen\/qwen3\.8-27b"\]/);
  assert.match(pools, /沒權限讀金鑰（鑰匙圈）/);
  assert.match(pools, /case \.missing: return nil/);
  assert.match(usage, /本機資料尚未提供/);
  assert.doesNotMatch(usage + pools, /Text\([^\n]*apiKey/);
  // 金鑰（變數 key）不准進 print／NSLog／Logger／字串插值輸出
  assert.doesNotMatch(pools, /(print|NSLog|debugPrint)\([^\n]*\bkey\b/);
  assert.match(usage, /magpie accounts codex/);
  assert.match(usage, /parseMagpieCodexAccounts/);
  assert.match(usage, /resolveCodexUsage\(magpieData: codexMagpieData, appServerResult: codexOut\)/);
  assert.match(usage, /plan\.lowercased\(\)\.contains\("plus"\)/);
  assert.match(usage, /CodexUsageAccountQuota\(id: account\.id, user: account\.user, plan: account\.plan, active: account\.active/);
  assert.match(usage, /String\(user\[\.\.\<at\]\.prefix\(3\)\) \+ "\*\*\*"/);
  assert.match(usage, /codexAccountsCard\(\)/);
  assert.match(usage, /if p == \.codex, !m\.codexAccounts\.isEmpty/);
  assert.match(usage, /ForEach\(paidAccounts\)/, 'Codex 付費帳號保留完整額度卡');
  assert.match(usage, /ForEach\(freeAccounts\)/, 'Codex 免費帳號集中顯示');
  assert.match(usage, /目前登入/);
  assert.match(usage, /account\.resetCredits/, '重置券顯示在所屬帳號卡片');
  assert.match(usage, /account\.resetExpiries\.map/, '卡片列出重置券到期時間');
  assert.match(usage, /codexGlanceItems\(accounts: codexAccounts, fallback: codexBuckets\)/);
  assert.match(usage, /let week = L\("每週"\), five = L\("5 小時"\)/);
  assert.match(usage, /standardGlanceItems\("Claude"/);
  const codexAccounts = JSON.parse(readFileSync(path.join(root, 'scripts/exam/dev/fixtures/codex-magpie-accounts.json'), 'utf8'));
  assert.equal(codexAccounts.length, 4);
  assert.equal(codexAccounts.filter(a => a.active).length, 1);
  assert.equal(codexAccounts.find(a => a.plan === 'plus').active, false, '付費帳號不是目前登入帳號');
  assert.deepEqual(codexAccounts.find(a => a.plan === 'plus').windows.map(w => w.remaining), [88, 6]);
} else if (id === 'C141') {
  const usage = readFileSync(path.join(root, 'Sources/Workbench/Usage.swift'), 'utf8');
  const harness = readFileSync(path.join(root, 'Sources/Workbench/TestHarness.swift'), 'utf8');
  const panel = readFileSync(path.join(root, 'Sources/Workbench/ModelPopover.swift'), 'utf8');
  assert.match(usage, /private struct UsageMasonryLayout: Layout/);
  // F12 規格 3 A：欄數公式加 0.5pt 容差（uiScale 1.15 的浮點誤差會把恰好 4.0 算成 3 欄）；其餘公式不變。
  assert.match(usage, /min\(4, max\(1, Int\(floor\(\(max\(0, width\) \+ gap \+ 0\.5\) \/ \(cardWidth \+ gap\)\)\)\)\)/);
  assert.match(usage, /bottoms\.indices\.min/);
  assert.match(usage, /UsageMasonryLayout\(cardWidth:/);
  assert.match(usage, /ForEach\(m\.extraKeyPools\)/, '額外用量卡也放進同一個瀑布流');
  assert.match(usage, /let paidAccounts = m\.codexAccounts\.filter \{ !\$0\.plan\.lowercased\(\)\.contains\("free"\) \}/);
  assert.match(usage, /Text\(L\("免費額度池（\\\(freeAccounts\.count\) 個帳號）"\)\)/);
  assert.match(usage, /codex:free-row:/);
  assert.match(usage, /Text\(account\.maskedUser\)/);
  assert.match(usage, /30 天額度/);
  assert.match(panel, /\[\.borderless, \.nonactivatingPanel, \.resizable\]/);
  assert.match(harness, /--usage-full-layout-probe/);
  assert.match(harness, /\(3, 3, nil\), \(5, 3, "wide\.png"\), \(5, 2, "narrow\.png"\)/);
} else if (id === 'C142') {
  const pools = readFileSync(path.join(root, 'Sources/Workbench/ExtraKeyPools.swift'), 'utf8');
  const usage = readFileSync(path.join(root, 'Sources/Workbench/Usage.swift'), 'utf8');
  const harness = readFileSync(path.join(root, 'Sources/Workbench/TestHarness.swift'), 'utf8');
  assert.match(usage, /PoolUsageSnapshot\.load/);
  assert.match(pools, /GroqProbeCache\.ttl/);
  assert.match(pools, /fetchKaggleQuota/);
  assert.match(pools, /out\.append\(opencodePool\(src\)\)/);
  assert.ok(pools.includes('PoolUsageSnapshot.clock(updated)) 使用時'), 'Groq 使用 shared updated_at 標示使用時間');
  assert.match(pools, /官方動態上限，查不到/);
  // 07-14 外部免費池金鑰的存在與讀取改走 security 子程序；C180 以假 security 驗其行為。
  assert.doesNotMatch(usage, /KeyVault\.status\(service: "(?:gemini-free-api|kaggle-api-token)"\)\.exists/,
    '外部免費池金鑰不得再依賴舊的 KeyVault.status 查詢形式');
  assert.match(harness, /--usage-poolcards-probe/);
} else if (id === 'C107') {
  const usage = readFileSync(path.join(root, 'Sources/Workbench/Usage.swift'), 'utf8');
  const fixture = JSON.parse(readFileSync(path.join(root, 'scripts/exam/dev/fixtures-magpie-real-1109.json'), 'utf8'));
  const poolKey = (pool, name) => {
    const s = `${pool} ${name}`.toLowerCase().replaceAll('·', ' ');
    if (s.includes('claude & gpt')) {
      if (/five hour|5 hour|5 小時|5h/.test(s)) return 'agyClaude5';
      if (/weekly|week|7 day|每週/.test(s)) return 'agyClaudeWeek';
      return null;
    }
    return null;
  };
  const keys = ['agyClaude5', 'agyClaudeWeek'];
  const expected = { agyClaude5: 100, agyClaudeWeek: 50 };
  const values = Object.fromEntries(keys.map(key => [key, []]));
  for (const account of fixture) for (const window of account.windows) {
    const key = poolKey(window.pool ?? '', window.name);
    if (key) values[key].push(window.remaining);
  }
  assert.deepEqual(Object.fromEntries(keys.map(key => [key, Math.round(values[key].reduce((a, b) => a + b, 0) / values[key].length)])), expected,
    'Claude & GPT 總池多帳號平均：5 小時 100%、每週 50%');
  assert.deepEqual(fixture[1].windows.filter(w => !w.pool && /Claude (?:Opus|Sonnet)/.test(w.name)).length, 6,
    '真實 fixture 有逐模型 Claude 窗口，不能誤當總池');
  assert.match(usage, /"agyClaude5": "agy Claude 5 小時"/);
  assert.match(usage, /"agyClaudeWeek": "agy Claude 每週"/);
  assert.match(usage, /if s\.contains\("claude & gpt"\)/);
  assert.match(usage, /for key in \["gemini5", "geminiWeek", "argonWeek", "agyClaude5", "agyClaudeWeek"\]/);
  assert.match(usage, /agyBuckets\.filter \{ !\$0\.label\.hasPrefix\("Claude"\)/,
    'agy Claude 標籤留在 Gemini（agy）卡片，不改既有 ClaudeAgy 池');
  assert.doesNotMatch(usage, /UsageGlanceItem\(tag: L\("agy CC"\)/, '底部列不再放 agy CC（11/10）；大卡片的 agy Claude 仍由上面的總池桶提供');
  assert.doesNotMatch(usage, /what: L\("agy Claude 每週"\)/, '底部列不再放 agy Claude 每週（11/10）');
  assert.match(usage, /多帳號依同一額度池的剩餘百分比平均；重置時間取最早。/);
} else if (id === 'C108') {
  const lid = readFileSync(path.join(root, 'Sources/Workbench/LidKeeper.swift'), 'utf8');
  const wiring = readFileSync(path.join(root, 'Sources/Workbench/LidWiring.swift'), 'utf8');
  const activity = readFileSync(path.join(root, 'Sources/Workbench/Activity.swift'), 'utf8');
  const harness = readFileSync(path.join(root, 'Sources/Workbench/TestHarness.swift'), 'utf8');
  assert.match(activity, /var activeIDs: Set<UUID>/, 'Activity 提供前景、背景與程序掃描中的聊天室');
  assert.match(wiring, /let activityIDs = SessionActivity\.shared\.activeIDs/);
  assert.match(wiring, /self\.store\.status\[\$0\.id\] == \.working \|\| activityIDs\.contains\(\$0\.id\)/,
    '各引擎回合與聊天室活動都列入工作狀態');
  assert.match(wiring, /case "codex": engine = "Codex"/);
  assert.match(wiring, /running\.filter\(\\\.background\)\.count/);
  assert.match(wiring, /等背景任務 \\\(backgroundCount\)/, '待命聊天室的背景程序會列入摘要');
  assert.match(wiring, /guard self\.store\.status\[id\] == \.working else \{ return false \}/,
    '背景子程序單獨活動時不送訊息喚醒待命聊天室');
  assert.match(lid, /在撐：" \+ items\.joined\(separator: "、"\)/, '闔蓋紀錄逐項列出正在撐的工作');
  assert.match(harness, /case "claude\+codex"/);
  assert.match(harness, /case "background"/);
} else if (id === 'C121') {
  // 底部列標籤與退路短寫由原生 C121 probe 實際讀取 NSTextField；此段保留 tooltip 和資料來源斷言。
  const usage = readFileSync(path.join(root, 'Sources/Workbench/Usage.swift'), 'utf8');
  const input = readFileSync(path.join(root, 'Sources/Workbench/ChatInputBar.swift'), 'utf8');
  const native = readFileSync(path.join(root, 'scripts/exam/native.sh'), 'utf8');
  const glanceStart = usage.indexOf('var glance: [UsageGlanceGroup]');
  const glance = usage.slice(glanceStart, usage.indexOf('return out', glanceStart));
  const strip = input.slice(input.indexOf('final class UsageGlanceStrip'), input.indexOf('final class ChatInputBar: NSView {'));
  assert.ok(glanceStart > 0 && glance.length > 300 && strip.length > 1000, '找得到 glance 與 UsageGlanceStrip');
  assert.doesNotMatch(glance, /agy CC|agy Claude/, '底部列沒有 agy Claude');
  const agyItems = usage.slice(usage.indexOf('static func agyGlanceItems'), usage.indexOf('/// gh 裝在 Homebrew'));
  assert.match(agyItems, /let available = buckets\.filter \{ !\$0\.label\.hasPrefix\("Claude"\) \}/,
    'agy 底部列先排除 Claude 額度');
  assert.match(agyItems, /if !available\.isEmpty \{ return available\.map/,
    'agy 缺少標準週期時的退路也只用排除 Claude 後的額度');
  // 方案 A 起 agy 組由 agyGlanceGroup() 產生（key 仍為 "agy"），glance 內以呼叫它排在 Codex 之後。
  const agyGroupFn = usage.slice(usage.indexOf('func agyGlanceGroup()'), usage.indexOf('func agyGlanceGroup()') + 4000);
  assert.ok(usage.indexOf('func agyGlanceGroup()') > 0 && /UsageGlanceGroup\(\s*key: "agy"/.test(agyGroupFn), 'agyGlanceGroup 產出 key 為 agy 的組');
  assert.ok(glance.indexOf('key: "cc"') < glance.indexOf('key: "codex"') && glance.indexOf('key: "codex"') < glance.indexOf('agyGlanceGroup()'), '底部列依序顯示 Claude、Codex、agy');
  assert.match(glance, /Self\.standardGlanceItems\("Claude", buckets: buckets, week: week, five: five\)/, 'cc 組委派給每週優先的標準額度列');
  assert.match(glance, /Self\.codexGlanceItems\(accounts: codexAccounts, fallback: codexBuckets\)/, 'codex 組使用帳號額度列');
  assert.match(agyGroupFn, /Self\.agyGlanceItems\(agyBuckets, tips: magpieQuotaTips, week: week, five: five\)/, 'agy 組（非換帳號模式）使用過濾 Claude 的專屬額度列');
  assert.match(agyGroupFn, /Self\.agyGlanceItems\(primary\?\.buckets \?\? \[\], tips: \[:\], week: week, five: five\)/, 'agy 組（換帳號模式）同樣使用過濾 Claude 的專屬額度列');
  const standardItems = usage.slice(usage.indexOf('static func standardGlanceItems'), usage.indexOf('static func agyGlanceItems'));
  assert.match(standardItems, /let weekly = buckets\.first[\s\S]*?fiveHour = buckets\.first[\s\S]*?return \[glanceItem\(weekly[\s\S]*?glanceItem\(fiveHour/,
    '標準額度列先每週再 5 小時');
  assert.match(agyItems, /glanceItem\(weekly, what: L\("agy Gemini 每週"\)/, 'agy 每週完整 tooltip 名稱');
  assert.match(agyItems, /glanceItem\(fiveHour, what: L\("agy Gemini 5 小時（Hydrogen 等共用）"\)/, 'agy 5 小時完整 tooltip 名稱');
  assert.match(agyItems, /glanceItem\(\$0, what: L\("agy 阿公（Argon）每週"\)/, 'agy Argon 完整 tooltip 名稱');
  assert.match(usage, /private static func compactGlanceLabel\(_ label: String\)/, '額度退路使用專門的短標籤轉換');
  assert.doesNotMatch(strip, /\btrack\b|\bfill\b|barW|barH|itemGap/, '底部列沒有長條');
  assert.match(strip, /static func levelColor\(_ remaining: Int\) -> NSColor/, '數字顏色有獨立函式');
  assert.match(strip, /remaining > 50 \? \.systemGreen : \(remaining >= 20 \? \.systemYellow : \.systemRed\)/, '綠／黃／紅門檻沿用 >50、20～50、<20');
  assert.match(input, /static let ctxRowH: CGFloat = 24/, '底部列兩行，列高 24（原本 16）');
  assert.match(usage, /"agyClaude5": "agy Claude 5 小時"/, '大卡片仍保留 agy Claude 總池');
  assert.match(native, /--usage-strip-probe/, 'native 案例用測試掛鉤讀底部列');
  // 上下文也是兩行：上排總上下文（上限）、下排已用；不再寫成「已用 / 上限」一行；字級跟用量共用同一組常數
  const ctx = input.slice(input.indexOf('final class ContextStrip'), input.indexOf('/// 輸入框下面「上下文」右邊的用量'));
  assert.ok(ctx.length > 500, '找得到 ContextStrip');
  assert.match(ctx, /total\.stringValue = limit\.map \{ ContextMonitor\.text\(\$0\) \} \?\? "—"/, '上排＝總上下文（上限）');
  assert.match(ctx, /value\.stringValue = tokens\.map \{ ContextMonitor\.text\(\$0\) \} \?\? "—"/, '下排＝目前已用');
  assert.doesNotMatch(ctx, / \/ "/, '不再把已用與上限寫成同一行');
  assert.match(ctx, /UsageGlanceStrip\.rowValueFont/, '上下文的數字字級跟右邊用量一樣');
  assert.match(ctx, /let ux = w \+ 16/, '用量從上下文兩行的右邊開始');
  assert.match(input, /static let rowLabelFont = NSFont\.systemFont\(ofSize: 9\)/, '兩行的小字字級 9');
} else if (id === 'C87') {
  const mode = readFileSync(path.join(root, 'Sources/Workbench/ChatSession.swift'), 'utf8');
  const pane = readFileSync(path.join(root, 'Sources/Workbench/ChatPane.swift'), 'utf8');
  const input = readFileSync(path.join(root, 'Sources/Workbench/ChatInputBar.swift'), 'utf8');
  const codex = readFileSync(path.join(root, 'Sources/Workbench/CodexBridge.swift'), 'utf8');
  const agy = readFileSync(path.join(root, 'Sources/Workbench/AgyBridge.swift'), 'utf8');
  const translations = JSON.parse(readFileSync(path.join(root, 'Resources/i18n/en.json'), 'utf8'));
  const hints = [
    ['claude', 'default', '每次都問（Claude）：執行需要權限的操作前會詢問'],
    ['claude', 'acceptEdits', '改檔不問（Claude）：自動接受檔案編輯；其他需要權限的操作仍會詢問'],
    ['claude', 'plan', '只規劃（Claude）：只讀探索與規劃，不修改檔案'],
    ['claude', 'auto', '自動（Claude）：使用 Claude Code 自動權限模式，由 Claude Code 判斷何時需要詢問'],
    ['claude', 'bypassPermissions', '全部不問（Claude）：略過權限提示，工具操作不逐次詢問'],
    ['codex', 'default', '每次都問（Codex）：未信任的指令先詢問；沙盒可讀寫專案資料夾'],
    ['codex', 'acceptEdits', '改檔不問（Codex）：專案資料夾內改檔、跑指令不問；要出去才問'],
    ['codex', 'plan', '只規劃（Codex）：唯讀沙盒；需要寫入時由 Codex 申請升權'],
    ['codex', 'auto', '自動（Codex）：專案資料夾內改檔、跑指令不問；要動資料夾外或連網才問'],
    ['codex', 'bypassPermissions', '全部不問（Codex）：不詢問核准，使用完整磁碟存取'],
    ['agy', 'default', '每次都問（Hydrogen／agy）：不加略過權限參數，依 agy 預設詢問'],
    ['agy', 'acceptEdits', '改檔不問（Hydrogen／agy）：使用 agy 的 accept-edits 模式'],
    ['agy', 'plan', '只規劃（Hydrogen／agy）：使用 agy 的 plan 模式'],
    // 依 07-41更新：agy 的 auto 顯示成「全都不問」；行為仍是放行全部（下方 --dangerously-skip-permissions 斷言不變）
    ['agy', 'auto', '全都不問（Hydrogen／agy）：所有指令與寫檔（含專案外）都直接放行，不詢問'],
    ['agy', 'bypassPermissions', '全部不問（Hydrogen／agy）：完全不問'],
  ];
  for (const [engine, key, text] of hints) {
    assert.ok(mode.includes(`case (.${engine}, "${key}"): return L("${text}")`), `${engine}/${key} tooltip uses L and matches policy`);
    assert.ok(translations[text], `${engine}/${key} tooltip is localized`);
  }
  assert.match(codex, /case "acceptEdits", "auto": return \("on-request", "workspace-write"/);
  assert.match(codex, /case "plan": return \("on-request", "read-only"/);
  assert.match(codex, /case "bypassPermissions": return \("never", "danger-full-access"/);
  assert.match(codex, /default: return \("untrusted", "workspace-write"/);
  assert.match(agy, /case "acceptEdits": a \+= \["--mode", "accept-edits"\]/);
  assert.match(agy, /case "plan": a \+= \["--mode", "plan"\]/);
  assert.match(agy, /case "auto", "bypassPermissions": a \+= \["--dangerously-skip-permissions"\]/);
  assert.match(pane, /inputBar\.permissionEngineForHint = session\.agyModel != nil \? \.agy : session\.codexModel != nil \? \.codex : session\.copilotModel != nil \? \.copilot : \.claude/); // 依 07-41：Copilot 也要依引擎顯示
  assert.match(pane, /refreshModelTitle\(\)\s*refreshMode\(\)\s*}\s*$/m, 'engine change refreshes tooltip');
  assert.match(input, /modeButton\.toolTip = PermissionMode\.tooltip\(engine: permissionEngine, mode: newValue\)/, 'mode changes refresh tooltip');
  // 已移除「引擎切換時重新整理 tooltip」的靜態比對：依 e2c759a 重構，行為由 --dump-permission 矩陣斷言覆蓋（codenv 裁決）
} else if (id === 'C88') {
  const lid = readFileSync(path.join(root, 'Sources/Workbench/LidKeeper.swift'), 'utf8');
  const virtualCheck = lid.match(/static func isOpenDisplay\([\s\S]*?\n    }/)?.[0] || '';
  const realCheck = lid.match(/static func isRealExternal\([\s\S]*?\n    }/)?.[0] || '';
  assert.match(virtualCheck, /localizedCaseInsensitiveContains\("OpenDisplay"\)/, 'OpenDisplay names are recognized case-insensitively');
  assert.match(realCheck, /!isOpenDisplay\(vendor: vendor, displayName: displayName\)/, 'named OpenDisplay is excluded after normal physical-screen checks');
  assert.match(realCheck, /!builtin && !asleep && vendor != 0 && vendor != 0xFFFF_FFFF && size\.width > 0 && size\.height > 0/, 'ordinary physical display checks remain');
  assert.match(lid, /displayName: name\)/, 'NSScreen.localizedName reaches the display classifier');
} else if (id === 'C89') {
  const layout = readFileSync(path.join(root, 'Sources/Workbench/LayoutEdit.swift'), 'utf8');
  const sidebar = readFileSync(path.join(root, 'Sources/Workbench/Sidebar.swift'), 'utf8');
  const moveBody = layout.match(/static func movedCommanderIDs\([\s\S]*?\n    }/)?.[0] || '';
  assert.match(moveBody, /remove\(at: from\)/);
  assert.match(moveBody, /insert\(item, at: max\(0, min\(to > from \? to - 1 : to, moved\.count\)\)\)/, 'destinations use pre-move insertion offsets');

  const move = (items, from, to) => {
    const result = [...items];
    const [item] = result.splice(from, 1);
    result.splice(Math.max(0, Math.min(to > from ? to - 1 : to, result.length)), 0, item);
    return result;
  };
  const original = ['study', 'codenv', 'input', 'library', 'tools', 'pet', 'game', 'rts', 'other'];
  const reordered = move(original, 1, 5);
  eq(reordered, ['study', 'input', 'library', 'tools', 'codenv', 'pet', 'game', 'rts', 'other'], 'move i to j updates order');
  eq(move(reordered, 4, 0), ['codenv', 'study', 'input', 'library', 'tools', 'pet', 'game', 'rts', 'other'], 'move to front works');
  const saved = JSON.stringify({ sessions: reordered.map(name => ({ name, area: null, groups: [] })) });
  eq(JSON.parse(saved).sessions.map(session => session.name), reordered, 'state.json sessions array round-trips order');
  assert.match(layout, /sessions = sessions\.map \{ session in[\s\S]*ordered\.next\(\) \?\? session/,
    'only existing commander slots in sessions are replaced');
  assert.match(sidebar, /let commanders = store\.sessions\.filter \{ \$0\.area == nil && \$0\.groups != nil \}/);
  assert.match(sidebar, /\.onDrag \{ Self\.commanderDragItem\(session\.id\) \}[\s\S]*\.modifier\(CommanderReorderDrop/);
  assert.match(sidebar, /Rectangle\(\)\.fill\(Color\.accentColor\)\.frame\(height: 2\)/, 'drop insertion line is visible');
  assert.match(sidebar, /\.onTapGesture\(perform: action\)/, 'single click still selects the commander');
} else if (id === 'C90') {
  const theme = readFileSync(path.join(root, 'Sources/Workbench/Theme.swift'), 'utf8');
  const chatPane = readFileSync(path.join(root, 'Sources/Workbench/ChatPane.swift'), 'utf8');
  const sidebar = readFileSync(path.join(root, 'Sources/Workbench/Sidebar.swift'), 'utf8');
  const graphPanel = readFileSync(path.join(root, 'Sources/Workbench/GraphPanel.swift'), 'utf8');
  const chatGraph = readFileSync(path.join(root, 'Sources/Workbench/ChatGraph.swift'), 'utf8');
  const mainWindow = readFileSync(path.join(root, 'Sources/Workbench/MainWindow.swift'), 'utf8');
  const windowHost = readFileSync(path.join(root, 'Sources/Workbench/WindowHost.swift'), 'utf8');
  assert.match(theme, /fg: rgb\(0x262626\), bg: rgb\(0xECECEA\)/, 'light palette uses soft charcoal and #ECECEA');
  assert.match(theme, /bold: rgb\(0x1A1A1A\), ansi: lightAnsiHex\.map\(rgb\)/, 'light bold and ANSI colors remain legible');
  assert.match(theme, /static let defaultDark = Palette\(fg: NSColor\(white: 0\.86, alpha: 1\), bg: NSColor\(white: 0\.08, alpha: 1\)/, 'dark palette values are unchanged');
  assert.match(chatPane, /layer\?\.backgroundColor = pal\.bg\.cgColor/, 'user terminal theme background remains respected');
  assert.match(theme, /static func mainSurface\(for appearance: NSAppearance\)[\s\S]*defaultLight\.bg/);
  assert.match(windowHost, /v\.layer\?\.backgroundColor = Theme\.mainSurface\(for: v\.effectiveAppearance\)\.cgColor/, 'empty workspace uses the softened app surface while terminal palettes stay custom');
  assert.match(sidebar, /\.background\(Color\(nsColor: colorScheme == \.dark \? \.controlBackgroundColor : Theme\.lightPanelBackground\)\)/, 'sidebar uses layered light surface while preserving dark semantics');
  assert.match(graphPanel, /NSRect\(origin: \.zero, size: cv\.bounds\.size\)/, 'graph overlay covers complete window content');
  assert.doesNotMatch(graphPanel, /sidebarEdge|overlay\(alignment: \.leading\)/, 'graph panel has no reserved sidebar gutter or separator');
  assert.match(chatGraph, /let target = CGPoint\(x: -cx \* s, y: -cy \* s\)/, 'initial fit and empty-space refit target panel center');
  assert.match(mainWindow, /GraphPanelController\(window: window!, store: store, workspace: workspace\)/, 'graph panel is not offset by sidebar width');
} else if (id === 'C115') {
  const areas = readFileSync(path.join(root, 'Sources/Workbench/Areas.swift'), 'utf8');
  const todo = readFileSync(path.join(root, 'scripts/codenv-todo'), 'utf8');
  const main = readFileSync(path.join(root, 'Sources/Workbench/MainWindow.swift'), 'utf8');
  const nodes = areas.match(/func areaNodes\([\s\S]*?\n    }/)?.[0] || '';
  const allNodes = areas.match(/func allAreaNodes\([\s\S]*?\n    }/)?.[0] || '';
  const remove = areas.match(/func commanderAreaRemove\([\s\S]*?\n    }/)?.[0] || '';
  assert.match(nodes, /func areaNodes[\s\S]*return all\.filter \{ hasChats\.contains/,
    'empty areas are pruned from the shared graph/right-panel area tree');
  assert.match(allNodes, /func allAreaNodes[\s\S]*out\.append\(AreaNode/,
    'complete area tree retains empty areas for commands');
  assert.match(areas, /func findArea[\s\S]*let nodes = allAreaNodes\(s\)/,
    'empty areas remain addressable for removal');
  assert.match(remove, /guard me\.chief/);
  assert.match(remove, /childGroups\(of: g\.id\)\.isEmpty/);
  assert.match(remove, /guard !hasChats/);
  assert.match(remove, /removeGroup\(g\.id\)/);
  assert.match(todo, /elif op == "rm"[\s\S]*"op": "rm"/);
  assert.match(main, /case "rm": done\(self\.store\.commanderAreaRemove/);
  const mayDelete = ({ chief, childAreas, chats }) => chief && childAreas === 0 && chats === 0;
  assert.equal(mayDelete({ chief: true, childAreas: 0, chats: 0 }), true, 'empty area can be deleted');
  assert.equal(mayDelete({ chief: true, childAreas: 1, chats: 0 }), false, 'parent with child area is rejected');
  assert.equal(mayDelete({ chief: true, childAreas: 0, chats: 1 }), false, 'area containing chat is rejected');
  assert.equal(mayDelete({ chief: false, childAreas: 0, chats: 0 }), false, 'non-chief caller is rejected');
} else if (id === 'C116') {
  const layout = readFileSync(path.join(root, 'Sources/Workbench/Layout.swift'), 'utf8');
  const graph = readFileSync(path.join(root, 'Sources/Workbench/ChatGraph.swift'), 'utf8');
  const rightPanel = readFileSync(path.join(root, 'Sources/Workbench/RightPanelView.swift'), 'utf8');
  const panel = readFileSync(path.join(root, 'Sources/Workbench/GraphPanel.swift'), 'utf8');
  for (const field of ['commanderToArea', 'areaToSubarea', 'areaToChat', 'repulsion']) assert.match(layout, new RegExp(`var ${field}: Double`));
  assert.match(layout, /var graphLayout: GraphLayoutSettings\? = nil/);
  assert.match(layout, /sessions\[i\]\.graphLayout = value[\s\S]*scheduleSave\(\)/);
  assert.match(graph, /static func linkLength\([\s\S]*case \(\.center, \.area\): return settings\.commanderToArea/);
  assert.match(graph, /case \(\.area, \.area\): return settings\.areaToSubarea/);
  assert.match(graph, /case \(\.area, \.chat\), \(\.center, \.chat\): return settings\.areaToChat/);
  assert.match(graph, /let k = CGFloat\(graphLayout\.repulsion\)/);
  assert.match(graph, /func apply\([\s\S]*graphLayout != snap\.layout/);
  assert.match(rightPanel, /onLayoutRequested: \{ graphLayoutOpen = true \}[\s\S]*Image\(systemName: "gearshape"\)/);
  assert.match(panel, /onLayoutRequested: \{ graphLayoutOpen = true \}[\s\S]*Image\(systemName: "gearshape"\)/);
  assert.match(graph, /L\("版面…"\)/);
  const settings = { commanderToArea: 100, areaToSubarea: 80, areaToChat: 55, repulsion: 1700 };
  const mean = (a) => a.reduce((sum, value) => sum + value, 0) / a.length;
  const before = mean([settings.commanderToArea, settings.areaToSubarea, settings.areaToChat]);
  settings.commanderToArea = 150;
  const after = mean([settings.commanderToArea, settings.areaToSubarea, settings.areaToChat]);
  assert.ok(after > before, 'changing link distance slider changes average link length');
  const roundTrip = JSON.parse(JSON.stringify(settings));
  assert.deepEqual(roundTrip, settings, 'commander graph layout settings survive state JSON round trip');
} else if (id === 'C91') {
  const graph = readFileSync(path.join(root, 'Sources/Workbench/ChatGraph.swift'), 'utf8');
  const rightPanel = readFileSync(path.join(root, 'Sources/Workbench/RightPanelView.swift'), 'utf8');
  const sidebar = readFileSync(path.join(root, 'Sources/Workbench/Sidebar.swift'), 'utf8');
  const windowHost = readFileSync(path.join(root, 'Sources/Workbench/WindowHost.swift'), 'utf8');
  const harness = readFileSync(path.join(root, 'Sources/Workbench/TestHarness.swift'), 'utf8');
  const theme = readFileSync(path.join(root, 'Sources/Workbench/Theme.swift'), 'utf8');
  const viewports = graph.match(/private var viewports: \[UUID: Viewport\] = \[:\]/);
  assert.ok(viewports, 'view state is keyed independently by commander session');
  assert.match(graph, /let sessionChanged = activeSessionID != snap\.sessionID[\s\S]*nodes = \[\]; index = \[:\]; signature = 0; alpha = 0/, 'session switch discards prior force positions and velocities');
  assert.match(graph, /if let savedViewport, savedViewport\.userMoved[\s\S]*userMoved = true[\s\S]*autoFitPending = false/, 'manual per-commander viewport survives switching even when content is off canvas');
  assert.match(graph, /if !userMoved, fitAfterLayout \|\| !viewportFits\(\) \{ fit\(animated: false\) \}/, 'automatic fit runs only when the user has not moved the viewport');
  assert.match(graph, /autoFitPending = !userMoved/, 'layout updates defer fit and never reset a manual viewport');
  assert.doesNotMatch(graph, /if alpha <= 0\.02, !fitting, !viewportFits\(\)/, 'tick does not repeatedly fit an undersized minimum scale');
  assert.match(graph, /g\.clip\(to: bounds\)/);
  assert.match(graph, /layer\?\.masksToBounds = true/);
  assert.match(rightPanel, /\.frame\(maxWidth: \.infinity, maxHeight: \.infinity\)\s*\.clipped\(\)/, 'SwiftUI clips graph to its own region');
  assert.match(harness, /case "viewport"[\s\S]*adjustViewportForTest/);
  assert.match(harness, /case "state"[\s\S]*self\.store\.status\[conversation\.id\] = status/);
  assert.match(harness, /case "dump", "probe"/);
  assert.match(harness, /case "resize"[\s\S]*RightPanelModel\.shared\.dividerHeight/);
  assert.match(theme, /rgb\(0xECECEA\)/);
  assert.match(theme, /lightPanelBackground = rgb\(0xE3E3E0\)/);
  assert.match(theme, /lightSeparatorColor = rgb\(0xD0D0CD\)/);
  assert.match(theme, /lightSecondaryText = rgb\(0x656565\)/, 'light secondary text keeps 4.5:1 contrast over panel surfaces');
  assert.match(theme, /secondaryTextColor = NSColor\(name: "CodenvSecondaryText"/);
  assert.match(sidebar, /Color\(nsColor: Theme\.secondaryTextColor\)/);
  assert.match(rightPanel, /Color\(nsColor: Theme\.secondaryTextColor\)/);
  assert.match(windowHost, /Theme\.secondaryTextColor/);
  const contrast = (fg, bg) => {
    const linear = (value) => { const c = value / 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
    const lum = (hex) => 0.2126 * linear((hex >> 16) & 255) + 0.7152 * linear((hex >> 8) & 255) + 0.0722 * linear(hex & 255);
    const [a, b] = [lum(fg), lum(bg)].sort((x, y) => y - x);
    return (a + 0.05) / (b + 0.05);
  };
  assert.ok(contrast(0x656565, 0xE3E3E0) >= 4.5, 'secondary text meets WCAG AA on sidebar/right panel');
  assert.ok(contrast(0x656565, 0xECECEA) >= 4.5, 'secondary text meets WCAG AA on main surface');
} else if (id === 'A06') {
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
} else if (id === 'C127') {
  const long = ('這是仿真的長段回覆，含 emoji 👇、全形標點，並跨過工具呼叫。\n').repeat(30);
  const user = { type: 'user', uuid: 'threads-user', message: { role: 'user', content: [{ type: 'text', text: 'Threads 貼文是不是類似我的世界樹？' }] } };
  const firstTool = { type: 'assistant', message: { id: 'fetch-message', role: 'assistant', content: [{ type: 'tool_use', id: 'fetch-1', name: 'Bash' }] } };
  const fetched = { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'fetch-1', content: '貼文內容 👇\n' + '關聯地圖。'.repeat(100) }] }, toolUseResult: { stdout: '貼文內容 👇\n' + '關聯地圖。'.repeat(100), stderr: '' } };
  const replyID = 'reply-message';
  const thought = { type: 'assistant', message: { id: replyID, role: 'assistant', content: [{ type: 'thinking', thinking: long }] } };
  const reply = { type: 'assistant', message: { id: replyID, role: 'assistant', content: [{ type: 'text', text: long }] } };
  const saveTool = { type: 'assistant', message: { id: replyID, role: 'assistant', content: [{ type: 'tool_use', id: 'save-1', name: 'Bash' }] } };
  const saved = { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'save-1', content: '已存進收藏。', is_error: false }] }, toolUseResult: { stdout: '已存進收藏。', stderr: '' } };
  const final = { type: 'assistant', message: { id: 'final-message', role: 'assistant', content: [{ type: 'text', text: '重點也存進收藏了。' }] } };
  const { wb, document, flushFrames } = dom(base);
  const visibleText = () => document.body.textContent;
  const plainText = () => visibleText().replace(/<br\s*\/?\s*>/g, '\n').replace(/<[^>]+>/g, '');
  wb.localUser({ uuid: 'threads-user', text: 'Threads 貼文是不是類似我的世界樹？' });
  wb.event(firstTool); wb.event(fetched); wb.event(thought);
  const event = e => wb.event({ type: 'stream_event', event: e, parent_tool_use_id: null, api_message_id: replyID });
  event({ type: 'message_start', message: { id: replyID } });
  event({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
  for (let i = 0; i < long.length; i += 97) event({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: long.slice(i, i + 97) } });
  event({ type: 'content_block_stop', index: 0 });
  wb.event(reply); flushFrames(); wb.event(saveTool); wb.event(saved); wb.event(final); flushFrames();
  assert.ok(plainText().includes(long), '即時串流的長文字泡泡完整保留');
  assert.ok(visibleText().includes('重點也存進收藏了。'), '工具呼叫後的最後一句可見');
  assert.equal(document.querySelectorAll('.tool').length, 2, '兩個工具步驟仍顯示');
  wb.event({ type: 'result', subtype: 'success', is_error: false });
  wb.history([user, firstTool, fetched, thought, reply, saveTool, saved, final]);
  assert.ok(plainText().includes(long), '重新載入歷史後長文字泡泡完整保留');
  assert.ok(visibleText().includes('重點也存進收藏了。'), '重新載入歷史後最後一句可見');
  assert.ok(visibleText().includes('Thought for'), '長 thinking 被保留為可展開的思考區塊');
  const overlapID = 'history-first-message', overlapText = '歷史與串流重疊只顯示一次';
  const overlap = { type: 'assistant', message: { id: overlapID, role: 'assistant', content: [{ type: 'text', text: overlapText }], stop_reason: 'end_turn' } };
  wb.history([overlap]);
  const overlapEvent = e => wb.event({ type: 'stream_event', event: e, parent_tool_use_id: null, api_message_id: overlapID });
  overlapEvent({ type: 'message_start', message: { id: overlapID } });
  overlapEvent({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
  overlapEvent({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: overlapText } });
  overlapEvent({ type: 'content_block_stop', index: 0 });
  overlapEvent({ type: 'message_stop' });
  wb.event(overlap);
  wb.event({ type: 'result', subtype: 'success', is_error: false });
  flushFrames();
  assert.equal(plainText().split(overlapText).length - 1, 1, '歷史先載入完整答案時，後來到達的同訊息串流不重複');
  // 重載後可能只收到已完成訊息的 delta，沒有對應的 content_block_start。
  // 這些重播要略過，不可丟例外、重複文字或中斷後續畫面更新。
  const replayErrors = [], originalError = console.error;
  console.error = (...args) => replayErrors.push(args);
  try {
    overlapEvent({ type: 'message_start', message: { id: overlapID } });
    overlapEvent({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: overlapText } });
    overlapEvent({ type: 'content_block_delta', index: 1, delta: { type: 'thinking_delta', thinking: '重播的思考內容' } });
    overlapEvent({ type: 'content_block_delta', index: 2, delta: { type: 'input_json_delta', partial_json: '{"x":1}' } });
  } finally { console.error = originalError; }
  assert.equal(replayErrors.length, 0, '只有 delta、沒有 start 的歷史重播不拋例外');
  assert.equal(plainText().split(overlapText).length - 1, 1, '只有 delta、沒有 start 的歷史重播不增加重複文字');
  const afterReplayID = 'after-history-replay';
  const afterReplayEvent = e => wb.event({ type: 'stream_event', event: e, parent_tool_use_id: null, api_message_id: afterReplayID });
  afterReplayEvent({ type: 'message_start', message: { id: afterReplayID } });
  afterReplayEvent({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
  afterReplayEvent({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '重播後畫面仍可更新' } });
  flushFrames();
  assert.ok(visibleText().includes('重播後畫面仍可更新'), '略過歷史 delta 後，新的串流仍可更新畫面');
} else if (id === 'C128') {
  const temp = mkdtempSync(path.join(os.tmpdir(), 'codenv-exam-report-'));
  try {
    const history = path.join(temp, 'exam-history.jsonl');
    const records = [];
    const outcomes = ['pass', 'pass', 'fail', 'pass', 'pass', 'pass', 'pass', 'pass', 'pass', 'fail'];
    for (let i = 0; i < 10; i++) {
      const runId = `fake-run-${String(i + 1).padStart(2, '0')}`;
      records.push({
        runId, caseId: 'C900', caseName: '假造的時好時壞題', status: outcomes[i], seconds: i === 9 ? 3.5 : 1,
        testAppHash: 'fake-app-sha256', gitCommit: 'fake-commit', examJobs: 4,
      });
      records.push({
        runId, caseId: 'C901', caseName: '假造的連續略過題', status: 'skip', seconds: 0,
        testAppHash: 'fake-app-sha256', gitCommit: 'fake-commit', examJobs: 4,
      });
    }
    writeFileSync(history, records.map(row => JSON.stringify(row)).join('\n') + '\n');
    const output = execFileSync(process.execPath, [path.join(root, 'scripts/exam/report.mjs'), '--runs', '20'], {
      cwd: root, encoding: 'utf8', env: { ...process.env, EXAM_HISTORY_FILE: history },
    });
    assert.match(output, /需要注意的題：/);
    const flaky = output.split('\n').find(line => line.includes('C900')) || '';
    assert.match(flaky, /flaky/);
    assert.match(flaky, /slow/);
    assert.match(flaky, /newly-failing/);
    const skipped = output.split('\n').find(line => line.includes('C901')) || '';
    assert.match(skipped, /always-skipped/);
    assert.match(skipped, /實作或移除/);
  } finally { rmSync(temp, { recursive: true, force: true }); }
  console.log('斷言通過 C128');
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
} else if (['C62', 'C80'].includes(id)) {
  const source = readFileSync(path.join(root, 'Sources/Workbench/Usage.swift'), 'utf8');
  const fixtureName = id === 'C80' ? 'fixtures-magpie-real-1109.json' : 'fixtures/magpie-accounts.json';
  const fixture = JSON.parse(readFileSync(path.join(root, 'scripts/exam/dev', fixtureName), 'utf8'));
  const poolKey = (pool, name) => {
    const s = `${pool} ${name}`.toLowerCase().replaceAll('·', ' ');
    if (s.includes('argon') || s.includes('gemini 4') || s.includes('gemini4')) return /week|weekly|每週|7 days/.test(s) ? 'argonWeek' : null;
    if (/five hour|5 hour|5 小時|5h|session/.test(s)) return 'gemini5';
    if (/weekly|week|每週/.test(s)) return 'geminiWeek';
    if (s.includes('gemini')) return 'geminiWeek';
    return null;
  };
  const labels = { gemini5: 'Gemini 5 小時', geminiWeek: 'Gemini 每週', argonWeek: 'Argon 每週' };
  const accounts = fixture.map(account => ({
    name: account.email,
    windows: Object.fromEntries(account.windows.map(window => [poolKey(`${window.pool ?? ''} ${window.model || window.modelName || window.label || ''}`, window.name), window.remaining]).filter(([key]) => key)),
    resets: Object.fromEntries(account.windows.map(window => [poolKey(`${window.pool ?? ''} ${window.model || window.modelName || window.label || ''}`, window.name), Date.parse(window.resetsAt)]).filter(([key]) => key)),
  }));
  assert.equal(accounts.length, 2, '雙帳號 fixture');
  if (id === 'C80') {
    assert.deepEqual(accounts.map(a => a.windows.argonWeek), [99.52854500000001, 29.972547000000006], '真實 Argon 7 days 視窗；模型視窗不得蓋掉');
    assert.equal(Math.round(accounts.reduce((sum, a) => sum + a.windows.argonWeek, 0) / accounts.length), 65, '真實 Argon 每週約 66%');
    assert.ok(fixture[1].windows.some(window => window.pool == null), 'fixture 含 pool null 視窗');
  } else assert.deepEqual(accounts.map(a => a.windows.argonWeek), [70, 50], 'Argon pool/name 與 Gemini 4 Argon 標籤對應');
  const average = key => Math.round(accounts.reduce((sum, a) => sum + a.windows[key], 0) / accounts.length);
  if (id === 'C80') {
    assert.deepEqual(['gemini5', 'geminiWeek', 'argonWeek'].map(average), [98, 90, 65], '真實資料三個平均 bucket');
    assert.deepEqual(accounts.map(a => Object.values(a.windows).map(Math.round)), [[99, 100, 100], [81, 96, 30]], '真實逐帳號額度明細（四捨五入）');
  } else {
    assert.deepEqual(['gemini5', 'geminiWeek', 'argonWeek'].map(average), [85, 70, 60], '三個平均 bucket');
    assert.deepEqual(accounts.map(a => a.name), ['alpha@example.test', 'beta@example.test']);
    assert.deepEqual(accounts.map(a => Object.values(a.windows)), [[90, 80, 70], [80, 60, 50]], '逐帳號額度明細');
    assert.equal(Math.min(...accounts.map(a => a.resets.argonWeek)), Date.parse('2026-11-13T04:00:00Z'), 'Argon 合計使用最早重置時間');
  }
  const status = `${average('gemini5')}%  ${average('geminiWeek')}%  阿公 ${average('argonWeek')}%`;
  assert.equal(status, id === 'C80' ? '98%  90%  阿公 65%' : '85%  70%  阿公 60%');
  assert.doesNotMatch(status, /阿公 —|—/);
  assert.match(source, /"argonWeek"\s*:\s*"Argon 每週"/);
  assert.match(source, /window\["model"\].*window\["modelName"\].*window\["label"\]/, '讀取窗口模型標籤');
  assert.match(source, /MagpieAccountQuota\(id: id, name: name, buckets: accountValues\[id\] \?\? \[:\]\)/);
  if (id === 'C80') {
    const card = source.match(/private func card\(_ p: UsagePool\) -> some View \{([\s\S]*?)\n    }\n}/)?.[1] || '';
    // 方案 A（00.07.17）起 agyAccountsCard 顯示換帳號各帳號；舊的 magpie 逐帳號明細改名為 legacyMagpieAgyAccountsCard（--agy-usage-card-probe 仍走它）。
    const agyAccountsCard = source.match(/private func legacyMagpieAgyAccountsCard\(\)[^{]*\{([\s\S]*?)(?=\n    private func|\n})/)?.[1] || '';
    assert.match(card, /ForEach\(m\.rows\(p\)\)/, 'Gemini 卡片呈現彙總額度列');
    assert.match(agyAccountsCard, /ForEach\(m\.magpieAccounts\)/, 'Gemini 卡片下方每個帳號各列一行明細');
    assert.match(card, /UsageRowView\(row: r, detail: p == \.gemini \? m\.magpieQuotaTips\[r\.bucket\.label\] : nil\)/, '帳號明細保留在彙總列的 hover 提示');
  }
  assert.doesNotMatch(source, /else if key == "agy", i == 2/, '狀態列不得硬填 Argon');
  if (id === 'C80') assert.ok(source.includes('阿公 \\(remaining("Argon 每週"))'), '狀態列保留阿公每週合計');
} else if (id === 'C117') {
  const keyVault = readFileSync(path.join(root, 'Sources/Workbench/KeyVault.swift'), 'utf8');
  const usage = readFileSync(path.join(root, 'Sources/Workbench/Usage.swift'), 'utf8');
  const sessions = readFileSync(path.join(root, 'Sources/Workbench/ChatSession.swift'), 'utf8');
  assert.match(keyVault, /static var prefix: String = prefix\(arguments: CommandLine\.arguments\)/);
  assert.match(keyVault, /static func isTestInstance\(_ arguments: \[String\]\)[\s\S]*arguments\.contains\("--state-dir"\)/);
  assert.match(keyVault, /return "codenv-test-\\\(generatedSuffix\)-"/);
  assert.match(keyVault, /guard isTestInstance\(arguments\) else \{ return "codenv-" \}/);
  assert.match(usage, /let isolated = KeyVault\.isTestInstance/);
  const extraRefresh = usage.slice(usage.indexOf('private func refreshExtraKeyPools'), usage.indexOf('func refresh()', usage.indexOf('private func refreshExtraKeyPools')));
  const isolatedExtraRefresh = extraRefresh.slice(extraRefresh.indexOf('if isolated'), extraRefresh.indexOf('} else {'));
  assert.doesNotMatch(isolatedExtraRefresh, /KeyVault\.(?:read|reader)|readKey:/, '測試實例不讀正式 OpenRouter／Groq 項目');
  // 07-14 改由 security 子程序讀取外部免費池金鑰；正向讀取與假 security 驗收由 C180 覆蓋。
  assert.doesNotMatch(extraRefresh, /readKey:\s*\{\s*KeyVault\.classify\(KeyVault\.reader\(/,
    '外部免費池金鑰不再要求舊的 KeyVault.reader 讀取形式');
  assert.match(keyVault, /filter \{ \$0\.hasPrefix\(prefix\) \}/, '測試鑰匙圈清單只顯示自身前綴');
  const harness = readFileSync(path.join(root, 'Sources/Workbench/TestHarness.swift'), 'utf8');
  assert.match(harness, /KeyVault\.delete\(service: svc\)/, '測試掛鉤只刪除自己建立的項目');
  assert.doesNotMatch(harness, /for s in KeyVault\.allServices\(\) \{ KeyVault\.delete/,
    '測試掛鉤不列舉正式鑰匙圈項目');
  assert.match(sessions, /var secretService: String \{ KeyVault\.service\(/);
  const testRun = (args) => args.includes('--state-dir') || args.some(arg => arg.startsWith('--'));
  const prefix = (args, suffix) => !testRun(args) ? 'codenv-' :
    (args.includes('--keyvault-prefix') ? args[args.indexOf('--keyvault-prefix') + 1] : `codenv-test-${suffix}-`);
  assert.notEqual(prefix(['--state-dir', '/tmp/exam'], 'random'), 'codenv-', '--state-dir always isolates keychain services');
  assert.equal(prefix(['--state-dir', '/tmp/exam'], 'random'), 'codenv-test-random-');
  assert.equal(prefix(['--usage-fake'], 'random'), 'codenv-test-random-', 'test flags also select an isolated prefix');
  assert.equal(prefix(['--commander-op'], 'random'), 'codenv-test-random-', 'other test harness flags also isolate');
  assert.equal(prefix([], 'random'), 'codenv-', 'ordinary production launch keeps the existing prefix');
  assert.equal(prefix(['--state-dir', '/tmp/exam', '--keyvault-prefix', 'codenv-test-fixture-'], 'random'), 'codenv-test-fixture-');
} else if (id === 'C118') {
  const pane = readFileSync(path.join(root, 'Sources/Workbench/ChatPane.swift'), 'utf8');
  assert.match(pane, /session\.codexModel != nil \? "Codex"/);
  const start = pane.indexOf('func ensureWeb()');
  const end = pane.indexOf('var canUnloadWeb', start);
  const startup = pane.slice(start, end);
  assert.match(startup, /syncAgent\(\)[\s\S]*?w\.loadFileURL/,
    'WebView 載入前先排入 Swift 實際引擎名稱');
  const chat = readFileSync(path.join(root, 'Resources/chat/chat.js'), 'utf8');
  assert.match(chat, /setAgent\(name\)[\s\S]*?S\.agent = String\(name \|\| 'Claude'\)/);
  assert.match(chat, /setBusy\(b\)[\s\S]*?typingTitle\.textContent = `\$\{S\.agent\} 正在處理`/);
  // 模擬 Swift 排入 setAgent 後 setBusy 的啟動順序；JS 呼叫按佇列順序執行。
  let agent = 'Claude';
  let title = '';
  const queue = [() => { agent = 'Codex'; }, () => { title = `${agent} 正在處理`; }];
  queue.forEach(operation => operation());
  assert.equal(title, 'Codex 正在處理');
} else if (id === 'C119') {
  const wiring = readFileSync(path.join(root, 'Sources/Workbench/LidWiring.swift'), 'utf8');
  assert.match(wiring, /private func shouldSendLidNotice\(to id: UUID\)[\s\S]*?store\.commander\(of: id\)/,
    '使用既有 commander/team 關係判斷隸屬');
  assert.match(wiring, /keeper\.sendStop = \{[\s\S]*?shouldSendLidNotice\(to: id\)/,
    '闔蓋停止訊息經 team 過濾');
  assert.match(wiring, /keeper\.sendResume = \{[\s\S]*?shouldSendLidNotice\(to: id\)/,
    '開蓋繼續訊息經同一過濾');
  const shouldSend = (member, chief) => !member || chief;
  for (const action of ['stopMessage', 'resumeMessage']) {
    assert.equal(shouldSend(true, false), false, `總指揮 team 工作聊天室闔蓋／開蓋都不收 ${action}`);
    assert.equal(shouldSend(false, false), true, `一般聊天室照常收 ${action}`);
    assert.equal(shouldSend(true, true), true, `總指揮本人照常收 ${action}`);
  }
} else if (id === 'C110') {
  const prefs = readFileSync(path.join(root, 'Sources/Workbench/Prefs.swift'), 'utf8');
  const settings = readFileSync(path.join(root, 'Sources/Workbench/SettingsPages.swift'), 'utf8');
  const team = readFileSync(path.join(root, 'Sources/Workbench/CommanderTeam.swift'), 'utf8');
  const cli = readFileSync(path.join(root, 'scripts/codenv-todo'), 'utf8');
  assert.match(prefs, /commanderChatPermission/);
  assert.match(settings, /總指揮開的聊天室預設權限/);
  assert.match(settings, /等於把放寬權限交給總指揮/);
  assert.match(team, /permissionMode = permission/);
  assert.match(cli, /權限：%s（依設定）/);
  assert.doesNotMatch(cli, /permission-mode|--permission/);
} else if (id === 'C130') {
  const local = readFileSync(path.join(root, 'Sources/Workbench/LocalBridge.swift'), 'utf8');
  const chat = readFileSync(path.join(root, 'Resources/chat/chat.js'), 'utf8');
  const fakeResponse = { choices: [{ finish_reason: 'length', delta: { tool_calls: [{ id: 'fake', function: { name: 'Bash', arguments: '{"command":"touch /tmp/no-run"}' } }] } }] };
  assert.equal(fakeResponse.choices[0].finish_reason, 'length');
  assert.equal(fakeResponse.choices[0].delta.tool_calls.length, 1);
  assert.match(local, /c\["finish_reason"\] as\? String/);
  assert.match(local, /shouldRejectToolBatch\(finishReason: finishReason, toolCount: tools\.count\)/);
  assert.match(local, /failTruncatedToolBatch\(tools\)[\s\S]*?ask\(\)/);
  assert.match(local, /模型輸出被長度上限截斷，為了安全沒有執行這個工具，請重新輸出完整指令/);
  assert.match(chat, /tool_calls_truncated[\s\S]*notice\(o\.message/);
} else if (id === 'C131') {
  const policy = readFileSync(path.join(root, 'Sources/Workbench/RetryPolicy.swift'), 'utf8');
  const local = readFileSync(path.join(root, 'Sources/Workbench/LocalBridge.swift'), 'utf8');
  const agy = readFileSync(path.join(root, 'Sources/Workbench/AgyBridge.swift'), 'utf8');
  const session = readFileSync(path.join(root, 'Sources/Workbench/ChatSession.swift'), 'utf8');
  const chat = readFileSync(path.join(root, 'Resources/chat/chat.js'), 'utf8');
  assert.match(policy, /quotaTerms\.contains\(where: s\.contains\)[\s\S]*return false/);
  assert.ok(policy.includes('(?<![0-9])(429|500|502|503|504)(?![0-9])'));
  assert.match(policy, /"rate limit", "rate_limit"/);
  assert.match(policy, /static let maxRetries = 3/);
  assert.match(policy, /pow\(2, Double\(max\(0, completedRetries\)\)\)/);
  assert.match(policy, /Mario Zechner, 2025/);
  assert.match(local, /if self\.retry\(err\) \{ return \}/);
  assert.match(local, /receivedDone \|\| receivedFinishReason else \{ onDone\(L\("串流中途斷掉"\)/);
  assert.match(agy, /RetryPolicy\.plan\(error: error/);
  assert.match(agy, /static func runRetrySelfTest/);
  assert.match(agy, /Fake transient result exercises agy retry scheduling without launching its CLI/);
  assert.match(session, /scheduleAgyRetry\(agy, retry\)/);
  assert.match(session, /cancelAgyRetry\(\)/);
  assert.match(chat, /case 'api_retry': notice\(o\.message/);
} else if (id === 'C132') {
  const local = readFileSync(path.join(root, 'Sources/Workbench/LocalBridge.swift'), 'utf8');
  const agy = readFileSync(path.join(root, 'Sources/Workbench/AgyBridge.swift'), 'utf8');
  const session = readFileSync(path.join(root, 'Sources/Workbench/ChatSession.swift'), 'utf8');
  const chat = readFileSync(path.join(root, 'Resources/chat/chat.js'), 'utf8');
  const steer = local.match(/func steer\(_ uuid: String\) \{([\s\S]*?)\n    }/)?.[1] || '';
  assert.match(steer, /steeringIDs\.append\(id\)/);
  assert.doesNotMatch(steer, /interrupt\(\)/);
  assert.match(local, /guard let c = calls\.first else \{[\s\S]*?consumeSteeredMessage\(\)[\s\S]*?ask\(\)/);
  assert.match(local, /messages\.append\(\["role": "user", "content": Self\.content\(q\.msg/);
  assert.match(local, /earliest ⌃ Enter message before the next model request/);
  assert.match(agy, /agyRetry/);
  assert.match(session, /if let mlx \{ mlx\.steer\(uuid\); return \}/);
  assert.match(chat, /S\.agent === 'agy'[\s\S]*agy 不支援中途插話，會在這輪結束後送出[\s\S]*return/);
  assert.match(chat, /目前工具回合結束後、下次呼叫模型前送出/);
  const agyQueueNote = { agent: 'agy', showsNowButton: false, text: 'agy 不支援中途插話，會在這輪結束後送出' };
  const localSteer = { queue: ['later', 'urgent'], steering: ['urgent'] };
  const inserted = localSteer.queue.splice(localSteer.queue.indexOf(localSteer.steering[0]), 1)[0];
  assert.equal(agyQueueNote.showsNowButton, false, 'agy queue never advertises unsupported interrupt');
  assert.equal(inserted, 'urgent', 'local steer is inserted before the remaining queue');
} else if (id === 'C120') {
  const cli = readFileSync(path.join(root, 'scripts/codenv-todo'), 'utf8');
  const engine = readFileSync(path.join(root, 'Sources/Workbench/CommanderEngine.swift'), 'utf8');
  const stuck = readFileSync(path.join(root, 'Sources/Workbench/CommanderStuck.swift'), 'utf8');
  const team = readFileSync(path.join(root, 'Sources/Workbench/CommanderTeam.swift'), 'utf8');
  assert.match(cli, /codenv-todo stop/);
  assert.match(cli, /--interrupt/);
  assert.match(engine, /store\.status\[c\.id\] == \.working/);
  assert.match(engine, /addingTimeInterval\(15\)/);
  assert.match(engine, /if interrupt \{[\s\S]*?commanderInterrupt\(pane\)[\s\S]*?if store\.status\[c\.id\] != \.working \{[\s\S]*?commanderSendChat\(caller: caller[\s\S]*?interrupt: false, allowClaudeAfterInterrupt: true/,
    '--interrupt stops the pane, waits for idle, then redelivers the message');
  assert.match(stuck, /timeIntervalSince\(last\) >= limit/);
  assert.ok(stuck.includes('queueNotice(conv: chief'));
  assert.match(stuck, /chiefNotified\.insert\(c\.id\)/);
  assert.match(team, /可能卡住/);
} else if (id === 'C124') {
  const groups = readFileSync(path.join(root, 'Sources/Workbench/Groups.swift'), 'utf8');
  const areas = readFileSync(path.join(root, 'Sources/Workbench/Areas.swift'), 'utf8');
  const team = readFileSync(path.join(root, 'Sources/Workbench/CommanderTeam.swift'), 'utf8');
  const engine = readFileSync(path.join(root, 'Sources/Workbench/CommanderEngine.swift'), 'utf8');
  const stuck = readFileSync(path.join(root, 'Sources/Workbench/CommanderStuck.swift'), 'utf8');
  const lid = readFileSync(path.join(root, 'Sources/Workbench/LidWiring.swift'), 'utf8');
  const cli = readFileSync(path.join(root, 'scripts/codenv-todo'), 'utf8');
  assert.match(groups, /var areaLeadID: UUID\? = nil/);
  assert.match(areas, /guard me\.chief else \{ return fail\("只有總指揮聊天室能指派區長"\) \}/);
  assert.match(areas, /guard lead\.modelCategory == "claude"/);
  assert.match(areas, /!isArchived\(caller\), caller\.modelCategory == "claude"/);
  assert.match(areas, /let areaID = groupOf\(caller\)[\s\S]*?group\.id == areaID && \$0\.group\.areaLeadID == caller\.id/,
    'area lead context resolves the current area before comparing the leader');
  assert.match(areas, /groups\[i\]\.areaLeadID == lead\.id && groups\[i\]\.id != area\.id/,
    'assigning a leader clears old area references');
  assert.match(areas, /let destinationIsArea[\s\S]*?groups\[i\]\.areaLeadID == c\.id[\s\S]*?groups\[i\]\.id != dest/,
    'moving a leader clears references outside the destination area');
  assert.match(areas, /guard let parent = archivedChatParent\(for: g, in: me\.session\) else/,
    'archived chats prevent removal when there is no valid parent group');
  assert.match(areas, /"lead": activeAreaLead\(for: n\.group, in: s\)/,
    'area ls filters inactive leaders');
  assert.match(team, /if let areaNote = areaLeadRoleNote\(for: id\)/);
  assert.match(areas, /teamNames/); // Native selftest covers actual in-area membership.
  assert.match(engine, /if let lead = store\.areaLeadContext\(caller: caller\)/);
  assert.match(engine, /store\.areaLeadTarget\(target, context: lead(?:,[^)]*)?\)/); // 07-2 補充：區長 --interrupt 只限已判定卡住；07-25：stop 對封存聊天室也要能停程序，簽名可帶額外參數
  assert.match(team, /func commanderArchive\([\s\S]*?guard me\.chief else/);
  assert.match(team, /func commanderHandoffInfo\([\s\S]*?guard let me = callerInfo\(caller\), me\.chief else/);
  assert.match(team, /if let lead \{\s*g = lead\.area\.id/);
  assert.match(stuck, /\.commander\(\.areaLeadTimeout\)/);
  assert.match(stuck, /case \.areaLeadInvalid:[\s\S]*區長已失效/);
  assert.match(stuck, /case \.areaLeadTimeout:[\s\S]*10 分鐘/);
  assert.match(stuck, /store\.activeAreaLead\(for: c, in: session\)/);
  assert.match(lid, /store\.commander\(of: id\)/);
  const cases = JSON.parse(readFileSync(path.join(root, 'scripts/exam/dev/cases.json'), 'utf8'));
  assert.ok(cases.some(c => c.id === 'C155' && c.runner === 'native.sh'),
    '區長併入區中心節點與清除後還原由 C155 原生互動情境驗證');
  assert.match(engine, /areaLeadTargetsSelf\(caller: caller, target: c\)[\s\S]*區長不能停止自己/);
  assert.match(engine, /interrupt && store\.areaLeadTargetsSelf\(caller: caller, target: c\)[\s\S]*區長不能用 --interrupt 中斷自己/);
  assert.match(cli, /area lead "<區名>" "<Claude 聊天室>"/);
} else if (id === 'C125') {
  const cli = readFileSync(path.join(root, 'scripts/codenv-todo'), 'utf8');
  const engine = readFileSync(path.join(root, 'Sources/Workbench/CommanderEngine.swift'), 'utf8');
  const server = readFileSync(path.join(root, 'Sources/Workbench/BrowserServer.swift'), 'utf8');
  const window = readFileSync(path.join(root, 'Sources/Workbench/MainWindow.swift'), 'utf8');
  const team = readFileSync(path.join(root, 'Sources/Workbench/CommanderTeam.swift'), 'utf8');
  assert.match(cli, /cmd_name = "new" if engine == "claude" else "new_engine"/);
  assert.match(cli, /"area": area or ""/);
  assert.match(server, /case "new_engine":[\s\S]*?req\["area"\] as\? String/);
  assert.ok(/newEngineChat = \{ \[weak self\][\s\S]*?topic, area, worktree, done in[\s\S]*?topic: topic, area: area/.test(window), 'MainWindow forwards area through new_engine with the 07-4 worktree parameter');
  assert.match(engine, /func commanderCreateEngine\([\s\S]*?area: String\? = nil/);
  assert.match(engine, /if engine == "claude" \{[\s\S]*?topic: topic, area: area(?:, worktree: worktree)?\)/);
  assert.match(engine, /let r = commanderCreate\([\s\S]*?mcp: "lite", topic: topic, area: area(?:, worktree: worktree)?\)/);
  assert.match(engine, /store\.commanderCreateEngine\([\s\S]*?topic: topic, area: area(?:, worktree: worktree)?\)/);
  assert.match(team, /if let lead \{\s*g = lead\.area\.id/);
  assert.match(team, /let r = findArea\(areaWant, in: me\.session\)[\s\S]*?guard let a = r\.area else \{ return fail/);
} else if (id === 'C126') {
  const session = readFileSync(path.join(root, 'Sources/Workbench/ChatSession.swift'), 'utf8');
  const pane = readFileSync(path.join(root, 'Sources/Workbench/ChatPane.swift'), 'utf8');
  const effort = session.match(/func setEffort\(_ value: String\?\) \{([\s\S]*?)\n    \}/)?.[1] || '';
  assert.match(effort, /let label = value\.map\(Effort\.name\)/, 'notice uses the visible localized effort name');
  assert.match(effort, /if codexModel != nil[\s\S]*?codex\?\.effort = value[\s\S]*?下一則訊息起用/,
    'Codex records the new level and tells the user it starts next message');
  assert.match(effort, /if mlxModel != nil[\s\S]*?mlx\?\.effort = value[\s\S]*?下一則訊息起用/,
    'MLX records the new level and tells the user it starts next message');
  assert.match(effort, /if agyModel != nil \|\| copilotModel != nil[\s\S]*?if status == \.idle[\s\S]*?restartAgyIfIdle\(\)[\s\S]*?已重開，用/,
    'idle agy/Copilot restarts and reports the selected level');
  assert.match(effort, /restartForEffortWhenIdle = true[\s\S]*?這輪做完重開後用/,
    'working agy/Copilot schedules a restart after its turn');
  assert.match(session, /private var restartForEffortWhenIdle = false[\s\S]*?if status == \.idle, restartForEffortWhenIdle[\s\S]*?restartAgyIfIdle\(\)[\s\S]*?onStatus\?\(status\)/,
    'the old process is terminated before the idle callback can send another turn');
  assert.match(pane, /session\.onEffortNotice = \{ \[weak self\] message in self\?\.notice\(message\) \}/,
    'effort notice is shown in the chat pane');
  const translations = JSON.parse(readFileSync(path.join(root, 'Resources/i18n/en.json'), 'utf8'));
  assert.equal(translations['下一則訊息起用%@'], 'Using %@ starting with the next message');
  assert.equal(translations['已重開，用%@'], 'Restarted; using %@');
  assert.equal(translations['這輪做完重開後用%@'], 'Will restart and use %@ after this turn');
} else if (id === 'C122') {
  const prefs = readFileSync(path.join(root, 'Sources/Workbench/Prefs.swift'), 'utf8');
  const settings = readFileSync(path.join(root, 'Sources/Workbench/SettingsPages.swift'), 'utf8');
  const session = readFileSync(path.join(root, 'Sources/Workbench/ChatSession.swift'), 'utf8');
  const workspace = readFileSync(path.join(root, 'Sources/Workbench/Workspace.swift'), 'utf8');
  const cliTools = readFileSync(path.join(root, 'Sources/Workbench/CLITools.swift'), 'utf8');
  const buildSh = readFileSync(path.join(root, 'build.sh'), 'utf8');
  const releaseSh = readFileSync(path.join(root, 'release.sh'), 'utf8');
  assert.match(prefs, /@Published var compactGuard: Bool/);
  assert.match(prefs, /compactGuard = d\.object\(forKey: "compactGuard"\) as\? Bool \?\? true/);
  assert.match(settings, /Toggle\(L\("壓縮後自動補回上下文"\), isOn: \$p\.compactGuard\)/);
  assert.match(session, /static func claudeSettingsPath\(conversationID: String, compactGuard: Bool, protectSharedMemory: Bool\)/);
  assert.match(session, /claudeSettingsPath\(conversationID: conversationTag \?\? id,[\s\S]*?compactGuard: Prefs\.shared\.compactGuard && localEndpoint == nil/);
  assert.match(workspace, /env\["CODENV_COMPACT_DIR"\]/);
  assert.match(cliTools, /"compact-guard\.py"/);
  assert.match(buildSh, /compact-guard\.py/);
  assert.match(releaseSh, /compact-guard\.py:compact-guard：壓縮防失憶/);
} else if (id === 'C129') {
  const prefs = readFileSync(path.join(root, 'Sources/Workbench/Prefs.swift'), 'utf8');
  const settings = readFileSync(path.join(root, 'Sources/Workbench/SettingsPages.swift'), 'utf8');
  const session = readFileSync(path.join(root, 'Sources/Workbench/ChatSession.swift'), 'utf8');
  const workspace = readFileSync(path.join(root, 'Sources/Workbench/Workspace.swift'), 'utf8');
  assert.match(prefs, /@Published var childMemoryWriteGuard: Bool/);
  assert.match(prefs, /childMemoryWriteGuard = d\.object\(forKey: "childMemoryWriteGuard"\) as\? Bool \?\? true/);
  assert.match(settings, /Toggle\(L\("子聊天室不能直接改記憶"\), isOn: \$p\.childMemoryWriteGuard\)/);
  assert.ok(session.includes('sharedMemoryWriteDenyRules = ["Edit(~/.claude/projects/*/memory/**)"]'),
    'Edit(path) is the path-aware rule for Write, Edit, and MultiEdit');
  assert.ok(session.includes('memory-drafts/\\(safeName).md'), 'child system prompt names its memory-drafts file');
  assert.match(session, /請勿直接修改 ~\/\.claude\/projects\/\*\/memory\/\*\*（包括透過 Bash）/);
  assert.match(session, /Prefs\.shared\.childMemoryWriteGuard && !\(isCommanderChatProvider\?\(\) \?\? false\)/);
  assert.match(workspace, /isCommanderChatProvider = \{ \[weak self\] in self\?\.store\.sessions\.contains\(where: \{ \$0\.chief == cid \}\) \?\? false \}/);
  assert.match(session, /appendingPathComponent\("claude-settings"/);
} else if (id === 'C171') {
  const prefs = readFileSync(path.join(root, 'Sources/Workbench/Prefs.swift'), 'utf8');
  const native = readFileSync(path.join(root, 'scripts/exam/native.sh'), 'utf8');
  const privacy = readFileSync(path.join(root, 'scripts/exam/archive_readme_privacy.py'), 'utf8');
  assert.match(prefs, /archiveSummaryUseAgy = Self\.boolPref\(d, "archiveSummaryUseAgy"\) \?\? true/,
    '封存摘要 fallback 偏好在未設定時預設開啟');
  assert.match(native, /from archive_readme_privacy import phone_masked/,
    'C171 README 探針透過專用判斷函式檢查電話遮罩');
  assert.match(privacy, /ARCHIVE_METADATA[\s\S]*UUID_PATTERN[\s\S]*TIMESTAMP_PATTERNS[\s\S]*def phone_masked/,
    'C171 掃描摘要本文並排除產生器 metadata、UUID 與明確格式時間戳');
} else if (id === 'C172' || id === 'C173') {
  const prefs = readFileSync(path.join(root, 'Sources/Workbench/Prefs.swift'), 'utf8');
  assert.match(prefs, /commanderCompletionNotices = Self\.boolPref\(d, "commanderCompletionNotices"\) \?\? true/,
    '派工完成通知偏好在未設定時預設開啟');
} else if (id === 'C134') {
  const agy = readFileSync(path.join(root, 'Sources/Workbench/AgyBridge.swift'), 'utf8');
  const session = readFileSync(path.join(root, 'Sources/Workbench/ChatSession.swift'), 'utf8');
  const engine = readFileSync(path.join(root, 'Sources/Workbench/CommanderEngine.swift'), 'utf8');
  const stuck = readFileSync(path.join(root, 'Sources/Workbench/CommanderStuck.swift'), 'utf8');
  const server = readFileSync(path.join(root, 'Sources/Workbench/BrowserServer.swift'), 'utf8');
  const harness = readFileSync(path.join(root, 'Sources/Workbench/TestHarness.swift'), 'utf8');
  assert.match(agy, /case "error", "error_event", "fatal_error"/);
  assert.ok(agy.includes('程序結束碼 \\(code)'), '非零結束訊息帶實際程序碼');
  assert.match(session, /processExitFailure\(code: proc\.terminationStatus, stderr: self\.stderrTail\)/);
  // 已移除「ChatSession 內 failureGeneration += 1」的靜態原始碼比對：依重構搬走（c96a605 之後，codenv 裁決已過時）；失敗不誤報成功的行為由 native.sh C134 後半（exit／error／resume 三種都回錯誤並通知總指揮）覆蓋
  assert.match(engine, /failureGeneration > baselineFailure/);
  assert.match(engine, /commanderDeliver\(pane, message, [^)]*\bdeliveryTimeout\b[^)]*\bdelivered\b[^)]*\)/,
    '擴充訊息 ID／steer 參數後仍傳入 deliveryTimeout 與 delivered');
  // 已移除「CommanderStuck 內『引擎回報失敗』字面」的靜態比對：依 07-22／56339ac，失敗訊息搬到獨立的終端結果判斷；行為由 native.sh C134 後半的 exit／error／resume 行為斷言覆蓋（codenv 裁決）
  assert.match(server, /req\["wait"\] as\? Bool == true \? sendTimeout : 60/);
  const agyFailureStart = harness.indexOf('private func agyFailureTimeoutDiagnostics(');
  const nextProbe = harness.indexOf('private func actualLidProbePaths(', agyFailureStart);
  assert.ok(agyFailureStart >= 0 && nextProbe > agyFailureStart,
    'TestHarness.swift contains the bounded agy-failure probe helpers');
  const agyFailureProbe = harness.slice(agyFailureStart, nextProbe);
  const startFunction = agyFailureProbe.indexOf('private func startAgyFailureProbe(');
  const waitFunction = agyFailureProbe.indexOf('private func waitForAgyFailureNotice(');
  assert.ok(startFunction >= 0 && waitFunction > startFunction,
    'agy-failure probe separates setup from notice waiting');
  const startProbe = agyFailureProbe.slice(startFunction, waitFunction);
  const waitProbe = agyFailureProbe.slice(waitFunction);
  const diagnosticsProbe = agyFailureProbe.slice(0, startFunction);

  const commanderSend = startProbe.indexOf('main.commanderSendChat(');
  const waitAfterSend = startProbe.indexOf('waitForAgyFailureNotice(');
  assert.ok(commanderSend >= 0 && waitAfterSend > commanderSend,
    'probe starts waiting only after commanderSendChat completes');
  assert.match(waitProbe, /var output:\s*\[String:\s*Any\]\s*=\s*response/,
    'successful probe output preserves the original commanderSendChat response fields');
  const takeNotice = waitProbe.indexOf('CollabBoardModel.takeNotices(for: chiefID)');
  const deadlineCheck = waitProbe.indexOf('DispatchTime.now() >= noticeDeadline');
  const nextPoll = waitProbe.indexOf('DispatchQueue.main.asyncAfter');
  assert.ok(takeNotice >= 0 && deadlineCheck > takeNotice && nextPoll > deadlineCheck,
    'probe checks takeNotices, checks its deadline, then schedules another poll while waiting');
  assert.match(waitProbe, /CollabBoardModel\.takeNotices\(for:\s*chiefID\)/,
    'probe takes the supervisor notice only from its notice-wait polling path');
  assert.match(waitProbe, /finish\(notice,\s*timedOut:\s*false\)/,
    'a queued notice finishes the wait as non-timeout');
  assert.match(waitProbe, /finish\(nil,\s*timedOut:\s*true\)/,
    'an expired wait still emits an empty notice and marks the timeout');

  const timeoutIsFortySeconds = /\.seconds\(\s*40\s*\)|\.milliseconds\(\s*40_?000\s*\)/.test(waitProbe);
  assert.ok(timeoutIsFortySeconds,
    'notice wait deadline remains 40 seconds (seconds or equivalent milliseconds)');
  assert.match(waitProbe, /\.milliseconds\(\s*250\s*\)|\.seconds\(\s*0\.25\s*\)/,
    'notice wait polling interval remains 0.25 seconds');
  assert.match(waitProbe, /DispatchQueue\.main\.asyncAfter[\s\S]*?pollNotice/,
    'empty notice polls schedule another poll instead of taking only once');

  for (const field of [
    'chatNoticesFileExists',
    'commanderChatSentAnyDuringWait',
    'takeNoticesPollSummary',
    'takeNoticesReadFailureCountObserved',
  ]) {
    assert.ok(diagnosticsProbe.includes(`diagnostics["${field}"]`),
      `timeout diagnostics retain ${field}`);
  }
  assert.match(waitProbe, /output\["notice"\]\s*=\s*notice\s*\?\?\s*""/);
  assert.match(waitProbe, /output\["noticeWaitTimedOut"\]\s*=\s*timedOut/,
    'probe output reports whether the notice wait timed out');
  const timedOutBranch = waitProbe.indexOf('if timedOut {');
  const diagnosticsCall = waitProbe.indexOf('agyFailureTimeoutDiagnostics(');
  const diagnosticsMerge = waitProbe.indexOf('for (key, value) in diagnostics');
  assert.ok(timedOutBranch >= 0 && diagnosticsCall > timedOutBranch && diagnosticsMerge > diagnosticsCall,
    'timeout-only diagnostics are added only on timeout; normal response fields remain unchanged');
} else if (id === 'C136') {
  const graph = readFileSync(path.join(root, 'Sources/Workbench/ChatGraph.swift'), 'utf8');
  assert.match(graph, /d3-force[\s\S]*ISC License/);
  assert.match(graph, /force-graph[\s\S]*MIT License/);
  assert.match(graph, /obsidian-orrery[\s\S]*MIT License/);
  assert.match(graph, /func spawnPositions\(for infos: \[GraphNodeInfo\]/);
  assert.match(graph, /parentPos = ensurePosition\(pid, visiting: &visiting\)/);
  assert.match(graph, /base \* max\(1, sqrt\(n\) \/ 2\)/);
  assert.match(graph, /func collide\(iterations: Int = 2\)/);
  assert.match(graph, /collide\(iterations: 2\)/);
  assert.doesNotMatch(graph, /if d2 > 160_000 \{ continue \}/);
  assert.match(graph, /alpha \+= \(alphaTarget - alpha\) \* alphaDecay/);
  assert.match(graph, /var velocityDecay: CGFloat = 0\.6/);
  assert.match(graph, /func warmup\(ticks: Int =/);
} else if (id === 'C137') {
  const graph = readFileSync(path.join(root, 'Sources/Workbench/ChatGraph.swift'), 'utf8');
  const groups = readFileSync(path.join(root, 'Sources/Workbench/Groups.swift'), 'utf8');
  const harness = readFileSync(path.join(root, 'Sources/Workbench/TestHarness.swift'), 'utf8');
  assert.match(groups, /var areaLeadID: UUID\? = nil/);
  assert.match(graph, /struct GraphAssignment/);
  assert.match(graph, /static func parseDispatchMessage/);
  assert.match(graph, /static func formatToolAction/);
  assert.match(graph, /"arrowDirection": "\\\(fromNode\.info\.rawTitle\)->\\\(n\.info\.rawTitle\)"/);
  assert.match(graph, /static func stageColorName/);
  for (const hex of ['#FF9F1C', '#30D158', '#4DA3FF', '#FF453A']) assert.ok(graph.includes(hex), `stage color ${hex}`);
  assert.match(graph, /drawHoverCard\(g: g, node: nodes\[hi\], assign: assign/);
  assert.match(graph, /func activeAreaLead\(for group: ConvGroup/);
  assert.match(graph, /out\[i\]\.areaLeadID = lead\.id/);
  assert.match(graph, /out\[i\]\.isAreaLead = true/);
  assert.match(graph, /func spawnLinkLength\([\s\S]*?if childKind == \.area, let childID[\s\S]*?subtreeCounts\[childID\]/);
  assert.match(graph, /lastDrawnEdgeLabels/);
  assert.match(graph, /ChatInfoCard\.shared\.cancel\(\) \/\/ 關聯圖內已畫工作卡/);
  assert.match(harness, /case "assignment-fixture"/);
  assert.match(harness, /case "edge-hover"/);
  assert.match(harness, /case "theme":/);
  assert.match(harness, /tracker\.seed/);
} else if (id === 'C140') {
  const screen = readFileSync(path.join(root, 'Sources/Workbench/TestScreen.swift'), 'utf8');
  const main = readFileSync(path.join(root, 'Sources/Workbench/main.swift'), 'utf8');
  const mainWindow = readFileSync(path.join(root, 'Sources/Workbench/MainWindow.swift'), 'utf8');
  const native = readFileSync(path.join(root, 'scripts/exam/native.sh'), 'utf8');
  // 僅測試旗標會裝；無目標螢幕時隔離測試的視窗先隱藏，正式版不走這裡。
  assert.match(screen, /guard !guardInstalled, screen != nil \|\| hiddenRequested else \{ return \}/);
  assert.match(screen, /guard let test = screen else \{ concealIfNoScreen\(w\); return \}/);
  assert.match(main, /TestScreen\.installGuard\(\)/);
  assert.match(mainWindow, /TestScreen\.concealIfNoScreen\(w\)/);
  // 所有顯示的入口都要攔
  for (const sel of ['orderWindow:relativeTo:', 'orderFront:', 'orderFrontRegardless', 'orderBack:', 'makeKeyAndOrderFront:', 'setIsVisible:', 'runModalForWindow:', 'runModal'])
    assert.ok(screen.includes(`"${sel}"`), '沒攔 ' + sel);
  // 搬進去之前排除跟著父視窗的子視窗與 sheet；獨立視窗一律 fit（太大就縮）
  assert.match(screen, /w\.parent == nil, w\.sheetParent == nil/);
  assert.doesNotMatch(screen, /w\.level\.rawValue < NSWindow\.Level\.popUpMenu/, '獨立視窗不因階層被漏掉');
  assert.match(screen, /\$0\.frame != test\.frame && \$0\.frame\.intersects\(f\) \}\) else \{ return \}\s+fit\(w\)/);
  assert.match(screen, /Timer\(timeInterval: 0\.05, repeats: true\)/);
  const c140 = native.match(/C140\)([\s\S]*?)\n    ;;/)?.[1] || '';
  assert.match(c140, /"\$WATCH" "\$BIN" 5 "\$T\/watch\.txt" "\$T\/watch\.ready" &/);
  assert.ok(c140.indexOf('"$WATCH" "$BIN"') < c140.indexOf('open -g -n "$APP"'), 'CGWindow 監看器要先待命，再背景開 App');
  assert.match(c140, /open -g -n "\$APP" --args[\s\S]*--test-screen ipad/);
  assert.doesNotMatch(c140, /"\$BIN" --state-dir/, '不能直接啟動 binary，必須用 open -g');
} else throw Error('未知案例：' + id);
console.log('斷言通過 ' + id);
