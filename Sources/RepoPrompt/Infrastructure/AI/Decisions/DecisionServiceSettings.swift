import Foundation

/// Redacted, registration-owned Settings content. Neither views nor this value can read a secret.
struct DecisionServiceSettingsPresentation: Equatable {
    enum NoticeEmphasis: Equatable {
        case information
        case warning
    }

    struct Notice: Equatable, Identifiable {
        let id: String
        let text: String
        let emphasis: NoticeEmphasis
    }

    enum DisclosureCategory: Equatable {
        case privacy
        case pricing
        case technical
    }

    struct DisclosureSection: Equatable, Identifiable {
        let id: String
        let category: DisclosureCategory
        let title: String
        let paragraphs: [String]
    }

    enum ProductStatus: Equatable {
        case beta
        case preview
        case deprecated
    }

    struct Capability: Equatable, Identifiable {
        let id: String
        let title: String
    }

    struct Link: Equatable, Identifiable {
        let title: String
        let url: URL
        let disclosureID: String?

        init(title: String, url: URL, disclosureID: String? = nil) {
            self.title = title
            self.url = url
            self.disclosureID = disclosureID
        }

        var id: URL {
            url
        }
    }

    let title: String
    let summary: String
    let notices: [Notice]
    let disclosures: [DisclosureSection]
    let productStatus: ProductStatus?
    let capabilities: [Capability]
    let secretFieldLabel: String?
    let supportedCredentialActions: [DecisionServiceSettingsCredentialActionKind]
    let links: [Link]

    func links(for disclosure: DisclosureSection, isLastDisclosure: Bool) -> [Link] {
        let assigned = links.filter { $0.disclosureID == disclosure.id }
        guard isLastDisclosure else { return assigned }

        let fallback = links.filter { link in
            guard let disclosureID = link.disclosureID else { return true }
            return !disclosures.contains { $0.id == disclosureID }
        }
        return assigned + fallback
    }
}

enum DecisionServiceSettingsCredentialActionKind: Equatable {
    case validateAndSaveSecret
    case revalidateStoredSecret
    case removeStoredSecret
}

enum DecisionServiceSettingsAction {
    case validateAndSaveSecret(String)
    case revalidateStoredSecret
    case removeStoredSecret

    var kind: DecisionServiceSettingsCredentialActionKind {
        switch self {
        case .validateAndSaveSecret: .validateAndSaveSecret
        case .revalidateStoredSecret: .revalidateStoredSecret
        case .removeStoredSecret: .removeStoredSecret
        }
    }
}

enum DecisionServiceSettingsActionResult: Equatable {
    case succeeded(String)
    case missingSecret(String)
    case superseded(String)
    case failed(String)
}
