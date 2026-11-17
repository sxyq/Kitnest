/* ============================================================
   Kitnest 手册 · 交互演示引擎（demo-kit · 按需加载版）
   ------------------------------------------------------------
   性能约定（2026-11-18 用户要求）：
   · 首屏只加载本文件（~11 KB），不加载任何场景数据；
   · 演示块进入视口（提前 320px）才 fetch 对应功能域的
     scenes-<group>.js，并且只构建这一个迷你界面；
   · 滚出视口 600px 就卸载 DOM、停止时间轴，回到视口重新加载；
   · 全页 36 段演示，任意时刻内存里只有视口附近的几段（实测 6–7 段），
     不再是首屏一次性构建 36 个迷你界面。

   场景数据（7 个 chunk，按需加载）：
     scenes-entry.js     界面与入口
     scenes-clipboard.js 剪贴板
     scenes-capture.js   截图与录屏
     scenes-monitor.js   系统监测
     scenes-transfer.js  传输
     scenes-tools.js     文件与工具
     scenes-app.js       应用与维护

   每个场景 = { title, stage, body, steps[], hit{} }，
   时间轴动作见下（act 方法）。
   ============================================================ */
(function () {
  "use strict";

  var reduced = window.matchMedia &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* 演示 id → 场景 chunk（保持与 tools/split_manual_scenes.py 一致） */
  var GROUP = {
    menubar: "entry", panel: "entry", statistics: "entry",
    clipboard: "clipboard", floatdesk: "clipboard", preview: "clipboard",
    capture: "capture", annotate: "capture", beautify: "capture",
    longshot: "capture", pin: "capture", curtain: "capture",
    history: "capture", ocr: "capture", captureplus: "capture",
    recording: "capture",
    monitor: "monitor", memory: "monitor", storage: "monitor",
    network: "monitor",
    transfer: "transfer", cast: "transfer",
    archive: "tools", toolbox: "tools", search: "tools", command: "tools",
    calendar: "tools", shortcuts: "tools", codepreview: "tools",
    cloudlink: "tools", ai: "tools",
    settings: "app", onboarding: "app", manual: "app", update: "app",
    workflow: "app"
  };

  var chunks = {};   // group → Promise

  function loadChunk(group) {
    if (chunks[group]) return chunks[group];
    chunks[group] = new Promise(function (resolve, reject) {
      var s = document.createElement("script");
      s.src = "demos/scenes-" + group + ".js";
      s.async = true;
      s.onload = function () { resolve(group); };
      s.onerror = function () {
        delete chunks[group];
        reject(new Error("场景加载失败：" + group));
      };
      document.head.appendChild(s);
    });
    return chunks[group];
  }

  function sleep(ms) {
    return new Promise(function (r) { setTimeout(r, ms); });
  }

  function el(sel, root) {
    return (root || document).querySelector(sel);
  }

  function center(sel, stage) {
    var node = el(sel, stage);
    if (!node) return null;
    var a = node.getBoundingClientRect();
    var b = stage.getBoundingClientRect();
    return { x: a.left - b.left + a.width / 2, y: a.top - b.top + a.height / 2 };
  }

  var CURSOR_SVG =
    '<svg width="18" height="24" viewBox="0 0 18 24" aria-hidden="true">' +
    '<path d="M2 1.6 15.4 12.2l-5.9.5 3.4 7.1-3.1 1.5-3.4-7.1-4.4 4z" ' +
    'fill="#111" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>';

  /* ---------------------------------------------------------- 单个演示 */

  function Demo(host) {
    this.host = host;
    this.id = host.getAttribute("data-demo");
    this.stage = el(".kdemo-stage", host);
    this.cap = el(".kdemo-cap", host);
    this.def = null;
    this.loading = null;
    this.built = false;
    this.playing = false;
    this.seen = false;
    this.token = 0;
    this.cursor = null;

    var self = this;
    var replay = el(".kdemo-replay", host);
    if (replay) {
      replay.addEventListener("click", function () {
        self.ensure().then(function (ok) { if (ok) self.play(); });
      });
    }
    this.observe();
  }

  Demo.prototype.observe = function () {
    var self = this;
    if (!("IntersectionObserver" in window)) {   // 兜底：老浏览器直接加载
      this.ensure().then(function (ok) { if (ok) self.play(); });
      return;
    }
    // 进入视口（提前 320px）：加载场景 + 构建 + 播放
    this.enterIO = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        self.ensure().then(function (ok) {
          if (!ok || self.playing) return;
          self.play();
        });
      });
    }, { rootMargin: "320px 0px", threshold: 0.01 });
    this.enterIO.observe(this.host);

    // 离开视口 600px：卸载 DOM、停时间轴（不使用的就不占内存）
    this.exitIO = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) return;
        self.teardown();
      });
    }, { rootMargin: "600px 0px", threshold: 0 });
    this.exitIO.observe(this.host);
  };

  /* 加载所属 chunk + 构建（同一块只构建一次） */
  Demo.prototype.ensure = function () {
    var self = this;
    if (this.built) return Promise.resolve(true);
    if (this.loading) return this.loading;
    var group = GROUP[this.id] || "app";
    this.loading = loadChunk(group).then(function () {
      self.loading = null;
      var def = (window.KDEMOS || {})[self.id];
      if (!def) {
        self.stage.innerHTML =
          '<div class="kdemo-missing">缺少演示定义：' + (self.id || "?") + "</div>";
        self.built = true;
        return false;
      }
      self.def = def;
      self.build();
      return true;
    }).catch(function (err) {
      self.loading = null;
      self.stage.innerHTML = '<div class="kdemo-missing">' + err.message + "</div>";
      return false;
    });
    return this.loading;
  };

  /* 卸载：清 DOM、清说明、中断时间轴 */
  Demo.prototype.teardown = function () {
    if (!this.built) return;
    this.token++;
    this.playing = false;
    this.built = false;
    this.seen = false;
    this.def = null;
    this.cursor = null;
    this.stage.innerHTML = "";
    this.say("");
    var dots = el(".kdemo-dots", this.host);
    if (dots) dots.innerHTML = "";
  };

  Demo.prototype.build = function () {
    var def = this.def;
    this.stage.style.minHeight = (def.stage || 420) + "px";
    this.stage.innerHTML = def.body;

    var c = document.createElement("div");
    c.className = "kui-cursor";
    c.innerHTML = CURSOR_SVG;
    this.stage.appendChild(c);
    this.cursor = c;
    this.place(46, this.stage.clientHeight * 0.32);

    this.bindHit();
    this.built = true;
  };

  Demo.prototype.bindHit = function () {
    var hit = this.def && this.def.hit;
    if (!hit) return;
    var self = this;
    Object.keys(hit).forEach(function (sel) {
      Array.prototype.forEach.call(self.stage.querySelectorAll(sel), function (node) {
        node.classList.add("kui-hit");
        node.addEventListener("click", function (ev) {
          if (self.playing) return;
          ev.stopPropagation();
          try { hit[sel].call(self, node, self); } catch (e) { /* 忽略 */ }
        });
      });
    });
  };

  Demo.prototype.place = function (x, y) {
    if (!this.cursor) return;
    this.cursor.style.transform = "translate(" + x + "px," + y + "px)";
  };

  Demo.prototype.say = function (text) {
    if (!this.cap) return;
    this.cap.textContent = text || "";
    this.cap.classList.toggle("on", !!text);
  };

  Demo.prototype.tick = function (i, n) {
    var dots = el(".kdemo-dots", this.host);
    if (!dots) return;
    if (!dots.children.length) {
      for (var k = 0; k < n; k++) {
        var d = document.createElement("i");
        dots.appendChild(d);
      }
    }
    Array.prototype.forEach.call(dots.children, function (d, k) {
      d.className = k < i ? "done" : k === i ? "on" : "";
    });
  };

  Demo.prototype.reset = function () {
    if (!this.def) return;
    this.stage.innerHTML = this.def.body;
    var c = document.createElement("div");
    c.className = "kui-cursor";
    c.innerHTML = CURSOR_SVG;
    this.stage.appendChild(c);
    this.cursor = c;
    this.place(46, this.stage.clientHeight * 0.32);
    this.say("");
    this.bindHit();
  };

  Demo.prototype.glow = function (sel, ms) {
    var node = el(sel, this.stage);
    if (!node) return Promise.resolve();
    node.classList.add("kui-glow");
    return sleep(ms || 700).then(function () {
      node.classList.remove("kui-glow");
    });
  };

  Demo.prototype.ripple = function (sel) {
    var p = sel && typeof sel === "string" ? center(sel, this.stage) : sel;
    if (!p) return;
    var r = document.createElement("span");
    r.className = "kui-ripple";
    r.style.left = p.x + "px";
    r.style.top = p.y + "px";
    this.stage.appendChild(r);
    setTimeout(function () { r.remove(); }, 620);
  };

  Demo.prototype.act = function (s) {
    var self = this;
    var stage = this.stage;

    if (s.wait) return sleep(s.wait);
    if (s.cap !== undefined) { this.say(s.cap); return sleep(s.hold || 900); }

    if (s.move) {
      var p = typeof s.move === "string" ? center(s.move, stage) : s.move;
      if (!p) return Promise.resolve();
      var ms = reduced ? 0 : (s.ms || 620);
      if (!this.cursor) return Promise.resolve();
      this.cursor.style.transitionDuration = ms + "ms";
      return new Promise(function (res) {
        requestAnimationFrame(function () {
          self.place(p.x, p.y);
          setTimeout(res, ms + 40);
        });
      });
    }

    if (s.click || s.rclick || s.dblclick) {
      var t = s.click || s.rclick || s.dblclick;
      var q = typeof t === "string" ? center(t, stage) : t;
      var node = typeof t === "string" ? el(t, stage) : null;
      if (q) this.ripple(q);
      if (s.rclick && node) node.classList.add("kui-ctx-open");
      return sleep(reduced ? 60 : 240).then(function () {
        if (s.rclick) return sleep(700);
        if (node && !reduced) {
          node.classList.add("kui-press");
          setTimeout(function () { node.classList.remove("kui-press"); }, 180);
        }
        return sleep(s.after || 520);
      });
    }

    if (s.type) {
      var target = el(s.type, stage);
      if (target) {
        target.classList.add("kui-typing");
        var txt = s.text || "";
        for (var i = 0; i < txt.length; i++) {
          (function (ch, idx) {
            setTimeout(function () {
              target.textContent = txt.slice(0, idx + 1);
            }, idx * (reduced ? 10 : 68));
          })(txt[i], i);
        }
        return sleep(txt.length * (reduced ? 10 : 68) + 260).then(function () {
          target.classList.remove("kui-typing");
        });
      }
      return Promise.resolve();
    }

    if (s.scroll) {
      var box = el(s.scroll, stage);
      if (box) {
        box.scrollBy({ top: s.dy || 200, behavior: reduced ? "auto" : "smooth" });
        return sleep(s.ms || 900);
      }
      return Promise.resolve();
    }

    if (s.add || s.remove || s.toggle) {
      var sel2 = s.add || s.remove || s.toggle;
      var cls = s.add ? s.addClass : s.remove ? s.removeClass : s.toggleClass;
      Array.prototype.forEach.call(stage.querySelectorAll(sel2), function (n) {
        n.classList[s.add ? "add" : s.remove ? "remove" : "toggle"](cls);
      });
      return sleep(s.hold === undefined ? 420 : s.hold);
    }

    if (s.set) {
      Array.prototype.forEach.call(stage.querySelectorAll(s.set), function (n) {
        n.textContent = s.text || "";
      });
      return sleep(s.hold === undefined ? 380 : s.hold);
    }

    if (s.html) {
      Array.prototype.forEach.call(stage.querySelectorAll(s.html), function (n) {
        n.innerHTML = s.value || "";
      });
      return sleep(s.hold === undefined ? 420 : s.hold);
    }

    if (s.show || s.hide) {
      var sel3 = s.show || s.hide;
      Array.prototype.forEach.call(stage.querySelectorAll(sel3), function (n) {
        n.classList[s.show ? "remove" : "add"]("kui-hidden");
      });
      return sleep(s.hold === undefined ? 420 : s.hold);
    }

    if (s.glow) return this.glow(s.glow, s.hold || 700);
    if (s.run) { s.run.call(this); return sleep(s.hold === undefined ? 500 : s.hold); }
    if (s.end) { this.playing = false; }
    return Promise.resolve();
  };

  Demo.prototype.play = function () {
    var self = this;
    if (!this.def || !this.def.steps || !this.built) return;
    this.token++;
    var me = this.token;
    this.playing = true;

    this.reset();
    this.playing = true;

    var steps = this.def.steps;
    var i = 0;
    var next = function () {
      if (me !== self.token || !self.built) { self.playing = false; return; }
      if (i >= steps.length) {
        self.playing = false;
        self.tick(-1, steps.length);
        return;
      }
      var s = steps[i];
      self.tick(i, steps.length);
      i++;
      Promise.resolve(self.act(s)).then(function () {
        if (me !== self.token) { self.playing = false; return; }
        setTimeout(next, s.gap === undefined ? 60 : s.gap);
      });
    };
    setTimeout(next, 420);
  };

  /* ---------------------------------------------------------- 启动 */

  function boot() {
    Array.prototype.forEach.call(document.querySelectorAll(".kdemo"), function (host) {
      new Demo(host);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
