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
    let pipVideo = null;
    let sessionURL = null;
    let playbackPath = location.pathname;
    let scheduled = false;

    const synchronizeRoute = () => {
        if (playbackPath === location.pathname) return;
        playbackPath = location.pathname;
        sessionURL = null;
        post('session', { url: null });
    };

    // 実際に再生される DPlayer の video を優先。画質変更で要素は交換される。
    const activeVideo = () => {
        const candidates = Array.from(document.querySelectorAll('.dplayer video'));
        return candidates.find(video => video.classList?.contains('dplayer-video-current'))
            || candidates.find(video => !video.paused && video.readyState > 0)
            || candidates.find(video => video.readyState > 0)
            || candidates[0] || null;
    };
    const inPiP = video => !!video && (document.pictureInPictureElement === video
        || video.webkitPresentationMode === 'picture-in-picture');
    const canUseWebKitPiP = video => {
        try { return typeof video?.webkitSupportsPresentationMode === 'function'
            && video.webkitSupportsPresentationMode('picture-in-picture'); } catch (_) { return false; }
    };
    const canUseStandardPiP = video => document.pictureInPictureEnabled === true
        && typeof video?.requestPictureInPicture === 'function' && !video.disablePictureInPicture;
    const publishPiP = video => {
        const active = inPiP(video);
        if (active) pipVideo = video;
        else if (pipVideo === video) pipVideo = null;
        post('pip', { active: !!pipVideo && inPiP(pipVideo) });
    };
    const publishPlayback = () => {
        const video = activeVideo();
        post('playback', { playing: !!video && !video.paused && !video.ended });
        if (!video) {
            sessionURL = null;
            post('session', { url: null });
            if (pipVideo && !pipVideo.isConnected) {
                pipVideo = null;
                post('pip', { active: false });
            }
        }
    };
    const showError = () => {
        const message = 'PiP を開始できませんでした。動画を再生してから、もう一度お試しください。';
        post('error', { message });
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
            ['loadedmetadata', 'play', 'pause', 'emptied', 'ended'].forEach(event => {
                video.addEventListener(event, () => { updateButtons(); publishPlayback(); });
            });
        });
        updateButtons();
        publishPlayback();
    };
    const scheduleScan = () => {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(scan);
    };

    // タップの同期処理内から要求し、native の非同期 evaluateJavaScript にユーザー操作を渡さない。
    document.addEventListener('click', event => {
        // 古い video が残ったまま画質を切り替えないよう、既存 UI の操作前に PiP を終了する。
        if (event.target?.closest?.('.dplayer-setting-quality-item') && pipVideo) {
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
                if (video.webkitPresentationMode === 'picture-in-picture'
                    && typeof video.webkitSetPresentationMode === 'function') {
                    video.webkitSetPresentationMode('inline');
                } else if (typeof document.exitPictureInPicture === 'function') {
                    Promise.resolve(document.exitPictureInPicture()).catch(showError);
                }
            } else if (canUseWebKitPiP(video)) {
                video.webkitSetPresentationMode('picture-in-picture');
            } else if (canUseStandardPiP(video)) {
                Promise.resolve(video.requestPictureInPicture()).catch(showError);
            } else {
                showError();
            }
        } catch (_) { showError(); }
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
    Object.defineProperty(window, 'KonomiTVNative', {
        value: Object.freeze({ version: '0.1.0', refresh }), configurable: false, writable: false
    });
    document.addEventListener('visibilitychange', refresh);
    document.addEventListener('DOMContentLoaded', () => {
        new MutationObserver(scheduleScan).observe(document.documentElement, {
            childList: true, subtree: true
        });
        scan();
        post('ready');
    }, { once: true });
})();
