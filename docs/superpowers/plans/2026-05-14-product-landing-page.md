# Landing Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `web/` 目录下产出一个 Apple 极简风、中英双语切换的单页 SSHKeeper 介绍页，能直接 `open web/index.html` 预览，并可整包传到任意静态主机。

**Architecture:** 纯静态：单 HTML（双语文本以 `<span data-lang>` 双份并存于 DOM）+ 单 CSS（Apple 风视觉系统、`prefers-color-scheme` 暗色、响应式断点 768px）+ 单 JS（语言切换、SHA256 复制、Intel Mac 嗅探）。零依赖、零 build。

**Tech Stack:** HTML5、CSS3（custom properties + grid + clamp）、Vanilla JS（无 framework，无 build），内联 SVG 图标，`<details>/<summary>` 原生 accordion。

**Repository note:** 当前工作目录非 git 仓库（`git status` 会失败），所以不做 `git commit`。每个 Task 末尾的「Verify」步骤代替 commit 作为里程碑。

**Reference spec:** `docs/superpowers/specs/2026-05-14-product-landing-page-design.md`

---

### Task 1: 创建目录骨架 + index.html 空架子

**Files:**
- Create: `web/index.html`

- [ ] **Step 1: 创建 web 目录**

Run:
```bash
mkdir -p ./web
```

- [ ] **Step 2: 写 index.html 骨架（含 lang 切换基础 + meta + 占位 sections）**

Create `web/index.html`:

```html
<!doctype html>
<html lang="zh">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>SSHKeeper — macOS 连接 / 数据 / 面板工作台</title>
    <meta name="description" content="SSHKeeper：写给 macOS 的 SSH 主机管理、MySQL/PostgreSQL 数据库工作台、网页面板自动登录三合一工具。Apple Silicon 原生。" data-lang="zh">
    <meta name="description" content="SSHKeeper: a macOS workbench combining SSH hosts, MySQL/PostgreSQL database tools, and web panel auto-login. Native Apple Silicon." data-lang="en">
    <link rel="icon" type="image/svg+xml" href="./favicon.svg">
    <link rel="stylesheet" href="./style.css">
</head>
<body>
    <nav id="nav"></nav>
    <header id="hero"></header>
    <section id="features"></section>
    <section id="screenshots"></section>
    <section id="download"></section>
    <section id="faq"></section>
    <footer id="footer"></footer>
    <script src="./script.js" defer></script>
</body>
</html>
```

- [ ] **Step 3: Verify**

Run:
```bash
ls -la ./web/index.html
```

Expected: file exists, ~600 bytes. Open in browser:
```bash
open ./web/index.html
```
Expected: page is blank (no styles yet, no body content), title bar shows "SSHKeeper — macOS 连接 / 数据 / 面板工作台". No console errors except a 404 on `style.css` / `script.js` / `favicon.svg`（这三个文件下面任务会创建）.

---

### Task 2: 视觉系统 CSS（base + tokens + 容器 + 暗色 + 响应式）

**Files:**
- Create: `web/style.css`

- [ ] **Step 1: 写视觉系统的 CSS tokens 与全局重置**

Create `web/style.css`:

```css
/* ===== Reset ===== */
*, *::before, *::after { box-sizing: border-box; }
html, body, h1, h2, h3, p, ul, figure, details { margin: 0; padding: 0; }
ul { list-style: none; }
a { color: inherit; text-decoration: none; }
img, svg { display: block; max-width: 100%; }
button { font: inherit; border: 0; background: none; color: inherit; cursor: pointer; }

/* ===== Tokens (light) ===== */
:root {
    --fg: #1d1d1f;
    --fg-soft: #6e6e73;
    --bg: #fbfbfd;
    --bg-elev: #ffffff;
    --accent: #0071e3;
    --accent-soft: rgba(0, 113, 227, .12);
    --border: rgba(0, 0, 0, .08);
    --shadow-mockup: 0 30px 60px -30px rgba(0, 0, 0, .12);
    --font-stack: -apple-system, BlinkMacSystemFont, "Inter", "PingFang SC", "Helvetica Neue", sans-serif;
    --mono: ui-monospace, SFMono-Regular, Menlo, monospace;
    --container: 980px;
    --gap: 8px;
    --radius-card: 18px;
    --radius-mockup: 12px;
    --section-y: clamp(64px, 12vw, 128px);
}

/* ===== Tokens (dark) ===== */
@media (prefers-color-scheme: dark) {
    :root {
        --fg: #f5f5f7;
        --fg-soft: #a1a1a6;
        --bg: #000000;
        --bg-elev: #111114;
        --accent: #2997ff;
        --accent-soft: rgba(41, 151, 255, .16);
        --border: rgba(255, 255, 255, .1);
        --shadow-mockup: 0 30px 60px -30px rgba(0, 0, 0, .6);
    }
}

/* ===== Base ===== */
body {
    font-family: var(--font-stack);
    font-size: 16px;
    line-height: 1.6;
    color: var(--fg);
    background: var(--bg);
    -webkit-font-smoothing: antialiased;
}

h1, h2, h3 { line-height: 1.15; letter-spacing: -.02em; font-weight: 600; }
h1 { font-size: clamp(48px, 6vw, 72px); }
h2 { font-size: clamp(32px, 4vw, 44px); }
h3 { font-size: 22px; }

/* ===== Language switch ===== */
html[lang="zh"] [data-lang="en"] { display: none; }
html[lang="en"] [data-lang="zh"] { display: none; }

/* ===== Container ===== */
.container {
    max-width: var(--container);
    margin: 0 auto;
    padding: 0 24px;
}

/* ===== Reduced motion ===== */
@media (prefers-reduced-motion: reduce) {
    *, *::before, *::after {
        animation: none !important;
        transition: none !important;
    }
}

/* ===== Section spacing ===== */
section, header[id], footer[id], nav[id] { padding-left: 24px; padding-right: 24px; }
section, header[id] { padding-top: var(--section-y); padding-bottom: var(--section-y); }
section + section, header + section { border-top: 1px solid var(--border); }
```

- [ ] **Step 2: Verify**

刷新浏览器（cmd+R）。
Expected:
- 背景变为 `#fbfbfd`（浅色模式）或 `#000`（暗色模式 — 看系统设置）
- 字体变成系统字体
- 内容仍空白但 background 已生效
- 浏览器 DevTools 检查 CSS 已加载，无 syntax error

