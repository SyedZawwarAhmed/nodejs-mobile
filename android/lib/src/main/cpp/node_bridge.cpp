/**
 * node_bridge.cpp — JNI bridge between Android (Kotlin/Java) and Node.js v24
 *
 * Architecture:
 *  - Node.js runs on a dedicated background thread (single instance per process)
 *  - A linked native module "mobile_bridge" is injected before user code starts
 *  - Messages flow via libuv async handles (thread-safe)
 *  - Android side calls nativeStart() and nativeSend(); Node.js side calls
 *    mobile_bridge.send() and registers with mobile_bridge.on()
 */

#include <jni.h>
#include <android/log.h>
#include <pthread.h>
#include <string>
#include <vector>
#include <functional>
#include <queue>
#include <mutex>

// Node.js embedding headers
#include "node/node.h"
#include "node/uv.h"
#include "node/v8.h"

#define LOG_TAG "NodejsMobile"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ─── Global state ────────────────────────────────────────────────────────────

static JavaVM* g_jvm = nullptr;
static jobject  g_runtime_obj = nullptr;  // NodejsRuntime instance (global ref)
static jmethodID g_on_message_method = nullptr;

static node::MultiIsolatePlatform* g_platform = nullptr;
static pthread_t g_node_thread;
static bool g_node_started = false;

// Thread-safe message queue: messages going INTO Node.js from Android
struct PendingMessage {
  std::string channel;
  std::string payload;
};
static std::queue<PendingMessage> g_incoming_queue;
static std::mutex g_queue_mutex;
static uv_async_t g_async_handle;  // wakes Node.js event loop

// The Node.js JS callback registered from JS: mobile_bridge.on(channel, fn)
static v8::Persistent<v8::Function> g_js_message_callback;
static v8::Isolate* g_isolate = nullptr;

// Script path passed from Java
static std::string g_script_path;

// ─── Forward declarations ─────────────────────────────────────────────────────

static void NodeThreadMain(void*);
static void OnAsyncMessage(uv_async_t* handle);
static void RegisterBridgeModule(v8::Local<v8::Object> exports,
                                  v8::Local<v8::Value> module,
                                  v8::Local<v8::Context> context,
                                  void* priv);

// ─── JNI: OnLoad ─────────────────────────────────────────────────────────────

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
  g_jvm = vm;
  return JNI_VERSION_1_6;
}

// ─── JNI: nativeStart ────────────────────────────────────────────────────────

extern "C" JNIEXPORT void JNICALL
Java_com_nodejs_mobile_NodejsRuntime_nativeStart(
    JNIEnv* env, jobject thiz, jstring script_path) {

  if (g_node_started) {
    LOGE("Node.js is already running. Only one instance per process is supported.");
    return;
  }
  g_node_started = true;

  // Store global reference to the Kotlin NodejsRuntime object so we can
  // invoke its onMessageFromNode() method from the Node thread.
  g_runtime_obj = env->NewGlobalRef(thiz);

  jclass clazz = env->GetObjectClass(thiz);
  g_on_message_method = env->GetMethodID(
      clazz, "onMessageFromNode",
      "(Ljava/lang/String;Ljava/lang/String;)V");

  const char* path = env->GetStringUTFChars(script_path, nullptr);
  g_script_path = path;
  env->ReleaseStringUTFChars(script_path, path);

  pthread_create(&g_node_thread, nullptr,
                 [](void* arg) -> void* { NodeThreadMain(arg); return nullptr; },
                 nullptr);
  pthread_detach(g_node_thread);
}

// ─── JNI: nativeSend ─────────────────────────────────────────────────────────

extern "C" JNIEXPORT void JNICALL
Java_com_nodejs_mobile_NodejsRuntime_nativeSend(
    JNIEnv* env, jobject /*thiz*/, jstring channel, jstring message) {

  if (!g_node_started) return;

  const char* ch  = env->GetStringUTFChars(channel, nullptr);
  const char* msg = env->GetStringUTFChars(message, nullptr);

  {
    std::lock_guard<std::mutex> lock(g_queue_mutex);
    g_incoming_queue.push({std::string(ch), std::string(msg)});
  }

  env->ReleaseStringUTFChars(channel, ch);
  env->ReleaseStringUTFChars(message, msg);

  // Wake up the Node.js event loop
  uv_async_send(&g_async_handle);
}

// ─── Node.js thread ──────────────────────────────────────────────────────────

