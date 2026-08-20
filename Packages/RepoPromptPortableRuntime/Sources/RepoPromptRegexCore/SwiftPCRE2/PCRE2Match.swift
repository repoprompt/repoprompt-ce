public struct PCRE2Match: Sendable, Equatable {
	public let byteRange: Range<Int>
	public let captureByteRanges: [Range<Int>?]

	public init(byteRange: Range<Int>, captureByteRanges: [Range<Int>?]) {
		self.byteRange = byteRange
		self.captureByteRanges = captureByteRanges
	}
}
