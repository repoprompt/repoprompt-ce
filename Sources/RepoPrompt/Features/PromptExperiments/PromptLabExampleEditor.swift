#if DEBUG
    import SwiftUI

    /// Plain fields for a frozen example; JSON is never required to define a text task.
    struct PromptLabExampleEditor: View {
        @Binding var example: PromptLabExampleDraft
        let onRemove: () -> Void
        @State private var newVariable = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Use", selection: $example.split) {
                        ForEach(PromptSuiteSplit.allCases, id: \.self) { Text($0.labDisplayName).tag($0) }
                    }
                    Button(role: .destructive, action: onRemove) { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove example")
                }
                if let payload = example.payload {
                    DisclosureGroup("Program example fields") {
                        ForEach(payload.keys.sorted().filter { !["id", "split", "expectedOutput", "expected_output", "variables"].contains($0) }, id: \.self) { name in
                            PromptLabJSONValueEditor(name: name, value: Binding(
                                get: { example.payload?[name] ?? .null },
                                set: { example.payload?[name] = $0 }
                            ))
                        }
                    }
                } else {
                    TextField("Example request", text: $example.input, axis: .vertical).lineLimit(2 ... 8)
                }
                DisclosureGroup("Reference answer or acceptance checks (optional)") {
                    TextEditor(text: $example.reference).font(.caption.monospaced()).frame(minHeight: 70, maxHeight: 150)
                    Text("Used only to evaluate the result. This reference is never included in the model's task input.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                DisclosureGroup("Prompt variables (\(example.variables.count))") {
                    ForEach(example.variables.keys.sorted(), id: \.self) { name in
                        HStack(alignment: .top) {
                            Text("{{\(name)}}").font(.caption.monospaced()).frame(width: 110, alignment: .leading)
                            TextField("Value", text: Binding(
                                get: { example.variables[name] ?? "" },
                                set: { example.variables[name] = $0 }
                            ), axis: .vertical).lineLimit(1 ... 5)
                            Button { example.variables.removeValue(forKey: name) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove variable \(name)")
                        }
                    }
                    HStack {
                        TextField("Variable name", text: $newVariable)
                        Button("Add variable") {
                            let name = newVariable.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            if example.variables[name] == nil { example.variables[name] = "" }
                            newVariable = ""
                        }.disabled(newVariable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let context = example.context, !context.files.isEmpty {
                    DisclosureGroup("Frozen context (\(context.files.count) files)") {
                        ForEach(Array(context.files.enumerated()), id: \.offset) { index, file in
                            DisclosureGroup(file.path) {
                                TextEditor(text: contextContent(at: index))
                                    .font(.caption.monospaced()).frame(minHeight: 80, maxHeight: 180)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }

        private func contextContent(at index: Int) -> Binding<String> {
            Binding(
                get: {
                    guard let context = example.context, context.files.indices.contains(index) else { return "" }
                    return context.files[index].content
                },
                set: { content in
                    guard let context = example.context, context.files.indices.contains(index) else { return }
                    var files = context.files
                    files[index] = PromptSuiteContextFile(path: files[index].path, content: content)
                    example.context = PromptSuiteCaseContext(fileTree: context.fileTree, files: files)
                }
            )
        }
    }

    /// A small field editor for opaque application datasets. Nested values retain their
    /// types; users need not rewrite their examples as JSON to change an input.
    private struct PromptLabJSONValueEditor: View {
        let name: String
        @Binding var value: PromptExperimentExampleValue

        var body: some View {
            switch value {
            case .null:
                LabeledContent(name, value: "null").font(.caption)
            case .boolean:
                Toggle(name, isOn: Binding(
                    get: { if case let .boolean(flag) = value { flag } else { false } },
                    set: { value = .boolean($0) }
                ))
            case .number:
                TextField(name, value: Binding(
                    get: { if case let .number(number) = value { number } else { 0 } },
                    set: { value = .number($0) }
                ), format: .number)
            case .string:
                TextField(name, text: Binding(
                    get: { if case let .string(text) = value { text } else { "" } },
                    set: { value = .string($0) }
                ), axis: .vertical).lineLimit(1 ... 8)
            case let .array(values):
                DisclosureGroup("\(name) (\(values.count) items)") {
                    ForEach(values.indices, id: \.self) { index in
                        PromptLabJSONValueEditor(name: "Item \(index + 1)", value: Binding(
                            get: { if case let .array(items) = value, items.indices.contains(index) { items[index] } else { .null } },
                            set: { updated in
                                guard case var .array(items) = value, items.indices.contains(index) else { return }
                                items[index] = updated
                                value = .array(items)
                            }
                        ))
                    }
                }
            case let .object(values):
                DisclosureGroup(name) {
                    ForEach(values.keys.sorted(), id: \.self) { key in
                        PromptLabJSONValueEditor(name: key, value: Binding(
                            get: { if case let .object(fields) = value { fields[key] ?? .null } else { .null } },
                            set: { updated in
                                guard case var .object(fields) = value else { return }
                                fields[key] = updated
                                value = .object(fields)
                            }
                        ))
                    }
                }
            }
        }
    }
#endif