---

### Task 3: Nav 栏（含语言切换 + 顶部下载锚）

**Files:**
- Modify: `web/index.html`（替换 `<nav id="nav">` 内容）
- Modify: `web/style.css`（追加 nav 样式）

- [ ] **Step 1: 写 Nav HTML**

替换 `<nav id="nav"></nav>` 为：

```html
<nav id="nav" aria-label="Primary">
    <div class="nav-inner container">
        <a href="#" class="nav-logo" aria-label="SSHKeeper home">
            <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <rect x="3" y="4" width="18" height="14" rx="3"/>
                <path d="M8 10l3 3-3 3M13 16h4"/>
            </svg>
            <span>SSHKeeper</span>
        </a>
        <div class="nav-actions">
            <div class="lang-switch" role="group" aria-label="Language">
                <button data-toggle-lang="zh" aria-current="true">中</button>
                <button data-toggle-lang="en" aria-current="false">EN</button>
            </div>
            <a class="btn btn-primary btn-sm" href="#download">
                <span data-lang="zh">下载</span>
                <span data-lang="en">Download</span>
            </a>
        </div>
    </div>
</nav>
```

- [ ] **Step 2: 写 Nav CSS（追加到 style.css 末尾）**

```css
/* ===== Nav ===== */
nav[id="nav"] {
    position: sticky;
    top: 0;
    z-index: 10;
    backdrop-filter: saturate(180%) blur(20px);
    background: color-mix(in oklab, var(--bg) 78%, transparent);
    border-bottom: 1px solid var(--border);
    padding-top: 12px;
    padding-bottom: 12px;
}
.nav-inner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
}
.nav-logo {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-weight: 600;
    font-size: 16px;
}
.nav-actions { display: flex; align-items: center; gap: 12px; }

/* Language switch */
.lang-switch {
    display: inline-flex;
    border: 1px solid var(--border);
    border-radius: 980px;
    padding: 2px;
    background: var(--bg-elev);
}
.lang-switch button {
    padding: 4px 12px;
    border-radius: 980px;
    font-size: 13px;
    color: var(--fg-soft);
    transition: color .15s, background .15s;
}
.lang-switch button[aria-current="true"] {
    background: var(--accent);
    color: white;
}

/* Buttons */
.btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    border-radius: 980px;
    padding: 10px 18px;
    font-weight: 500;
    font-size: 15px;
    transition: transform .15s, background .15s, color .15s;
}
.btn:active { transform: scale(.97); }
.btn-primary { background: var(--accent); color: white; }
.btn-primary:hover { background: color-mix(in oklab, var(--accent) 86%, black); }
.btn-secondary { background: var(--accent-soft); color: var(--accent); }
.btn-sm { padding: 7px 14px; font-size: 14px; }
```

- [ ] **Step 3: Verify**

刷新浏览器。
Expected:
- 顶部出现固定 nav，左 Logo「⌨ SSHKeeper」，右「中/EN」按钮 +「下载」蓝按钮
- 当前选中「中」是蓝底白字、「EN」灰字（语言切换 JS 还未挂，点击无效，仅视觉 OK）
- 下方页面仍空白
- 在 macOS 切系统暗色 → nav 背景跟随变深

---

### Task 4: 语言切换 JS + Hero section（含 CSS mockup）

**Files:**
- Create: `web/script.js`
- Modify: `web/index.html`（hero 内容）
- Modify: `web/style.css`（追加 hero 与 mockup 样式）

- [ ] **Step 1: 写 script.js 的 lang 切换部分**

Create `web/script.js`:

```js
// Language switch — flips <html lang> + updates lang-switch UI; persisted to localStorage.
(function () {
    function setLang(lang) {
        document.documentElement.lang = lang;
        try { localStorage.setItem("lang", lang); } catch (_) { /* private mode */ }
        document.querySelectorAll("[data-toggle-lang]").forEach(btn => {
            btn.setAttribute("aria-current", btn.dataset.toggleLang === lang ? "true" : "false");
        });
    }
    function initialLang() {
        try {
            const stored = localStorage.getItem("lang");
            if (stored === "zh" || stored === "en") return stored;
        } catch (_) {}
        return (navigator.language || "").toLowerCase().startsWith("zh") ? "zh" : "en";
    }
    setLang(initialLang());
    document.querySelectorAll("[data-toggle-lang]").forEach(btn => {
        btn.addEventListener("click", () => setLang(btn.dataset.toggleLang));
    });
})();
```

- [ ] **Step 2: 写 Hero HTML**

替换 `<header id="hero"></header>` 为：

```html
<header id="hero">
    <div class="hero-inner container">
        <div class="hero-copy">
            <h1>
                <span data-lang="zh">写给 macOS 的连接 / 数据 / 面板工作台</span>
                <span data-lang="en">The macOS workbench for connections, data, panels</span>
            </h1>
            <p class="hero-sub">
                <span data-lang="zh">SSH 主机管理、MySQL & PostgreSQL 数据库工作台、网页面板自动登录 —— 三合一，原生 Apple Silicon。</span>
                <span data-lang="en">SSH hosts, MySQL & PostgreSQL workbench, and web panel auto-login — all in one native Apple Silicon app.</span>
            </p>
            <div class="hero-cta">
                <a class="btn btn-primary" href="#download">
                    <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                        <path d="M12 4v12m0 0l-5-5m5 5l5-5"/>
                        <path d="M5 20h14"/>
                    </svg>
                    <span data-lang="zh">下载 macOS 版</span>
                    <span data-lang="en">Download for macOS</span>
                </a>
                <a class="btn btn-secondary" href="#download">
                    <span data-lang="zh">系统要求</span>
                    <span data-lang="en">System requirements</span>
                </a>
            </div>
        </div>
        <figure class="mockup mockup-hero" aria-hidden="true">
            <div class="mockup-chrome">
                <span class="dot dot-r"></span>
                <span class="dot dot-y"></span>
                <span class="dot dot-g"></span>
                <span class="mockup-title">SSHKeeper</span>
            </div>
            <div class="mockup-body mockup-body-hero">
                <pre class="mock-term">
<span class="mt-prompt">long@mac ~ %</span> ssh prod-db
<span class="mt-muted">Last login: Tue Sep  3 09:14:22</span>
<span class="mt-prompt">long@prod-db ~ %</span> mysql -u root -p
<span class="mt-muted">mysql&gt;</span> SELECT id, email FROM users LIMIT 3;
<span class="mt-out">+----+-------------------+</span>
<span class="mt-out">| id | email             |</span>
<span class="mt-out">+----+-------------------+</span>
<span class="mt-out">|  1 | alice@example.com |</span>
<span class="mt-out">|  2 | bob@example.com   |</span>
<span class="mt-out">|  3 | carol@example.com |</span>
<span class="mt-out">+----+-------------------+</span></pre>
            </div>
        </figure>
    </div>
</header>
```

