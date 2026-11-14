// Isolated checks for workouts: the run's set flow, control gestures and rep counting.
//
//     swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift \
//       RunesIOS/Persistence/IdentityStore.swift RunesIOS/Mappings/MappingModel.swift RunesIOS/Mappings/AirGesture.swift RunesIOS/Mappings/MappingEngine.swift \
//       RunesIOS/Mappings/TriggerRules.swift RunesIOS/Mappings/CommandTrigger.swift Shared/ProfileIcon.swift Shared/SVGPath.swift Shared/LucideData.swift Shared/MuscleFigure.swift \
//       RunesIOS/Workouts/ExerciseCatalog.swift RunesIOS/Workouts/WorkoutModel.swift RunesIOS/Sounds/SoundLibrary.swift RunesIOS/Workouts/WorkoutSounds.swift \
//       Tests/WorkoutTests.swift -o /private/tmp/runes-workout-tests && /private/tmp/runes-workout-tests
import Foundation

@main
struct WorkoutTests {
    /// A quaternion turned `degrees` about the x axis.
    static func turn(_ degrees: Double) -> [Double] {
        let half = degrees * .pi / 360
        return [cos(half), sin(half), 0, 0]
    }

    /// Holds `pose` for a second, then swings `count` times by `degrees` end to end about `axis`
    /// (in the band's frame) at 100 samples a second. Returns the reps counted.
    static func swings(_ counter: inout RepCounter, count: Int, degrees: Double, period: Double, axis: [Double], after pose: [Double]) -> Int {
        let n = sqrt(axis.reduce(0) { $0 + $1 * $1 }), u = axis.map { $0 / n }
        var reps = 0, t = 0.0
        for _ in 0..<100 { t += 0.01; if counter.orientation(pose, at: t) { reps += 1 } }
        for i in 0...Int(Double(count) * period * 100) {
            let half = (degrees / 2 - degrees / 2 * cos(2 * .pi * Double(i) / (period * 100))) * .pi / 360
            let (w, x, y, z) = (cos(half), sin(half) * u[0], sin(half) * u[1], sin(half) * u[2])
            let (pw, px, py, pz) = (pose[0], pose[1], pose[2], pose[3])
            let q = [pw * w - px * x - py * y - pz * z, pw * x + px * w + py * z - pz * y,
                     pw * y - px * z + py * w + pz * x, pw * z + px * y - py * x + pz * w]
            t += 0.01; if counter.orientation(q, at: t) { reps += 1 }
        }
        return reps
    }