static void NodeThreadMain(void*) {
  LOGI("Node.js thread starting...");

  std::vector<std::string> args = {"node", g_script_path};

  // Register our linked native module before Node.js starts.
  // Field order: nm_version, nm_flags, nm_dso_handle, nm_filename,
  //              nm_register_func, nm_context_register_func, nm_modname, nm_priv, nm_link
  static node::node_module bridge_module = {
      NODE_MODULE_VERSION,
      node::ModuleFlags::kLinked,
      nullptr,              // nm_dso_handle
      nullptr,              // nm_filename
      nullptr,              // nm_register_func (non-context-aware, unused)
      RegisterBridgeModule, // nm_context_register_func
      "mobile_bridge",      // nm_modname
      nullptr,              // nm_priv
      nullptr,              // nm_link
  };
  node_module_register(&bridge_module);

  // InitializeOncePerProcess initialises V8 (including platform) for us.
  auto init_result = node::InitializeOncePerProcess(args);
  if (init_result->exit_code() != 0) {
    LOGE("Node.js initialization failed: exit_code=%d", init_result->exit_code());
    return;
  }

  // Reuse the platform that Node.js created internally.
  g_platform = init_result->platform();

  std::vector<std::string> exec_args;
  std::vector<std::string> errors;
  auto isolate_setup = node::CommonEnvironmentSetup::Create(
      g_platform, &errors, args, exec_args);

  if (!isolate_setup) {
    for (auto& e : errors) LOGE("Setup error: %s", e.c_str());
    return;
  }

  // Async handle on the environment's event loop so Android can post messages.
  uv_async_init(isolate_setup->event_loop(), &g_async_handle, OnAsyncMessage);

  g_isolate = isolate_setup->isolate();

  {
    v8::Locker locker(g_isolate);
    v8::Isolate::Scope isolate_scope(g_isolate);
    v8::HandleScope handle_scope(g_isolate);
    v8::Context::Scope ctx_scope(isolate_setup->context());

    auto* env = isolate_setup->env();

    // Expose mobile_bridge via require('mobile_bridge').
    node::AddLinkedBinding(env, bridge_module);

    node::LoadEnvironment(env,
        // embedderRequire only allows built-in modules; use Module._load
        // to load the user script from the filesystem.
        "require('module')._load(process.argv[1], null, true);");

    node::SpinEventLoop(env).FromMaybe(1);
    node::Stop(env);
  }

  g_js_message_callback.Reset();
  node::TearDownOncePerProcess();

  LOGI("Node.js thread exiting.");
}

// ─── libuv async callback: drain incoming queue into Node.js ─────────────────

static void OnAsyncMessage(uv_async_t* /*handle*/) {
  if (!g_isolate) return;

  v8::Locker locker(g_isolate);
  v8::Isolate::Scope isolate_scope(g_isolate);
  v8::HandleScope handle_scope(g_isolate);
  auto ctx = g_isolate->GetCurrentContext();

  std::queue<PendingMessage> local;
  {
    std::lock_guard<std::mutex> lock(g_queue_mutex);
    std::swap(local, g_incoming_queue);
  }

  if (g_js_message_callback.IsEmpty()) return;
  auto cb = v8::Local<v8::Function>::New(g_isolate, g_js_message_callback);

  while (!local.empty()) {
    auto& m = local.front();
    v8::Local<v8::Value> args[2] = {
        v8::String::NewFromUtf8(g_isolate, m.channel.c_str()).ToLocalChecked(),
        v8::String::NewFromUtf8(g_isolate, m.payload.c_str()).ToLocalChecked(),
    };
    cb->Call(ctx, v8::Undefined(g_isolate), 2, args).IsEmpty();
    local.pop();
  }
}

// ─── Bridge native module: exposed as require('mobile_bridge') ───────────────

// mobile_bridge.send(channel, message)
// Called from Node.js JS code → fires JNI callback to Kotlin
static void BridgeSend(const v8::FunctionCallbackInfo<v8::Value>& args) {
  if (args.Length() < 2) return;
  v8::Isolate* isolate = args.GetIsolate();
  v8::String::Utf8Value channel(isolate, args[0]);
  v8::String::Utf8Value message(isolate, args[1]);

  JNIEnv* env = nullptr;
  bool attached = false;
  if (g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    g_jvm->AttachCurrentThread(&env, nullptr);
    attached = true;
  }

  jstring jchannel = env->NewStringUTF(*channel);
  jstring jmessage = env->NewStringUTF(*message);
  env->CallVoidMethod(g_runtime_obj, g_on_message_method, jchannel, jmessage);
  env->DeleteLocalRef(jchannel);
  env->DeleteLocalRef(jmessage);

  if (attached) g_jvm->DetachCurrentThread();
}

// mobile_bridge.setReceiver(fn)
// Called from Node.js to register the function that receives messages from Android
static void BridgeSetReceiver(const v8::FunctionCallbackInfo<v8::Value>& args) {
  if (args.Length() < 1 || !args[0]->IsFunction()) return;
  g_js_message_callback.Reset(args.GetIsolate(),
                               v8::Local<v8::Function>::Cast(args[0]));
}

static void RegisterBridgeModule(v8::Local<v8::Object> exports,
                                  v8::Local<v8::Value> /*module*/,
                                  v8::Local<v8::Context> context,
                                  void* /*priv*/) {
  v8::Isolate* isolate = context->GetIsolate();
  auto set = [&](const char* name, v8::FunctionCallback fn) {
    exports->Set(context,
        v8::String::NewFromUtf8(isolate, name).ToLocalChecked(),
        v8::Function::New(context, fn).ToLocalChecked()).Check();
  };
  set("send",        BridgeSend);
  set("setReceiver", BridgeSetReceiver);
}
