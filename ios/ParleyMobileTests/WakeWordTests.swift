import Foundation
import Testing
@testable import ParleyMobile

struct WakeWordTests {
    @Test(arguments: [
        "Hey Parley",
        "hey parley",
        "HEY, PARLEY!",
        "Parley",
        "Parley, bist du da?",
        "Okay Parley",
        "Hallo Parley wie geht's",
        "Hé Parlé",            // diacritics
        "Hey Parlay",          // one edit away
        "Hey Parle",
        "Parly",
        "Barley",              // p/b confusion
        "Hey Partie",          // German recognizer's take
        "Hey Party",
        "hey partei",
        "Hey Paley",
        "Hey Bali",
        "Hey Par Lee",         // split in two
        "äh hey parley",
        "Ich wollte sagen hey Parley",
    ])
    func hears(_ transcript: String) {
        #expect(WakeWord.matches(transcript), "\(transcript)")
    }

    @Test(arguments: [
        "",
        "Hey",
        "Hey Siri",
        "Hallo zusammen",
        "Partei",              // lookalikes need the greeting
        "Ich gehe heute zur Party",
        "Paris",
        "Hey Paris",
        "Parlament",
        "das Parlament tagt",
        "parken",
        "Perle",
        "Harley",
        "Marley",
        "Hey Bob",
        "Charlie",
        "Er spielt Bali-Musik",
        "parallel",
    ])
    func ignores(_ transcript: String) {
        #expect(!WakeWord.matches(transcript), "\(transcript)")
    }

    @Test func tokens() {
        #expect(WakeWord.tokens("Hé, PARLÉ! 12 x") == ["he", "parle", "x"])
        #expect(WakeWord.tokens("—") == [])
    }

    @Test func distance() {
        #expect(WakeWord.distance("parley", "parley") == 0)
        #expect(WakeWord.distance("parle", "parley") == 1)
        #expect(WakeWord.distance("party", "parley") == 2)
        #expect(WakeWord.distance("", "abc") == 3)
        #expect(WakeWord.distance("abc", "") == 3)
        #expect(WakeWord.distance("kitten", "sitting") == 3)
    }
}
