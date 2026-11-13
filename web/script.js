/* ============================================================
   SSHKeeper Landing — interactions
   - Language switch with localStorage persistence
   - SHA256 clipboard copy with success flip
   ============================================================ */

// Language switch
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

// SHA256 clipboard copy
(function () {
    const btn = document.getElementById("sha-copy");
    const code = document.getElementById("sha-value");
    if (!btn || !code) return;
    btn.addEventListener("click", async () => {
        const value = code.textContent.trim();
        try {
            await navigator.clipboard.writeText(value);
            const orig = btn.innerHTML;
            btn.classList.add("copied");
            btn.innerHTML = document.documentElement.lang === "zh" ? "已复制" : "Copied";
            setTimeout(() => {
                btn.classList.remove("copied");
                btn.innerHTML = orig;
            }, 1500);
        } catch (_) {
            // Clipboard API blocked — fall back to selecting text.
            const range = document.createRange();
            range.selectNodeContents(code);
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
        }
    });
})();