    static func main() {
        // Set flow: wait → count → log → next set waits again.
        let plan = WorkoutPlan(name: "Arms", items: [WorkoutItem(exercise: .bicepCurl, sets: 2, reps: 10),
                                                    WorkoutItem(exercise: .lateralRaise, sets: 1, reps: 8)])
        var run = WorkoutRun(plan: plan)
        precondition(run.slots.count == 3 && run.phase == .waiting)
        run.rep(); precondition(run.reps == 0, "Reps before the start gesture don't count")
        precondition(run.apply(.stop) == nil && run.phase == .waiting, "Stop does nothing while waiting")
        run.apply(.start); run.rep(); run.rep(); run.rep()
        let log = run.apply(.stop)
        precondition(log?.reps == 3 && log?.slot.set == 1, "Stop logs the set")
        precondition(run.phase == .waiting && run.current?.set == 2 && run.reps == 0, "Moves to set 2 and waits")
        precondition(run.next?.exercise == .lateralRaise)

        // Repeat last set inserts it again before the next one.
        run.apply(.repeatLast)
        precondition(run.current?.set == 1 && run.current?.isRepeat == true && run.slots.count == 4)
        run.apply(.start); run.rep(); run.apply(.stop)
        precondition(run.current?.set == 2 && run.logs.count == 2)

        // Repeat while counting restarts the count.
        run.apply(.start); run.rep(); run.rep(); run.apply(.repeatLast)
        precondition(run.phase == .counting && run.reps == 0, "Repeat restarts the current set")

        // Skip, while counting or waiting, moves on without logging.
        run.apply(.skip)
        precondition(run.logs.count == 2 && run.current?.exercise == .lateralRaise && run.phase == .waiting)
        run.apply(.skip)
        precondition(run.phase == .finished && run.current == nil, "Skipping the last set finishes")
        run.apply(.start); precondition(run.phase == .finished)
        run.apply(.repeatLast)
        precondition(run.phase == .waiting && run.current?.set == 1, "A finished workout can repeat its last set")

        // Controls: one gesture per command; reassigning swaps.
        var controls = WorkoutControls.standard
        precondition(controls.command(for: .doubleTapIndex) == .start)
        controls.set(.doubleTapMiddle, for: .start)
        precondition(controls.gesture(for: .start) == .doubleTapMiddle && controls.gesture(for: .stop) == .doubleTapIndex, "Swapped")
        var decoded = try! JSONDecoder().decode(WorkoutControls.self, from: JSONEncoder().encode(controls))
        precondition(decoded == controls, "Controls round-trip")
        // Settings saved when a command had one gesture still load.
        decoded = try! JSONDecoder().decode(WorkoutControls.self, from: Data(#"{"gestures":["start","hold-index","skip","swipe-up"]}"#.utf8))
        precondition(decoded.gesture(for: .start) == .holdIndex && decoded.gesture(for: .skip) == .swipeUp && decoded.trigger(for: .stop) == nil)

        // A command can take a combo. The engine Mappings uses decides when it was made.
        controls = .standard
        let hold = CommandTrigger(steps: [.holdMiddle, .swipeUp, .releaseMiddle].steps, intervalMs: 500)
        controls.setTrigger(hold, for: .skip)
        precondition(controls.trigger(for: .skip) == hold && controls.gesture(for: .skip) == nil && controls.command(for: .swipeRight) == nil)
        precondition(controls.reserved == [.doubleTapIndex, .tapIndex, .doubleTapMiddle, .tapMiddle, .swipeLeft, .holdMiddle, .releaseMiddle, .swipeUp])
        controls.setTrigger(hold, for: .repeatLast)
        precondition(controls.trigger(for: .repeatLast) == hold && controls.gesture(for: .skip) == .swipeLeft, "Taking a combo swaps too")
        precondition(try! JSONDecoder().decode(WorkoutControls.self, from: JSONEncoder().encode(controls)) == controls, "Combos round-trip")
        var engine = MappingEngine(mappings: controls.mappings)
        func made(_ events: [MappingEngine.Event]) -> [WorkoutCommand] {
            events.compactMap { if case .fire(let id, _) = $0 { controls.command(forMapping: id) } else { nil } }
        }
        precondition(made(engine.receive(.swipeLeft, at: 0)) == [.skip])
        precondition(made(engine.receive(.holdMiddle, at: 1) + engine.receive(.swipeUp, at: 5)).isEmpty, "Held, so no time limit")
        precondition(made(engine.receive(.releaseMiddle, at: 9)) == [.repeatLast])
        precondition(made(engine.receive(.doubleTapIndex, at: 10)) == [.start])
        // Rotation, movement and air steps work too.
        controls.setTrigger(CommandTrigger(steps: [ComboStep(.tapIndex), .rotation(.x)]), for: .start)
        precondition(controls.usesMotion && controls.reserved.contains(.rotation) && controls.mappings.count == 4)
        engine = MappingEngine(mappings: controls.mappings)
        precondition(made(engine.receive(.tapIndex, at: 20)).isEmpty)
        precondition(made(engine.receive(.rotation(.y, .left), at: 20.2)).isEmpty, "Another axis doesn't count")
        precondition(made(engine.receive(.rotation(.x, .left), at: 20.4)) == [.start], "Either way on X does")
        precondition(CommandTrigger(steps: [.rotation(.x), ComboStep(.tapIndex)]).isValid, "A combo may start with motion")
        precondition(!CommandTrigger(steps: [.rotation(.x)]).isValid, "but motion can't stand alone")
        precondition(!CommandTrigger(steps: [ComboStep(.tapIndex), ComboStep(.air)]).isValid, "An air step needs its shape")

        // Swing counting: out-and-back swings about any axis, from any start pose, 100 samples a second.
        for (axis, pose) in [([1.0, 0, 0], turn(0)), ([0, 1.0, 0], [0.5, 0.5, -0.5, 0.5]), ([0, 0.6, 0.8], [0.2, -0.9, 0.3, 0.24])] {
            var curl = RepCounter(exercise: .bicepCurl)
            let reps = swings(&curl, count: 8, degrees: 100, period: 2, axis: axis, after: pose)
            precondition(reps == 8, "Eight curls about \(axis) from any start, got \(reps)")
        }
        var row = RepCounter(exercise: Exercise.byID["seatedCableRow"]!)
        precondition(swings(&row, count: 10, degrees: 30, period: 2.5, axis: [0, 0, 1], after: turn(70)) == 10, "Ten rows, a short swing")
        var shiver = RepCounter(exercise: Exercise.byID["seatedCableRow"]!)
        precondition(swings(&shiver, count: 10, degrees: 8, period: 2, axis: [0, 0, 1], after: turn(0)) == 0, "Swings under the minimum don't count")
        var hurried = RepCounter(exercise: .bicepCurl)
        precondition(swings(&hurried, count: 20, degrees: 100, period: 0.5, axis: [1, 0, 0], after: turn(0)) <= 10, "Too soon after a rep")
        var normal = RepCounter(exercise: Exercise.byID["seatedCableRow"]!), gentle = RepCounter(exercise: Exercise.byID["seatedCableRow"]!, sensitivity: .high)
        precondition(swings(&normal, count: 10, degrees: 11.5, period: 2.5, axis: [0, 0, 1], after: turn(0)) == 0
                     && swings(&gentle, count: 10, degrees: 11.5, period: 2.5, axis: [0, 0, 1], after: turn(0)) >= 9,
                     "High sensitivity needs less movement")

        // Burst counting for punches, from the gyroscope.
        var punches = RepCounter(exercise: .punches)
        let samples: [[Double]] = [[10, 0, 0], [150, 120, 0], [20, 0, 0], [0, 200, 0], [190, 0, 0], [10, 10, 0]]
        let counted = samples.enumerated().filter { punches.gyroscope($1, at: Double($0) * 0.4) }.count
        precondition(counted == 2, "Two punches, got \(counted)")
        precondition(!punches.orientation(turn(90), at: 10), "Punches ignore orientation")

        // The feed only counts while a set is active.
        let feed = RepFeed()
        precondition(!feed.ingest(orientation: true, turn(0), at: 0))
        feed.count(.bicepCurl, sensitivity: .normal)
        let fed = (0..<600).filter { i in
            let angle = 50 - 50 * cos(2 * .pi * Double(i) / 200)
            return feed.ingest(orientation: true, turn(angle), at: Double(i) / 100)
        }.count
        precondition(fed == 3, "The feed counts three curls, got \(fed)")
        feed.count(nil, sensitivity: .normal)
        precondition(!feed.isCounting)

        // Exercises the band can't count log their target; timed ones log how long the set ran.
        let start = Date(timeIntervalSince1970: 1000)
        var mixed = WorkoutRun(plan: WorkoutPlan(name: "Mixed", items: [WorkoutItem(exercise: .benchPress, sets: 1, reps: 8, weight: 60),
                                                                         WorkoutItem(exercise: .plank, sets: 1, reps: 45)]), at: start)
        mixed.apply(.start, at: start); mixed.rep()
        let bench = mixed.apply(.stop, at: start.addingTimeInterval(30))
        precondition(bench?.reps == 8 && bench?.weight == 60, "Bench logs its target and weight, got \(String(describing: bench?.reps))")
        mixed.apply(.start, at: start.addingTimeInterval(60))
        let plank = mixed.apply(.stop, at: start.addingTimeInterval(112))
        precondition(plank?.reps == 52, "Plank logs 52 s, got \(String(describing: plank?.reps))")
        precondition(!RepFeed().isCounting)
        let feed2 = RepFeed(); feed2.count(.benchPress, sensitivity: .normal)
        precondition(!feed2.isCounting, "No counter for an exercise the band can't follow")

        // The catalog: unique ids, every exercise trains something, ids survive a round trip, unknown ids still decode.
        precondition(Set(Exercise.all.map(\.id)).count == Exercise.all.count, "Duplicate exercise id")
        precondition(Exercise.all.allSatisfy { !$0.primary.isEmpty })
        let item = try! JSONDecoder().decode(WorkoutItem.self, from: JSONEncoder().encode(WorkoutItem(exercise: .hammerCurl, sets: 2, reps: 9)))
        precondition(item.exercise == .hammerCurl && item.exercise.detectsReps && item.weight == nil)
        let unknown = try! JSONDecoder().decode([Exercise].self, from: Data(#"["somethingNew"]"#.utf8))
        precondition(unknown[0].id == "somethingNew" && !unknown[0].detectsReps)
        print("Exercise catalog: \(Exercise.all.count) exercises, \(Exercise.all.filter(\.detectsReps).count) counted by the band.")

        // Sound cues: start, each rep, the target, the set, then the workout instead of the last set.
        var cued = WorkoutRun(plan: WorkoutPlan(name: "Cues", items: [WorkoutItem(exercise: .bicepCurl, sets: 2, reps: 2)]))
        func step(_ command: WorkoutCommand) -> WorkoutCue? {
            let before = cued
            let logged = cued.apply(command)
            return WorkoutCue.after(command, from: before, to: cued, logged: logged)
        }
        precondition(step(.start) == .start)
        cued.rep(); precondition(WorkoutCue.afterRep(cued) == .rep)
        cued.rep(); precondition(WorkoutCue.afterRep(cued) == .target)
        cued.rep(); precondition(WorkoutCue.afterRep(cued) == .rep, "Reps past the target are reps")
        precondition(step(.repeatLast) == .start, "Restarting a set starts it again")
        precondition(step(.stop) == .setDone)
        precondition(step(.stop) == nil, "Stop while waiting does nothing")
        precondition(step(.start) == .start)
        precondition(step(.stop) == .workoutDone)
        precondition(step(.repeatLast) == nil)

        // Sound settings: defaults, a chosen None survives a round trip, older saves get defaults.
        var sounds = WorkoutSounds()
        precondition(sounds[.rep] == nil && sounds[.start] != nil, "Rep sound is opt-in")
        sounds[.setDone] = nil; sounds[.rep] = .tick; sounds.volume = 0.4
        precondition(try! JSONDecoder().decode(WorkoutSounds.self, from: JSONEncoder().encode(sounds)) == sounds)
        precondition(try! JSONDecoder().decode(WorkoutSounds.self, from: Data("{}".utf8)) == WorkoutSounds())

        print("Workout checks passed: set flow, repeat and skip, control gestures, swing and burst rep counting, sound cues.")
    }
}
