const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const template = fs.readFileSync(path.join(__dirname, '../KonomiTV/Resources/MediaBridge.js'), 'utf8');

class Target {
    constructor() { this.listeners = new Map(); }
    addEventListener(name, callback) {
        const callbacks = this.listeners.get(name) || [];
        callbacks.push(callback);
        this.listeners.set(name, callbacks);
    }
    emit(name, event = {}) { for (const callback of this.listeners.get(name) || []) callback(event); }
}

class Element extends Target {
    constructor(tagName = 'div', className = '') {
        super();
        this.tagName = tagName.toUpperCase();
        this.className = className;
        this.attributes = {};
        this.children = [];
        this.parentNode = null;
        this.isConnected = false;
        this.style = { setProperty(name, value) { this[name] = String(value); } };
        this.hidden = false;
        this.classList = { contains: name => this.className.split(/\s+/).includes(name) };
    }
    setAttribute(name, value) { this.attributes[name] = String(value); }
    getAttribute(name) { return this.attributes[name] ?? null; }
    connect(connected) {
        this.isConnected = connected;
        for (const child of this.children) child.connect(connected);
    }
    appendChild(child) {
        child.parentNode?.removeChild(child);
        child.parentNode = this;
        this.children.push(child);
        child.connect(this.isConnected);
        return child;
    }
    insertBefore(child, before) {
        if (!before) return this.appendChild(child);
        child.parentNode?.removeChild(child);
        child.parentNode = this;
        this.children.splice(this.children.indexOf(before), 0, child);
        child.connect(this.isConnected);
        return child;
    }
    removeChild(child) {
        this.children.splice(this.children.indexOf(child), 1);
        child.parentNode = null;
        child.connect(false);
    }
    get firstChild() { return this.children[0] || null; }
    matches(selector) {
        if (selector.startsWith('.')) return this.classList.contains(selector.slice(1));
        if (selector.startsWith('#')) return this.id === selector.slice(1);
        const attribute = selector.match(/^\[([^=\]]+)(?:="([^"]*)")?\]$/);
        return !!attribute && (attribute[2] === undefined
            ? this.getAttribute(attribute[1]) !== null
            : this.getAttribute(attribute[1]) === attribute[2]);
    }
    querySelectorAll(selector) {
        const matches = [];
        for (const child of this.children) {
            if (child.matches(selector)) matches.push(child);
            matches.push(...child.querySelectorAll(selector));
        }
        return matches;
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    closest(selector) {
        for (let element = this; element; element = element.parentNode) {
            if (element.matches(selector)) return element;
        }
        return null;
    }
    getClientRects() { return this.style.display === 'none' || this.hidden ? [] : [{}]; }
    click() { this.emit('click'); }
}

function harness(options = {}) {
    const messages = [];
    const calls = [];
    const document = new Target();
    const video = new Element('video');
    Object.assign(video, {
        paused: !!options.paused, ended: false, readyState: 4, isConnected: true,
        autoPictureInPicture: false,
        webkitPresentationMode: 'inline', attributes: {},
        classList: { contains: name => name === 'dplayer-video-current' },
        setAttribute(name, value) { this.attributes[name] = value; },
        play() {
            calls.push(['play']);
            if (options.rejectPlay) return Promise.reject(new Error('unavailable'));
            this.paused = false;
            this.emit('play');
            return Promise.resolve();
        },
        webkitSupportsPresentationMode: () => options.webKit !== false,
        webkitSetPresentationMode(mode) {
            if (options.throwWebKit) { calls.push(['webkit', mode]); throw new Error('unavailable'); }
            if (options.silentWebKit) { calls.push(['webkit', mode]); return; }
            if (options.pauseOnPiPRequest && mode === 'picture-in-picture') {
                this.paused = true;
                this.emit('pause');
            }
            this.webkitPresentationMode = mode;
            calls.push(['webkit', mode]);
            this.emit('webkitpresentationmodechanged');
        },
        requestPictureInPicture() {
            calls.push(['standard']);
            if (options.throwStandard) throw new Error('unavailable');
            if (options.rejectStandard) return Promise.reject(new Error('unavailable'));
            document.pictureInPictureElement = this;
            this.emit('enterpictureinpicture');
            return Promise.resolve({});
        }
    });
    const button = { style: { display: 'none' }, setAttribute() {} };
    let videos = [video];
    const documentElement = new Element('html');
    documentElement.connect(true);
    const head = documentElement.appendChild(new Element('head'));
    const body = documentElement.appendChild(new Element('body'));
    const surfaces = {};
    const surfaceClasses = {
        navigation: 'settings-navigation', detail: 'settings', login: 'login-container',
        player: 'dplayer-setting-origin-panel', home: 'header', watch: 'watch-container'
    };
    for (const surface of options.surfaces || []) {
        surfaces[surface] = body.appendChild(new Element('div', surfaceClasses[surface]));
    }
    if (surfaces.navigation && options.hiddenNavigation) surfaces.navigation.style.display = 'none';
    const mask = body.appendChild(new Element('div', 'dplayer-mask'));
    const fullButtons = [body.appendChild(new Element('button', 'dplayer-full-icon')),
        body.appendChild(new Element('button', 'dplayer-full-in-icon'))];
    let maskClicks = 0;
    mask.addEventListener('click', () => maskClicks++);
    Object.assign(document, {
        documentElement, head, body, hidden: false, pictureInPictureEnabled: options.standard !== false,
        pictureInPictureElement: null,
        createElement: tagName => new Element(tagName),
        getElementById: id => documentElement.querySelector('#' + id),
        querySelectorAll(selector) {
            if (selector === '.dplayer video') return videos;
            if (selector === '.dplayer-pip-icon') return [button];
            return documentElement.querySelectorAll(selector);
        },
        querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
        exitPictureInPicture() {
            calls.push(['exit']);
            const oldVideo = this.pictureInPictureElement;
            this.pictureInPictureElement = null;
            oldVideo?.emit('leavepictureinpicture');
            return Promise.resolve();
        }
    });
    let observer;
    class MutationObserver {
        constructor(callback) { observer = callback; }
        observe() {}
    }
    class XMLHttpRequest {
        open(...args) { calls.push(['xhr', ...args]); }
    }
    const window = Object.assign(new Target(), {
        webkit: { messageHandlers: { konomiNative: { postMessage: message => messages.push(message) } } },
        fetch(...args) { calls.push(['fetch', ...args]); return Promise.resolve('response'); },
        XMLHttpRequest,
        getComputedStyle: element => ({ display: element.style.display || 'block', visibility: element.style.visibility || 'visible' })
    });
    window.top = options.iframe ? {} : window;
    const origin = options.origin || 'https://tv.example:7000';
    const location = { origin, href: origin + '/tv/watch/gr011', pathname: '/tv/watch/gr011' };
    const timers = new Map();
    let nextTimer = 0;
    let currentTime = 0;
    class Clock extends Date { static now() { return currentTime; } }
    const context = vm.createContext({
        window, document, location, URL, Date: Clock,
        XMLHttpRequest, MutationObserver, requestAnimationFrame: callback => callback(), Promise,
        setTimeout: (callback, delay) => { const id = ++nextTimer; timers.set(id, { callback, due: currentTime + delay }); return id; },
        clearTimeout: id => timers.delete(id)
    });
    const script = template.replace('__KONOMI_ORIGIN__', JSON.stringify('https://tv.example:7000'));
    vm.runInContext(script, context, { filename: 'MediaBridge.js' });
    document.emit('DOMContentLoaded');
    const click = (selector = '.dplayer-pip-icon') => {
        let prevented = false;
        let stopped = false;
        document.emit('click', {
            target: { closest: candidate => candidate === selector ? button : null },
            preventDefault() { prevented = true; },
            stopImmediatePropagation() { stopped = true; }
        });
        return { prevented, stopped };
    };
    return { window, document, video, button, fullButtons, messages, calls, click, location, surfaces,
        get maskClicks() { return maskClicks; },
        clickElement(target) {
            let prevented = false;
            let stopped = false;
            document.emit('click', { target,
                preventDefault() { prevented = true; },
                stopImmediatePropagation() { stopped = true; }
            });
            return { prevented, stopped };
        },
        setHidden(hidden) { document.hidden = hidden; document.emit('visibilitychange'); },
        advanceTime(milliseconds) { currentTime += milliseconds; },
        runTimers() { for (const timer of Array.from(timers.values())) timer.callback(); timers.clear(); },
        runDueTimers() {
            for (const [id, timer] of Array.from(timers.entries())) {
                if (timer.due <= currentTime) { timers.delete(id); timer.callback(); }
            }
        },
        mutate() { observer?.(); },
        addSurface(surface) {
            const element = body.appendChild(new Element('div', surfaceClasses[surface]));
            surfaces[surface] = element;
            observer?.();
            return element;
        },
        replaceVideos(next) { videos = next; observer?.(); }
    };
}

test('exposes bridge only in the registered server main frame', () => {
    for (const options of [{ origin: 'https://other.example' }, { iframe: true }]) {
        const h = harness(options);
        assert.equal(h.window.KonomiTVNative, undefined);
        assert.equal(h.messages.length, 0);
    }
});

test('starts WebKit PiP from the same click and prevents duplicate DPlayer requests', () => {
    const h = harness();
    assert.deepEqual(h.click(), { prevented: true, stopped: true });
    assert.equal(h.video.webkitPresentationMode, 'picture-in-picture');
    assert.deepEqual(h.calls, [['webkit', 'picture-in-picture']]);
    assert.ok(h.messages.some(message => message.event === 'pip' && message.active));
    h.click();
    assert.equal(h.video.webkitPresentationMode, 'inline');
    assert.equal(h.messages.filter(message => message.event === 'pip').at(-1).active, false);
});

test('makes a WebKit-capable button available when standard PiP detection fails', () => {
    const h = harness({ standard: false });
    assert.equal(h.button.style.display, '');
    assert.equal(h.video.attributes.playsinline, '');
    h.click();
    assert.equal(h.video.webkitPresentationMode, 'picture-in-picture');
});

test('uses standard PiP when WebKit presentation mode is not available', () => {
    const h = harness({ webKit: false });
    h.click();
    assert.equal(h.document.pictureInPictureElement, h.video);
    assert.deepEqual(h.calls, [['standard']]);
    h.click();
    assert.equal(h.document.pictureInPictureElement, null);
    assert.deepEqual(h.calls.at(-1), ['exit']);
});

test('reports a rejected PiP request instead of treating API availability as success', async () => {
    const h = harness({ webKit: false, rejectStandard: true });
    h.click();
    await Promise.resolve();
    assert.ok(h.messages.some(message => message.event === 'error'));
    assert.ok(!h.messages.some(message => message.event === 'pip' && message.active));
});

test('captures only registered-origin recording sessions without modifying fetch results', async () => {
    const h = harness();
    const url = 'https://tv.example:7000/api/streams/video/42/1080p-hevc/playlist?session_id=abc123&type=master';
    const result = await h.window.fetch(url);
    assert.equal(result, 'response');
    assert.equal(h.messages.filter(message => message.event === 'session').at(-1).url,
        'https://tv.example:7000/api/streams/video/42/1080p-hevc/keep-alive?session_id=abc123');
    assert.deepEqual(h.calls.at(-1), ['fetch', url]);
    const count = h.messages.length;
    await h.window.fetch('https://other.example/api/streams/video/42/1080p/playlist?session_id=secret');
    await h.window.fetch('/api/users/me');
    await h.window.fetch('/api/streams/video/42/1080p/playlist?session_id=%2Fescape');
    assert.equal(h.messages.length, count);
});

test('observes Axios XHR sessions and rebinds newly created video elements once', () => {
    const h = harness();
    const xhr = new h.window.XMLHttpRequest();
    xhr.open('PUT', '/api/streams/video/42/1080p/keep-alive?session_id=abc123');
    assert.ok(h.messages.some(message => message.event === 'session' && message.url.includes('abc123')));
    const nextVideo = new Target();
    Object.assign(nextVideo, {
        paused: false, readyState: 4, isConnected: true,
        setAttribute() {}, classList: { contains: () => true }
    });
    h.replaceVideos([nextVideo]);
    h.mutate();
    assert.equal(nextVideo.listeners.get('enterpictureinpicture').length, 1);
});

test('clears native heartbeat and PiP state when the player leaves the page', () => {
    const h = harness();
    h.click();
    h.video.isConnected = false;
    h.replaceVideos([]);
    assert.ok(h.messages.some(message => message.event === 'session' && message.url === null));
    assert.equal(h.messages.at(-1).active, false);
});

test('exits old PiP before changing quality without swallowing the quality selection', () => {
    const h = harness();
    h.click();
    assert.deepEqual(h.click('.dplayer-setting-quality-item'), { prevented: false, stopped: false });
    assert.equal(h.video.webkitPresentationMode, 'inline');
});

test('discards a recording session when an SPA route changes with a video still present', async () => {
    const h = harness();
    h.location.pathname = '/videos/watch/42';
    await h.window.fetch('/api/streams/video/42/1080p/playlist?session_id=abc123');
    assert.ok(h.messages.at(-1).url.includes('abc123'));
    h.location.pathname = '/tv/watch/gr011';
    h.mutate();
    assert.ok(h.messages.some(message => message.event === 'session' && message.url === null));
    assert.equal(h.messages.filter(message => message.event === 'session').at(-1).url, null);
});

test('clears old PiP when its video is replaced without a leave event', () => {
    const h = harness();
    h.click();
    h.video.isConnected = false;
    const next = new Target();
    Object.assign(next, { paused: false, readyState: 4, isConnected: true, setAttribute() {} });
    h.replaceVideos([next]);
    h.window.KonomiTVNative.refresh();
    assert.equal(h.messages.filter(message => message.event === 'pip').at(-1).active, false);
});

test('a new document explicitly resets native PiP state', () => {
    const h = harness();
    assert.ok(h.messages.some(message => message.event === 'pip' && message.active === false));
});

test('reports a silent WebKit PiP failure after checking actual presentation state', () => {
    const h = harness({ silentWebKit: true });
    h.click();
    assert.ok(!h.messages.some(message => message.event === 'error'));
    h.runTimers();
    assert.ok(h.messages.some(message => message.event === 'error'));
    assert.ok(!h.messages.some(message => message.event === 'pip' && message.active));
});

test('adds native settings and reload actions to settings, login and player surfaces exactly once', () => {
    const h = harness({ surfaces: ['navigation', 'detail', 'login', 'player'] });
    h.mutate();
    h.window.KonomiTVNative.refresh();
    assert.equal(h.document.querySelectorAll('#konomi-native-actions-style').length, 1);
    assert.equal(h.surfaces.navigation.querySelectorAll('[data-konomi-native-action]').length, 2);
    assert.equal(h.surfaces.login.querySelectorAll('[data-konomi-native-action]').length, 2);
    assert.equal(h.surfaces.detail.querySelectorAll('[data-konomi-native-action]').length, 0);
    const playerActions = h.surfaces.player.querySelectorAll('[data-konomi-native-action]');
    assert.equal(playerActions.length, 2);
    assert.ok(playerActions.every(button => button.tagName === 'BUTTON'
        && button.type === 'button' && button.classList.contains('dplayer-setting-item')
        && button.parentNode === h.surfaces.player));
    for (const action of ['settings', 'reload']) {
        const button = h.surfaces.player.querySelector(`[data-konomi-native-action="${action}"]`);
        assert.deepEqual(h.clickElement(button.firstChild), { prevented: true, stopped: true });
        assert.equal(h.messages.at(-1).event, action);
    }
    assert.equal(h.maskClicks, 2);
    assert.equal(h.window.KonomiTVNative.version, '0.2.0');
});

test('shows detail actions when settings navigation is hidden and updates on viewport resize', () => {
    const h = harness({ surfaces: ['navigation', 'detail'], hiddenNavigation: true });
    const row = h.surfaces.detail.querySelector('[data-konomi-native-actions="detail"]');
    assert.ok(row && !row.hidden);
    h.surfaces.navigation.style.display = 'block';
    h.window.emit('resize');
    assert.equal(row.hidden, true);
    h.surfaces.navigation.style.display = 'none';
    h.window.emit('resize');
    assert.equal(row.hidden, false);
    assert.equal(h.surfaces.detail.querySelectorAll('[data-konomi-native-action]').length, 2);
});

test('re-injects actions after a Vue page is replaced without leaving duplicates', () => {
    const h = harness({ surfaces: ['login'] });
    const old = h.surfaces.login;
    old.parentNode.removeChild(old);
    const next = h.addSurface('login');
    h.mutate();
    assert.equal(next.querySelectorAll('[data-konomi-native-action]').length, 2);
    assert.equal(h.document.querySelectorAll('[data-konomi-native-actions="login"]').length, 1);
    const settings = next.querySelector('[data-konomi-native-action="settings"]');
    h.clickElement(settings);
    assert.equal(h.messages.at(-1).event, 'settings');
});

test('adds one page-footer recovery row after an unrecognized HTTP 200 page remains mounted', () => {
    const h = harness();
    assert.equal(h.document.querySelector('[data-konomi-native-actions="fallback"]'), null);
    h.advanceTime(5000);
    h.runTimers();
    h.mutate();
    h.window.KonomiTVNative.refresh();
    const rows = h.document.querySelectorAll('[data-konomi-native-actions="fallback"]');
    assert.equal(rows.length, 1);
    assert.equal(rows[0].parentNode, h.document.body);
    assert.equal(rows[0].querySelectorAll('[data-konomi-native-action]').length, 2);
    for (const action of ['settings', 'reload']) {
        h.clickElement(rows[0].querySelector(`[data-konomi-native-action="${action}"]`));
        assert.equal(h.messages.at(-1).event, action);
    }
});

test('keeps recognized home, watch, settings and login pages free from fallback controls', () => {
    for (const surface of ['home', 'watch', 'navigation', 'detail', 'login']) {
        const h = harness({ surfaces: [surface] });
        h.advanceTime(5000);
        h.runTimers();
        h.mutate();
        assert.equal(h.document.querySelector('[data-konomi-native-actions="fallback"]'), null);
    }
});

test('removes the recovery footer when a late Vue mount creates the recognized home UI', () => {
    const h = harness();
    h.advanceTime(5000);
    h.runTimers();
    assert.ok(h.document.querySelector('[data-konomi-native-actions="fallback"]'));
    h.addSurface('home');
    h.mutate();
    assert.equal(h.document.querySelector('[data-konomi-native-actions="fallback"]'), null);
});

test('replaces both fullscreen buttons with a native landscape toggle without touching playback', () => {
    const h = harness();
    for (const button of h.fullButtons) {
        const icon = button.appendChild(new Element('svg'));
        assert.deepEqual(h.clickElement(icon), { prevented: true, stopped: true });
        assert.equal(h.messages.at(-1).event, 'landscape-toggle');
    }
    assert.deepEqual(h.calls, []);
    assert.equal(h.document.fullscreenElement, undefined);
});

test('native orientation state updates button labels and survives player UI replacement', () => {
    const h = harness();
    h.window.KonomiTVNative.setLandscapeLocked(true);
    assert.equal(h.fullButtons[0].getAttribute('aria-pressed'), 'true');
    assert.equal(h.fullButtons[0].getAttribute('aria-label'), '横画面固定を解除');
    const replacement = h.document.body.appendChild(new Element('button', 'dplayer-full-icon'));
    h.mutate();
    assert.equal(replacement.getAttribute('title'), '横画面固定を解除');
    h.window.KonomiTVNative.setLandscapeLocked(false);
    assert.equal(replacement.getAttribute('aria-pressed'), 'false');
    assert.equal(replacement.getAttribute('data-balloon'), '横画面に固定');
});

test('keeps landscape lock across channel changes and releases it when leaving live or recorded watch', () => {
    const h = harness();
    h.window.KonomiTVNative.setLandscapeLocked(true);
    for (const pathname of ['/tv/watch/gr022', '/videos/watch/42']) {
        h.location.pathname = pathname;
        h.location.href = h.location.origin + pathname;
        h.window.KonomiTVNative.refresh();
        assert.ok(!h.messages.some(message => message.event === 'landscape-exit'));
    }
    h.location.pathname = '/settings';
    h.location.href = h.location.origin + '/settings';
    h.window.KonomiTVNative.refresh();
    assert.equal(h.messages.filter(message => message.event === 'landscape-exit').length, 1);
    assert.equal(h.fullButtons[0].getAttribute('aria-pressed'), 'false');
});

test('fullscreen shortcut and video double click request native orientation, excluding text input', () => {
    const h = harness();
    const event = { code: 'KeyF', key: 'f', preventDefault() {}, stopImmediatePropagation() {} };
    h.window.emit('keydown', event);
    assert.equal(h.messages.at(-1).event, 'landscape-toggle');
    const count = h.messages.length;
    h.window.emit('keydown', { ...event, target: { tagName: 'INPUT' } });
    h.window.emit('keydown', { ...event, target: { isContentEditable: true } });
    h.window.emit('keydown', { ...event, ctrlKey: true });
    h.window.emit('keydown', { ...event, repeat: true });
    assert.equal(h.messages.length, count);
    h.document.emit('dblclick', { ...event, target: new Element('div', 'dplayer-video-wrap') });
    assert.equal(h.messages.at(-1).event, 'landscape-toggle');
    h.window.KonomiTVNative.setLandscapeLocked(true);
    h.window.emit('keydown', { ...event, code: 'Escape', key: 'Escape' });
    assert.equal(h.messages.at(-1).event, 'landscape-exit');
});

test('Home visibility changes never start PiP or resume a paused video automatically', () => {
    for (const paused of [false, true]) {
        const h = harness({ paused });
        h.setHidden(true);
        h.setHidden(false);
        h.window.KonomiTVNative.refresh();
        assert.deepEqual(h.calls, []);
        assert.equal(h.video.paused, paused);
    }
});

test('manually started PiP remains active across Home and foreground visibility changes', () => {
    const h = harness();
    h.click();
    h.setHidden(true);
    h.setHidden(false);
    assert.deepEqual(h.calls, [['webkit', 'picture-in-picture']]);
    assert.equal(h.video.webkitPresentationMode, 'picture-in-picture');
});

test('leaves the original media library and media properties untouched', () => {
    const h = harness();
    const library = { createPlayer: () => ({}) };
    h.window.mpegts = library;
    assert.equal(h.window.mpegts, library);
    assert.equal(Object.getOwnPropertyDescriptor(h.window, 'mpegts').set, undefined);
    assert.equal(Object.hasOwn(h.video, 'muted'), false);
    assert.equal(h.window.KonomiTVNative.setNativePlayback, undefined);
    assert.equal(h.window.KonomiTVNative.prepareForBackground, undefined);
});
