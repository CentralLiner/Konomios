(() => {
    'use strict';
    const expectedOrigin = __KONOMI_ORIGIN__;
    if (window.top !== window || location.origin !== expectedOrigin || window.KonomiTVNative) return;

    const native = window.webkit?.messageHandlers?.konomiNative;
    if (!native) return;
    const post = (event, details = {}) => {
        try { native.postMessage({ event, ...details }); } catch (_) { /* ページの破棄中は送信しない */ }
    };
    const boundVideos = new WeakSet();
    const startChecks = new WeakMap();
    const pendingStandardRequests = new WeakSet();
    let pipVideo = null;
    let sessionURL = null;
    let playbackPath = location.pathname;
    let scheduled = false;
    let fallbackEnabled = false;
    let landscapeLocked = false;
    const isWatchRoute = () => /\/(?:tv|videos)\/watch\/[^/]+\/?$/.test(location.pathname);
    const landscapeButtons = () => [
        ...document.querySelectorAll('.dplayer-full-icon'),
        ...document.querySelectorAll('.dplayer-full-in-icon')
    ];
    const updateLandscapeButtons = () => {
        const label = landscapeLocked ? '横画面固定を解除' : '横画面に固定';
        landscapeButtons().forEach(button => {
            button.setAttribute('aria-label', label);
            button.setAttribute('aria-pressed', String(landscapeLocked));
            button.setAttribute('title', label);
            button.setAttribute('data-balloon', label);
        });
    };
    const setLandscapeLocked = locked => {
        landscapeLocked = locked === true;
        updateLandscapeButtons();
    };

    const synchronizeRoute = () => {
        if (playbackPath === location.pathname) return;
        playbackPath = location.pathname;
        sessionURL = null;
        post('session', { url: null });
        if (landscapeLocked && !isWatchRoute()) {
            setLandscapeLocked(false);
            post('landscape-exit');
        }
    };

    // 実際に再生される DPlayer の video を優先。画質変更で要素は交換される。
    const activeVideo = () => {
        const candidates = Array.from(document.querySelectorAll('.dplayer video'));
        return candidates.find(video => video.classList?.contains('dplayer-video-current'))
            || candidates.find(video => !video.paused && video.readyState > 0)
            || candidates.find(video => video.readyState > 0)
            || candidates[0] || null;
    };
    const inPiP = video => !!video && video.isConnected && (document.pictureInPictureElement === video
        || video.webkitPresentationMode === 'picture-in-picture');
    const canUseWebKitPiP = video => {
        try { return typeof video?.webkitSupportsPresentationMode === 'function'
            && video.webkitSupportsPresentationMode('picture-in-picture'); } catch (_) { return false; }
    };
    const canUseStandardPiP = video => document.pictureInPictureEnabled === true
        && typeof video?.requestPictureInPicture === 'function' && !video.disablePictureInPicture;
    const isPlaying = video => !!video && video.isConnected && !video.paused
        && !video.ended && video.readyState > 0;
    const reportMediaState = (video, kind) => {
        post('media-diagnostic', {
            kind, paused: video.paused, ended: video.ended, readyState: video.readyState,
            time: Number(video.currentTime) || 0, hidden: document.hidden,
            mode: video.webkitPresentationMode || 'inline',
            bufferedEnd: video.buffered?.length ? video.buffered.end(video.buffered.length - 1) : 0,
            errorCode: video.error?.code || 0
        });
    };
    const clearStartCheck = video => {
        if (!startChecks.has(video)) return;
        clearTimeout(startChecks.get(video));
        startChecks.delete(video);
    };
    const isRequestPending = video => startChecks.has(video) || pendingStandardRequests.has(video);
    const publishPiP = video => {
        const active = inPiP(video);
        if (active) {
            clearStartCheck(video);
            pendingStandardRequests.delete(video);
        }
        if (active) pipVideo = video;
        else if (pipVideo === video) pipVideo = null;
        post('pip', { active: !!pipVideo && inPiP(pipVideo) });
    };
    const publishPlayback = () => {
        // 新しい video がすでに存在しても、切断された旧 PiP は保持しない。
        if (pipVideo && !pipVideo.isConnected) {
            pipVideo = null;
            post('pip', { active: false });
        }
        const video = activeVideo();
        post('playback', { playing: isPlaying(video) });
        if (!video) {
            sessionURL = null;
            post('session', { url: null });
        }
    };
    const showError = () => {
        const message = 'PiP を開始できませんでした。動画を再生してから、もう一度お試しください。';
        post('error', { message });
    };

    const requestWebKitPiP = video => {
        if (inPiP(video) || isRequestPending(video)) return false;
        startChecks.set(video, setTimeout(() => {
            startChecks.delete(video);
            if (video.isConnected && !inPiP(video)) showError();
        }, 2000));
        try {
            video.webkitSetPresentationMode('picture-in-picture');
            return true;
        } catch (_) {
            clearStartCheck(video);
            showError();
            return false;
        }
    };

    const styleID = 'konomi-native-actions-style';
    const ensureActionStyle = () => {
        if (document.getElementById(styleID)) return;
        const style = document.createElement('style');
        style.id = styleID;
        style.textContent = `
            /* The native browser extends through the home indicator area. */
            .route-container:has(> .watch-container) { border-bottom:0 !important; }
            .konomi-native-actions { display:flex; flex-wrap:wrap; gap:8px; margin:12px 0; }
            .konomi-native-actions[hidden] { display:none !important; }
            .konomi-native-action { font:inherit; font-size:13px; color:inherit; cursor:pointer;
                border:1px solid rgba(128,128,128,.28); border-radius:6px; min-height:36px;
                padding:6px 12px; background:rgba(128,128,128,.08); touch-action:manipulation; }
            .konomi-native-action:focus-visible { outline:2px solid var(--v-primary-base,#ac7afa); outline-offset:2px; }
            .konomi-native-actions--navigation .konomi-native-action { flex:1; }
            .konomi-native-actions--login { justify-content:center; }
            .konomi-native-actions--fallback { justify-content:center; margin:24px 16px; }
            .konomi-native-player-action { display:flex; align-items:center; width:100%; border:0;
                border-radius:0; min-height:40px; padding:8px 20px; background:transparent; text-align:left; }
            .konomi-native-player-action:hover { background:rgba(255,255,255,.08); }
        `;
        (document.head || document.documentElement).appendChild(style);
    };
    const actions = [['settings', 'アプリの接続先'], ['reload', '再読み込み']];
    const actionButton = (action, title, player) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = player ? 'dplayer-setting-item konomi-native-action konomi-native-player-action'
            : 'konomi-native-action';
        button.setAttribute('data-konomi-native-action', action);
        button.setAttribute('aria-label', action === 'settings' ? 'iOS アプリの接続先を設定' : '視聴画面を再読み込み');
        const label = document.createElement('span');
        if (player) label.className = 'dplayer-label';
        label.textContent = title;
        button.appendChild(label);
        return button;
    };
    const ensureActionRow = (host, surface) => {
        let row = host.querySelector(`[data-konomi-native-actions="${surface}"]`);
        if (row) return row;
        row = document.createElement('div');
        row.className = `konomi-native-actions konomi-native-actions--${surface}`;
        row.setAttribute('data-konomi-native-actions', surface);
        for (const [action, title] of actions) row.appendChild(actionButton(action, title, false));
        if (surface === 'detail') host.insertBefore(row, host.firstChild);
        else host.appendChild(row);
        return row;
    };
    const navigationVisible = navigation => {
        const style = window.getComputedStyle(navigation);
        return style.display !== 'none' && style.visibility !== 'hidden'
            && navigation.getClientRects().length > 0;
    };
    const injectActions = () => {
        ensureActionStyle();
        const navigations = Array.from(document.querySelectorAll('.settings-navigation'));
        navigations.forEach(host => ensureActionRow(host, 'navigation'));
        const hasVisibleNavigation = navigations.some(navigationVisible);
        document.querySelectorAll('.settings').forEach(host => {
            const row = host.querySelector('[data-konomi-native-actions="detail"]');
            if (row || !hasVisibleNavigation) ensureActionRow(host, 'detail').hidden = hasVisibleNavigation;
        });
        document.querySelectorAll('.login-container').forEach(host => ensureActionRow(host, 'login'));
        document.querySelectorAll('.dplayer-setting-origin-panel').forEach(panel => {
            for (const [action, title] of actions) {
                if (panel.querySelector(`[data-konomi-native-action="${action}"]`)) continue;
                const button = actionButton(action, title, true);
                button.setAttribute('data-konomi-native-actions', 'player');
                panel.appendChild(button);
            }
        });
        const fallback = document.querySelector('[data-konomi-native-actions="fallback"]');
        const recognizedUI = ['.header', '.watch-container', '.settings-navigation', '.settings', '.login-container']
            .some(selector => document.querySelector(selector));
        if (recognizedUI) fallback?.parentNode?.removeChild(fallback);
        else if (fallbackEnabled && document.body) ensureActionRow(document.body, 'fallback');
    };

    const updateButtons = () => {
        const video = activeVideo();
        if (!video) return;
        const supported = canUseWebKitPiP(video) || canUseStandardPiP(video);
        document.querySelectorAll('.dplayer-pip-icon').forEach(button => {
            // DPlayer が標準 API 判定で隠した場合でも、WebKit の動画 PiP が使えれば表示する。
            if (supported && button.style.display === 'none') button.style.display = '';
            button.setAttribute('aria-label', 'ピクチャ・イン・ピクチャ');
        });
    };
    const scan = () => {
        scheduled = false;
        synchronizeRoute();
        document.querySelectorAll('.dplayer video').forEach(video => {
            if (boundVideos.has(video)) return;
            boundVideos.add(video);
            video.setAttribute('playsinline', '');
            video.addEventListener('enterpictureinpicture', () => publishPiP(video));
            video.addEventListener('leavepictureinpicture', () => publishPiP(video));
            video.addEventListener('webkitpresentationmodechanged', () => publishPiP(video));
            ['playing', 'pause', 'waiting', 'stalled', 'error', 'webkitpresentationmodechanged'].forEach(event => {
                video.addEventListener(event, () => reportMediaState(video, event));
            });
            ['loadedmetadata', 'play', 'pause', 'emptied', 'ended'].forEach(event => {
                video.addEventListener(event, () => {
                    updateButtons();
                    publishPlayback();
                });
            });
        });
        injectActions();
        updateButtons();
        updateLandscapeButtons();
        publishPlayback();
        // 新規 document でも初期状態を通知し、前ページの native PiP 状態を解除する。
        const actualPiPVideo = Array.from(document.querySelectorAll('.dplayer video')).find(inPiP);
        if (actualPiPVideo) publishPiP(actualPiPVideo);
        else {
            pipVideo = null;
            post('pip', { active: false });
        }
    };
    const scheduleScan = () => {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(scan);
    };

    // タップの同期処理内から要求し、native の非同期 evaluateJavaScript にユーザー操作を渡さない。
    document.addEventListener('click', event => {
        const landscapeButton = event.target?.closest?.('.dplayer-full-icon')
            || event.target?.closest?.('.dplayer-full-in-icon');
        if (landscapeButton && isWatchRoute()) {
            event.preventDefault();
            event.stopImmediatePropagation();
            post('landscape-toggle');
            return;
        }
        const action = event.target?.closest?.('[data-konomi-native-action]')?.getAttribute('data-konomi-native-action');
        if (action === 'settings' || action === 'reload') {
            event.preventDefault();
            event.stopImmediatePropagation();
            document.querySelector('.dplayer-mask')?.click();
            post(action);
            return;
        }
        // 古い video が残ったまま画質を切り替えないよう、既存 UI の操作前に PiP を終了する。
        if (event.target?.closest?.('.dplayer-setting-quality-item')) {
            if (!pipVideo) return;
            try {
                if (pipVideo.webkitPresentationMode === 'picture-in-picture') {
                    pipVideo.webkitSetPresentationMode('inline');
                } else if (typeof document.exitPictureInPicture === 'function') {
                    Promise.resolve(document.exitPictureInPicture()).catch(() => {});
                }
            } catch (_) { /* 切り替え自体のエラー処理は既存プレイヤーが行う */ }
            return;
        }
        const button = event.target?.closest?.('.dplayer-pip-icon');
        if (!button) return;
        const video = activeVideo();
        if (!video) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        try {
            if (inPiP(video)) {
                clearStartCheck(video);
                if (video.webkitPresentationMode === 'picture-in-picture'
                    && typeof video.webkitSetPresentationMode === 'function') {
                    video.webkitSetPresentationMode('inline');
                } else if (typeof document.exitPictureInPicture === 'function') {
                    Promise.resolve(document.exitPictureInPicture()).catch(showError);
                }
            } else if (isRequestPending(video)) {
                return;
            } else if (canUseWebKitPiP(video)) {
                requestWebKitPiP(video);
            } else if (canUseStandardPiP(video)) {
                pendingStandardRequests.add(video);
                Promise.resolve(video.requestPictureInPicture()).then(() => pendingStandardRequests.delete(video), () => {
                    pendingStandardRequests.delete(video);
                    showError();
                });
            } else {
                showError();
            }
        } catch (_) {
            pendingStandardRequests.delete(video);
            showError();
        }
    }, true);
    document.addEventListener('dblclick', event => {
        if (!isWatchRoute() || !event.target?.closest?.('.dplayer-video-wrap')) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        post('landscape-toggle');
    }, true);
    window.addEventListener('keydown', event => {
        if (!isWatchRoute() || event.repeat || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return;
        const target = event.target;
        if (target?.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(target?.tagName)) return;
        if (event.code === 'KeyF' || (!event.code && event.key?.toLowerCase() === 'f')) {
            event.preventDefault();
            event.stopImmediatePropagation();
            post('landscape-toggle');
        } else if (landscapeLocked && event.key === 'Escape') {
            event.preventDefault();
            event.stopImmediatePropagation();
            post('landscape-exit');
        }
    }, true);
    // 既存の通信から録画 session_id だけを観測する。トークン・Cookie・レスポンスは渡さない。
    const observeStreamRequest = rawURL => {
        synchronizeRoute();
        try {
            const url = new URL(rawURL, location.href);
            if (url.origin !== expectedOrigin || url.username || url.password || url.hash) return;
            const match = url.pathname.match(/^\/api\/streams\/video\/([0-9]+)\/([A-Za-z0-9_-]+)\/(playlist|segment|keep-alive)$/);
            const sessionID = url.searchParams.get('session_id');
            if (!match || !sessionID || !/^[A-Za-z0-9_-]{1,128}$/.test(sessionID)) return;
            const keepAlive = new URL(`/api/streams/video/${match[1]}/${match[2]}/keep-alive`, expectedOrigin);
            keepAlive.searchParams.set('session_id', sessionID);
            if (sessionURL === keepAlive.href) return;
            sessionURL = keepAlive.href;
            post('session', { url: sessionURL });
        } catch (_) { /* Web 側の元の通信を変更しない */ }
    };
    const originalFetch = window.fetch;
    if (typeof originalFetch === 'function') {
        window.fetch = function(input, ...args) {
            observeStreamRequest(typeof input === 'string' || input instanceof URL ? input : input?.url);
            return originalFetch.call(this, input, ...args);
        };
    }
    if (window.XMLHttpRequest) {
        const originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url, ...args) {
            observeStreamRequest(url);
            return originalOpen.call(this, method, url, ...args);
        };
    }
    const refresh = () => { scan(); if (pipVideo) publishPiP(pipVideo); };
    const reportLayout = () => {
        const watch = document.querySelector('.watch-container')?.getBoundingClientRect?.();
        post('layout-diagnostic', { width: window.innerWidth, height: window.innerHeight,
            fullscreen: !!(document.fullscreenElement || document.webkitFullscreenElement),
            landscapeLocked,
            watchWidth: watch?.width || 0, watchHeight: watch?.height || 0 });
    };
    Object.defineProperty(window, 'KonomiTVNative', {
        value: Object.freeze({ version: '0.2.0', refresh, setLandscapeLocked }), configurable: false, writable: false
    });
    document.addEventListener('visibilitychange', refresh);
    window.addEventListener('resize', () => { scheduleScan(); reportLayout(); });
    document.addEventListener('DOMContentLoaded', () => {
        new MutationObserver(scheduleScan).observe(document.documentElement, {
            childList: true, subtree: true
        });
        scan();
        post('ready');
        // 誤った URL が HTTP 200 の一般ページを返しても、接続先を変更できるようにする。
        setTimeout(() => {
            fallbackEnabled = true;
            injectActions();
        }, 5000);
    }, { once: true });
})();
