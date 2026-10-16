import Foundation

package protocol FriendlyErrorRepresentable: Error {
    var friendlyErrorString: String { get }
}
