/* ============================================================
   Kitnest 手册 · 交互演示引擎（demo-kit）
   ------------------------------------------------------------
   设计目标与「设置 → 个性化 → 效果预览」一致：
   · 迷你窗口 / 面板用真实组件样式渲染，数据全部是模拟数据；
   · 每段演示 = 一条预设时间轴（光标移动 → 点击 → 界面响应）；
   · 自动播放，也可以随时点界面里的元素自己试，随时重播。

   场景数据在 scenes.js，本文件只负责渲染与播放：
     KDEMOS.<id> = {
       title: "…",            // 演示标题
       stage: 460,            // 舞台高度（px，可省略）
       body: `<div>…</div>`,  // 舞台 HTML（.kui-* 原语）
       steps: [ … ],          // 时间轴
       hit:   { … }           // 可选：读者手动点按的交互
     }

   时间轴动作（按顺序执行）：
     move(sel|{x,y}, ms)  click(sel)  rclick(sel)  dblclick(sel)
     type(sel, text)      scroll(sel, dy)          wait(ms)
     cap(text)            add(sel, cls)  remove(sel, cls)  toggle(sel, cls)
     set(sel, text)       html(sel, html)  show(sel)  hide(sel)
     run(fn)              end()
   ============================================================ */
(function () {
  "use strict";

  var reduced = window.matchMedia &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;

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

  /* ---------------------------------------------------------- 单个演示 */

  function Demo(host) {
    this.host = host;
    this.id = host.getAttribute("data-demo");
    this.def = (window.KDEMOS || {})[this.id];
    this.stage = el(".kdemo-stage", host);
    this.cap = el(".kdemo-cap", host);
    this.ctrl = el(".kdemo-ctrl", host);
    this.token = 0;
    this.cursor = null;
    this.pos = { x: 40, y: 40 };
    this.playing = false;
    this.build();
  }

  Demo.prototype.build = function () {
    if (!this.def) {
      this.stage.innerHTML =
        '<div class="kdemo-missing">缺少演示定义：' + (this.id || "?") + "</div>";
      return;
    }
    this.stage.style.minHeight = (this.def.stage || 420) + "px";
    this.stage.innerHTML = this.def.body;

    // 合成光标（指向左上）
    var c = document.createElement("div");
    c.className = "kui-cursor";
    c.innerHTML =
      '<svg width="18" height="24" viewBox="0 0 18 24" aria-hidden="true">' +
      '<path d="M2 1.6 15.4 12.2l-5.9.5 3.4 7.1-3.1 1.5-3.4-7.1-4.4 4z" ' +
      'fill="#111" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>';
    this.stage.appendChild(c);
    this.cursor = c;
    this.place(46, this.stage.clientHeight * 0.32);

    // 重播按钮
    var replay = el(".kdemo-replay", this.host);
    if (replay) {
      var self = this;
      replay.addEventListener("click", function () { self.play(); });
    }

    // 读者手动点按：带 .kui-hit 的元素可直接操作
    var hit = this.def.hit;
    if (hit) {
      var self2 = this;
      Object.keys(hit).forEach(function (sel) {
        Array.prototype.forEach.call(
          self2.stage.querySelectorAll(sel),
          function (node) {
            node.classList.add("kui-hit");
            node.addEventListener("click", function (ev) {
              if (self2.playing) return;
              ev.stopPropagation();
              try { hit[sel].call(self2, node, self2); } catch (e) { /* 忽略 */ }
            });
          }
        );
      });
    }

    // 视口内才自动播放
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting && !self.played) {
            self.played = true;
            self.play();
          }
        });
      },
      { threshold: 0.35 }
    );
    io.observe(this.host);
  };

  Demo.prototype.place = function (x, y) {
    this.pos = { x: x, y: y };
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
    c.innerHTML =
      '<svg width="18" height="24" viewBox="0 0 18 24" aria-hidden="true">' +
      '<path d="M2 1.6 15.4 12.2l-5.9.5 3.4 7.1-3.1 1.5-3.4-7.1-4.4 4z" ' +
      'fill="#111" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>';
    this.stage.appendChild(c);
    this.cursor = c;
    this.place(46, this.stage.clientHeight * 0.32);
    this.say("");
    var self = this, hit = this.def.hit;
    if (hit) {
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
    }
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
    if (s.end) { this.playing = false; this.cursor && this.cursor.classList.add("kui-rest"); }
    return Promise.resolve();
  };

  Demo.prototype.play = function () {
    var self = this;
    if (!this.def || !this.def.steps) return;
    this.token++;
    var me = this.token;
    this.playing = true;

    var run = function () {
      self.reset();
      self.playing = true;
      var steps = self.def.steps;
      var i = 0;
      var next = function () {
        if (me !== self.token) return;
        if (i >= steps.length) {
          self.playing = false;
          self.tick(-1, steps.length);
          if (self.cursor) self.cursor.classList.add("kui-rest");
          return;
        }
        var s = steps[i];
        self.tick(i, steps.length);
        i++;
        Promise.resolve(self.act(s)).then(function () {
          setTimeout(next, s.gap === undefined ? 60 : s.gap);
        });
      };
      setTimeout(next, 420);
    };

    // 从视口外进入时，等布局稳定再播
    setTimeout(run, 60);
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
