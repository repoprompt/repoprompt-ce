import Foundation

protocol Greeter {
    func greet(name: String) -> String
}

struct FriendlyGreeter: Greeter {
    let prefix: String

    func greet(name: String) -> String {
        "\(prefix), \(name)"
    }
}

func makeGreeter(prefix: String) -> Greeter {
    FriendlyGreeter(prefix: prefix)
}
