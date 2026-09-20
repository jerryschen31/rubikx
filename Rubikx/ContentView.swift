import SwiftUI

struct ContentView: View {
    @State private var model = CubeModel()
    @State private var debug = TouchDebug()

    var body: some View {
        ZStack {
            CubeView(model: model, debug: debug)
                .ignoresSafeArea()

            #if DEBUG
            Text(debug.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
            #endif

            VStack {
                if model.justSolved {
                    Label("Solved", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                HStack(spacing: 12) {
                    Button("Scramble", systemImage: "shuffle", action: model.scramble)
                    Button("Undo", systemImage: "arrow.uturn.backward", action: model.undo)
                        .disabled(!model.canUndo)
                    Button("Reset", systemImage: "arrow.counterclockwise", action: model.reset)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding()
            .animation(.spring(duration: 0.4), value: model.justSolved)
        }
        #if DEBUG
        .task {
            // Lets the simulator exercise turn animations without touch input.
            if ProcessInfo.processInfo.arguments.contains("-scrambleOnLaunch") {
                try? await Task.sleep(for: .seconds(1))
                model.scramble()
            }
        }
        #endif
    }
}

struct CubeView: UIViewRepresentable {
    let model: CubeModel
    let debug: TouchDebug

    func makeUIView(context: Context) -> CubeARView {
        CubeARView(model: model, debug: debug)
    }

    func updateUIView(_ view: CubeARView, context: Context) {}
}