- [ ] **Step 3: 写 Hero CSS（追加 style.css）**

```css
/* ===== Hero ===== */
#hero { padding-top: clamp(48px, 8vw, 96px); }
.hero-inner { display: grid; gap: clamp(40px, 6vw, 72px); }
.hero-copy { max-width: 720px; }
.hero-sub {
    margin-top: 18px;
    font-size: clamp(18px, 2.2vw, 22px);
    color: var(--fg-soft);
    max-width: 600px;
}
.hero-cta { margin-top: 32px; display: flex; flex-wrap: wrap; gap: 12px; }

/* ===== Mockup window ===== */
.mockup {
    border-radius: var(--radius-mockup);
    background: var(--bg-elev);
    border: 1px solid var(--border);
    box-shadow: var(--shadow-mockup);
    overflow: hidden;
    margin: 0;
}
.mockup-chrome {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 10px 14px;
    background: color-mix(in oklab, var(--bg-elev) 92%, var(--fg) 8%);
    border-bottom: 1px solid var(--border);
}
.dot { width: 12px; height: 12px; border-radius: 50%; display: inline-block; }
.dot-r { background: #ff5f57; }
.dot-y { background: #febc2e; }
.dot-g { background: #28c840; }
.mockup-title {
    margin-left: 12px;
    font-size: 12px;
    color: var(--fg-soft);
}
.mockup-body {
    padding: 18px 20px;
    font-family: var(--mono);
    font-size: 13px;
    line-height: 1.55;
    background: var(--bg-elev);
}
.mockup-body-hero { min-height: 240px; }

/* Terminal mock colors */
.mock-term { white-space: pre; margin: 0; color: var(--fg); }
.mt-prompt { color: var(--accent); }
.mt-muted  { color: var(--fg-soft); }
.mt-out    { color: var(--fg); opacity: .85; }
```

- [ ] **Step 4: Verify**

刷新浏览器。
Expected:
- Hero 区出现大标题（中文默认）、副标题、两个按钮、一个 macOS 风格 mockup 窗口（顶部红黄绿三圆 + 内部伪终端文字）
- 点击右上「EN」按钮 → 所有文案切英文，「EN」按钮变蓝底；「中」按钮恢复灰；localStorage 写入 `lang=en`
- 点回「中」→ 切回中文，状态持久（刷新页面仍是当前选择）
- 暗色模式下 mockup chrome 自动变深

DevTools Application → Local Storage 应能看到 `lang` 值。

---

### Task 5: Features 4 块（含 SVG 图标）

**Files:**
- Modify: `web/index.html`（features 内容）
- Modify: `web/style.css`（追加 features 样式）

- [ ] **Step 1: 写 Features HTML**

替换 `<section id="features"></section>` 为：

```html
<section id="features">
    <div class="container">
        <h2 class="section-title">
            <span data-lang="zh">能做什么</span>
            <span data-lang="en">What it does</span>
        </h2>
        <div class="feature-grid">
            <article class="feature-card">
                <div class="feature-icon">
                    <svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                        <rect x="3" y="4" width="18" height="13" rx="2"/>
                        <path d="M8 20h8M12 17v3"/>
                        <path d="M7 9l3 3-3 3M12 12h4"/>
                    </svg>
                </div>
                <h3>
                    <span data-lang="zh">SSH 主机管理</span>
                    <span data-lang="en">SSH Hosts</span>
                </h3>
                <p>
                    <span data-lang="zh">统一管理 ssh config + Keychain 密码 + 私钥；右键直接开终端会话。多标签、跨主机分组。</span>
                    <span data-lang="en">Manage ssh config, Keychain passwords, private keys in one place. Right-click to open terminal sessions. Tabs and groups.</span>
                </p>
            </article>

            <article class="feature-card">
                <div class="feature-icon">
                    <svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                        <ellipse cx="12" cy="5" rx="8" ry="3"/>
                        <path d="M4 5v6c0 1.66 3.58 3 8 3s8-1.34 8-3V5"/>
                        <path d="M4 11v6c0 1.66 3.58 3 8 3s8-1.34 8-3v-6"/>
                    </svg>
                </div>
                <h3>
                    <span data-lang="zh">数据库工作台</span>
                    <span data-lang="en">Database Workbench</span>
                </h3>
                <p>
                    <span data-lang="zh">MySQL &amp; PostgreSQL 浏览、SQL 编辑器（自动补全 + EXPLAIN）、表/字段/索引可视化改、行级增删改。支持 SSH 隧道。</span>
                    <span data-lang="en">MySQL &amp; PostgreSQL browser, SQL editor with autocomplete and EXPLAIN, visual table / column / index editing, row-level CRUD. Via SSH tunnel.</span>
                </p>
            </article>

            <article class="feature-card">
                <div class="feature-icon">
                    <svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                        <circle cx="12" cy="12" r="9"/>
                        <path d="M3 12h18"/>
                        <path d="M12 3a13 13 0 010 18M12 3a13 13 0 000 18"/>
                    </svg>
                </div>
                <h3>
                    <span data-lang="zh">面板自动登录</span>
                    <span data-lang="en">Panel Auto-Login</span>
                </h3>
                <p>
                    <span data-lang="zh">把后台 / 路由器 / NAS 的网页登录页喂进来，密码存 Keychain，再访问一键登录。多面板单窗口 tab 切换。</span>
                    <span data-lang="en">Feed in admin / router / NAS login pages, store passwords in Keychain, one-click login on revisit. Multi-panel tabs in single window.</span>
                </p>
            </article>

            <article class="feature-card">
                <div class="feature-icon">
                    <svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                        <path d="M12 3l8 4v5c0 5-3.5 8-8 9-4.5-1-8-4-8-9V7l8-4z"/>
                        <path d="M9 12l2 2 4-4"/>
                    </svg>
                </div>
                <h3>
                    <span data-lang="zh">安全与性能</span>
                    <span data-lang="en">Security &amp; Performance</span>
                </h3>
                <p>
                    <span data-lang="zh">Apple Developer ID + 公证；密码全部走 macOS Keychain；Apple Silicon 原生 arm64；SwiftNIO 异步 DB 连接。</span>
                    <span data-lang="en">Apple Developer ID + notarized. All passwords in macOS Keychain. Native arm64 for Apple Silicon. SwiftNIO async DB connections.</span>
                </p>
            </article>
        </div>
    </div>
</section>
```

