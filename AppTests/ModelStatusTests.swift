import XCTest
@testable import TypoBouncer

final class ModelStatusTests: XCTestCase {
    func testEveryKnownAvailabilityReasonHasItsOwnStatus() {
        XCTAssertEqual(ModelStatus(availability: .available), .ready)
        XCTAssertEqual(ModelStatus(availability: .unavailable(.deviceNotEligible)), .deviceNotEligible)
        XCTAssertEqual(ModelStatus(availability: .unavailable(.appleIntelligenceNotEnabled)), .intelligenceDisabled)
        XCTAssertEqual(ModelStatus(availability: .unavailable(.modelNotReady)), .modelNotReady)
    }
}
