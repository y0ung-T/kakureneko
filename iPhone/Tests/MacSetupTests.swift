// Onboarding's "Your Mac" step (Model/MacSetup.swift): the question, both answers, and "Connected" from anywhere.

import KakurenekoCloud
import Foundation
import Testing

@Suite("Mac setup")
struct MacSetupTests {
    @Test func withoutAMacItAsksThenFollowsTheAnswer() {
        #expect(MacSetupScreen.of(answer: nil, macs: []) == .question)
        #expect(MacSetupScreen.of(answer: .notYet, macs: []) == .getMacApp)
        #expect(MacSetupScreen.of(answer: .onMac, macs: []) == .waiting)
    }

    @Test func aMacThatSharesItsStatusConnectsFromEveryScreen() {
        let studio = Fixture.status("mac-1", name: "Studio", updatedAt: Fixture.t0)
        for answer: MacSetupAnswer? in [nil, .notYet, .onMac] {
            #expect(MacSetupScreen.of(answer: answer, macs: [studio]) == .connected(macName: "Studio", macID: "mac-1"),
                    "\(String(describing: answer))")
        }
    }

    @Test func severalMacsConnectTheFirstByName() {
        let macs = [Fixture.status("b", name: "Air", updatedAt: Fixture.t0), Fixture.status("a", name: "Studio", updatedAt: Fixture.t0)]
        #expect(MacSetupScreen.of(answer: nil, macs: macs) == .connected(macName: "Air", macID: "b"))
    }

    /// The iPhone quotes the Mac app's own labels (Sources/KakurenekoApp: onboarding and Settings → Notifications).
    @Test func theInstructionsQuoteTheMacApp() {
        #expect(MacSetupText.macButton == "Set up my iPhone")
        #expect(MacSetupText.macSetting == "Settings → Notifications → Send alerts to your iPhone")
    }

    @Test func theDownloadAddressReadsShort() {
        #expect(MacSetupText.display(URL(string: "https://kakureneko.com/")!) == "kakureneko.com")
        #expect(MacSetupText.display(URL(string: "https://www.kakureneko.com/")!) == "kakureneko.com")
        #expect(MacSetupText.display(URL(string: "https://example.org/kakureneko/")!) == "example.org/kakureneko")
    }

    @Test func helpWaitsLongEnoughForAnInstallToFinish() {
        #expect(MacSetupScreen.helpDelay >= .seconds(30) && MacSetupScreen.helpDelay <= .seconds(90))
    }
}