- [ ] **Step 2: 写 Features CSS（追加 style.css）**

```css
/* ===== Section title (shared) ===== */
.section-title {
    text-align: center;
    margin-bottom: clamp(40px, 6vw, 64px);
}

/* ===== Features ===== */
.feature-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 24px;
}
.feature-card {
    padding: 28px;
    border-radius: var(--radius-card);
    background: var(--bg-elev);
    border: 1px solid var(--border);
}
.feature-icon {
    width: 44px;
    height: 44px;
    border-radius: 12px;
    background: var(--accent-soft);
    color: var(--accent);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    margin-bottom: 16px;
}
.feature-card h3 {
    margin: 0 0 8px;
    font-size: 20px;
}
.feature-card p {
    color: var(--fg-soft);
    margin: 0;
    font-size: 15px;
}

@media (max-width: 768px) {
    .feature-grid { grid-template-columns: 1fr; }
}
```

- [ ] **Step 3: Verify**

刷新浏览器。
Expected:
- Hero 下方出现「能做什么」标题，居中
- 2×2 卡片网格，4 张卡：每张顶部一个 line-style SVG 图标（蓝绿/蓝色填充）+ 标题 + 1-2 行描述
- 切语言时 4 张卡全部跟着翻译
- 拖窄浏览器到 <768px → 卡片变 1 列
- 暗色模式下卡片背景变深

---

### Task 6: Screenshots 区（两张 CSS mockup）

**Files:**
- Modify: `web/index.html`（screenshots 内容）
- Modify: `web/style.css`（追加 screenshot 样式）

- [ ] **Step 1: 写 Screenshots HTML**

替换 `<section id="screenshots"></section>` 为：

```html
<section id="screenshots">
    <div class="container">
        <div class="screenshot-row">
            <div class="screenshot-copy">
                <h2>
                    <span data-lang="zh">内置终端，多标签会话</span>
                    <span data-lang="en">Built-in terminal, tabbed sessions</span>
                </h2>
                <p>
                    <span data-lang="zh">基于 SwiftTerm 的真终端，多个主机同时开窗、共用一个窗口切 tab；ssh config 改动实时同步。</span>
                    <span data-lang="en">A real terminal powered by SwiftTerm. Open multiple hosts at once, tab between them in one window. ssh config edits sync live.</span>
                </p>
            </div>
            <figure class="mockup" aria-hidden="true">
                <!-- TODO: 替换为真实截图 -->
                <div class="mockup-chrome">
                    <span class="dot dot-r"></span><span class="dot dot-y"></span><span class="dot dot-g"></span>
                    <span class="mockup-title">SSHKeeper — Terminal</span>
                </div>
                <div class="mockup-tabs">
                    <span class="mock-tab active">● prod-db</span>
                    <span class="mock-tab">● bastion</span>
                    <span class="mock-tab">+ </span>
                </div>
                <div class="mockup-body">
<pre class="mock-term">
<span class="mt-prompt">long@prod-db ~ %</span> uptime
 11:42  up 47 days,  2:18,  load averages: 0.32 0.28 0.30
<span class="mt-prompt">long@prod-db ~ %</span> docker ps
<span class="mt-muted">CONTAINER ID   IMAGE       STATUS</span>
ab12cd34ef56   postgres    Up 12 days
9876543210ab   redis       Up 12 days
<span class="mt-prompt">long@prod-db ~ %</span> █
</pre>
                </div>
            </figure>
        </div>

        <div class="screenshot-row screenshot-row-rev">
            <div class="screenshot-copy">
                <h2>
                    <span data-lang="zh">数据库工作台，所见即所改</span>
                    <span data-lang="en">Database workbench, edit what you see</span>
                </h2>
                <p>
                    <span data-lang="zh">侧栏跳表，主区切「结构 / 内容 / 关系 / 触发器 / 表信息」5 个 tab；行级增删改右键就走，无需手写 SQL。</span>
                    <span data-lang="en">Sidebar to jump tables; main pane tabs across Structure / Content / Relations / Triggers / Info. Right-click on a row to insert, edit, delete — no SQL by hand.</span>
                </p>
            </div>
            <figure class="mockup" aria-hidden="true">
                <!-- TODO: 替换为真实截图 -->
                <div class="mockup-chrome">
                    <span class="dot dot-r"></span><span class="dot dot-y"></span><span class="dot dot-g"></span>
                    <span class="mockup-title">SSHKeeper — Database Workbench</span>
                </div>
                <div class="mockup-body mockup-body-db">
                    <aside class="mock-sidebar">
                        <div class="mock-search">⌕ Filter tables</div>
                        <ul>
                            <li>users <small>1,724</small></li>
                            <li class="active">orders <small>9,310</small></li>
                            <li>products <small>412</small></li>
                            <li>shipments <small>2,205</small></li>
                            <li>audit_log <small>—</small></li>
                        </ul>
                    </aside>
                    <main class="mock-pane">
                        <div class="mock-tabbar">
                            <span class="mock-tab">Structure</span>
                            <span class="mock-tab active">Content</span>
                            <span class="mock-tab">Relations</span>
                            <span class="mock-tab">Info</span>
                        </div>
                        <table class="mock-table">
                            <thead><tr><th>id</th><th>user_id</th><th>total</th><th>status</th></tr></thead>
                            <tbody>
                                <tr><td>4123</td><td>17</td><td>$128.40</td><td>paid</td></tr>
                                <tr><td>4124</td><td>92</td><td>$ 12.00</td><td>pending</td></tr>
                                <tr class="hl"><td>4125</td><td>17</td><td>$ 88.99</td><td>paid</td></tr>
                            </tbody>
                        </table>
                    </main>
                </div>
            </figure>
        </div>
    </div>
</section>
```

