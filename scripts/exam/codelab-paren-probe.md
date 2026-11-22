# codelab C++ 括號與 Enter 縮排探針

此探針載入實際的 `Resources/codelab/editor.html`，在瀏覽器內以 `ed.trigger('keyboard', 'type', { text })` 模擬字元與 `\n` Enter。依派工，尚未執行；請由施工-sonnet 在 WKWebView 或 Chrome 實測。

在 worktree 根目錄啟動只綁本機的靜態伺服器：

```sh
python3 -m http.server 8765 --bind 127.0.0.1
```

以 Chrome 開啟 `http://127.0.0.1:8765/scripts/exam/codelab-paren-probe.html`。完成後頁面應顯示 **31 通過、0 失敗**。輸出文字中的 `·` 代表一個 ASCII 空格；探針本身以四個實際空格做精確字串比對。

探針每次 `type` 後會讓出一個事件迴圈（`MessageChannel`）：真實鍵盤的每個按鍵是獨立事件，若在同一個呼叫堆疊內連續輸入，Monaco 尚未對剛輸入的行做 tokenization，「單行內容後退回」的 `onEnterRules` 會看不到那一行（2026-11-16 實測：未讓出時 26 通過、5 失敗；讓出後 31 通過）。離屏 WKWebView 的 `setTimeout` 會被節流，所以不用它。

## 084ad3：字串內括號不自動補齊

探針也檢查原 C++ 語言設定的欄位與值仍保留，只有 `(`、`[`、`{` 的 `autoClosingPairs` 增加 `notIn: ['string']`；單、雙引號仍照常自動補齊。

| 輸入序列 | 預期文字 |
| --- | --- |
| `"` → `(` | `"("` |
| `"` → `[` | `"["` |
| `"` → `{` | `"{"` |
| `(` | `()` |
| `[` | `[]` |
| `{` | `{}` |
| `"` | `""` |
| `'` | `''` |

## 54dff2：控制行 Enter 縮排與退縮

每列先把游標放在初始文字尾端，再依序輸入「輸入序列」。

| 初始文字 | 輸入序列 | 預期文字 |
| --- | --- | --- |
| `for (int i = 0; i < 3; ++i)` | `\n` → `work();` → `\n` | `for (int i = 0; i < 3; ++i)\n····work();\n` |
| `if (ready && check(value))` | `\n` → `work();` → `\n` | `if (ready && check(value))\n····work();\n` |
| `if (ready) work();\nelse` | `\n` → `return 0;` → `\n` | `if (ready) work();\nelse\n····return 0;\n` |
| `while (ready)` | `\n` → `work();` → `\n` | `while (ready)\n····work();\n` |
| `if (ready) {` | `\n` | `if (ready) {\n····` |
| `} else {` | `\n` | `} else {\n····` |
| `int value = 1;` | `\n` | `int value = 1;\n` |
| `for (int i=0; i<3; ++i) work();` | `\n` | `for (int i=0; i<3; ++i) work();\n` |
| `else if (ready)` | `\n` | `else if (ready)\n` |
| `if (ready);` | `\n` | `if (ready);\n` |
| `while (x);` | `\n` | `while (x);\n` |
| `do { } while (ready);` | `\n` | `do { } while (ready);\n` |
| `// if (ready)` | `\n` | `// if (ready)\n` |
| `const char *text = "for (x)";` | `\n` | `const char *text = "for (x)";\n` |
| `/* comment\nif (ready)` | `\n` | `/* comment\nif (ready)\n` |
| `for (` | `\n` | `for (\n····` |
| `call(` | `\n` | `call(\n····` |
| `if (ready) // body follows` | `\n` → `work();` → `\n` | `if (ready) // body follows\n····work();\n` |

大括號案例確認既有縮排仍作用；`for`、`if`、`else`、`while` 完整無括號區塊的標頭按 Enter 後，下一行增加一層；單行敘述以分號結束後再按 Enter，`onEnterRules` 將新行退回標頭縮排。控制條件必須有非空內容，未配平的 `for (` 不會觸發新增的 body 縮排；它和普通 `call(` 一樣保留 Monaco 原有的開括號縮排。行註解與 C++ tokenizer 判成 comment/string 的括號字元會在縮排規則比對前被移除，因此註解／字串內的 `for`、`if` 不會符合控制標頭樣式。`else if`、同行 body、`while (x);`、`} else {`、do-while 尾端都由探針檢查不會套用新增的控制行規則。

一般 `editor.html` 不會啟用探針介面，不改 Swift 訊息橋接。瀏覽器探針、縮排互動與括號高亮尚待實測；本次未 build、未開 App。
