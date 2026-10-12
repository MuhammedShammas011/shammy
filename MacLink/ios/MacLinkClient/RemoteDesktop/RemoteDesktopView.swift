// RemoteDesktopView.swift
// MacLink – iOS Client
// Live remote desktop screen: renders streamed Mac frames and converts touch
// gestures into remote control messages.

import SwiftUI
import UIKit

struct RemoteDesktopView: View {
    @EnvironmentObject var session: ClientSession
    @State private var currentFrame: UIImage? = nil
    @State private var showControls = true
    @State private var showKeyboard  = false
    @State private var controlMode: ControlMode = .trackpad
    @State private var keyboardText = ""

    enum ControlMode: String, CaseIterable {
        case trackpad = "Trackpad"
        case direct   = "Direct Touch"
        case scroll   = "Scroll"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // MARK: Desktop viewer
                DesktopView(
                    frame: currentFrame,
                    displayInfo: session.displayInfo,
                    controlMode: controlMode,
                    showKeyboard: $showKeyboard,
                    onTap: handleTap,
                    onLongPress: handleRightClick,
                    onDrag: handleDrag,
                    onScroll: handleScroll
                )

                // MARK: Overlay controls (shown/hidden by tap on toolbar)
                if showControls {
                    VStack {
                        topBar
                        Spacer()
                        bottomBar
                    }
                    .transition(.opacity)
                }
            }
        }
        .onReceive(session.framePublisher) { image in
            currentFrame = image
        }
        .ignoresSafeArea(edges: .bottom)
        .statusBarHidden()
        .sheet(isPresented: $showKeyboard) {
            KeyboardView(onDismiss: { showKeyboard = false })
                .environmentObject(session)
                .presentationDetents([.fraction(0.5)])
                .presentationDragIndicator(.visible)
        }
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
        }
    }

    // MARK: - Top bar

    var topBar: some View {
        HStack {
            // Connection quality
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .shadow(color: .green, radius: 3)
                Text("\(Int(session.currentFPS)) fps · \(Int(session.latencyMs))ms")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .cornerRadius(20)

            Spacer()

            Button {
                session.disconnect()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark")
                    Text("Disconnect")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.8))
                .cornerRadius(20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 54)   // status bar height
    }

    // MARK: - Bottom bar

    var bottomBar: some View {
        HStack(spacing: 16) {
            // Control mode picker
            Menu {
                ForEach(ControlMode.allCases, id: \.self) { mode in
                    Button(mode.rawValue) { controlMode = mode }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: controlModeIcon)
                    Text(controlMode.rawValue)
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .foregroundStyle(.white)
            }

            Spacer()

            // Keyboard toggle
            Button {
                showKeyboard.toggle()
            } label: {
                Image(systemName: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 34)    // home indicator
    }

    var controlModeIcon: String {
        switch controlMode {
        case .trackpad:  return "hand.point.up"
        case .direct:    return "cursorarrow.click"
        case .scroll:    return "scroll"
        }
    }

    // MARK: - Input handlers (forwarded from DesktopView)

    private func handleTap(normX: Double, normY: Double) {
        let down = ControlMessage(type: .mouseDown,
                                   payload: .mouseButton(MouseButtonPayload(
                                     button: .left, pressed: true, normX: normX, normY: normY)))
        let up = ControlMessage(type: .mouseUp,
                                 payload: .mouseButton(MouseButtonPayload(
                                   button: .left, pressed: false, normX: normX, normY: normY)))
        session.send(down)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.session.send(up) }
    }

    private func handleRightClick(normX: Double, normY: Double) {
        let down = ControlMessage(type: .mouseDown,
                                   payload: .mouseButton(MouseButtonPayload(
                                     button: .right, pressed: true, normX: normX, normY: normY)))
        let up = ControlMessage(type: .mouseUp,
                                 payload: .mouseButton(MouseButtonPayload(
                                   button: .right, pressed: false, normX: normX, normY: normY)))
        session.send(down)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.session.send(up) }
    }

    private func handleDrag(normX: Double, normY: Double) {
        let move = ControlMessage(type: .mouseMove,
                                   payload: .mouseMove(MouseMovePayload(normX: normX, normY: normY)))
        session.send(move)
    }

    private func handleScroll(deltaX: Double, deltaY: Double, normX: Double, normY: Double) {
        let scroll = ControlMessage(type: .mouseScroll,
                                     payload: .mouseScroll(MouseScrollPayload(
                                       deltaX: deltaX, deltaY: deltaY,
                                       normX: normX, normY: normY)))
        session.send(scroll)
    }
}

// MARK: - DesktopView (UIKit gesture bridge)