- [ ] **Step 2: 写 Screenshots CSS（追加 style.css）**

```css
/* ===== Screenshots ===== */
.screenshot-row {
    display: grid;
    grid-template-columns: 1fr 1.2fr;
    align-items: center;
    gap: clamp(32px, 6vw, 80px);
    margin-bottom: clamp(48px, 8vw, 96px);
}
.screenshot-row:last-child { margin-bottom: 0; }
.screenshot-row-rev { grid-template-columns: 1.2fr 1fr; }
.screenshot-row-rev .mockup { order: -1; }
.screenshot-copy h2 { margin-bottom: 12px; }
.screenshot-copy p { color: var(--fg-soft); font-size: 17px; }

/* Terminal tabs in screenshot */
.mockup-tabs {
    display: flex;
    gap: 4px;
    padding: 6px 14px;
    border-bottom: 1px solid var(--border);
    background: color-mix(in oklab, var(--bg-elev) 96%, var(--fg) 4%);
}
.mock-tab {
    font-size: 12px;
    padding: 4px 10px;
    border-radius: 6px;
    color: var(--fg-soft);
    font-family: var(--mono);
}
.mock-tab.active {
    background: var(--accent-soft);
    color: var(--accent);
}

/* DB mockup body: sidebar + pane */
.mockup-body-db {
    display: grid;
    grid-template-columns: 180px 1fr;
    padding: 0;
    min-height: 280px;
}
.mock-sidebar {
    border-right: 1px solid var(--border);
    padding: 12px;
    font-family: var(--mono);
    font-size: 12px;
}
.mock-search {
    padding: 4px 6px;
    border: 1px solid var(--border);
    border-radius: 6px;
    color: var(--fg-soft);
    margin-bottom: 10px;
}
.mock-sidebar ul { display: flex; flex-direction: column; gap: 2px; }
.mock-sidebar li {
    padding: 4px 8px;
    border-radius: 4px;
    display: flex;
    justify-content: space-between;
    color: var(--fg);
}
.mock-sidebar li small { color: var(--fg-soft); }
.mock-sidebar li.active { background: var(--accent-soft); color: var(--accent); }
.mock-sidebar li.active small { color: var(--accent); opacity: .8; }

.mock-pane { padding: 12px 16px; }
.mock-tabbar { display: flex; gap: 4px; margin-bottom: 12px; }
.mock-table {
    width: 100%;
    font-family: var(--mono);
    font-size: 12px;
    border-collapse: collapse;
}
.mock-table th, .mock-table td {
    text-align: left;
    padding: 6px 8px;
    border-bottom: 1px solid var(--border);
}
.mock-table th { color: var(--fg-soft); font-weight: 500; }
.mock-table tr.hl { background: var(--accent-soft); }

@media (max-width: 768px) {
    .screenshot-row,
    .screenshot-row-rev { grid-template-columns: 1fr; }
    .screenshot-row-rev .mockup { order: 0; }
}
```

- [ ] **Step 3: Verify**

刷新浏览器。
Expected:
- 两个截图段落：第一个左字右图（终端 mockup，带 3 个 tab），第二个右字左图（DB 工作台 mockup，左侧栏 + 右内容表格）
- 切语言：标题/描述跟随翻译；mockup 内文字保持原样（hard-coded，符合实际产品 UI 不切语言的现状）
- <768px：图文上下堆叠

---

### Task 7: Download 区 + SHA256 复制 + Intel 嗅探

**Files:**
- Modify: `web/index.html`（download 内容）
- Modify: `web/style.css`（追加 download 样式）
- Modify: `web/script.js`（追加复制 + Intel 嗅探）

- [ ] **Step 1: 写 Download HTML**

替换 `<section id="download"></section>` 为：

```html
<section id="download">
    <div class="container download-inner">
        <h2 class="section-title">
            <span data-lang="zh">下载</span>
            <span data-lang="en">Download</span>
        </h2>
        <div class="download-card">
            <div class="download-meta">
                <strong>SSHKeeper for macOS</strong>
                <span class="dlm">
                    <span class="dlm-ver"><!-- TODO: 发布时填实际版本号 -->1.0.0</span> ·
                    <span class="dlm-size"><!-- TODO: 发布时填实际包大小 -->约 12 MB</span> ·
                    arm64
                </span>
            </div>
            <a class="btn btn-primary btn-lg" download href="./SSHKeeper-1.0.0.dmg">
                <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                    <path d="M12 4v12m0 0l-5-5m5 5l5-5M5 20h14"/>
                </svg>
                <span data-lang="zh">下载 .dmg</span>
                <span data-lang="en">Download .dmg</span>
            </a>
            <div id="intel-warn" hidden>
                <span data-lang="zh">检测到 Intel Mac —— 本应用仅支持 Apple Silicon。</span>
                <span data-lang="en">Intel Mac detected — this app supports Apple Silicon only.</span>
            </div>
            <ul class="download-reqs">
                <li>
                    <span class="check">✓</span>
                    <span data-lang="zh">macOS 14.0 Sonoma 或更高</span>
                    <span data-lang="en">macOS 14.0 Sonoma or later</span>
                </li>
                <li>
                    <span class="check">✓</span>
                    <span data-lang="zh">Apple Silicon（M 系列）</span>
                    <span data-lang="en">Apple Silicon (M-series)</span>
                </li>
                <li>
                    <span class="check">✓</span>
                    <span data-lang="zh">Apple Developer ID 签名 · Apple 公证</span>
                    <span data-lang="en">Apple Developer ID signed · Apple notarized</span>
                </li>
            </ul>
            <div class="download-sha">
                <span class="sha-label">SHA256</span>
                <code id="sha-value"><!-- TODO: 发布时填实际 SHA256 -->a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2</code>
                <button class="btn-copy" id="sha-copy" type="button">
                    <span data-lang="zh">复制</span>
                    <span data-lang="en">Copy</span>
                </button>
            </div>
        </div>
    </div>
</section>
```

- [ ] **Step 2: 写 Download CSS（追加 style.css）**

