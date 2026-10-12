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

function harness(options = {}) {
    const messages = [];
    const calls = [];
    const document = new Target();
    const video = new Target();
    Object.assign(video, {
        paused: false, ended: false, readyState: 4, isConnected: true,
        webkitPresentationMode: 'inline', attributes: {},
        classList: { contains: name => name === 'dplayer-video-current' },
        setAttribute(name, value) { this.attributes[name] = value; },
        webkitSupportsPresentationMode: () => options.webKit !== false,
        webkitSetPresentationMode(mode) {
            if (options.silentWebKit) { calls.push(['webkit', mode]); return; }
            this.webkitPresentationMode = mode;
            calls.push(['webkit', mode]);
            this.emit('webkitpresentationmodechanged');
        },
        requestPictureInPicture() {
            calls.push(['standard']);
            if (options.rejectStandard) return Promise.reject(new Error('unavailable'));
            document.pictureInPictureElement = this;
            this.emit('enterpictureinpicture');
            return Promise.resolve({});
        }
    });
    const button = { style: { display: 'none' }, setAttribute() {} };
    let videos = [video];
    Object.assign(document, {
        documentElement: {}, pictureInPictureEnabled: options.standard !== false,
        pictureInPictureElement: null,
        querySelectorAll(selector) {
            return selector === '.dplayer video' ? videos : [button];
        },
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
    const window = {
        webkit: { messageHandlers: { konomiNative: { postMessage: message => messages.push(message) } } },
        fetch(...args) { calls.push(['fetch', ...args]); return Promise.resolve('response'); },
        XMLHttpRequest
    };
    window.top = options.iframe ? {} : window;
    const origin = options.origin || 'https://tv.example:7000';
    const location = { origin, href: origin + '/tv/watch/gr011', pathname: '/tv/watch/gr011' };
    const timers = new Map();
    let nextTimer = 0;
    const context = vm.createContext({
        window, document, location, URL,
        XMLHttpRequest, MutationObserver, requestAnimationFrame: callback => callback(), Promise,
        setTimeout: callback => { const id = ++nextTimer; timers.set(id, callback); return id; },
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
    return { window, document, video, button, messages, calls, click, location,
        runTimers() { for (const callback of Array.from(timers.values())) callback(); timers.clear(); },
        mutate() { observer?.(); },
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
    assert.equal(h.messages.at(-1).active, false);
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
