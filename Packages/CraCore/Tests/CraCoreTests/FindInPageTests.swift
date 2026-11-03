import CraCore
import Testing

struct FindInPageTests {
    @Test func countLabel() {
        #expect(FindInPage.countLabel(query: "cra", matches: 7, active: 2) == "2/7")
        #expect(FindInPage.countLabel(query: "cra", matches: 0, active: 3) == "0/0")
        // Before the page answers, and with the field empty: nothing.
        #expect(FindInPage.countLabel(query: "cra", matches: nil, active: 0) == nil)
        #expect(FindInPage.countLabel(query: "", matches: 4, active: 1) == nil)
    }
}
