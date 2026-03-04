'use strict';

/**
 * @nodejs-mobile/bridge
 *
 * Node.js-side API for communicating with the host Android (or iOS) app.
 *
 * Usage in your Node.js code:
 *
 *   const bridge = require('@nodejs-mobile/bridge');
 *
 *   // Listen for messages from the Android app
 *   bridge.on('ping', (msg) => {
 *     const data = JSON.parse(msg);
 *     bridge.send('pong', JSON.stringify({ echo: data }));
 *   });
 *
 *   // Notify Android of the HTTP port
 *   const http = require('http');
 *   const server = http.createServer(...);
 *   server.listen(0, () => {
 *     bridge.channel('http-port').send(String(server.address().port));
 *   });
 */

const EventEmitter = require('events');

// The native mobile_bridge module is injected as a linked binding by node_bridge.cpp.
// It exposes: { send(channel, msg), setReceiver(fn) }
let _native = null;

try {
  _native = process._linkedBinding('mobile_bridge');
} catch (e) {
  // Not running on mobile — provide a no-op stub for desktop testing
  _native = {
    send: (ch, msg) => console.log(`[bridge stub] -> ${ch}: ${msg}`),
    setReceiver: () => {},
  };
}

const _emitter = new EventEmitter();
_emitter.setMaxListeners(100);

// Wire the native receiver so incoming messages from Android dispatch to JS
_native.setReceiver((channel, message) => {
  _emitter.emit(channel, message);
  _emitter.emit('*', channel, message);
});

/**
 * Send a message to the Android app on [channel].
 * @param {string} channel
 * @param {string} message  Plain string or JSON.stringify'd object
 */
function send(channel, message) {
  _native.send(channel, typeof message === 'string' ? message : JSON.stringify(message));
}

/**
 * Register a listener for messages on [channel] from the Android app.
 * @param {string} channel
 * @param {(message: string) => void} listener
 */
function on(channel, listener) {
  _emitter.on(channel, listener);
}

/**
 * Remove a specific listener, or all listeners for [channel].
 */
function off(channel, listener) {
  if (listener) {
    _emitter.removeListener(channel, listener);
  } else {
    _emitter.removeAllListeners(channel);
  }
}

/**
 * Convenience: get a channel object with send/on/off bound to a specific channel name.
 * @param {string} name
 * @returns {{ send(msg: string): void, on(fn): void, off(fn?): void }}
 */
function channel(name) {
  return {
    send:  (msg) => send(name, msg),
    on:    (fn)  => on(name, fn),
    off:   (fn)  => off(name, fn),
  };
}

module.exports = { send, on, off, channel };
