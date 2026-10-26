# vendor：聊天畫面用到的函式庫

都是從 npm 下載的發行檔原封不動放進來（`npm pack` 後解開），畫面不連網。

| 檔案 | 套件 | 版本 | 授權 | 授權全文 |
|---|---|---|---|---|
| `marked.umd.js` | [marked](https://github.com/markedjs/marked)（Markdown 解析） | 18.1.1 | MIT | `marked.LICENSE` |
| `highlight.min.js` | [@highlightjs/cdn-assets](https://github.com/highlightjs/highlight.js)（程式碼上色，內建常用 36 種語言，含 Swift、Python、TS、Bash、JSON、diff…） | 11.12.0 | BSD-3-Clause | `highlight.LICENSE` |

highlight.js 的配色 CSS 沒有用，上色顏色寫在 `../chat.css`（取自 setTheme 給的 ANSI 色）。

更新方法：`npm pack marked@<版本> @highlightjs/cdn-assets@<版本>`，解開後把
`package/lib/marked.umd.js`、`package/highlight.min.js` 和兩個 LICENSE 換掉，再跑一次 test.html 確認。
