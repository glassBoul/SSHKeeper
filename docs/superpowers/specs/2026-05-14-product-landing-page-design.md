# Spec — SSHKeeper 产品介绍页（单页 landing）

- 日期：2026-05-14
- 范围：本地静态单页，中英双语，提供产品介绍与 DMG 下载
- 部署：本地生成、可上传任意静态主机（Vercel / Netlify / GitHub Pages / Cloudflare Pages / nginx 均可）
- 不在范围：博客、changelog、独立 FAQ 页、统计埋点、CMS、build pipeline

## 1. 文件结构

```
web/
├── index.html           # 全部文案 + 结构（中英文本并存于 DOM）
├── style.css            # Apple 极简视觉系统，含 dark mode
├── script.js            # 语言切换、SHA256 复制、Intel Mac 检测、FAQ 折叠
├── favicon.svg          # 简易 SVG 图标
└── SSHKeeper-1.0.0.dmg  # 占位，发布时替换为真实 DMG
```

零依赖、零 build step。直接 `open web/index.html` 可预览；整个 `web/` 目录上传到任何静态主机即上线。

## 2. 页面结构

从上到下 7 个 section：

1. **Nav** — Logo + 产品名「SSHKeeper」+ 右侧 `[中文 | EN]` segmented 切换 + `[⬇ 下载]` 锚定按钮
2. **Hero** — 主标题 + 副标题 + 主 CTA + macOS 窗口 mockup（CSS 画）
3. **Features** — 2×2 grid，4 张卡片，line-style SVG 图标 + 标题 + 1-2 行描述
4. **Screenshots** — 2 张大 mockup（终端 + DB 工作台）
5. **Download** — 主下载按钮 + 版本号 / 大小 / SHA256 + 系统要求 + 签名/公证标识
6. **FAQ** — 6 条 `<details>`/`<summary>` 折叠
7. **Footer** — 公司名（中英）+ 邮件 + © 年份 + ICP 占位

Section 间用大留白（96-128px 垂直）+ 1px 细分隔线。

## 3. 视觉系统

| 项 | 值 |
|---|---|
| 字体 | `-apple-system, BlinkMacSystemFont, "Inter", "PingFang SC", "Helvetica Neue", sans-serif`；不引外部 webfont |
| 行高 | 正文 1.6、标题 1.15 |
| 字号 | hero 标题 `clamp(48px, 6vw, 72px)`、副标题 20-22、正文 16、caption 13 |
| 主色（浅） | 文字 `#1d1d1f`、背景 `#fbfbfd`、accent `#0071e3` |
| 主色（深） | 文字 `#f5f5f7`、背景 `#000`、accent `#2997ff`（`prefers-color-scheme: dark` 自动切） |
| 圆角 | 卡片 18px、按钮 980px（pill）、mockup 窗口 12px |
| 阴影 | `0 30px 60px -30px rgba(0,0,0,.12)`，仅 mockup 用 |
| 间距系统 | 8px 基数；section 上下 padding 96-128 |
| 容器 | `max-width: 980px`，居中 |
| 响应式断点 | 768px：折叠 nav、2×2 feature grid 转 1 列、hero 字号缩小 |
| 动效 | `prefers-reduced-motion` 一键关；hero CSS 入场 fade+translate 1 次；scroll 无 JS 监听 |

## 4. Feature 4 块

每块包含 line-style SVG（24×24，`fill="none"`，`stroke="currentColor"`，stroke-width `1.5`）+ 标题 + 描述。SVG 内联在 HTML 里，不发额外请求。

| Icon | 标题 | 描述 |
|---|---|---|
| 终端框 + `_>` | SSH 主机管理 / SSH Hosts | 统一管理 ssh config + Keychain 密码 + 私钥；右键直接开终端会话。多标签、跨主机分组。<br/>Manage ssh config + Keychain passwords + private keys in one place. Right-click to open terminal sessions. Tabs, groups. |
| 数据库圆柱（3 段） | 数据库工作台 / Database Workbench | MySQL & PostgreSQL 浏览、SQL 编辑器（自动补全 + EXPLAIN）、表/字段/索引可视化改、行级增删改。支持 SSH 隧道。<br/>MySQL & PostgreSQL browser, SQL editor with autocomplete + EXPLAIN, visual table/column/index editing, row-level CRUD. Via SSH tunnel. |
| 地球网格 | 面板自动登录 / Panel Auto-Login | 把后台 / 路由器 / NAS 的网页登录页喂进来，密码存 Keychain，再访问一键登录。多面板单窗口 tab 切换。<br/>Feed in web admin / router / NAS login pages, store passwords in Keychain, one-click login on revisit. Multi-panel tabs in single window. |
| 盾 + 勾 | 安全与性能 / Security & Performance | Apple Developer ID + 公证；密码全部走 macOS Keychain；Apple Silicon 原生 arm64；SwiftNIO 异步 DB 连接。<br/>Apple Developer ID + notarized. All passwords in macOS Keychain. Native arm64 for Apple Silicon. SwiftNIO async DB connections. |

