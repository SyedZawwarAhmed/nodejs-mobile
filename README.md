# nodejs-mobile

Run **Node.js v24** on Android (and iOS coming soon).

## What this is

A framework-agnostic library that embeds Node.js v24 LTS into mobile apps.
The existing [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile) project tops out at v18 — this project picks up from there.

## Architecture

```
Android App (Kotlin/Java)
        │
        │  NodejsRuntime API
        ▼
  android/lib  (AAR)
        │
        │  JNI  (node_bridge.cpp)
        ▼
  libnode.so  (Node.js v24, cross-compiled for Android)
        │
        │  require('mobile_bridge')  [linked native module]
        ▼
  Your Node.js code
```

## Quick Start

### 1. Build `libnode.so`

```bash
# Requires Android NDK r27.1+
./scripts/android-build.sh ~/Android/Sdk/ndk/27.1.12297006 arm64
./scripts/android-build.sh ~/Android/Sdk/ndk/27.1.12297006 arm
./scripts/android-build.sh ~/Android/Sdk/ndk/27.1.12297006 x86_64
./scripts/copy-outputs.sh
```

### 2. Add the AAR to your Android app

```gradle
// settings.gradle
includeBuild('../nodejs-mobile/android')

// app/build.gradle
implementation 'com.nodejs.mobile:android-bridge:24.14.0'
```

### 3. Start Node.js

```kotlin
val runtime = NodejsRuntime(this)

runtime.on("pong") { msg ->
    Log.d("App", "Node said: $msg")
}

runtime.start("nodejs-project/main.js")   // path inside assets/
runtime.send("ping", """{"hello": "world"}""")
```

### 4. Node.js code (`assets/nodejs-project/main.js`)

```js
const bridge = require('@nodejs-mobile/bridge');

bridge.on('ping', (msg) => {
  bridge.send('pong', JSON.stringify({ echo: msg, node: process.version }));
});
```

## Communication

| Direction          | API                                       |
|--------------------|-------------------------------------------|
| Android → Node.js  | `runtime.send(channel, message)`          |
| Node.js → Android  | `bridge.send(channel, message)`           |
| Android listens    | `runtime.on(channel) { msg -> ... }`      |
| Node.js listens    | `bridge.on(channel, (msg) => { ... })`    |

HTTP/WebSocket also works — Node.js runs a real server, Android connects to `127.0.0.1:<port>`.

## Supported ABIs

| ABI          | Status         |
|--------------|----------------|
| arm64-v8a    | ✅ Primary      |
| armeabi-v7a  | ✅ Supported    |
| x86_64       | ✅ Emulator     |
| x86          | Planned         |

## Project Structure

```
nodejs-mobile/
├── nodejs-src/        Node.js v24.14.0 source (git clone)
├── patches/android/   Android-specific patches
├── scripts/           Build + copy scripts
├── android/
│   ├── lib/           AAR library (Kotlin + JNI)
│   └── sample/        Sample app
├── npm-bridge/        @nodejs-mobile/bridge npm package
└── ios/               (Phase 2)
```

## iOS

iOS support (XCFramework + Swift API) is planned as Phase 2. The bridge API
(`@nodejs-mobile/bridge`) is designed to be identical on both platforms.

## Requirements

- Android NDK r27.1+
- Android API 24+ (Android 7.0)
- AGP 8.5+, Kotlin 2.0+
- Python 3.9+ (for build scripts)
- Node.js 24.x on host (for npm-bridge)
