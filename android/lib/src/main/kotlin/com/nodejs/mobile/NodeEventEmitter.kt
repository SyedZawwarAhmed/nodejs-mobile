package com.nodejs.mobile

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Thread-safe channel → listener registry.
 */
internal class NodeEventEmitter {

    private val listeners =
        ConcurrentHashMap<String, CopyOnWriteArrayList<(String) -> Unit>>()

    fun on(channel: String, listener: (String) -> Unit) {
        listeners.getOrPut(channel) { CopyOnWriteArrayList() }.add(listener)
    }

    fun off(channel: String) {
        listeners.remove(channel)
    }

    fun emit(channel: String, message: String) {
        listeners[channel]?.forEach { it(message) }
    }
}