实际 SVG path 在实现时给完整 24×24 矢量（线宽 1.5，圆角端点）。

## 5. 截图区 mockup（CSS 画）

不用真实截图。每张是 CSS + HTML 模拟的 macOS 窗口：
- 顶部 traffic light 三圆点（红黄绿）
- 窗口标题
- 内容区：用单色块 + 等宽字体文字（伪 SQL、伪表头）模拟内容
- 圆角 12px + 阴影

两张 mockup 各占一行，配标题：
- 「内置终端，多标签会话」 / "Built-in terminal with tabbed sessions"
- 「数据库工作台，所见即所改」 / "Database workbench, edit what you see"

HTML 注释里写明 `<!-- TODO: 替换为真实截图 -->`，你后期拿 PNG 替换很容易。

## 6. 双语切换机制

**思路**：同一 HTML 里每条文案以 `<span data-lang>` 包裹两份；JS 切换时改 `<html lang>` + 直接 mutate 对应文本节点（避免 `::before` 注入文本无法选中的问题）。

**HTML 写法**（节点级双份）：
```html
<h1>
    <span data-lang="zh">写给 macOS 的连接 / 数据 / 面板工作台</span>
    <span data-lang="en">The macOS workbench for connections, data, panels</span>
</h1>
```

**CSS**：
```css
html[lang="zh"] [data-lang="en"] { display: none; }
html[lang="en"] [data-lang="zh"] { display: none; }
```

**JS 核心（10 行内）**：
```js
function setLang(lang) {
    document.documentElement.lang = lang;
    localStorage.setItem("lang", lang);
    document.querySelectorAll("[data-toggle-lang]").forEach(btn => {
        btn.setAttribute("aria-current", btn.dataset.toggleLang === lang ? "true" : "false");
    });
}
const stored = localStorage.getItem("lang");
const initial = stored || (navigator.language.startsWith("zh") ? "zh" : "en");
setLang(initial);
```

**默认语言决策**：localStorage `lang` 优先 → `navigator.language` 匹配 `zh*` → 默认 `zh`。

**切换按钮**：右上角 segmented `[中文 | EN]`，`aria-current="true"` 标识当前态，accent 色描边。点击调 `setLang(...)`。

**SEO**：HTML 默认 `lang="zh"`；中英两条 `<meta name="description">` 各写一份；搜索引擎按 Accept-Language 抓不到差异但能扫到正文。

## 7. 下载区

```
SSHKeeper for macOS
1.0.0 · 约 12 MB · arm64
[⬇  下载 .dmg]
系统要求：macOS 14.0 Sonoma 或更高 · Apple Silicon (M 系列)
✓ Apple Developer ID 签名     ✓ Apple Notarized
SHA256: a1b2c3...e9f0  [复制]
```

**实现细节**：
- 主按钮：`<a download href="./SSHKeeper-1.0.0.dmg">` —— `download` 属性强制浏览器下载而非内联打开
- 版本号 / 大小 / SHA256 用独立 `<span>` 包裹，配 `<!-- TODO: 发布时填实际值 -->` 注释方便定位
- SHA256「复制」按钮：`navigator.clipboard.writeText(text)`；成功后按钮文字 1.5s 内显示「已复制」
- 系统要求双行 `✓` 列出 macOS 版本 + 架构
- Intel Mac 嗅探：JS 检测 `navigator.userAgent` 中 `Intel Mac OS X`，按钮下方 inline 显示「检测到 Intel Mac，本应用仅支持 Apple Silicon」。无脚本时不影响主流程。

## 8. FAQ 6 条

原生 `<details>` / `<summary>`，无 JS 依赖。每条标题中英文并列双份（同语言切换机制）。CSS 加旋转的 `▸` 三角符号 + `[open]` 状态过渡。

