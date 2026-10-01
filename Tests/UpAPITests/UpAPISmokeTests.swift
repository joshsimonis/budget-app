import Testing
@testable import UpAPI

@Test func baseURLIsUp() {
    #expect(UpAPI.baseURLString == "https://api.up.com.au/api/v1")
}
