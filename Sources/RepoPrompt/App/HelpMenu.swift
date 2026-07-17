import SwiftUI

struct HelpMenu: View {
    var body: some View {
        Group {
            Link(
                "What's New",
                destination: URL(string: "https://repoprompt.com/docs#s=changelog")!
            )

            Button("Setup Guide…") {
                NotificationCenter.default.post(name: .showAgentOnboardingWizard, object: nil)
            }

            Link(
                "Getting Started",
                destination: URL(string: "https://youtube.com/playlist?list=PLFg9suyZ1OnIKYyoCbAGBaFB-QOAk1nSq&si=hiUSja9eTRWeB26j")!
            )

            Link(
                "Documentation",
                destination: URL(string: "https://repoprompt.com/docs#s=getting-started")!
            )

            Link(
                "Repo Prompt",
                destination: URL(string: "https://repoprompt.com")!
            )

            Link(
                "Discord Community",
                destination: URL(string: "https://discord.gg/NtbFDAJPGM")!
            )
        }
    }
}
