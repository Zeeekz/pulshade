import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import Pulshade

/// One device whose main account and a persona are both in the same group (the phone knows each of them; they don't
/// know each other). Each must take part on its own and read the other.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct PersonaGroupTests {
    private func makeUser(_ name: String, shared: Bool) async throws -> AppModel {
        let model = testModel("pulshade-persona-group")
        model.sharedGroupsEnabled = shared
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func until(_ models: [AppModel], seconds: Double = 25, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models { await m.syncOnce() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test(arguments: [false, true])
    func aMainAccountAndItsPersonaInOneGroupReadEachOther(_ shared: Bool) async throws {
        let phone = try await makeUser("Phone", shared: shared)
        let laptop = try await makeUser("Laptop", shared: shared)
        defer { for m in [phone, laptop] { m.lock() } }
        let persona = try #require(laptop.createPersona(name: "Mask"))
        let main = try #require(phone.addContact(code: laptop.makeInviteCode(persona: .some(nil)), nickname: ""))
        let masked = try #require(phone.addContact(code: laptop.makeInviteCode(persona: .some(persona.id)), nickname: ""))
        await until([phone, laptop]) { laptop.data.contacts.filter { !$0.hidden }.count == 2 }
        // Each side hears from the other's apps once, so the phone knows what they can do.
        for fp in [main.fingerprint, masked.fingerprint] {
            let chat = phone.startConversation(kind: .direct, title: "", members: [fp])
            phone.send("hi", in: chat.id)
        }
        await until([phone, laptop]) { laptop.data.conversations.filter { $0.kind == .direct }.count == 2 }
        for chat in laptop.data.conversations where chat.kind == .direct { laptop.send("hey", in: chat.id) }
        await until([phone, laptop]) { phone.data.conversations.filter { $0.kind == .direct }.allSatisfy { $0.messages.count == 2 } }

        let group = phone.startConversation(kind: .group, title: "Both", members: [main.fingerprint, masked.fingerprint])
        #expect((group.shared != nil) == shared)
        await until([phone, laptop]) { laptop.data.conversations.filter { $0.kind == .group }.count == 2 }
        let copies = laptop.data.conversations.filter { $0.kind == .group }
        #expect(copies.count == 2, "one copy for the main account, one for the persona: \(copies.map(\.persona))")
        #expect(Set(copies.map(\.persona)) == [nil, persona.id])
        let mainCopy = try #require(copies.first { $0.persona == nil })
        let maskCopy = try #require(copies.first { $0.persona == persona.id })
        #expect(mainCopy.id != maskCopy.id && mainCopy.wireID == group.id && maskCopy.wireID == group.id)
        if shared {
            await until([phone, laptop]) {
                laptop.conversation(mainCopy.id)?.shared?.joining == false && laptop.conversation(maskCopy.id)?.shared?.joining == false
            }
        }

        laptop.send("from main", in: mainCopy.id)
        await until([phone, laptop]) {
            laptop.conversation(maskCopy.id)?.messages.contains { $0.text == "from main" } == true
                && phone.conversation(group.id)?.messages.contains { $0.text == "from main" } == true
        }
        #expect(laptop.conversation(maskCopy.id)?.messages.contains { $0.text == "from main" && !$0.isMine } == true, "the persona reads the main account")
        laptop.send("from mask", in: maskCopy.id)
        await until([phone, laptop]) {
            laptop.conversation(mainCopy.id)?.messages.contains { $0.text == "from mask" } == true
                && phone.conversation(group.id)?.messages.contains { $0.text == "from mask" } == true
        }
        #expect(laptop.conversation(mainCopy.id)?.messages.contains { $0.text == "from mask" && !$0.isMine } == true, "the main account reads the persona")
        #expect(phone.conversation(group.id)?.messages.filter { ["from main", "from mask"].contains($0.text) }.count == 2)
        phone.send("from phone", in: group.id)
        await until([phone, laptop]) {
            laptop.conversation(mainCopy.id)?.messages.contains { $0.text == "from phone" } == true
                && laptop.conversation(maskCopy.id)?.messages.contains { $0.text == "from phone" } == true
        }
        #expect(laptop.conversation(mainCopy.id)?.messages.contains { $0.text == "from phone" } == true)
        #expect(laptop.conversation(maskCopy.id)?.messages.contains { $0.text == "from phone" } == true)
        // A photo big enough to follow on its own reaches the other persona's copy whole.
        let photo = Self.bigPhoto()
        laptop.send("pic", image: photo, in: mainCopy.id)
        await until([phone, laptop]) { laptop.conversation(maskCopy.id)?.messages.contains { $0.text == "pic" && $0.image == photo } == true }
        #expect(laptop.conversation(maskCopy.id)?.messages.contains { $0.text == "pic" && $0.image == photo } == true, "the photo arrived")
        #expect(laptop.conversation(mainCopy.id)?.messages.first { $0.text == "pic" }?.image == photo, "the sender's copy keeps it")
        // Each copy keeps its own sent message as its own, and the other's as someone else's.
        #expect(laptop.conversation(mainCopy.id)?.messages.first { $0.text == "from main" }?.isMine == true)
        #expect(laptop.conversation(maskCopy.id)?.messages.first { $0.text == "from mask" }?.isMine == true)
    }

    private static func bigPhoto(side: Int = 400) -> Data {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let pixels = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * side)
        for i in 0..<(ctx.bytesPerRow * side) { pixels[i] = UInt8.random(in: 0...255) }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
