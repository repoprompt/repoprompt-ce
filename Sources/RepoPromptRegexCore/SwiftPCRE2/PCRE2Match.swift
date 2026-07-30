package struct PCRE2Match: Sendable, Equatable {
	package let byteRange: Range<Int>
	package let captureByteRanges: [Range<Int>?]

	package init(byteRange: Range<Int>, captureByteRanges: [Range<Int>?]) {
		self.byteRange = byteRange
		self.captureByteRanges = captureByteRanges
	}
}
