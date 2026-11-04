/* ============================================================
   Kitnest 官网脚本
   · hash 路由（首页 / 功能 / 界面 / 下载 / 更新 / 帮助 / 安全）
   · 菜单栏模拟：点小猫展开真实面板截图
   · 界面截图切换、FAQ 折叠、移动端菜单
   · 读取 /kitnest/stable/latest.json 渲染版本、SHA-256 与下载
   页面不写入任何密钥、签名信息或用户数据。
   ============================================================ */

(function () {
  "use strict";

  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

  /* ---------------- 反馈 ---------------- */

  var toastTimer = null;
  function toast(message) {
    var el = $("#toast");
    if (!el) return;
    el.textContent = message;
    el.classList.add("show");
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.remove("show"); }, 2400);
  }

  function formatSize(bytes) {
    var mb = bytes / 1024 / 1024;
    return mb >= 100 ? Math.round(mb) + " MiB" : mb.toFixed(1) + " MiB";
  }

  function formatDate(value) {
    if (!value) return "";
    var d = new Date(value);
    if (isNaN(d.getTime())) return String(value);
    var p = function (n) { return n < 10 ? "0" + n : String(n); };
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate());
  }

  /* ---------------- 视图路由 ---------------- */

  var VIEWS = ["home", "features", "showcase", "download", "changelog", "help", "privacy"];

  function currentView() {
    var hash = (location.hash || "#home").replace("#", "");
    return VIEWS.indexOf(hash) !== -1 ? hash : "home";
  }

  function render() {
    var view = currentView();

    VIEWS.forEach(function (name) {
      var el = document.getElementById("view-" + name);
      if (el) el.classList.toggle("active", name === view);
    });

    $$("[data-nav]").forEach(function (a) {
      var target = (a.getAttribute("href") || "").replace("#", "");
      var inMenu = a.closest(".nav-links") || a.closest(".mobile-menu");
      a.classList.toggle("active", !!inMenu && target === view);
    });

    document.title = view === "home"
      ? "Kitnest · 菜单栏里的效率工具集"
      : titleFor(view) + " · Kitnest";

    window.scrollTo({ top: 0, behavior: "auto" });
    closeMobileMenu();
  }

  function titleFor(view) {
    return {
      home: "首页",
      features: "功能介绍",
      showcase: "界面展示",
      download: "下载",
      changelog: "更新记录",
      help: "帮助",
      privacy: "隐私与安全"
    }[view] || "Kitnest";
  }

  window.addEventListener("hashchange", render);
  $$("[data-nav]").forEach(function (a) {
    a.addEventListener("click", function () {
      if (a.getAttribute("href") === location.hash) render();
    });
  });

  /* ---------------- 移动端菜单 ---------------- */

  var navToggle = $("#navToggle");
  var mobileMenu = $("#mobileMenu");

  function closeMobileMenu() {
    if (mobileMenu) mobileMenu.classList.remove("open");
    if (navToggle) navToggle.setAttribute("aria-expanded", "false");
  }

  if (navToggle && mobileMenu) {
    navToggle.addEventListener("click", function () {
      var open = mobileMenu.classList.toggle("open");
      navToggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
    document.addEventListener("click", function (e) {
      if (!mobileMenu.contains(e.target) && !navToggle.contains(e.target)) closeMobileMenu();
    });
  }

  /* ---------------- 菜单栏模拟 ---------------- */

  var mbIcon = $("#mbIcon");
  var panelDrop = $("#panelDrop");

  function setPanel(open) {
    if (!panelDrop || !mbIcon) return;
    panelDrop.classList.toggle("open", open);
    mbIcon.setAttribute("aria-expanded", open ? "true" : "false");
    mbIcon.setAttribute("aria-label", open ? "收起主面板" : "展开主面板");
  }

  if (mbIcon && panelDrop) {
    mbIcon.addEventListener("click", function () {
      setPanel(!panelDrop.classList.contains("open"));
    });
    document.addEventListener("click", function (e) {
      if (!panelDrop.contains(e.target) && !mbIcon.contains(e.target) && panelDrop.classList.contains("open")) {
        setPanel(false);
      }
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") setPanel(false);
    });
  }

  /* ---------------- 截图切换 ---------------- */

  $$(".shot-tabs").forEach(function (root) {
    var tabs = $$(".shot-tab", root);
    var stage = document.getElementById(root.getAttribute("data-stage"));
    if (!stage) return;
    var slides = $$("[data-shot-slide]", stage);
    var panels = $$("[data-shot-panel]", stage);

    function select(name) {
      tabs.forEach(function (t) {
        var on = t.getAttribute("data-shot") === name;
        t.classList.toggle("on", on);
        t.setAttribute("aria-selected", on ? "true" : "false");
      });
      slides.forEach(function (s) { s.hidden = s.getAttribute("data-shot-slide") !== name; });
      panels.forEach(function (p) { p.hidden = p.getAttribute("data-shot-panel") !== name; });
    }

    tabs.forEach(function (tab) {
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-selected", tab.classList.contains("on") ? "true" : "false");
      tab.addEventListener("click", function () { select(tab.getAttribute("data-shot")); });
    });
    select((tabs.filter(function (t) { return t.classList.contains("on"); })[0] || tabs[0]).getAttribute("data-shot"));
  });

  /* 截图缺失时的占位（图片尚未并入或部署漏传时给出明确提示） */
  $$("img[data-shot-file]").forEach(function (img) {
    img.addEventListener("error", function () {
      var frame = img.closest(".shot-frame") || img.parentNode;
      if (!frame) return;
      var note = document.createElement("div");
      note.className = "shot-missing";
      note.textContent = "截图未并入：" + img.getAttribute("data-shot-file");
      note.style.cssText = "padding:26px;font-size:12.5px;color:#8A8A94;border:1px dashed #DCDCE2;border-radius:10px;background:#FFF;text-align:center;width:100%";
      img.replaceWith(note);
    });
  });

  /* ---------------- 版本清单 ----------------
     清单字段与客户端 AppUpdateChecker 一致：
     build / versionName / minBuild / zipUrl / size / sha256 /
     releaseNotes / whatsNew{added,improved,fixed} / pageUrl / publishedAt
     校验不通过就停用下载，绝不给出不可靠的链接。 */

  /* 相对路径：同一份站点既可以挂在 / 根目录，也可以挂在 /kitnest-site/ 子路径下 */
  var MANIFEST_URL = "kitnest/stable/latest.json";
  if (location.hostname === "127.0.0.1" || location.hostname === "localhost") {
    try {
      var qs = new URLSearchParams(location.search).get("manifest");
      if (qs) MANIFEST_URL = qs;
    } catch (e) { /* 用默认地址 */ }
  }

  var manifest = null;
  var downloadReady = false;

  function showManifestState(state, detail) {
    var map = { loading: "#manifestLoading", error: "#manifestError", ready: "#manifestReady" };
    Object.keys(map).forEach(function (key) {
      var el = $(map[key]);
      if (el) el.hidden = key !== state;
    });
    if (state === "error" && detail) {
      var p = $("#manifestErrorDetail");
      if (p) p.textContent = detail;
    }
  }

  function isReleaseZipPath(pathname) {
    return pathname.indexOf("/kitnest/releases/") === 0 &&
      /\.zip$/.test(pathname) &&
      pathname.indexOf("..") === -1;
  }

  function resolveUrl(value) {
    try { return new URL(String(value || ""), location.href); } catch (e) { return null; }
  }

  function validateManifest(data) {
    if (!data || typeof data !== "object") return "版本清单格式不正确。";
    if (!/^\d+\.\d+\.\d+$/.test(String(data.versionName || ""))) return "清单中的版本号不符合 x.y.z 约定。";
    if (typeof data.build !== "number" || !isFinite(data.build) || data.build <= 0) return "清单缺少有效的 build 号。";
    if (!/^[0-9a-fA-F]{64}$/.test(String(data.sha256 || ""))) return "清单缺少有效的 SHA-256 校验值。";
    if (typeof data.size !== "number" || !isFinite(data.size) || data.size <= 0) return "清单缺少有效的安装包大小。";
    var url = resolveUrl(data.zipUrl);
    if (!url || !isReleaseZipPath(url.pathname)) return "清单中的安装包路径不符合发布约定。";
    return null;
  }

  function isDownloadAllowed(data) {
    if (!data) return false;
    var url = resolveUrl(data.zipUrl);
    if (!url) return false;
    if (!isReleaseZipPath(url.pathname)) return false;
    if (!/^https?:$/.test(location.protocol)) return false;
    if (location.protocol === "https:" && url.protocol !== "https:") return false;
    var h = url.hostname;
    if (h === "127.0.0.1" || h === "localhost" || h === "0.0.0.0" || h === "::1") return false;
    return true;
  }

  function whatsNewMarkup(data) {
    var groups = [
      { key: "added", label: "新增" },
      { key: "improved", label: "改进" },
      { key: "fixed", label: "修复" }
    ];
    var wn = data.whatsNew || {};
    var html = "";
    groups.forEach(function (g) {
      var items = Array.isArray(wn[g.key]) ? wn[g.key].filter(Boolean) : [];
      if (!items.length) return;
      html += "<div class=\"whatsnew-group\"><div class=\"wn-label\">" + g.label + "</div><ul>" +
        items.map(function (text) { return "<li>" + escapeHtml(String(text)) + "</li>"; }).join("") +
        "</ul></div>";
    });
    return html;
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[c];
    });
  }

  function releaseNotesText(data) {
    if (data.releaseNotes && String(data.releaseNotes).trim()) return String(data.releaseNotes).trim();
    var wn = data.whatsNew || {};
    var lines = [];
    [["added", "新增"], ["improved", "改进"], ["fixed", "修复"]].forEach(function (pair) {
      var items = Array.isArray(wn[pair[0]]) ? wn[pair[0]] : [];
      if (items.length) lines.push("【" + pair[1] + "】" + items.join("；"));
    });
    return lines.join("\n");
  }

  function renderManifest(data) {
    var sizeText = formatSize(data.size);
    var sizeLong = "约 " + sizeText;

    var set = function (id, text) { var el = document.getElementById(id); if (el) el.textContent = text; };

    set("vName", "v" + data.versionName);
    set("vBuild", "build " + data.build);
    set("vSize", sizeText);
    set("vMin", data.minBuild && data.minBuild > 1
      ? "build " + data.minBuild + " 及以上可直接覆盖；更低版本请先升级到中间版本"
      : "任意旧版本均可直接覆盖升级");
    set("vDate", formatDate(data.publishedAt) || "—");
    set("vSha", String(data.sha256).toLowerCase());
    set("vNotes", releaseNotesText(data) || "本版本未附更新说明。");

    $$("[data-pkg-size]").forEach(function (el) { el.textContent = sizeLong; });

    var heroLine = $("#heroVersionText");
    if (heroLine) {
      heroLine.textContent = "v" + data.versionName + " · build " + data.build + " · 安装包" + sizeLong;
    }

    var modalSize = $("#modalPkgSize");
    if (modalSize) modalSize.textContent = sizeText;

    var wnBody = $("#whatsNewMockBody");
    if (wnBody) {
      var wn = whatsNewMarkup(data);
      wnBody.innerHTML = wn || "<p style=\"font-size:13px;color:#8A8A94\">本版本暂无条目。</p>";
      var badge = $("#whatsNewMockBadge");
      if (badge) badge.textContent = "build " + data.build;
      var title = $("#whatsNewMockTitle");
      if (title) title.textContent = "已更新到 " + data.versionName;
    }

    var latest = $("#latestRelease");
    if (latest) {
      latest.innerHTML = "<div class=\"tl-head\"><h3>当前稳定版 · v" + escapeHtml(data.versionName) + "</h3>" +
        "<span class=\"tl-date\">build " + data.build + (data.publishedAt ? " · " + formatDate(data.publishedAt) : "") + "</span>" +
        "<span class=\"tl-badge\">最新</span></div><div class=\"tl-body\">" +
        (whatsNewMarkup(data) || "<p class=\"tl-empty\">该版本未附条目。</p>") +
        "<p style=\"margin-top:14px;font-size:12.5px;color:#8A8A94\">完整安装包 " + sizeText +
        " · SHA-256 前 12 位 <code>" + String(data.sha256).slice(0, 12) + "…</code></p></div>";
    }

    var btn = $("#dlButton");
    if (btn) {
      downloadReady = isDownloadAllowed(data);
      btn.disabled = !downloadReady;
      var note = $("#dlButtonNote");
      if (note) note.textContent = downloadReady ? "（" + sizeText + "）" : "";
      var hint = $("#dlButtonHint");
      if (hint) {
        hint.textContent = downloadReady
          ? "点击后先检查下载通道，再确认下载须知。"
          : "下载链接未通过安全校验，按钮已停用。请通过正式站点访问或稍后重试。";
      }
    }

    var dmgLink = $("#dmgLink");
    if (dmgLink) {
      if (data.dmgUrl) {
        var du = resolveUrl(data.dmgUrl);
        if (du) { dmgLink.href = du.href; dmgLink.hidden = false; }
      } else {
        dmgLink.hidden = true;
      }
    }
  }

  function loadManifest() {
    showManifestState("loading");
    var controller = new AbortController();
    var timer = setTimeout(function () { controller.abort(); }, 10000);

    fetch(MANIFEST_URL, { cache: "no-store", signal: controller.signal })
      .then(function (res) {
        clearTimeout(timer);
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      })
      .then(function (data) {
        var problem = validateManifest(data);
        if (problem) {
          showManifestState("error", problem + " 未能取得有效版本信息前，下载暂不开放。");
          return;
        }
        manifest = data;
        renderManifest(data);
        showManifestState("ready");
      })
      .catch(function (err) {
        clearTimeout(timer);
        var reason = err && err.name === "AbortError"
          ? "版本清单请求超时（10 秒无响应）。"
          : "版本清单读取失败（" + (err && err.message ? err.message : "网络异常") + "）。";
        showManifestState("error", reason + " 可能是网络异常或发布服务正在维护；应用内更新不受影响。");
      });
  }

  var retryBtn = $("#manifestRetry");
  if (retryBtn) retryBtn.addEventListener("click", loadManifest);

  /* ---------------- 下载流程 ---------------- */

  var dlModal = $("#dlModal");
  var dlButton = $("#dlButton");
  var dlConfirm = $("#dlConfirm");
  var dlCancel = $("#dlCancel");
  var modalOpener = null;
  var checking = false;

  function openModal(opener) {
    if (!dlModal) return;
    modalOpener = opener || null;
    dlModal.classList.add("open");
    var box = $(".modal", dlModal);
    if (box) box.focus();
  }

  function closeModal() {
    if (!dlModal || !dlModal.classList.contains("open")) return;
    dlModal.classList.remove("open");
    if (modalOpener && modalOpener.focus) modalOpener.focus();
    modalOpener = null;
  }

  function setHint(text) {
    var hint = $("#dlButtonHint");
    if (hint) hint.textContent = text;
  }

  function setButton(label, disabled) {
    var btn = $("#dlButton");
    if (!btn) return;
    btn.innerHTML = label;
    btn.disabled = !!disabled;
  }

  function preflight(url) {
    var controller = new AbortController();
    var timer = setTimeout(function () { controller.abort(); }, 12000);
    return fetch(url, { method: "HEAD", cache: "no-store", signal: controller.signal })
      .then(function (res) { clearTimeout(timer); return res.status; })
      .catch(function (err) { clearTimeout(timer); throw err; });
  }

  if (dlButton) {
    dlButton.addEventListener("click", function () {
      if (!downloadReady || !manifest || checking) return;
      var url = resolveUrl(manifest.zipUrl);
      if (!url) return;

      checking = true;
      setButton("正在检查下载通道…", true);
      setHint("正在确认发布通道是否可用…");

      preflight(url.href).then(function (status) {
        checking = false;
        setButton("下载安装包<span class=\"btn-note\" id=\"dlButtonNote\">（" + formatSize(manifest.size) + "）</span>", false);
        if (status === 429) {
          setHint("当前通道繁忙，请稍后重试。");
          toast("当前通道繁忙，请稍后重试");
          return;
        }
        if (status >= 400) {
          setHint("发布服务返回 HTTP " + status + "，请稍后重试。");
          toast("发布服务暂时不可用（HTTP " + status + "）");
          return;
        }
        setHint("通道已就绪，请确认下载须知。");
        openModal(dlButton);
      }).catch(function (err) {
        checking = false;
        setButton("下载安装包<span class=\"btn-note\">（" + formatSize(manifest.size) + "）</span>", false);
        setHint(err && err.name === "AbortError" ? "检查超时，请稍后重试。" : "网络连接失败，请检查网络后重试。");
        toast("暂时连不上下载服务");
      });
    });
  }

  if (dlCancel) dlCancel.addEventListener("click", closeModal);
  if (dlModal) {
    dlModal.addEventListener("click", function (e) { if (e.target === dlModal) closeModal(); });
    dlModal.addEventListener("keydown", function (e) {
      if (e.key !== "Tab") return;
      var focusables = $$("button, [href], [tabindex]:not([tabindex=\"-1\"])", dlModal).filter(function (el) { return !el.disabled; });
      if (!focusables.length) return;
      var first = focusables[0];
      var last = focusables[focusables.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    });
  }
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") { closeModal(); closeMobileMenu(); }
  });

  if (dlConfirm) {
    dlConfirm.addEventListener("click", function () {
      if (!manifest) return;
      var url = resolveUrl(manifest.zipUrl);
      if (!url) return;

      var a = document.createElement("a");
      a.href = url.href;
      a.download = "";
      a.rel = "noopener";
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);

      closeModal();
      setButton("已开始下载<span class=\"btn-note\">浏览器接管中</span>", true);
      setHint("浏览器已开始下载。下载完成后建议核对 SHA-256 再解压。");
      toast("已开始下载，请留意浏览器下载提示");

      setTimeout(function () {
        if (!manifest) return;
        setButton("重新下载<span class=\"btn-note\">（" + formatSize(manifest.size) + "）</span>", false);
        setHint("再次点击可重新下载。");
      }, 7000);
    });
  }

  /* ---------------- SHA-256 复制 ---------------- */

  var copyBtn = $("#copySha");
  if (copyBtn) {
    copyBtn.addEventListener("click", function () {
      var node = $("#vSha");
      var text = node ? node.textContent.trim() : "";
      if (!text || text === "—") return;

      function done() {
        copyBtn.textContent = "已复制";
        copyBtn.classList.add("done");
        toast("SHA-256 已复制");
        setTimeout(function () { copyBtn.textContent = "复制"; copyBtn.classList.remove("done"); }, 2000);
      }

      function fallback() {
        var ta = document.createElement("textarea");
        ta.value = text;
        ta.style.cssText = "position:fixed;opacity:0";
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand("copy"); } catch (e) { /* 忽略 */ }
        document.body.removeChild(ta);
      }

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () { fallback(); done(); });
      } else {
        fallback();
        done();
      }
    });
  }

  /* ---------------- FAQ ---------------- */

  $$(".faq-item").forEach(function (item) {
    var q = $(".faq-q", item);
    var a = $(".faq-a", item);
    if (!q || !a) return;
    q.setAttribute("aria-expanded", "false");
    q.addEventListener("click", function () {
      var open = item.classList.toggle("open");
      q.setAttribute("aria-expanded", open ? "true" : "false");
      a.style.maxHeight = open ? a.scrollHeight + "px" : "0px";
      var arrow = $(".faq-arrow", q);
      if (arrow) arrow.textContent = open ? "−" : "＋";
    });
  });

  window.addEventListener("resize", function () {
    $$(".faq-item.open .faq-a").forEach(function (a) { a.style.maxHeight = a.scrollHeight + "px"; });
  }, { passive: true });

  /* ---------------- 启动 ---------------- */

  render();
  loadManifest();
})();