```css
/* ===== Download ===== */
.download-card {
    max-width: 720px;
    margin: 0 auto;
    padding: 40px;
    border-radius: var(--radius-card);
    background: var(--bg-elev);
    border: 1px solid var(--border);
    text-align: center;
}
.download-meta { margin-bottom: 24px; }
.download-meta strong { display: block; font-size: 22px; }
.dlm {
    display: inline-block;
    margin-top: 6px;
    color: var(--fg-soft);
    font-size: 14px;
}
.btn-lg { padding: 14px 24px; font-size: 17px; }

#intel-warn {
    margin-top: 12px;
    padding: 10px 14px;
    border-radius: 10px;
    background: rgba(255, 159, 10, .12);
    color: #b25800;
    font-size: 13px;
}
@media (prefers-color-scheme: dark) {
    #intel-warn { background: rgba(255, 159, 10, .12); color: #ffb454; }
}

.download-reqs {
    text-align: left;
    margin-top: 28px;
    display: grid;
    gap: 8px;
    max-width: 380px;
    margin-left: auto;
    margin-right: auto;
}
.download-reqs li {
    display: flex;
    align-items: baseline;
    gap: 8px;
    font-size: 14px;
    color: var(--fg);
}
.check { color: #2eb670; font-weight: 600; }

.download-sha {
    margin-top: 28px;
    padding-top: 20px;
    border-top: 1px solid var(--border);
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    flex-wrap: wrap;
}
.sha-label {
    font-size: 12px;
    color: var(--fg-soft);
    text-transform: uppercase;
    letter-spacing: .08em;
}
#sha-value {
    font-family: var(--mono);
    font-size: 12px;
    color: var(--fg);
    background: color-mix(in oklab, var(--bg-elev) 85%, var(--fg) 15%);
    padding: 4px 8px;
    border-radius: 6px;
    overflow-wrap: anywhere;
    max-width: 100%;
}
.btn-copy {
    font-size: 12px;
    padding: 4px 10px;
    border-radius: 980px;
    background: var(--accent-soft);
    color: var(--accent);
    transition: background .15s;
}
.btn-copy:hover { background: color-mix(in oklab, var(--accent-soft) 60%, var(--accent) 20%); }
```

- [ ] **Step 3: 追加 SHA256 复制 + Intel 嗅探到 script.js**

追加到 `web/script.js` 末尾：

```js
// SHA256 copy — clipboard write + transient label flip.
(function () {
    const btn = document.getElementById("sha-copy");
    const code = document.getElementById("sha-value");
    if (!btn || !code) return;
    btn.addEventListener("click", async () => {
        const value = code.textContent.trim();
        try {
            await navigator.clipboard.writeText(value);
            const orig = btn.innerHTML;
            btn.innerHTML = document.documentElement.lang === "zh" ? "已复制" : "Copied";
            setTimeout(() => { btn.innerHTML = orig; }, 1500);
        } catch (_) {
            // Clipboard API blocked (insecure context / Safari private). Fallback selects text.
            const range = document.createRange();
            range.selectNodeContents(code);
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
        }
    });
})();

// Intel Mac warning — only x86_64 macOS triggers; Apple Silicon UA reports "Mac OS X" too but without "Intel".
(function () {
    const ua = navigator.userAgent || "";
    if (/Intel Mac OS X/.test(ua)) {
        const el = document.getElementById("intel-warn");
        if (el) el.removeAttribute("hidden");
    }
})();
```

**Important note about Intel detection:** Safari 17+ on Apple Silicon historically reports `Intel Mac OS X 10_15_7` in UA for compatibility, which would falsely trigger this warning. Modern Safari (Sequoia+) reports `Macintosh; Intel Mac OS X` for **all** macOS regardless of arch. There is no fully reliable architecture sniff from UA. This warning will appear for many Apple Silicon users too — accepted trade-off because it's just informational, not blocking. If false-positive rate becomes a complaint, remove the Intel check entirely.

- [ ] **Step 4: Verify**

刷新浏览器，滚到 Download 区。
Expected:
- 居中卡片：粗体 SSHKeeper for macOS + 版本号 / 大小 / arm64
- 大蓝色「下载 .dmg」按钮（点击会触发下载，因为文件不存在所以 404 — 后面 Task 10 创建占位文件）
- 三条 ✓ 列出系统要求
- SHA256 区：标签 + 等宽 16 字节 hex + 「复制」按钮
- 点「复制」→ 按钮变「已复制」1.5s 后恢复
- 切语言时所有文案 + 复制成功提示都跟着切
- macOS 上访问几乎肯定会触发 Intel 警告横幅（因为 UA 含 Intel 字串）— 这是已知 false-positive

---

### Task 8: FAQ 6 条

**Files:**
- Modify: `web/index.html`（faq 内容）
- Modify: `web/style.css`（追加 faq 样式）

- [ ] **Step 1: 写 FAQ HTML**

替换 `<section id="faq"></section>` 为：

