import Foundation
public enum PCRE2Literal {
	/// Returns a PCRE2 pattern that matches `literal` exactly.
	///
	/// PCRE2's `\Q...\E` quoting is convenient but embedded `\E` terminates the
	/// quote, so every embedded terminator is rewritten as `\E\\E\Q`.
	public static func escapedPattern(for literal: String) -> String {
		if literal.isEmpty {
			return ""
		}
		return "\\Q" + literal.replacingOccurrences(of: "\\E", with: "\\E\\\\E\\Q") + "\\E"
	}
}
