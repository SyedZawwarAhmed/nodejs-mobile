cmake_minimum_required(VERSION 3.22.1)
project(nodejs_mobile_bridge CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── libnode (pre-built shared library) ──────────────────────────────────────
add_library(libnode SHARED IMPORTED)
set_target_properties(libnode PROPERTIES
    IMPORTED_LOCATION
    ${CMAKE_SOURCE_DIR}/jniLibs/${ANDROID_ABI}/libnode.so
)

# ── node_bridge (our JNI layer) ──────────────────────────────────────────────
add_library(node_bridge SHARED node_bridge.cpp)

target_include_directories(node_bridge PRIVATE
    ${CMAKE_SOURCE_DIR}/include          # V8 headers (v8.h, etc.)
    ${CMAKE_SOURCE_DIR}/include/node     # Node.js + libuv headers (node.h, uv.h, uv/*)
)

target_compile_options(node_bridge PRIVATE
    -fexceptions
    -frtti
    -Wall
    -Wno-unused-parameter
)

target_link_libraries(node_bridge
    libnode
    android
    log
)

# Copy libnode.so next to node_bridge.so so the dynamic linker finds it
# (Android loads from the same directory as the calling library)
add_custom_command(TARGET node_bridge POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_SOURCE_DIR}/jniLibs/${ANDROID_ABI}/libnode.so
        $<TARGET_FILE_DIR:node_bridge>/libnode.so
    COMMENT "Copying libnode.so alongside node_bridge.so"
)