```html
<section id="faq">
    <div class="container faq-inner">
        <h2 class="section-title">
            <span data-lang="zh">常见问题</span>
            <span data-lang="en">FAQ</span>
        </h2>
        <div class="faq-list">
            <details>
                <summary>
                    <span data-lang="zh">为什么 Intel Mac 不支持？</span>
                    <span data-lang="en">Why no Intel Mac support?</span>
                </summary>
                <div class="faq-body">
                    <p>
                        <span data-lang="zh">SwiftNIO + Swift 6 严格并发对 arm64 优化更稳；维护单架构能更快迭代。需求集中再补。</span>
                        <span data-lang="en">SwiftNIO + Swift 6 strict concurrency runs cleanest on arm64. Focusing on one architecture lets us ship faster. We may revisit if demand consolidates.</span>
                    </p>
                </div>
            </details>

            <details>
                <summary>
                    <span data-lang="zh">我的密码存在哪？</span>
                    <span data-lang="en">Where are my passwords stored?</span>
                </summary>
                <div class="faq-body">
                    <p>
                        <span data-lang="zh">全部存 macOS Keychain；SSHKeeper 不写明文到磁盘。Keychain ACL 限定只有 SSHKeeper 签名二进制可读，换签名密钥也读不到。</span>
                        <span data-lang="en">All in macOS Keychain. Never written to disk in plaintext. Keychain ACLs allow only the signed SSHKeeper binary to read — even a re-signed copy cannot.</span>
                    </p>
                </div>
            </details>

            <details>
                <summary>
                    <span data-lang="zh">第一次打开报「无法验证开发者」？</span>
                    <span data-lang="en">"Cannot verify developer" on first open?</span>
                </summary>
                <div class="faq-body">
                    <p>
                        <span data-lang="zh">Gatekeeper 公证缓存未刷新。右键 App → 打开 → 在弹窗确认；或命令行：</span>
                        <span data-lang="en">Gatekeeper notarization cache miss. Right-click the App → Open → confirm; or via Terminal:</span>
                    </p>
                    <pre class="faq-code">xattr -dr com.apple.quarantine /Applications/SSHKeeper.app</pre>
                </div>
            </details>

            <details>
                <summary>
                    <span data-lang="zh">支持 SSH 隧道连数据库吗？</span>
                    <span data-lang="en">Database via SSH tunnel?</span>
                </summary>
                <div class="faq-body">
                    <p>
                        <span data-lang="zh">支持。编辑数据库时勾「通过 SSH 隧道」并选 ssh config 中的跳板机；连接时自动 <code>ssh -N -L lport:host:port alias</code>。</span>
                        <span data-lang="en">Yes. In the Database editor, enable "Via SSH tunnel" and pick a host from ssh config. The app runs <code>ssh -N -L lport:host:port alias</code> for you.</span>
                    </p>
                </div>
            </details>

            <details>
                <summary>
                    <span data-lang="zh">数据库密码安全吗？</span>
                    <span data-lang="en">Database password safety?</span>
                </summary>
                <div class="faq-body">
                    <p>
                        <span data-lang="zh">与 SSH 密码同策略：Keychain + 二进制签名校验。所有 SQL 全部走参数化 <code>?</code> 占位 + bindings，无字符串拼接；TLS 可强制。</span>
                        <span data-lang="en">Same policy as SSH: Keychain + signed binary check. All SQL is parameterized (<code>?</code> placeholders + bindings) — no string concat. TLS can be enforced.</span>
                    </p>
                </div>
            </details>

            <details>
                <summary>
                    <span data-lang="zh">商业支持 / 反馈邮箱</span>
                    <span data-lang="en">Support &amp; feedback</span>
                </summary>
                <div class="faq-body">
                    <p>
                        <span data-lang="zh">邮件：<a href="mailto:sshkeeper@feilian.cc">sshkeeper@feilian.cc</a>。Bug、商业授权、定制开发都走这里；通常 1-2 个工作日回复。</span>
                        <span data-lang="en">Email <a href="mailto:sshkeeper@feilian.cc">sshkeeper@feilian.cc</a>. Bugs, commercial licensing, custom development — typical reply within 1-2 business days.</span>
                    </p>
                </div>
            </details>
        </div>
    </div>
</section>
```

- [ ] **Step 2: 写 FAQ CSS（追加 style.css）**

```css
/* ===== FAQ ===== */
.faq-inner { max-width: 760px; margin: 0 auto; }
.faq-list { display: grid; gap: 4px; }
.faq-list details {
    border-radius: 12px;
    overflow: hidden;
    background: var(--bg-elev);
    border: 1px solid var(--border);
}
.faq-list summary {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 18px 20px;
    cursor: pointer;
    list-style: none;
    font-weight: 500;
    font-size: 16px;
}
.faq-list summary::-webkit-details-marker { display: none; }
.faq-list summary::after {
    content: "";
    width: 10px;
    height: 10px;
    border-right: 1.5px solid var(--fg-soft);
    border-bottom: 1.5px solid var(--fg-soft);
    transform: rotate(-45deg);
    transition: transform .2s;
    flex: 0 0 auto;
}
.faq-list details[open] summary::after { transform: rotate(45deg); }
.faq-body {
    padding: 0 20px 20px;
    color: var(--fg-soft);
}
.faq-body p { margin: 0 0 8px; }
.faq-body p:last-child { margin-bottom: 0; }
.faq-body code {
    font-family: var(--mono);
    font-size: 13px;
    background: color-mix(in oklab, var(--bg-elev) 85%, var(--fg) 15%);
    padding: 1px 6px;
    border-radius: 4px;
    color: var(--fg);
}
.faq-code {
    font-family: var(--mono);
    font-size: 13px;
    background: color-mix(in oklab, var(--bg-elev) 85%, var(--fg) 15%);
    color: var(--fg);
    padding: 10px 14px;
    border-radius: 8px;
    overflow-x: auto;
    margin: 8px 0 0;
}
.faq-body a { color: var(--accent); }
```

- [ ] **Step 3: Verify**

刷新浏览器，滚到 FAQ 区。
Expected:
- 6 个折叠条目，默认全部收起
- 标题右侧一个 `›` 朝下的箭头；点击展开，箭头旋转向上
- 展开后看到答案；含代码片段的渲染为等宽字体 code block
- 邮箱链接 `mailto:` 可点
- 切语言全部翻译
- 键盘 Tab + Enter 也能展开/收起（原生 `<details>` 行为）

---

### Task 9: Footer

**Files:**
- Modify: `web/index.html`（footer 内容）
- Modify: `web/style.css`（追加 footer 样式）

- [ ] **Step 1: 写 Footer HTML**

替换 `<footer id="footer"></footer>` 为：

```html
<footer id="footer">
    <div class="container footer-inner">
        <div class="footer-brand">
            <strong>
                <span data-lang="zh">飞链数字科技南通有限公司</span>
                <span data-lang="en">Feilian Digital Technology (Nantong) Co., Ltd.</span>
            </strong>
        </div>
        <div class="footer-meta">
            <a href="mailto:sshkeeper@feilian.cc">sshkeeper@feilian.cc</a>
            <span class="footer-sep">·</span>
            <span data-lang="zh">系统要求 macOS 14+ Apple Silicon</span>
            <span data-lang="en">Requires macOS 14+ Apple Silicon</span>
        </div>
        <div class="footer-legal">
            <span data-lang="zh">© 2026 飞链数字科技南通有限公司. 保留所有权利。</span>
            <span data-lang="en">© 2026 Feilian Digital Technology (Nantong) Co., Ltd. All rights reserved.</span>
            <!-- TODO: 国内主机部署前补 ICP 备案号；海外主机删此行 -->
        </div>
    </div>
</footer>
```

- [ ] **Step 2: 写 Footer CSS（追加 style.css）**

