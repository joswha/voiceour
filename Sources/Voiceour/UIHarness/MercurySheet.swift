// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
#if UI_HARNESS

    import AppKit
    import CoreGraphics
    import Foundation
    import ImageIO
    import UniformTypeIdentifiers
    import VoiceCore

    /// A bench for the recording island's mercury body, rendered straight through the
    /// production rasterizer with no window, no SwiftUI and no session.
    ///
    /// The scene catalog can only ever pin one frame of one state at a time, and driving
    /// the real app to look at the body is slow, non-reproducible and only ever shows the
    /// state the app happens to be in. This mode renders every state, every ground, every
    /// world and a strip of consecutive frames into a handful of contact sheets, so the
    /// look can be judged and iterated on directly.
    ///
    /// It writes no goldens and gates nothing. It is a debugging instrument.
    @MainActor
    enum MercurySheet {
        static func run(_ request: UIHarnessRequest) -> Bool {
            let directory = request.outputDirectory.appendingPathComponent("mercury", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                fputs("mercury-sheet: cannot create \(directory.path): \(error)\n", stderr)
                return false
            }

            let calibration = MercuryCalibration.shared
            var written: [String] = []
            for sheet in [
                states(), motion(), outcomeMotion(), worlds(), adaptations(),
                comparison(), candidateMotion(), candidateWorlds(),
                roomSweep(), selectedRoomWorlds(), chromaSweep(),
            ] {
                guard let image = compose(sheet) else {
                    fputs("mercury-sheet: \(sheet.name) produced no image\n", stderr)
                    return false
                }
                let url = directory.appendingPathComponent("\(sheet.name).png")
                guard write(image, to: url) else {
                    fputs("mercury-sheet: cannot write \(url.path)\n", stderr)
                    return false
                }
                written.append(url.lastPathComponent)
            }

            print(
                "mercury-sheet: drive=\(format(calibration.gains.drive))"
                    + " snake=\(format(calibration.gains.snake))"
                    + " prominence=\(format(calibration.crestProminence))pt"
                    + " mirror=\(format(calibration.mirrorCorrelation))"
            )
            for world in MercuryWorld.allCases {
                print("mercury-sheet: \(world.rawValue) \(contrastReport(world: world))")
            }
            print("mercury-sheet: wrote \(written.joined(separator: ", ")) in \(directory.path)")
            return true
        }

        // MARK: - Sheets

        private static func states() -> Sheet {
            Sheet(
                name: "states",
                columns: Ground.allCases.map(\.title),
                rows: Pose.allCases.map { pose in
                    // One body, four grounds: the ground is a composite, not a re-render.
                    let image = body(pose: pose)
                    return Row(
                        title: pose.title,
                        cells: Ground.allCases.map { Cell(ground: $0, body: image) }
                    )
                }
            )
        }

        /// Consecutive frames of the speaking body, so the travelling crest train and the
        /// specular sweep are visible as motion rather than inferred from one still.
        private static func motion() -> Sheet {
            let frames = 8
            let stride = 9
            let state = State(pose: .speaking, world: .roomOfTen, seed: MercuryMetrics.defaultSeed)
            let session = Session(state: state)
            var rows: [Row] = []
            for frame in 0..<frames {
                session.advance(steps: frame == 0 ? 600 : stride)
                let image = session.render(appearance: .standard)
                rows.append(
                    Row(
                        title: frame == 0 ? "settled" : "+\(frame * stride) steps",
                        cells: [Ground.dark, .light].map { Cell(ground: $0, body: image) }
                    )
                )
            }
            return Sheet(name: "motion", columns: ["dark", "light"], rows: rows)
        }

        /// Transition frames for the two outcome poses with one-shot impulses. The settled
        /// state sheet cannot witness these because its deterministic reset starts after
        /// the gesture has already latched.
        private static func outcomeMotion() -> Sheet {
            let seed = MercuryMetrics.defaultSeed
            let gains = MercuryCalibration.shared.gains
            let room = MercuryEnvironment(world: .roomOfTen, seed: seed)
            let response = MercuryCalibration.shared.displayResponse(
                for: room,
                bodySeed: seed
            )
            let rasterizer = MercuryRasterizer()
            return Sheet(
                name: "outcome-motion",
                columns: ["before", "+2 steps", "+8 steps", "+20 steps"],
                rows: [Pose.lurch, .collapse].map { pose in
                    let transition = pose.drive
                    var neutralPose = transition.pose
                    neutralPose.gesture = nil
                    let neutral = MercurySimulation.Drive(
                        pose: neutralPose,
                        samples: transition.samples,
                        reduceMotion: true
                    )
                    let simulation = MercurySimulation(seed: seed, gains: gains)
                    simulation.reset(to: neutral)
                    var previousStep = 0
                    let cells = [0, 2, 8, 20].map { step in
                        if step > previousStep {
                            simulation.advance(
                                steps: step - previousStep,
                                drive: transition
                            )
                            previousStep = step
                        }
                        let field = MercuryField(
                            geometry: simulation.geometry,
                            lateralOffset: transition.pose.lateralOffset
                        )
                        return Cell(
                            ground: .dark,
                            body: rasterizer.image(
                                field: field,
                                environment: room,
                                response: response,
                                appearance: .standard,
                                scale: MercuryMetrics.rasterScale
                            )
                        )
                    }
                    return Row(title: pose.title, cells: cells)
                }
            )
        }

        /// Four rooms per world at the speaking pose: the per-session variety a reader
        /// actually sees, and the check that no room is a black hole or a white blob.
        private static func worlds() -> Sheet {
            let seeds: [UInt64] = [
                MercuryMetrics.defaultSeed, 0x1d3a_7f21_9c4e_b806, 0xa07b_5514_ee92_3fd1, 0x6c19_e83d_402f_a75b,
            ]
            return Sheet(
                name: "worlds",
                columns: seeds.enumerated().map { "room \($0.offset)" },
                rows: MercuryWorld.allCases.map { world in
                    Row(
                        title: world.displayName,
                        cells: seeds.map { seed in
                            Cell(
                                ground: .dark,
                                body: body(pose: .speaking, world: world, seed: seed)
                            )
                        }
                    )
                }
            )
        }

        private static func adaptations() -> Sheet {
            let variants: [(String, MercuryAppearance)] = [
                ("standard", .standard),
                ("increase contrast", MercuryAppearance(increasedContrast: true)),
            ]
            return Sheet(
                name: "adaptations",
                columns: Ground.allCases.map(\.title),
                rows: variants.map { variant in
                    let image = body(pose: .speaking, appearance: variant.1)
                    return Row(
                        title: variant.0,
                        cells: Ground.allCases.map { Cell(ground: $0, body: image) }
                    )
                }
            )
        }

        /// Shipping and candidate from the same simulation state and room.
        private static func comparison() -> Sheet {
            Sheet(
                name: "comparison",
                columns: ["shipping / dark", "candidate / dark", "shipping / light", "candidate / light"],
                rows: Pose.allCases.map { pose in
                    let session = Session(
                        state: State(pose: pose, world: .roomOfTen, seed: MercuryMetrics.defaultSeed)
                    )
                    session.advance(steps: 600)
                    let shipping = session.render(appearance: .standard)
                    let candidate = session.renderPrototype()
                    return Row(
                        title: pose.title,
                        cells: [
                            Cell(ground: .dark, body: shipping),
                            Cell(ground: .dark, body: candidate),
                            Cell(ground: .light, body: shipping),
                            Cell(ground: .light, body: candidate),
                        ]
                    )
                }
            )
        }

        private static func candidateMotion() -> Sheet {
            let session = Session(
                state: State(
                    pose: .speaking,
                    world: .roomOfTen,
                    seed: MercuryMetrics.defaultSeed
                )
            )
            var rows: [Row] = []
            for frame in 0..<8 {
                session.advance(steps: frame == 0 ? 600 : 9)
                rows.append(
                    Row(
                        title: frame == 0 ? "settled" : "+\(frame * 9) steps",
                        cells: [
                            Cell(ground: .dark, body: session.render(appearance: .standard)),
                            Cell(ground: .dark, body: session.renderPrototype()),
                        ]
                    )
                )
            }
            return Sheet(
                name: "candidate-motion",
                columns: ["shipping", "candidate"],
                rows: rows
            )
        }

        private static func candidateWorlds() -> Sheet {
            let seeds: [UInt64] = [
                MercuryMetrics.defaultSeed,
                0x1d3a_7f21_9c4e_b806,
                0xa07b_5514_ee92_3fd1,
                0x6c19_e83d_402f_a75b,
            ]
            var shipping: [Cell] = []
            var candidate: [Cell] = []
            for seed in seeds {
                let session = Session(
                    state: State(pose: .speaking, world: .roomOfTen, seed: seed)
                )
                session.advance(steps: 600)
                shipping.append(Cell(ground: .dark, body: session.render(appearance: .standard)))
                candidate.append(Cell(ground: .dark, body: session.renderPrototype()))
            }
            return Sheet(
                name: "candidate-worlds",
                columns: seeds.indices.map { "room \($0)" },
                rows: [
                    Row(title: "shipping", cells: shipping),
                    Row(title: "candidate", cells: candidate),
                ]
            )
        }

        /// Material search over room statistics, all rendered through the fixed candidate
        /// crown and display response. Each cell pools the same two live poses for its
        /// exposure solve and renders the same speaking body/seed.
        private static func roomSweep() -> Sheet {
            let seed = MercuryMetrics.defaultSeed
            let gains = MercuryCalibration.shared.gains
            let meterFields = Session.meterFields(seed: seed, gains: gains)
            let speakingDrive = Pose.speaking.drive
            let simulation = MercurySimulation(seed: seed, gains: gains)
            simulation.reset(to: speakingDrive)
            simulation.advance(steps: 600, drive: speakingDrive)
            let field = MercuryField(
                geometry: simulation.geometry,
                lateralOffset: speakingDrive.pose.lateralOffset
            )
            let rasterizer = MercuryPrototypeRasterizer()
            let sharpnesses: [(Double, Double)] = [(12, 180), (20, 600), (40, 1200)]
            let sourceCounts = [16, 32, 48]
            let bounceFractions = [0.04, 0.10]
            let intensitySpreads = [0.55, 0.85]
            var rows: [Row] = []
            for sourceCount in sourceCounts {
                for intensitySpread in intensitySpreads {
                    var cells: [Cell] = []
                    for sharpness in sharpnesses {
                        for bounce in bounceFractions {
                            let parameters = MercuryPrototypeRoom.Parameters(
                                sourceCount: sourceCount,
                                minimumSharpness: sharpness.0,
                                maximumSharpness: sharpness.1,
                                intensitySpread: intensitySpread,
                                bounceFraction: bounce
                            )
                            let room = MercuryPrototypeRoom(seed: seed, parameters: parameters)
                            let response = rasterizer.response(
                                fields: meterFields,
                                environment: room,
                                scale: MercuryMetrics.rasterScale
                            )
                            cells.append(
                                Cell(
                                    ground: .dark,
                                    body: response.flatMap {
                                        rasterizer.image(
                                            field: field,
                                            environment: room,
                                            response: $0,
                                            scale: MercuryMetrics.rasterScale
                                        )
                                    }
                                )
                            )
                        }
                    }
                    rows.append(
                        Row(
                            title: "M\(sourceCount) σ\(format(intensitySpread))",
                            cells: cells
                        )
                    )
                }
            }
            let columns = sharpnesses.flatMap { sharpness in
                bounceFractions.map {
                    "λ\(Int(sharpness.0))-\(Int(sharpness.1)) b\(format($0))"
                }
            }
            return Sheet(name: "room-sweep", columns: columns, rows: rows)
        }

        private static func selectedRoomWorlds() -> Sheet {
            let seeds: [UInt64] = [
                MercuryMetrics.defaultSeed,
                0x1d3a_7f21_9c4e_b806,
                0xa07b_5514_ee92_3fd1,
                0x6c19_e83d_402f_a75b,
                0xf24d_0b6a_9137_5ce8,
                0x3e85_c9f0_71ab_2d64,
                0xc913_a745_6e82_b0df,
                0x74be_21d8_f0c6_395a,
            ]
            let scalar = selectedRoomParameters(chroma: 0)
            let chromatic = selectedRoomParameters(chroma: 0.07)
            return Sheet(
                name: "selected-room-worlds",
                columns: seeds.indices.map { "room \($0)" },
                rows: [
                    selectedRoomRow(title: "scalar", parameters: scalar, seeds: seeds),
                    selectedRoomRow(title: "subtle chroma", parameters: chromatic, seeds: seeds),
                ]
            )
        }

        private static func selectedRoomRow(
            title: String,
            parameters: MercuryPrototypeRoom.Parameters,
            seeds: [UInt64]
        ) -> Row {
            let gains = MercuryCalibration.shared.gains
            let rasterizer = MercuryPrototypeRasterizer()
            return Row(
                title: title,
                cells: seeds.map { seed in
                    let room = MercuryPrototypeRoom(seed: seed, parameters: parameters)
                    let fields = Session.meterFields(seed: seed, gains: gains)
                    let response = rasterizer.response(
                        fields: fields,
                        environment: room,
                        scale: MercuryMetrics.rasterScale
                    )
                    return Cell(
                        ground: .dark,
                        body: response.flatMap {
                            rasterizer.image(
                                field: fields[1],
                                environment: room,
                                response: $0,
                                scale: MercuryMetrics.rasterScale
                            )
                        }
                    )
                }
            )
        }

        private static func selectedRoomParameters(
            chroma: Double
        ) -> MercuryPrototypeRoom.Parameters {
            MercuryPrototypeRoom.Parameters(
                sourceCount: 32,
                minimumSharpness: 20,
                maximumSharpness: 600,
                intensitySpread: 0.55,
                bounceFraction: 0.30,
                chromaStrength: chroma
            )
        }

        private static func chromaSweep() -> Sheet {
            let seeds: [UInt64] = [
                MercuryMetrics.defaultSeed,
                0x1d3a_7f21_9c4e_b806,
                0xa07b_5514_ee92_3fd1,
                0x6c19_e83d_402f_a75b,
            ]
            let strengths = [0.0, 0.06, 0.10, 0.14]
            let gains = MercuryCalibration.shared.gains
            let rasterizer = MercuryPrototypeRasterizer()
            return Sheet(
                name: "chroma-sweep",
                columns: strengths.map { "chroma \(format($0))" },
                rows: seeds.enumerated().map { roomIndex, seed in
                    let fields = Session.meterFields(seed: seed, gains: gains)
                    return Row(
                        title: "room \(roomIndex)",
                        cells: strengths.map { strength in
                            let room = MercuryPrototypeRoom(
                                seed: seed,
                                parameters: selectedRoomParameters(chroma: strength)
                            )
                            let response = rasterizer.response(
                                fields: fields,
                                environment: room,
                                scale: MercuryMetrics.rasterScale
                            )
                            return Cell(
                                ground: .dark,
                                body: response.flatMap {
                                    rasterizer.image(
                                        field: fields[1],
                                        environment: room,
                                        response: $0,
                                        scale: MercuryMetrics.rasterScale
                                    )
                                }
                            )
                        }
                    )
                }
            )
        }

        // MARK: - Rendering one body

        private static func body(
            pose: Pose,
            world: MercuryWorld = .roomOfTen,
            seed: UInt64 = MercuryMetrics.defaultSeed,
            appearance: MercuryAppearance = .standard
        ) -> CGImage? {
            let session = Session(state: State(pose: pose, world: world, seed: seed))
            session.advance(steps: 600)
            return session.render(appearance: appearance)
        }

        /// What the body's pixels actually span, over four rooms of one world.
        ///
        /// The look question this bench exists for is "does it read as metal", and metal
        /// is a *spread*: bright where the reflection catches a source, near-black where it
        /// does not. A median on its own cannot tell a mercury ridge from a grey lozenge,
        /// and neither can an eye that has been staring at both.
        private static func contrastReport(world: MercuryWorld) -> String {
            let seeds: [UInt64] = [
                MercuryMetrics.defaultSeed, 0x1d3a_7f21_9c4e_b806, 0xa07b_5514_ee92_3fd1, 0x6c19_e83d_402f_a75b,
            ]
            var spans: [String] = []
            for seed in seeds {
                let session = Session(state: State(pose: .speaking, world: world, seed: seed))
                session.advance(steps: 600)
                let values = session.luminance().sorted()
                guard values.count > 20 else { continue }
                spans.append(
                    "p5=\(format(values[values.count / 20]))"
                        + " p50=\(format(values[values.count / 2]))"
                        + " p95=\(format(values[values.count * 19 / 20]))"
                )
            }
            return spans.joined(separator: " | ")
        }

        private struct State {
            var pose: Pose
            var world: MercuryWorld
            var seed: UInt64
        }

        /// One body plus the room it reflects, advanced together exactly as the engine
        /// advances them.
        @MainActor
        private final class Session {
            private let simulation: MercurySimulation
            private let environment: MercuryEnvironment
            private let shippingResponse: MercuryDisplayResponse
            private let rasterizer = MercuryRasterizer()
            private let prototypeRasterizer: MercuryPrototypeRasterizer
            private let prototypeResponse: MercuryDisplayResponse?
            private let drive: MercurySimulation.Drive
            private var started = false

            init(state: State) {
                let calibration = MercuryCalibration.shared
                let gains = calibration.gains
                simulation = MercurySimulation(seed: state.seed, gains: gains)
                let generatedRoom = MercuryEnvironment(
                    world: state.world,
                    seed: state.seed
                )
                environment = generatedRoom
                shippingResponse = calibration.displayResponse(
                    for: generatedRoom,
                    bodySeed: state.seed
                )
                drive = state.pose.drive
                let prototype = MercuryPrototypeRasterizer()
                prototypeRasterizer = prototype
                prototypeResponse = prototype.response(
                    fields: Self.meterFields(seed: state.seed, gains: gains),
                    environment: generatedRoom,
                    scale: MercuryMetrics.rasterScale
                )
            }

            func advance(steps: Int) {
                if !started {
                    simulation.reset(to: drive)
                    started = true
                }
                simulation.advance(steps: steps, drive: drive)
                environment.advance(steps: steps, frozen: drive.reduceMotion)
            }

            func render(appearance: MercuryAppearance) -> CGImage? {
                rasterizer.image(
                    field: field,
                    environment: environment,
                    response: shippingResponse,
                    appearance: appearance,
                    scale: MercuryMetrics.rasterScale
                )
            }

            func renderPrototype() -> CGImage? {
                guard let prototypeResponse else { return nil }
                return prototypeRasterizer.image(
                    field: field,
                    environment: environment,
                    response: prototypeResponse,
                    scale: MercuryMetrics.rasterScale
                )
            }

            /// Display luminance of every in-body pixel, through the shipping shading path.
            func luminance() -> [Double] {
                rasterizer.sampleSceneRadiance(
                    field: field,
                    environment: environment,
                    scale: MercuryMetrics.rasterScale
                ).map { sample in
                    MercuryDisplayResponse.luminance(
                        shippingResponse.map(
                            SIMD3(
                                Double(sample.x),
                                Double(sample.y),
                                Double(sample.z)
                            )
                        )
                    )
                }
            }

            func prototypeLuminance() -> [Double] {
                guard let prototypeResponse else { return [] }
                return prototypeRasterizer.luminance(
                    field: field,
                    environment: environment,
                    response: prototypeResponse,
                    scale: MercuryMetrics.rasterScale
                )
            }

            private var field: MercuryField {
                MercuryField(
                    geometry: simulation.geometry,
                    lateralOffset: drive.pose.lateralOffset
                )
            }

            static func meterFields(
                seed: UInt64,
                gains: MercuryGains
            ) -> [MercuryField] {
                [Pose.listening, .speaking].map { pose in
                    let drive = pose.drive
                    let simulation = MercurySimulation(seed: seed, gains: gains)
                    simulation.reset(to: drive)
                    simulation.advance(steps: 600, drive: drive)
                    return MercuryField(
                        geometry: simulation.geometry,
                        lateralOffset: drive.pose.lateralOffset
                    )
                }
            }
        }

        // MARK: - States the bench covers

        @MainActor
        private enum Pose: CaseIterable {
            case warming
            case listening
            case speaking
            case processing
            case gathered
            case lurch
            case collapse

            var title: String {
                switch self {
                case .warming: return "warming"
                case .listening: return "listening"
                case .speaking: return "speaking"
                case .processing: return "processing"
                case .gathered: return "copied"
                case .lurch: return "paste failed"
                case .collapse: return "error"
                }
            }

            /// Built from the production ladder, never from copied numbers.
            var drive: MercurySimulation.Drive {
                let model = RecordingOverlayModel()
                switch self {
                case .warming:
                    model.update(.recording)
                    feed(model, Self.speech)
                case .listening:
                    model.update(.recording)
                    model.updateCaptureLive(true)
                    feed(model, Self.quiet)
                case .speaking:
                    model.update(.recording)
                    model.updateCaptureLive(true)
                    feed(model, Self.speech)
                case .processing:
                    model.update(.transcribing)
                case .gathered:
                    latch(model, .copiedOnly(reason: "target_terminal"))
                case .lurch:
                    latch(model, .insertFailed(reason: "no focused element"))
                case .collapse:
                    latch(model, .error(.inferenceFailed))
                }
                return MercurySimulation.Drive(
                    pose: MercuryPose.target(for: model),
                    samples: model.samples,
                    reduceMotion: false
                )
            }

            private func feed(_ model: RecordingOverlayModel, _ levels: [Float]) {
                for level in levels { model.record(level) }
            }

            private func latch(_ model: RecordingOverlayModel, _ state: SessionState) {
                model.update(state)
                if let outcome = RecordingOverlayOutcome(state: state) {
                    model.present(outcome)
                }
            }

            static let speech: [Float] = [0.08, 0.19, 0.34, 0.52, 0.71, 0.88, 0.64, 0.41, 0.27, 0.15, 0.46]
            static let quiet: [Float] = [0.0, 0.02, 0.01, 0.03, 0.0, 0.04, 0.02, 0.0, 0.01, 0.05, 0.02]
        }

        /// What the island is floating over. The body is transparent mercury, so what it
        /// is composited against is half of whether it reads.
        private enum Ground: CaseIterable {
            case dark
            case light
            case mid
            case text

            var title: String {
                switch self {
                case .dark: return "near-black"
                case .light: return "near-white"
                case .mid: return "mid-grey"
                case .text: return "dense text"
                }
            }

            func fill(_ context: CGContext, rect: CGRect) {
                switch self {
                case .dark:
                    context.setFillColor(gray: 0.075, alpha: 1)
                    context.fill(rect)
                case .light:
                    context.setFillColor(gray: 0.95, alpha: 1)
                    context.fill(rect)
                case .mid:
                    context.setFillColor(gray: 0.45, alpha: 1)
                    context.fill(rect)
                case .text:
                    context.setFillColor(gray: 0.11, alpha: 1)
                    context.fill(rect)
                    drawText(context, rect: rect)
                }
            }

            /// A stand-in for the editor and terminal windows the island actually floats
            /// over: high-frequency light-on-dark detail, which is the hardest ground for
            /// a silhouette to survive.
            private func drawText(_ context: CGContext, rect: CGRect) {
                let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor(white: 0.62, alpha: 1),
                ]
                let line = String(repeating: "let mercury = field.value(at: point) ", count: 6)
                let graphics = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                var vertical = rect.maxY - 11
                while vertical > rect.minY {
                    NSAttributedString(string: line, attributes: attributes)
                        .draw(at: CGPoint(x: rect.minX + 4, y: vertical))
                    vertical -= 11
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        // MARK: - Layout

        private struct Cell {
            var ground: Ground
            var body: CGImage?
        }

        private struct Row {
            var title: String
            var cells: [Cell]
        }

        private struct Sheet {
            var name: String
            var columns: [String]
            var rows: [Row]
        }

        private static let labelWidth: CGFloat = 110
        private static let headerHeight: CGFloat = 18
        private static let cellSize = CGSize(width: 200, height: 56)
        private static let scale: CGFloat = 2

        private static func compose(_ sheet: Sheet) -> CGImage? {
            let width = labelWidth + cellSize.width * CGFloat(sheet.columns.count)
            let height = headerHeight + cellSize.height * CGFloat(sheet.rows.count)
            guard
                let context = CGContext(
                    data: nil,
                    width: Int(width * scale),
                    height: Int(height * scale),
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(gray: 0.02, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            for (column, title) in sheet.columns.enumerated() {
                label(
                    title,
                    in: context,
                    at: CGPoint(x: labelWidth + CGFloat(column) * cellSize.width + 8, y: height - 13),
                    white: 0.75
                )
            }

            for (index, row) in sheet.rows.enumerated() {
                let top = height - headerHeight - CGFloat(index + 1) * cellSize.height
                label(
                    row.title,
                    in: context,
                    at: CGPoint(x: 8, y: top + cellSize.height / 2 - 5),
                    white: 0.62
                )
                for (column, cell) in row.cells.enumerated() {
                    let frame = CGRect(
                        x: labelWidth + CGFloat(column) * cellSize.width,
                        y: top,
                        width: cellSize.width,
                        height: cellSize.height
                    )
                    context.saveGState()
                    context.clip(to: frame.insetBy(dx: 1, dy: 1))
                    cell.ground.fill(context, rect: frame)
                    if let body = cell.body {
                        let island = CGRect(
                            x: frame.midX - RecordingOverlayMetrics.islandSize.width / 2,
                            y: frame.midY - RecordingOverlayMetrics.islandSize.height / 2,
                            width: RecordingOverlayMetrics.islandSize.width,
                            height: RecordingOverlayMetrics.islandSize.height
                        )
                        context.draw(body, in: island)
                    }
                    context.restoreGState()
                }
            }
            return context.makeImage()
        }

        private static func label(_ text: String, in context: CGContext, at point: CGPoint, white: CGFloat) {
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: NSColor(white: white, alpha: 1),
                ]
            ).draw(at: point)
            NSGraphicsContext.restoreGraphicsState()
        }

        private static func write(_ image: CGImage, to url: URL) -> Bool {
            guard
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                )
            else { return false }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination)
        }

        private static func format(_ value: Double) -> String {
            String(format: "%.4f", value)
        }
    }

#endif