| 问题 | 答案要点（中文 / English） |
|---|---|
| 为什么 Intel Mac 不支持？/ Why no Intel Mac support? | SwiftNIO + Swift 6 严格并发对 arm64 优化更稳；维护单架构能更快迭代。需求集中再补。<br/>SwiftNIO + Swift 6 strict concurrency runs cleanest on arm64. We focus on one architecture to ship faster. Will revisit if demand consolidates. |
| 我的密码存在哪？/ Where are my passwords stored? | 全部存 macOS Keychain；SSHKeeper 不写明文到磁盘。Keychain ACL 限定只 SSHKeeper 二进制可读，换签名密钥也读不到。<br/>All in macOS Keychain. Never written to disk in plaintext. Keychain ACL allows only the signed SSHKeeper binary to read — even a re-signed copy cannot. |
| 第一次打开报「无法验证开发者」？/ "Cannot verify developer" on first open? | Gatekeeper 公证缓存未刷新。右键 App → 打开 → 弹窗确认；或 `xattr -dr com.apple.quarantine /Applications/SSHKeeper.app`。<br/>Gatekeeper notarization cache miss. Right-click App → Open → confirm; or run `xattr -dr com.apple.quarantine /Applications/SSHKeeper.app`. |
| 支持 SSH 隧道连数据库吗？/ Database via SSH tunnel? | 支持。编辑数据库时勾「通过 SSH 隧道」并选 ssh config 中的跳板机；连接时自动 `ssh -N -L lport:host:port alias`。<br/>Yes. In the Database editor, enable "Via SSH tunnel" and pick a host from ssh config. Auto-runs `ssh -N -L lport:host:port alias`. |
| 数据库密码安全吗？/ Database password safety? | 与 SSH 密码同策略：Keychain + 二进制签名校验。SQL 全部参数化 `?` + bindings，无字符串拼接。可强制 TLS。<br/>Same policy as SSH: Keychain + signed binary check. All SQL is parameterized (`?` + bindings), no string concat. TLS can be enforced. |
| 商业支持 / 反馈邮箱 / Support & feedback | `sshkeeper@feilian.cc`（`mailto:`）。Bug、商业授权、定制开发都走这里；通常 1-2 个工作日回复。<br/>Email `sshkeeper@feilian.cc`. Bugs, commercial licensing, custom development — typical reply 1-2 business days. |

## 9. Footer

```
飞链数字科技南通有限公司
Feilian Digital Technology (Nantong) Co., Ltd.

邮件 sshkeeper@feilian.cc  ·  系统要求 macOS 14+ Apple Silicon

© 2026 飞链数字科技南通有限公司. All rights reserved.
〔ICP 备案号占位 — 上线前补，海外主机可删〕
```

- 公司中文 / 英文名走双语切换机制各显示一份
- 邮件用 `<a href="mailto:sshkeeper@feilian.cc">`
- ICP 备案号留 HTML 注释占位 `<!-- TODO: 国内主机部署前补；海外主机删此行 -->`
- 不放社交链接（避免空链接）

## 10. 可访问性 / a11y

- 所有图标 `aria-hidden="true"`，文字版本就在旁边
- 语言切换按钮带 `aria-current` 表达当前状态
- `<details>` / `<summary>` 原生键盘可达
- 颜色对比满足 WCAG AA（深色文字 `#1d1d1f` on `#fbfbfd`、反之）
- `prefers-reduced-motion: reduce` 关掉所有过渡 / 动画

## 11. 性能

- 单 HTML 文件，含全部内联 SVG，约 ~25 KB（gzip 后 <10 KB）
- 单 CSS 文件，约 ~10 KB
- 单 JS 文件，约 ~2 KB（仅 lang 切换 + SHA256 复制 + Intel 嗅探）
- 0 外部资源、0 webfont、0 第三方脚本 → 首屏 Largest Contentful Paint 应 <1s（在合理带宽下）

## 12. 不做什么

- 博客 / changelog / 独立 FAQ 页（多页站点不在范围）
- 统计埋点（GA / 百度统计 等）—— 用户后期可自己加
- CMS / headless 框架
- npm 依赖 / build pipeline
- 真实截图（用 CSS mockup，后期替换）
- 社交链接（无现成账号，不做空链接）
- 不同版本的多 DMG 下载（仅最新版）
- 自动获取 GitHub Releases 最新版（无 GitHub 仓库）

## 13. 文件改动清单

全部新建：

- 新：`web/index.html`
- 新：`web/style.css`
- 新：`web/script.js`
- 新：`web/favicon.svg`
- 占位：`web/SSHKeeper-1.0.0.dmg`（发布时替换）

不动现有任何代码。
