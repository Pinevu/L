// ==通用媒体检测脚本（可拖拽浮窗版）==
// 功能：
// - 扫描 video/source/iframe
// - 扫描 HTML 源码中的媒体候选
// - 监听 MediaSource 与 createObjectURL
// - 右上角可拖拽浮窗
// - 支持复制全部结果
// - 支持 JSON 导出
//
// 仅用于你有权限的站点调试

(function () {
  'use strict';

  const CONFIG = {
    scanInterval: 3000,
    panelWidth: 420,
    panelHeight: 520,
    maxItems: 500,
    debug: true
  };

  const seen = new Set();
  const items = [];
  let panelEl, listEl, countEl, statusEl, headerEl;
  let dragging = false;
  let dragOffsetX = 0;
  let dragOffsetY = 0;

  function log(...args) {
    if (CONFIG.debug) console.log('[MediaDetector]', ...args);
  }

  function normalizeUrl(url, baseUrl) {
    try {
      return new URL(url, baseUrl || location.href).href;
    } catch (e) {
      return url;
    }
  }

  function isProbablyMediaUrl(url) {
    if (!url || typeof url !== 'string') return false;
    if (url.startsWith('blob:') || url.startsWith('data:')) return false;
    if (/\.(jpg|jpeg|png|gif|webp|svg|bmp|ico)(\?|#|$)/i.test(url)) return false;
    if (/\.(css|woff|woff2|ttf|eot|otf)(\?|#|$)/i.test(url)) return false;

    if (
      url.includes('.m3u8') || url.includes('.mpd') || url.includes('.mp4') || url.includes('.webm') || url.includes('.flv') ||
      url.includes('.ts') || url.includes('.m4s') || url.includes('.mkv') || url.includes('.mov') ||
      url.includes('manifest') || url.includes('playlist') || url.includes('/live/') || url.includes('/stream/') || url.includes('/hls/')
    ) return true;

    return /\/(video|audio|stream|hls|vod|media|live|player|embed)\//i.test(url);
  }

  function registerMedia(url, source, extra = {}) {
    const normalized = normalizeUrl(url);
    if (!normalized || seen.has(normalized)) return false;
    if (!isProbablyMediaUrl(normalized)) return false;

    seen.add(normalized);

    const item = {
      url: normalized,
      source,
      time: new Date().toISOString(),
      ...extra
    };

    items.push(item);
    if (items.length > CONFIG.maxItems) {
      items.splice(0, items.length - CONFIG.maxItems);
    }

    renderList();
    return true;
  }

  function extractMediaCandidates(text, baseUrl) {
    const results = new Set();
    if (!text) return [];

    const patterns = [
      /https?:\/\/[^"'\\s>]+?\.(m3u8|mpd|mp4|webm|flv|m4s|ts)([^"'\\s>]*)/ig,
      /[^"'\\s>]+?\.(m3u8|mpd|mp4|webm|flv|m4s|ts)([^"'\\s>]*)/ig
    ];

    for (const re of patterns) {
      let m;
      while ((m = re.exec(text))) {
        const raw = m[0].replace(/&amp;/g, '&');
        try {
          results.add(new URL(raw, baseUrl || location.href).href);
        } catch (e) {}
      }
    }

    return [...results];
  }

  function createPanel() {
    panelEl = document.createElement('div');
    panelEl.id = 'media-detector-panel';
    panelEl.style.cssText = [
      'position:fixed',
      'top:12px',
      'right:12px',
      'width:' + CONFIG.panelWidth + 'px',
      'height:' + CONFIG.panelHeight + 'px',
      'z-index:2147483647',
      'background:rgba(17,24,39,0.96)',
      'color:#fff',
      'font:12px/1.4 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif',
      'border:1px solid rgba(255,255,255,0.15)',
      'border-radius:10px',
      'box-shadow:0 8px 30px rgba(0,0,0,0.35)',
      'overflow:hidden',
      'display:flex',
      'flex-direction:column',
      'resize:both'
    ].join(';');

    panelEl.innerHTML = `
      <div id="md-header" style="display:flex;align-items:center;justify-content:space-between;padding:10px 12px;background:rgba(255,255,255,0.06);border-bottom:1px solid rgba(255,255,255,0.08);cursor:move;user-select:none">
        <div style="font-weight:700">媒体检测面板</div>
        <div style="display:flex;gap:6px;align-items:center;flex-wrap:wrap;justify-content:flex-end">
          <button id="md-refresh" style="all:unset;cursor:pointer;background:#2563eb;padding:4px 8px;border-radius:6px">刷新</button>
          <button id="md-copy" style="all:unset;cursor:pointer;background:#16a34a;padding:4px 8px;border-radius:6px">复制全部</button>
          <button id="md-export" style="all:unset;cursor:pointer;background:#7c3aed;padding:4px 8px;border-radius:6px">导出 JSON</button>
          <button id="md-clear" style="all:unset;cursor:pointer;background:#374151;padding:4px 8px;border-radius:6px">清空</button>
          <button id="md-close" style="all:unset;cursor:pointer;background:#b91c1c;padding:4px 8px;border-radius:6px">关闭</button>
        </div>
      </div>
      <div style="padding:8px 12px;border-bottom:1px solid rgba(255,255,255,0.08);display:flex;gap:10px;align-items:center;flex-wrap:wrap">
        <span>数量: <b id="md-count">0</b></span>
        <span id="md-status" style="opacity:.75"></span>
      </div>
      <div id="md-list" style="flex:1;overflow:auto;padding:8px 0"></div>
    `;

    document.documentElement.appendChild(panelEl);
    listEl = panelEl.querySelector('#md-list');
    countEl = panelEl.querySelector('#md-count');
    statusEl = panelEl.querySelector('#md-status');
    headerEl = panelEl.querySelector('#md-header');

    panelEl.querySelector('#md-close').addEventListener('click', () => panelEl.remove());

    panelEl.querySelector('#md-clear').addEventListener('click', () => {
      seen.clear();
      items.length = 0;
      renderList('已清空');
    });

    panelEl.querySelector('#md-refresh').addEventListener('click', () => {
      scanAll();
      renderList('已刷新');
    });

    panelEl.querySelector('#md-copy').addEventListener('click', async () => {
      const text = items.map((it, i) => `${i + 1}. [${it.source}] ${it.url}`).join('\n');
      try {
        await navigator.clipboard.writeText(text || '');
        renderList('已复制全部结果');
      } catch (e) {
        renderList('复制失败：浏览器权限限制');
      }
    });

    panelEl.querySelector('#md-export').addEventListener('click', async () => {
      const json = JSON.stringify(items, null, 2);
      try {
        const blob = new Blob([json], { type: 'application/json;charset=utf-8' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `media-detect-${Date.now()}.json`;
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
        renderList('已导出 JSON');
      } catch (e) {
        renderList('导出失败');
      }
    });

    headerEl.addEventListener('mousedown', onDragStart);
    document.addEventListener('mousemove', onDragMove);
    document.addEventListener('mouseup', onDragEnd);
    headerEl.addEventListener('touchstart', onTouchStart, { passive: false });
    document.addEventListener('touchmove', onTouchMove, { passive: false });
    document.addEventListener('touchend', onTouchEnd);
  }

  function onDragStart(e) {
    if (e.button !== 0) return;
    dragging = true;
    const rect = panelEl.getBoundingClientRect();
    dragOffsetX = e.clientX - rect.left;
    dragOffsetY = e.clientY - rect.top;
    panelEl.style.right = 'auto';
    panelEl.style.bottom = 'auto';
    panelEl.style.left = rect.left + 'px';
    panelEl.style.top = rect.top + 'px';
    e.preventDefault();
  }

  function onDragMove(e) {
    if (!dragging) return;
    panelEl.style.left = (e.clientX - dragOffsetX) + 'px';
    panelEl.style.top = (e.clientY - dragOffsetY) + 'px';
  }

  function onDragEnd() {
    dragging = false;
  }

  function onTouchStart(e) {
    if (!e.touches || !e.touches[0]) return;
    dragging = true;
    const t = e.touches[0];
    const rect = panelEl.getBoundingClientRect();
    dragOffsetX = t.clientX - rect.left;
    dragOffsetY = t.clientY - rect.top;
    panelEl.style.right = 'auto';
    panelEl.style.bottom = 'auto';
    panelEl.style.left = rect.left + 'px';
    panelEl.style.top = rect.top + 'px';
    e.preventDefault();
  }

  function onTouchMove(e) {
    if (!dragging || !e.touches || !e.touches[0]) return;
    const t = e.touches[0];
    panelEl.style.left = (t.clientX - dragOffsetX) + 'px';
    panelEl.style.top = (t.clientY - dragOffsetY) + 'px';
    e.preventDefault();
  }

  function onTouchEnd() {
    dragging = false;
  }

  function renderList(status) {
    if (!listEl || !countEl) return;
    countEl.textContent = String(items.length);
    if (statusEl && status) statusEl.textContent = status;

    listEl.innerHTML = items.slice().reverse().map(item => `
      <div style="padding:8px 12px;border-bottom:1px solid rgba(255,255,255,0.06)">
        <div style="font-size:11px;opacity:.75;margin-bottom:4px">${item.source} · ${item.time}</div>
        <div style="word-break:break-all">
          <a href="${item.url}" target="_blank" rel="noreferrer" style="color:#93c5fd;text-decoration:none">${item.url}</a>
        </div>
      </div>
    `).join('') || `
      <div style="padding:16px 12px;opacity:.65">暂无检测结果</div>
    `;
  }

  function scanVideos() {
    document.querySelectorAll('video').forEach(video => {
      try {
        const src = video.getAttribute('src') || video.currentSrc || '';
        if (src) registerMedia(src, 'video');

        video.querySelectorAll('source').forEach(source => {
          const s = source.getAttribute('src') || source.src || '';
          if (s) registerMedia(s, 'source');
        });
      } catch (e) {}
    });
  }

  function scanIframes() {
    document.querySelectorAll('iframe').forEach(frame => {
      try {
        const src = frame.getAttribute('src') || '';
        if (src && !src.startsWith('about:blank')) {
          registerMedia(src, 'iframe');
        }
      } catch (e) {}
    });
  }

  function scanHtml() {
    try {
      const html = document.documentElement?.innerHTML || '';
      extractMediaCandidates(html, location.href).forEach(url => registerMedia(url, 'html'));
    } catch (e) {
      log('HTML 扫描失败', e);
    }
  }

  function scanPerformance() {
    try {
      const entries = performance.getEntriesByType('resource') || [];
      entries.forEach(entry => {
        if (entry && entry.name) registerMedia(entry.name, 'performance');
      });
    } catch (e) {}
  }

  function hookMediaSource() {
    if (!window.MediaSource || !window.MediaSource.prototype) return;
    const original = window.MediaSource.prototype.addSourceBuffer;
    if (typeof original !== 'function') return;

    window.MediaSource.prototype.addSourceBuffer = function (mimeType) {
      try {
        registerMedia('MediaSource:' + mimeType, 'mediasource');
      } catch (e) {}
      return original.apply(this, arguments);
    };
  }

  function hookCreateObjectURL() {
    if (!window.URL || typeof URL.createObjectURL !== 'function') return;
    const original = URL.createObjectURL;
    URL.createObjectURL = function (obj) {
      try {
        const type = obj && obj.constructor ? obj.constructor.name : typeof obj;
        registerMedia('createObjectURL:' + type, 'blob-hook');
      } catch (e) {}
      return original.apply(this, arguments);
    };
  }

  function observeDom() {
    const obs = new MutationObserver(() => {
      scanVideos();
      scanIframes();
      scanHtml();
    });

    obs.observe(document.documentElement || document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src', 'href']
    });

    return obs;
  }

  function scanAll() {
    scanVideos();
    scanIframes();
    scanHtml();
    scanPerformance();
  }

  function startLoop() {
    setInterval(scanAll, CONFIG.scanInterval);
  }

  function init() {
    createPanel();
    hookMediaSource();
    hookCreateObjectURL();
    scanAll();
    observeDom();
    startLoop();
    renderList('已启动');
    log('可拖拽浮窗版已启动');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }

  window.__MediaDetectorPanel__ = {
    getItems: () => items.slice(),
    clear: () => {
      seen.clear();
      items.length = 0;
      renderList('已清空');
    },
    scanAll
  };
})();
