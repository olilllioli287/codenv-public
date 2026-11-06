import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const chat = new URL('../Resources/chat/', import.meta.url);
const context = vm.createContext({});
context.window = context;
for (const file of ['vendor/katex/katex.min.js', 'vendor/marked.umd.js', 'math.js']) {
  vm.runInContext(readFileSync(new URL(file, chat), 'utf8'), context, { filename: file });
}
const { protect, restore } = context.wbMath;
const render = (src) => {
  const { text, items } = protect(src);
  return restore(context.marked.parse(text), items);
};
let passed = 0;
function test(name, run) {
  try { run(); passed++; }
  catch (error) { console.error('失敗：' + name); throw error; }
}

const cases = String.raw`f(x)=\begin{cases} -x & 若 x<0 \\ x & 若 x\ge 0 \end{cases}`;
for (const [name, tex, open, close, display] of [
  ['行內分段函數', cases, '$', '$', false],
  ['獨立分段函數', cases, '$$\n', '\n$$', true],
  ['行內分數', String.raw`\frac{a}{b}`, '$', '$', false],
  ['獨立分數', String.raw`\frac{a}{b}`, '$$', '$$', true],
  ['極限', String.raw`\lim_{x\to 0}\frac{\sin x}{x}=1`, '$$', '$$', true],
  ['小括號分數', String.raw`\frac{a}{b}`, '\\(', '\\)', false],
  ['中括號分數', String.raw`\frac{a}{b}`, '\\[\n', '\n\\]', true],
]) {
  test(name, () => {
    const src = open + tex + close;
    const { text, items } = protect(src);
    assert.equal(items.length, 1);
    assert.equal(items[0].raw, src);
    assert.equal(items[0].display, display);
    assert.match(text, /^[A-Za-z0-9]+$/);
    const html = render(src);
    assert.match(html, /class="katex"/);
    assert.equal(html.includes('class="katex-display"'), display);
    assert.doesNotMatch(html, /katex-error|WBMATHPLACEHOLDER/);
    if (tex === cases) assert.match(html, /若/);
  });
}

for (const src of [
  '$5 和 $10', '花了 $3', String.raw`\$5 和 \$10`,
  '$ x$', '$x $', '$x$2', '$x\ny$', '\\(x\ny\\)',
  '`$x$`', '``含 `$x$` 的程式碼``',
  '```js\nconst price = "$5"; // $x$ 和 $$y$$\n```',
  '````\n```\n$x$\n````', '```\n$x$',
  '~~~\n$x$\n~~~',
  '$$未收尾 <tag> & 後面的字 $x$',
  '\\[未收尾 $x$',
]) {
  test('保留原文：' + src, () => {
    const { text, items } = protect(src);
    assert.equal(text, src);
    assert.equal(items.length, 0);
    assert.equal(restore(text, items), src);
    assert.doesNotMatch(render(src), /class="katex"/);
  });
}

test('錯誤公式不丟例外', () => {
  const html = render(String.raw`$\frac{1}{$`);
  assert.match(html, /katex-error/);
});
test('程式碼前後的數學式', () => {
  const src = '$a$\n\n```\n$b$\n```\n\n`$c$` 與 $d$';
  assert.equal(protect(src).items.length, 2);
  const html = render(src);
  assert.equal((html.match(/class="katex"/g) || []).length, 2);
  assert.match(html, /<code>\$c\$<\/code>/);
  assert.match(html, /<pre><code>\$b\$/);
});
test('跳脫分隔符與成對反斜線', () => {
  assert.equal(protect(String.raw`\$x\$ \\(y\\)`).items.length, 0);
  assert.equal(protect(String.raw`\\$x$`).items.length, 1);
});
test('原文中的佔位名稱不會碰撞', () => {
  const html = render('WBMATHPLACEHOLDER0END 與 $x$');
  assert.match(html, /WBMATHPLACEHOLDER0END/);
  assert.match(html, /class="katex"/);
});
test('串流從未收尾到完成', () => {
  assert.equal(protect('$$\nx + y\n後面的字').text, '$$\nx + y\n後面的字');
  assert.match(render('$$\nx + y\n$$'), /class="katex"/);
});
test('佔位在 Markdown 強調、表格與連結內仍能還原', () => {
  const html = render('**$x_1$**\n\n| 公式 |\n|---|\n| $a \\mid b$ |\n\n[$y$](https://example.com)');
  assert.equal((html.match(/class="katex"/g) || []).length, 3);
  assert.doesNotMatch(html, /WBMATHPLACEHOLDER/);
});

const katex = context.katex;
test('中文包裝、既有文字與 KaTeX 選項', () => {
  const calls = [];
  context.katex = { renderToString(tex, options) { calls.push({ tex, options }); return '<span class="katex"></span>'; } };
  try {
    render('$$' + cases + '$$');
    render(String.raw`$\text{中文 {若} x} + 中文$`);
    assert.match(calls[0].tex, /\\text\{若 \}x/);   // 中文後的空白要包在 \text 裡，不然「若 x」會黏成「若x」
    assert.equal(calls[1].tex, String.raw`\text{中文 {若} x} + \text{中文}`);
    assert.equal(JSON.stringify(calls[0].options), JSON.stringify({
      displayMode: true, throwOnError: false, strict: 'ignore', trust: false, output: 'html',
    }));
  } finally { context.katex = katex; }
});
for (const [name, replacement] of [
  ['KaTeX 不存在', undefined],
  ['KaTeX 丟出例外', { renderToString() { throw new Error('測試失敗回退'); } }],
]) {
  test(name + '時跳脫原文', () => {
    context.katex = replacement;
    try {
      const { text, items } = protect('$<img src="x"> & \'$');
      assert.equal(restore(text, items), '$&lt;img src=&quot;x&quot;&gt; &amp; &#39;$');
    } finally { context.katex = katex; }
  });
}
test('HTML 屬性內不插入 KaTeX 標籤', () => {
  const { text, items } = protect('$x$');
  assert.equal(restore('<a title="' + text + '">連結</a>', items), '<a title="$x$">連結</a>');
});

// 直接測聊天畫面現用的入口，確認有／沒有數學式模組都能轉 Markdown。
const chatSource = readFileSync(new URL('chat.js', chat), 'utf8');
const entry = chatSource.slice(chatSource.indexOf('  function renderMarkdownHtml('), chatSource.indexOf('  function setMarkdown('));
vm.runInContext('const md = new marked.Marked({ gfm: true, breaks: true }); const esc = (s) => s;\n' + entry, context);
test('聊天畫面的 Markdown 與數學式整合', () => {
  const html = context.renderMarkdownHtml('**分數**：$\\frac{a}{b}$', 'sync');
  assert.match(html, /<strong>分數<\/strong>/);
  assert.match(html, /class="katex"/);
});
test('未載入 wbMath 時維持原本行為', () => {
  const math = context.wbMath;
  delete context.wbMath;
  try {
    assert.equal(context.renderMarkdownHtml('**原文** $x$', 'sync'), '<p><strong>原文</strong> $x$</p>\n');
  } finally { context.wbMath = math; }
});

console.log(`數學式測試通過：${passed} 項`);
