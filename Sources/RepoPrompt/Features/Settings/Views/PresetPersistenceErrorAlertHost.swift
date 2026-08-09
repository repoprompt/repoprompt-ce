import SwiftUI

struct PresetPersistenceErrorAlertHost: View {
    let message: String
    @Binding var isPresented: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert("Preset Save Failed", isPresented: $isPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message)
            }
    }
}
