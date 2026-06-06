package struct TokenProjection: Equatable {
    package enum View: Equatable {
        case normalized
        case userConfigured
    }

    package enum Scope: Equatable {
        case selection
        case workspace
        case export
    }

    package enum Source: Equatable {
        case activeLive
        case virtualRecomputed
        case immutableSnapshot
    }

    package enum Basis: Equatable {
        case componentEstimate
        case exactRenderedPayload
    }

    package struct Provenance: Equatable {
        package let view: View
        package let scope: Scope
        package let source: Source
        package let basis: Basis

        package init(view: View, scope: Scope, source: Source, basis: Basis) {
            self.view = view
            self.scope = scope
            self.source = source
            self.basis = basis
        }
    }

    /// Optional presence is semantic: `nil` is unavailable/omitted and zero is a known value.
    /// `filesContent` and `codemaps` subdivide `files` and are not added to `total`.
    package struct Components: Equatable {
        package let files: Int?
        package let prompt: Int?
        package let fileTree: Int?
        package let meta: Int?
        package let git: Int?
        package let other: Int?
        package let filesContent: Int?
        package let codemaps: Int?

        package init(
            files: Int? = nil,
            prompt: Int? = nil,
            fileTree: Int? = nil,
            meta: Int? = nil,
            git: Int? = nil,
            other: Int? = nil,
            filesContent: Int? = nil,
            codemaps: Int? = nil
        ) {
            self.files = files
            self.prompt = prompt
            self.fileTree = fileTree
            self.meta = meta
            self.git = git
            self.other = other
            self.filesContent = filesContent
            self.codemaps = codemaps
        }
    }

    package let provenance: Provenance
    package let components: Components
    package let total: Int

    package init(provenance: Provenance, components: Components, total: Int) {
        self.provenance = provenance
        self.components = components
        self.total = total
    }
}
