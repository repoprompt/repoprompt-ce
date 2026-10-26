//
//  Buttons.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-10-30.
//

import RepoPromptInstrumentation
import SwiftUI

struct TrashButton: View {
    let action: () -> Void
    @State private var isHovered: Bool = false
    @State private var showingConfirmation: Bool = false

    var body: some View {
        Button(action: {
            showingConfirmation = true
        }) {
            ZStack {
                Rectangle()
                    .fill(isHovered ? Color.red.opacity(0.1) : Color.clear)

                Image(systemName: "trash")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundColor(isHovered ? .red : .gray)
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(PlainButtonStyle())
        .cornerRadius(12)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("Clear Chat")
        .popover(isPresented: $showingConfirmation, arrowEdge: .leading) {
            VStack(spacing: 8) {
                Text("Clear the entire chat?")
                    .font(.headline)
                    .padding(.top, 8)

                Text("This action cannot be undone.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Button("Cancel") {
                        showingConfirmation = false
                    }
                    .buttonStyle(.bordered)

                    Button("Clear") {
                        showingConfirmation = false
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal)
            .frame(width: 200)
        }
    }
}

struct SendOrResendButton: View {
    let inputText: String
    let hasMessages: Bool
    let sendWhenEmpty: Bool
    let sendTooltip: String
    let foregroundColor: Color
    let sendAction: () -> Void
    let resendAction: () -> Void

    init(
        inputText: String,
        hasMessages: Bool,
        sendWhenEmpty: Bool = false,
        sendTooltip: String = "Send Message",
        foregroundColor: Color = .accentColor,
        sendAction: @escaping () -> Void,
        resendAction: @escaping () -> Void
    ) {
        self.inputText = inputText
        self.hasMessages = hasMessages
        self.sendWhenEmpty = sendWhenEmpty
        self.sendTooltip = sendTooltip
        self.foregroundColor = foregroundColor
        self.sendAction = sendAction
        self.resendAction = resendAction
    }

    @State private var isHovered = false

    var body: some View {
        Button(action: {
            if inputText.isEmpty && hasMessages {
                resendAction()
            } else if !inputText.isEmpty || sendWhenEmpty {
                sendAction()
            }
        }) {
            ZStack {
                Rectangle()
                    .fill(isHovered && isEnabled ? Color.secondary.opacity(0.1) : Color.clear)

                Image(systemName: inputText.isEmpty && hasMessages ? "arrow.clockwise" : "paperplane")
                    .foregroundColor(isEnabled ? foregroundColor : .gray)
                    .font(.system(size: 20))
                    .frame(width: 24, height: 24)
            }
            .frame(width: 40, height: 40)
        }
        .cornerRadius(20)
        .buttonStyle(PlainButtonStyle())
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering && isEnabled
            }
        }
        .hoverTooltip(inputText.isEmpty && hasMessages ? "Resend Last Message" : sendTooltip)
    }

    private var isEnabled: Bool {
        !inputText.isEmpty || hasMessages || sendWhenEmpty
    }
}

enum CancelButtonSource: String {
    case chatInput
    case agentInput
    case unknown
}

struct CancelButton: View {
    @Environment(\.agentModePerfRecorder) private var perfRecorder
    let source: CancelButtonSource
    let action: () -> Void
    @State private var isHovered = false
    #if DEBUG
        @State private var visibleStartMS: Double?
    #endif

    init(source: CancelButtonSource = .unknown, action: @escaping () -> Void) {
        self.source = source
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Rectangle()
                    .fill(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
                    .frame(width: 40, height: 40)

                LoadingIndicatorWithStop(isHovered: isHovered, source: source)
                    .frame(width: 24, height: 24)
            }
        }
        .cornerRadius(20)
        .buttonStyle(PlainButtonStyle())
        .onAppear(perform: recordAppear)
        .onDisappear(perform: recordDisappear)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .hoverTooltip("Cancel AI Response")
    }

    private func recordAppear() {
        #if DEBUG
            visibleStartMS = perfRecorder.timestampMSIfEnabled()
            let sourceName = source.rawValue
            perfRecorder.increment(perfRecorder.counterKey("cancelButton.visible.appear", source: sourceName))
            perfRecorder.event("cancelButton.visible.appear", fields: ["source": sourceName])
        #endif
    }

    private func recordDisappear() {
        #if DEBUG
            let sourceName = source.rawValue
            perfRecorder.increment(perfRecorder.counterKey("cancelButton.visible.disappear", source: sourceName))
            perfRecorder.durationEvent(
                "cancelButton.visibleDuration",
                startMS: visibleStartMS,
                fields: ["source": sourceName]
            )
            visibleStartMS = nil
        #endif
    }
}
