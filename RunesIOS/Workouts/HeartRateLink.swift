import CoreBluetooth
import Foundation

/// Reads heart rate from a wearable that shares it the standard Bluetooth way: watches and
/// bands in their heart rate sharing mode, and chest straps. It is separate from the band's
/// own connection and touches Bluetooth only once the person asks to link a wearable.
/// Everything here runs on the main queue. Readings are never logged.
final class HeartRateLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let service = CBUUID(string: "180D")
    private static let measurement = CBUUID(string: "2A37")

    var onState: ((HeartLinkState) -> Void)?
    /// The sensors found so far, in the order they turned up.
    var onSensors: (([HeartSensor]) -> Void)?
    var onBeats: ((Int) -> Void)?

    private var central: CBCentralManager?
    private var searching = false
    private var sensors: [HeartSensor] = []
    private var found: [UUID: CBPeripheral] = [:]
    private var followed: UUID?
    private var peripheral: CBPeripheral?

    /// Looks for wearables sharing heart rate nearby, for the person to pick one.
    func search() {
        searching = true; sensors = []; found = [:]
        onSensors?([])
        apply()
    }

    func stopSearch() {
        guard searching else { return }
        searching = false
        apply()
    }

    /// Reads from the linked wearable until `stop`. It connects whenever the wearable comes
    /// into range and starts sharing, and again after a drop.
    func follow(_ id: String) {
        guard let id = UUID(uuidString: id), id != followed else { return }
        release()
        followed = id
        apply()
    }

    func stop() {
        guard followed != nil else { return }
        release()
        followed = nil
        apply()
    }

    private func release() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
    }

    private func apply() {
        guard searching || followed != nil else {
            central?.stopScan()
            onState?(.idle)
            return
        }
        guard let central else {
            // The state arrives in a moment and this runs again.
            self.central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            return
        }
        switch central.state {
        case .poweredOn: break
        case .unknown, .resetting: return
        default: onState?(.unavailable); return
        }
        if let followed, peripheral == nil, let known = central.retrievePeripherals(withIdentifiers: [followed]).first ?? found[followed] {
            connect(known)
        }
        if searching {
            // A wearable another app is already reading does not advertise, so ask for those too.
            for connected in central.retrieveConnectedPeripherals(withServices: [Self.service]) { note(connected, name: nil) }
        }
        if searching || (followed != nil && peripheral == nil) {
            central.scanForPeripherals(withServices: [Self.service])
        } else {
            central.stopScan()
        }
        if searching { onState?(.searching) } else if peripheral?.state != .connected { onState?(.waiting) }
    }

    private func connect(_ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        // No time limit: the system connects when the wearable shows up.
        central?.connect(target)
    }

    private func note(_ sensor: CBPeripheral, name: String?) {
        found[sensor.identifier] = sensor
        let id = sensor.identifier.uuidString
        guard searching, !sensors.contains(where: { $0.id == id }) else { return }
        sensors.append(HeartSensor(id: id, name: sensor.name ?? name ?? "Heart rate sensor"))
        onSensors?(sensors)
    }

    // MARK: Bluetooth

    func centralManagerDidUpdateState(_ central: CBCentralManager) { apply() }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        note(peripheral, name: advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        if peripheral.identifier == followed, self.peripheral == nil {
            connect(peripheral)
            if !searching { central.stopScan() }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == followed else { return central.cancelPeripheralConnection(peripheral) }
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { retry(peripheral) }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { retry(peripheral) }

    private func retry(_ dropped: CBPeripheral) {
        guard dropped.identifier == followed, central?.state == .poweredOn else { return }
        if !searching { onState?(.waiting) }
        connect(dropped)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.service {
            peripheral.discoverCharacteristics([Self.measurement], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.measurement {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == followed, characteristic.uuid == Self.measurement,
              let beats = characteristic.value.flatMap(HeartRateReading.beats) else { return }
        if !searching { onState?(.live) }
        onBeats?(beats)
    }
}