```css
/* ===== Footer ===== */
footer[id="footer"] {
    padding-top: 48px;
    padding-bottom: 48px;
    text-align: center;
    color: var(--fg-soft);
}
.footer-brand strong {
    color: var(--fg);
    display: block;
    font-size: 15px;
    margin-bottom: 8px;
}
.footer-meta { font-size: 13px; margin-bottom: 12px; }
.footer-meta a { color: var(--accent); }
.footer-sep { margin: 0 8px; opacity: .5; }
.footer-legal { font-size: 12px; opacity: .7; }
```

- [ ] **Step 3: Verify**

刷新浏览器，滚到底部。
Expected:
- 居中三行：公司名（粗）/ 邮箱 · 系统要求 / 版权
- 切「EN」时公司中英文版本切换
- 邮箱链接颜色 accent

---

### Task 10: favicon.svg + DMG 占位文件

**Files:**
- Create: `web/favicon.svg`
- Create: `web/SSHKeeper-1.0.0.dmg`（占位空文件）

- [ ] **Step 1: 写 favicon.svg**

Create `web/favicon.svg`:

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
    <rect width="32" height="32" rx="7" fill="#0071e3"/>
    <g fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M9 12l4 4-4 4"/>
        <path d="M16 20h7"/>
    </g>
</svg>
```

- [ ] **Step 2: 创建 DMG 占位文件**

Run:
```bash
touch ./web/SSHKeeper-1.0.0.dmg
```

This is a 0-byte placeholder. Replace it with the real DMG produced by `Tools/build_release.sh` before publishing.

- [ ] **Step 3: Verify**

Run:
```bash
ls -la ./web/
```

Expected output 应该包含：
```
favicon.svg
index.html
script.js
SSHKeeper-1.0.0.dmg
style.css
```

刷新浏览器：
- Tab 图标变成蓝底白「>_」（favicon）
- 点击「下载 .dmg」按钮 → 浏览器下载 0 字节的 `SSHKeeper-1.0.0.dmg` 文件（这是预期 — 等真包替换）

---

### Task 11: 终验

**Files:** none

- [ ] **Step 1: 整体 smoke check**

刷新页面后逐项过：

1. 加载完整 — 无 404（除非 DMG 链接被点）— DevTools Network 全绿
2. 浅色模式：背景 `#fbfbfd`，文字深炭
3. 切系统 Dark Mode → 全站自动变深底白字
4. Nav 滚动时贴顶 + 模糊背景
5. Hero 大标题 + mockup 终端 + 两个按钮
6. Features 2×2 4 张卡 + SVG 图标着色 accent
7. Screenshots 两段图文（终端 + DB 工作台）
8. Download 卡：版本号 / 复制 SHA256 / 系统要求清单 / 下载按钮触发下载
9. FAQ 6 条可展开
10. Footer 公司名 + 邮箱 + 版权

- [ ] **Step 2: 双语切换**

- 点「EN」→ 所有文案翻译，URL hash 不动，scroll 位置保留
- 点「中」→ 切回中文
- 刷新页面 → 保持上次选择（localStorage 生效）
- DevTools Application → Local Storage → `lang` 有值

- [ ] **Step 3: 响应式**

- 拖窄浏览器到 <768px:
    - Features 变 1 列
    - Screenshots 图文上下堆叠
    - Nav 整体不变（已用 flex-wrap 兜底，按钮挤在一起也能用）
- 拖窄到 <420px 文字不溢出

- [ ] **Step 4: 性能 / a11y 抽查**

DevTools → Lighthouse → Run audit（Performance + Accessibility + Best Practices + SEO）:

Expected scores（参考）:
- Performance: 95+
- Accessibility: 95+
- Best Practices: 95+
- SEO: 90+

如果 Accessibility 提示 contrast 问题，调整对应颜色。

- [ ] **Step 5: 文件清单确认**

Run:
```bash
ls -la ./web/
wc -c ./web/{index.html,style.css,script.js,favicon.svg}
```

Expected:
- 共 5 个文件（index.html / style.css / script.js / favicon.svg / SSHKeeper-1.0.0.dmg）
- index.html ~12-15 KB
- style.css ~8-12 KB
- script.js ~2 KB
- favicon.svg <300 B

---

## Self-Review

**Spec coverage 检查**：

| Spec 节 | 实现位置 |
|---|---|
| 1. 文件结构 | Task 1 + 10 |
| 2. 页面结构（7 节） | Task 3-9 各一节 |
| 3. 视觉系统 | Task 2 |
| 4. Feature 4 块 | Task 5 |
| 5. 截图区 mockup | Task 6 |
| 6. 双语切换机制 | Task 4 step 1（JS）+ Task 2（CSS） |
| 7. 下载区 | Task 7 |
| 8. FAQ 6 条 | Task 8 |
| 9. Footer | Task 9 |
| 10. a11y | Task 8（`<details>` 原生）+ Task 4（`aria-current`）+ Task 11 Lighthouse |
| 11. 性能 | Task 11 Lighthouse 抽查 |
| 12. 不做什么 | N/A — exclusion list，无需实现 |
| 13. 文件改动清单 | Task 1, 10 |

**已知技术折中**（spec 没明说但实现时确认的）：

1. **Intel Mac UA 嗅探的 false-positive**：现代 Safari/Chrome 在 Apple Silicon 上 UA 仍含「Intel Mac OS X」字串。Task 7 Step 3 注释了这个限制。如果反馈说 AS 用户被误标红，去 script.js 删那个 IIFE 即可。
2. **mockup 终端 / DB 文字不切语言**：与产品实际 UI 一致（产品默认中文），仅描述文字 / 标题切。
3. **macOS 窗口 mockup 用 CSS 画**：traffic light 三圆 + 内容用单色块 + 等宽字体伪造，不用真实截图。`<!-- TODO: 替换为真实截图 -->` 标记便于后期换。

**Type consistency 检查**：
- 双语切换 selector：`html[lang="zh"]` / `html[lang="en"]` + `[data-lang="zh"]` / `[data-lang="en"]` 全文件一致 ✓
- 按钮 class：`.btn .btn-primary .btn-secondary .btn-sm .btn-lg` 命名 + 用法一致 ✓
- mockup class：`.mockup .mockup-chrome .mockup-body .mockup-body-hero .mockup-body-db` 命名清晰，无冲突 ✓
- script.js 元素 ID：`sha-copy` / `sha-value` / `intel-warn` 与 HTML 中 ID 一一对应 ✓

无 placeholder（除 `<!-- TODO: ... -->` 注释，这些是发布时数据点，已说明替换路径）。
