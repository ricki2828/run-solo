package app.runsolo.platform

import android.content.Context
import app.runsolo.ble.BleHolder

class BleApiImpl(private val context: Context) : BleApi {
    private val client get() = BleHolder.client(context)

    override fun bleScan(callback: (Result<List<BleDevice>>) -> Unit) {
        client.scan { r ->
            callback(r.map { found -> found.map { BleDevice(address = it.address, name = it.name) } })
        }
    }

    override fun blePair(address: String) = client.pair(address)

    override fun bleForget() = client.forget()

    override fun bleStatus(): BleStatus = BleStatus(
        connected = client.connected,
        address = client.savedAddress,
        name = client.deviceName,
        lastHr = client.lastHr?.toLong(),
        adapterOn = client.adapterOn,
    )
}