struct DesktopView: UIViewRepresentable {
    let frame: UIImage?
    let displayInfo: DisplayInfoPayload
    let controlMode: RemoteDesktopView.ControlMode
    @Binding var showKeyboard: Bool

    let onTap: (Double, Double) -> Void
    let onLongPress: (Double, Double) -> Void
    let onDrag: (Double, Double) -> Void
    let onScroll: (Double, Double, Double, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> DesktopUIView {
        let view = DesktopUIView()
        view.backgroundColor = .black
        view.contentMode = .scaleAspectFit

        // Tap
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        // Long press (right click)
        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                       action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        view.addGestureRecognizer(longPress)

        // Pan (drag / trackpad move)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        // Pinch / two-finger scroll
        let twoFingerPan = UIPanGestureRecognizer(target: context.coordinator,
                                                    action: #selector(Coordinator.handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(twoFingerPan)

        tap.require(toFail: longPress)
        pan.require(toFail: twoFingerPan)

        return view
    }

    func updateUIView(_ uiView: DesktopUIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.view = uiView
        if let frame {
            uiView.update(image: frame, displayInfo: displayInfo)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var parent: DesktopView
        weak var view: DesktopUIView?
        private var lastDragLocation: CGPoint = .zero
        private var dragVelocity: CGPoint = .zero

        init(_ parent: DesktopView) { self.parent = parent }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let norm = view.normalise(g.location(in: view))
            parent.onTap(norm.x, norm.y)
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let view else { return }
            let norm = view.normalise(g.location(in: view))
            parent.onLongPress(norm.x, norm.y)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view else { return }
            switch parent.controlMode {
            case .direct:
                let norm = view.normalise(g.location(in: view))
                if g.state == .began {
                    let down = ControlMessage(type: .mouseDown,
                                              payload: .mouseButton(MouseButtonPayload(
                                                button: .left, pressed: true,
                                                normX: norm.x, normY: norm.y)))
                    parent.onTap(norm.x, norm.y)
                    _ = down
                }
                parent.onDrag(norm.x, norm.y)
                if g.state == .ended || g.state == .cancelled {
                    let norm2 = view.normalise(g.location(in: view))
                    let up = ControlMessage(type: .mouseUp,
                                            payload: .mouseButton(MouseButtonPayload(
                                              button: .left, pressed: false,
                                              normX: norm2.x, normY: norm2.y)))
                    ClientSession.shared.send(up)
                }

            case .trackpad:
                // Trackpad mode: translate relative movement into mouse move
                let translation = g.translation(in: view)
                let bounds = view.imageRect
                let dx = translation.x / bounds.width
                let dy = translation.y / bounds.height
                if g.state == .changed {
                    // Get current cursor position (not tracked client-side; just send delta-based moves)
                    // Use centre as anchor – server accumulates position
                    parent.onDrag(0.5 + dx * 2, 0.5 + dy * 2)
                }

            case .scroll:
                let translation = g.translation(in: view)
                if g.state == .changed {
                    parent.onScroll(-translation.x * 0.5, -translation.y * 0.5,
                                     0.5, 0.5)
                    g.setTranslation(.zero, in: view)
                }
            }
        }

        @objc func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
            guard let view else { return }
            if g.state == .changed {
                let translation = g.translation(in: view)
                parent.onScroll(-translation.x * 2, -translation.y * 2, 0.5, 0.5)
                g.setTranslation(.zero, in: view)
            }
        }
    }
}

// MARK: - DesktopUIView

final class DesktopUIView: UIView {
    private let imageView = UIImageView()
    private var displayInfo: DisplayInfoPayload?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(image: UIImage, displayInfo: DisplayInfoPayload) {
        self.displayInfo = displayInfo
        imageView.image = image
    }

    /// The rect inside the view that actually contains the image (letterboxed).
    var imageRect: CGRect {
        guard let image = imageView.image else { return bounds }
        let viewSize = bounds.size
        let imgSize  = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return bounds }
        let scale = min(viewSize.width / imgSize.width, viewSize.height / imgSize.height)
        let scaledW = imgSize.width * scale
        let scaledH = imgSize.height * scale
        let x = (viewSize.width  - scaledW) / 2
        let y = (viewSize.height - scaledH) / 2
        return CGRect(x: x, y: y, width: scaledW, height: scaledH)
    }

    /// Convert a touch point in view coordinates to normalised [0,1] Mac display coordinates.
    func normalise(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let nx = max(0, min(1, (point.x - rect.minX) / rect.width))
        let ny = max(0, min(1, (point.y - rect.minY) / rect.height))
        return CGPoint(x: nx, y: ny)
    }
}
