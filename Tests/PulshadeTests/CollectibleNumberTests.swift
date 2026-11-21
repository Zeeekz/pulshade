import Testing
@testable import Pulshade
@testable import PulshadeShared

/// Which numbers are wanted: what the badges say, for the app, Admin and trades to agree on.
struct CollectibleNumberTests {
    @Test func lowNumbersComeFirst() {
        #expect(Collectible.rarity(of: 1, edition: 100) == .first)
        #expect(Collectible.rarity(of: 2, edition: 100) == .topTen)
        #expect(Collectible.rarity(of: 10, edition: 100) == .topTen)
        #expect(Collectible.rarity(of: 7, edition: 100) == .special(.lucky))
        #expect(Collectible.rarity(of: 12, edition: 100) == .topTwentyFive)
        #expect(Collectible.rarity(of: 25, edition: 100) == .topTwentyFive)
        #expect(Collectible.rarity(of: 26, edition: 100) == .common)
        #expect(Collectible.rarity(of: 100, edition: 100) == .special(.round), "a round last number counts as round")
        #expect(Collectible.rarity(of: 99, edition: 99) == .special(.repeated))
        #expect(Collectible.rarity(of: 98, edition: 98) == .last)
        #expect(Collectible.rarity(of: 1, edition: 1) == .first)
    }

    @Test func numbersWithAPatternAreSpecial() {
        for n: UInt32 in [11, 22, 33, 111, 222, 999, 4444] { #expect(Collectible.pattern(of: n) == .repeated, "\(n)") }
        for n: UInt32 in [77, 777, 7777] { #expect(Collectible.pattern(of: n) == .lucky, "\(n)") }
        for n: UInt32 in [123, 234, 789, 1234, 321, 987, 4321] { #expect(Collectible.pattern(of: n) == .run, "\(n)") }
        for n: UInt32 in [50, 100, 500, 1000, 5000, 10000] { #expect(Collectible.pattern(of: n) == .round, "\(n)") }
        for n: UInt32 in [12, 21, 69, 420, 200, 30, 40, 135, 1235, 101, 1001, 8] { #expect(Collectible.pattern(of: n) == nil, "\(n)") }
        #expect(Collectible.rarity(of: 12, edition: 1000) == .topTwentyFive, "two digits in a row are only a start")
        #expect(Collectible.rarity(of: 22, edition: 1000) == .special(.repeated), "a pattern beats the top 25")
    }

    @Test func everyBadgeHasAName() {
        let all: [Collectible.Rarity] = [.first, .topTen, .special(.lucky), .special(.repeated), .special(.run), .special(.round), .topTwentyFive, .last]
        #expect(all.allSatisfy { $0.name != nil })
        #expect(Collectible.Rarity.common.name == nil)
        #expect(Set(all.compactMap(\.name)).count == all.count)
    }

    @Test func theHatchScreenCelebratesEveryWantedNumberAndNoOther() {
        let all: [Collectible.Rarity] = [.first, .topTen, .special(.lucky), .special(.repeated), .special(.run), .special(.round), .topTwentyFive, .last]
        #expect(all.allSatisfy { HatchedSheet.flourish($0) != nil })
        #expect(HatchedSheet.flourish(.common) == nil)
    }
}
