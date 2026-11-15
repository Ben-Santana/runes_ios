// Replays the sets of an exported workout recording through RepCounter and compares with
// hand counts. Override a detector with `exerciseID=swing:<degrees>`.
//
//     swiftc -O -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift \
//       RunesIOS/Persistence/IdentityStore.swift RunesIOS/Mappings/MappingModel.swift RunesIOS/Mappings/AirGesture.swift RunesIOS/Mappings/MappingEngine.swift \
//       RunesIOS/Mappings/TriggerRules.swift RunesIOS/Mappings/CommandTrigger.swift Shared/ProfileIcon.swift Shared/SVGPath.swift Shared/LucideData.swift Shared/MuscleFigure.swift \
//       RunesIOS/Workouts/ExerciseCatalog.swift RunesIOS/Workouts/WorkoutModel.swift Tools/RepReplay.swift -o /private/tmp/rep-replay
//     /private/tmp/rep-replay <WorkoutData-export/folder> [benchPress=swing:8 ...]
import Foundation
@main
struct Replay {
    static func rows(_ url: URL) -> [[Substring]] {
        let text = try! String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) }
    }
    static func main() {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let ori = rows(folder.appendingPathComponent("orientation.csv")).map { r in (Double(r[0])!, r[3...6].map { Double($0)! }) }
        let gyro = rows(folder.appendingPathComponent("gyro.csv")).map { r in (Double(r[0])!, r[3...5].map { Double($0)! }) }
        let emgData = (try? Data(contentsOf: folder.appendingPathComponent("emg.bin"))) ?? Data()
        var sets: [(String, String, Double, Double, Int)] = []
        var cur: (String, String, Double)?
        var appReps = 0
        for r in rows(folder.appendingPathComponent("events.csv")) {
            let t = Double(r[0])!, kind = r[1], detail = r[2...].joined(separator: ",")
            if kind == "set_start" {
                let ex = String(detail.split(separator: " ")[0].dropFirst("exercise=".count))
                let label = detail.components(separatedBy: " target=")[0].components(separatedBy: " ").dropFirst().joined(separator: " ")
                cur = (ex, label, t); appReps = 0
            } else if kind == "rep" { appReps += 1 }
            else if kind == "command", detail.hasPrefix("repeatLast counting"), let c = cur { cur = (c.0, c.1, t); appReps = 0 }
            else if kind == "set_logged", let c = cur {
                if t - c.2 > 5 { sets.append((c.0, c.1, c.2, t, appReps)) }
                cur = nil
            }
        }
        let n = emgData.count / 280
        let useEMG = ProcessInfo.processInfo.environment["NOEMG"] == nil
        var overrides: [String: Exercise.Signal] = [:]
        for arg in CommandLine.arguments.dropFirst(2) {
            let parts = arg.split(separator: "="), spec = parts[1].split(separator: ":")
            overrides[String(parts[0])] = spec[0] == "swing" ? .swing(degrees: Double(spec[1])!) : nil
        }
        let truth: [String: Int] = ["benchPress Set 1 of 3": 10, "benchPress Set 3 of 3": 10, "pecDeck Set 1 of 3": 10, "pecDeck Set 2 of 3": 9,
            "cableFly Set 2 of 6": 10, "cableFly Set 3 of 6": 11, "cableFly Set 4 of 6": 10, "cableFly Set 5 of 6": 10,
            "tricepPushdown Set 1 of 3": 11, "tricepPushdown Set 2 of 3": 11, "tricepPushdown Set 3 of 3": 11, "lateralRaise Set 1 of 3": 11,
            "seatedCableRow Set 1 of 3": 10, "seatedCableRow Set 2 of 3": 10, "seatedCableRow Set 3 of 3": 10,
            "latPulldown Set 1 of 3": 10, "latPulldown Set 2 of 3": 10, "hammerCurl Set 1 of 3": 10, "hammerCurl Set 2 of 3": 10, "hammerCurl Set 3 of 3": 10]
        for (id, label, t0, t1, app) in sets {
            guard var ex = Exercise.byID[id] else { continue }
            if let o = overrides[id] { ex.signal = o }
            var counter = RepCounter(exercise: ex)
            var times: [Double] = []
            var oi = ori.firstIndex { $0.0 >= t0 } ?? ori.count, gi = gyro.firstIndex { $0.0 >= t0 } ?? gyro.count
            var ei: Int
            // binary search emg start
            var lo = 0, hi = n
            while lo < hi { let m = (lo + hi) / 2; let tm = emgData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: m * 280, as: Double.self) }; if tm < t0 { lo = m + 1 } else { hi = m } }
            ei = lo
            while true {
                let to = oi < ori.count ? ori[oi].0 : .infinity, tg = gi < gyro.count ? gyro[gi].0 : .infinity
                let te = ei < n ? emgData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: ei * 280, as: Double.self) } : .infinity
                let t = min(to, tg, te)
                if t > t1 { break }
                var rep = false
                if t == to { rep = counter.orientation(ori[oi].1, at: t); oi += 1 }
                else if t == tg { rep = counter.gyroscope(gyro[gi].1, at: t); gi += 1 }
                else {
                    let values: [UInt16] = emgData.withUnsafeBytes { raw in (0..<128).map { raw.loadUnaligned(fromByteOffset: ei * 280 + 24 + 2 * $0, as: UInt16.self) } }
                    if useEMG { counter.emg(values, at: t) }
                    ei += 1
                }
                if rep { times.append(t - t0) }
            }
            let detector = ex.signal.map { String(describing: $0) } ?? "none"
            let t = truth["\(id) \(label)"].map(String.init) ?? "?"
            print(String(format: "%-16@ %-14@ truth=%2@ app=%2d live=%2d settled=%2d  %@  [%@]", id as NSString, label as NSString, t as NSString, app, times.count, counter.settled, detector as NSString,
                         times.map { String(format: "%.1f", $0) }.joined(separator: " ") as NSString))
        }
    }
}
