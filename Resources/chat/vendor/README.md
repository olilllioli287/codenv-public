# vendor：聊天畫面用到的函式庫

都是從 npm 下載的發行檔原封不動放進來（`npm pack` 後解開），畫面不連網。

| 檔案 | 套件 | 版本 | 授權 | 授權全文 |
|---|---|---|---|---|
| `marked.umd.js` | [marked](https://github.com/markedjs/marked)（Markdown 解析） | 18.1.1 | MIT | `marked.LICENSE` |
| `highlight.min.js` | [@highlightjs/cdn-assets](https://github.com/highlightjs/highlight.js)（程式碼上色，內建常用 36 種語言，含 Swift、Python、TS、Bash、JSON、diff…） | 11.12.0 | BSD-3-Clause | `highlight.LICENSE` |
| `katex/` | [katex](https://github.com/KaTeX/KaTeX)（數學式，只放 woff2 字型；更新方法見下方） | 0.16.11 | MIT | `katex.LICENSE` |

highlight.js 的配色 CSS 沒有用，上色顏色寫在 `../chat.css`（取自 setTheme 給的 ANSI 色）。

更新方法：`npm pack marked@<版本> @highlightjs/cdn-assets@<版本>`，解開後把
`package/lib/marked.umd.js`、`package/highlight.min.js` 和兩個 LICENSE 換掉，再跑一次 test.html 確認。

KaTeX 更新方法：`npm pack katex@<版本>`，解開後把 `package/dist/katex.min.js`、
`package/dist/katex.min.css` 放到 `katex/`，只複製 `package/dist/fonts/*.woff2` 到
`katex/fonts/`，並用 `package/LICENSE` 更新 `katex.LICENSE`。CSS 裡的 woff／ttf 路徑保留原樣，
瀏覽器會優先使用 woff2；更新後跑 `node scripts/test-math.mjs`，再開 test.html 的「數學式」確認。
